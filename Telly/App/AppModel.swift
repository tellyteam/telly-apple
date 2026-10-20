import Foundation
import Observation

/** What the player is asked to play: a playlist (a live group or a season) and where to start. */
struct PlayRequest: Identifiable, Hashable {
    let id = UUID()
    var heading: String
    var live: Bool
    var items: [Channel]
    var index: Int
    var seriesId: String?
    var art: String?
    /** Start here (ms) instead of the saved position. */
    var startAt: Double?
}

struct Settings: Codable, Equatable {
    var autoNext = true
}

struct Meta: Codable, Equatable {
    var updatedAt: Double?
    /** Sync is hidden until unlocked (seven taps on the version in Settings). */
    var syncUnlocked: Bool?
}

/** Kept in the Keychain: the link code is the household's only secret. */
struct SyncConfig: Codable, Equatable {
    var code: String
    var device: String
    var relay: String
}

enum FavKind: String { case live, film, series }
func favKey(_ kind: FavKind, _ id: String) -> String { "\(kind.rawValue):\(id)" }

private func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

/** The whole app's state: provider, lists, progress, history, My List and sync. Mirrors the Mac app. */
@MainActor
@Observable
final class AppModel {
    static let defaultRelay = "https://telly-sync.tellyteam.workers.dev"
    /** Coming back to telly syncs at most this often. */
    private static let syncGapMs: Double = 60_000

    var ready = false
    var provider: Provider?
    var live: [ItemGroup<Channel>]?
    var films: [ItemGroup<Channel>]?
    var series: [ItemGroup<Series>]?
    var refreshing = false
    var loadError: String?
    var meta = Meta()

    var favourites: [String] = []
    var progress: [String: Progress] = [:]
    var history: [LastWatched] = []
    var settings = Settings()

    var player: PlayRequest?

    var sync: SyncConfig?
    var syncBusy = false
    var syncedAt: Double?
    var syncError: String?
    private var ledger = SyncLedger()

    @ObservationIgnored private var liveById: [String: Channel] = [:]
    @ObservationIgnored private var filmById: [String: Channel] = [:]
    @ObservationIgnored private var seriesById: [String: Series] = [:]
    @ObservationIgnored private var syncSoonTask: Task<Void, Never>?

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0" }

    // MARK: Start-up

    func start() async {
        favourites = Store.read("favourites", as: [String].self) ?? []
        progress = Store.read("progress", as: [String: Progress].self) ?? [:]
        history = Store.read("history", as: [LastWatched].self) ?? []
        settings = Store.read("settings", as: Settings.self) ?? Settings()
        meta = Store.read("meta", as: Meta.self) ?? Meta()
        ledger = Store.read("sync-ledger", as: SyncLedger.self) ?? SyncLedger()
        sync = Keychain.get("sync").flatMap { try? JSONDecoder().decode(SyncConfig.self, from: Data($0.utf8)) }
            .flatMap { SyncCrypto.normaliseCode($0.code) != nil && $0.relay.hasPrefix("https://") ? $0 : nil }
        guard let p = Keychain.get("provider").flatMap({ try? JSONDecoder().decode(Provider.self, from: Data($0.utf8)) }) else {
            ready = true
            return
        }
        await use(p)
        ready = true
    }

    /** Shows the saved lists straight away, then refreshes them in the background. */
    private func use(_ p: Provider) async {
        provider = p
        HTTP.shared.allowCleartext = p.allowCleartext
        async let l = try? Repo.liveGroups(p, .cache)
        async let f = try? Repo.filmGroups(p, .cache)
        async let s = try? Repo.seriesGroups(p, .cache)
        setCatalogues(await l ?? nil, await f ?? nil, await s ?? nil)
        Task {
            await refresh()
            await syncNow()
        }
    }

    private func setCatalogues(_ l: [ItemGroup<Channel>]?, _ f: [ItemGroup<Channel>]?, _ s: [ItemGroup<Series>]?) {
        if let l {
            live = l
            liveById = Dictionary(l.flatMap { $0.items.map { ($0.id, $0) } }, uniquingKeysWith: { a, _ in a })
        }
        if let f {
            films = f
            filmById = Dictionary(f.flatMap { $0.items.map { ($0.id, $0) } }, uniquingKeysWith: { a, _ in a })
        }
        if let s {
            series = s
            seriesById = Dictionary(s.flatMap { $0.items.map { ($0.id, $0) } }, uniquingKeysWith: { a, _ in a })
        }
        searchIndex = nil
    }

    func refresh() async {
        guard let p = provider, !refreshing else { return }
        refreshing = true
        loadError = nil
        async let l = Result.of { try await Repo.liveGroups(p, .network) }
        async let f = Result.of { try await Repo.filmGroups(p, .network) }
        async let s = Result.of { try await Repo.seriesGroups(p, .network) }
        let (lr, fr, sr) = await (l, f, s)
        guard provider == p else { return }
        setCatalogues(try? lr.get(), try? fr.get(), try? sr.get())
        let failure = [lr.failure, fr.failure, sr.failure].compactMap { $0 }.first
        if let failure {
            // Only an error worth a screen when there's nothing saved to show instead.
            if live == nil { loadError = failure.localizedDescription }
        } else {
            meta.updatedAt = nowMs()
            Store.write("meta", meta)
        }
        refreshing = false
    }

    // MARK: Provider

    func saveProvider(_ p: Provider) async throws {
        HTTP.shared.allowCleartext = p.allowCleartext
        try await Repo.verify(p)
        Keychain.set("provider", String(decoding: try JSONEncoder().encode(p), as: UTF8.self))
        live = nil; films = nil; series = nil
        await use(p)
    }

    func signOut() {
        Keychain.delete("provider")
        // History holds stream URLs, which carry the login.
        history = []
        Store.delete("history")
        CatalogCache.clearAll()
        provider = nil
        live = nil; films = nil; series = nil
    }

    func setAllowCleartext(_ allow: Bool) {
        guard let p = provider?.with(allowCleartext: allow) else { return }
        Keychain.set("provider", String(decoding: (try? JSONEncoder().encode(p)) ?? Data(), as: UTF8.self))
        provider = p
        HTTP.shared.allowCleartext = allow
    }

    func clearSavedData() async {
        CatalogCache.clearAll()
        meta.updatedAt = nil
        Store.write("meta", meta)
        await refresh()
    }

    // MARK: Lookups

    func liveChannel(_ id: String) -> Channel? { liveById[id] }
    func film(_ id: String) -> Channel? { filmById[id] }
    func seriesItem(_ id: String) -> Series? { seriesById[id] }

    @ObservationIgnored private var searchIndex: (live: [(String, Channel)], films: [(String, Channel)], series: [(String, Series)])?

    private static func normalise(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    func search(_ query: String, limit: Int = 40) -> (live: [Channel], films: [Channel], series: [Series]) {
        let q = Self.normalise(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return ([], [], []) }
        if searchIndex == nil {
            searchIndex = (
                (live ?? []).flatMap(\.items).map { (Self.normalise($0.name), $0) },
                (films ?? []).flatMap(\.items).map { (Self.normalise($0.name), $0) },
                (series ?? []).flatMap(\.items).map { (Self.normalise($0.name), $0) }
            )
        }
        func find<T>(_ list: [(String, T)]) -> [T] {
            // Names that start with the query first, then any that contain it.
            var starts: [T] = [], contains: [T] = []
            for (name, item) in list {
                if name.hasPrefix(q) || name.contains(" \(q)") { starts.append(item) } else if name.contains(q) { contains.append(item) }
                if starts.count >= limit { break }
            }
            return Array((starts + contains).prefix(limit))
        }
        return (find(searchIndex!.live), find(searchIndex!.films), find(searchIndex!.series))
    }

    /** Newest first, across every category. */
    func recentlyAdded(films n: Int = 24) -> [Channel] {
        Array((films ?? []).flatMap(\.items).filter { $0.added > 0 }.sorted { $0.added > $1.added }.prefix(n))
    }

    func recentlyUpdatedSeries(_ n: Int = 24) -> [Series] {
        Array((series ?? []).flatMap(\.items).filter { $0.added > 0 }.sorted { $0.added > $1.added }.prefix(n))
    }

    /** The live group a channel belongs to, for zapping. */
    func liveGroup(of c: Channel) -> [Channel] { live?.first { $0.name == c.group }?.items ?? [c] }

    // MARK: My List

    func isFavourite(_ kind: FavKind, _ id: String) -> Bool { favourites.contains(favKey(kind, id)) }

    func toggleFavourite(_ kind: FavKind, _ id: String) {
        let key = favKey(kind, id)
        let on = !favourites.contains(key)
        favourites = on ? [key] + favourites : favourites.filter { $0 != key }
        Store.write("favourites", favourites)
        ledger.list[key] = .init(at: nowMs(), on: on)
        Store.write("sync-ledger", ledger)
        syncSoon()
    }

    func favouriteItems() -> (live: [Channel], films: [Channel], series: [Series]) {
        var l: [Channel] = [], f: [Channel] = [], s: [Series] = []
        for key in favourites {
            guard let colon = key.firstIndex(of: ":") else { continue }
            let kind = key[..<colon], id = String(key[key.index(after: colon)...])
            switch kind {
            case "live": if let c = liveById[id] { l.append(c) }
            case "film": if let c = filmById[id] { f.append(c) }
            case "series": if let x = seriesById[id] { s.append(x) }
            default: break
            }
        }
        return (l, f, s)
    }

    // MARK: Progress and history

    func progressOf(_ url: String) -> Progress? { progress[Playback.progressKey(url)] }

    func saveProgress(_ url: String, position: Double, duration: Double) {
        guard duration > 0, duration.isFinite else { return }
        progress[Playback.progressKey(url)] = Progress(position: min(max(position, 0), duration).rounded(), duration: duration.rounded(), at: nowMs())
        Store.write("progress", progress)
    }

    func seriesHistory(_ seriesId: String) -> LastWatched? { history.first { $0.seriesId == seriesId } }

    func play(_ req: PlayRequest) {
        player = req
        recordWatching(req, index: req.index)
    }

    /** Called when playback starts and on every episode change, so "pick up" always lands right. */
    func recordWatching(_ req: PlayRequest, index: Int) {
        history = history.remembering(LastWatched(heading: req.heading, live: req.live, index: index, items: req.items,
                                                  seriesId: req.seriesId, art: req.art, at: nowMs()))
        Store.write("history", history)
    }

    /** Plays a history entry: the next episode if the last one reached its credits. */
    func resume(_ h: LastWatched) {
        play(PlayRequest(heading: h.heading, live: h.live, items: h.items, index: h.continueIndex(progressOf), seriesId: h.seriesId, art: h.art))
    }

    func removeFromHistory(_ h: LastWatched) {
        history.removeAll { $0.slot == h.slot }
        Store.write("history", history)
        ledger.removed[h.slot] = nowMs()
        Store.write("sync-ledger", ledger)
        syncSoon()
    }

    /** Forgets every position and Continue watching (My List stays). With sync on, on every linked device too. */
    func clearProgress() {
        progress = [:]
        history = []
        ledger.removed = [:]
        ledger.cleared = nowMs()
        Store.write("progress", progress)
        Store.write("history", history)
        Store.write("sync-ledger", ledger)
        Task { await syncNow(force: true) }
    }

    /** Leaving the player shares what was watched. */
    func closePlayer() {
        player = nil
        Task { await syncNow(force: true) }
    }

    func saveSettings() { Store.write("settings", settings) }

    // MARK: Plays

    func playChannel(_ c: Channel, in group: [Channel]? = nil) {
        let items = group ?? liveGroup(of: c)
        play(PlayRequest(heading: Playback.liveHeading, live: true, items: items, index: max(0, items.firstIndex { $0.id == c.id } ?? 0)))
    }

    func playFilm(_ f: Channel, fromStart: Bool = false) {
        play(PlayRequest(heading: Playback.film, live: false, items: [f], index: 0, art: f.logo, startAt: fromStart ? 0 : nil))
    }

    func playEpisode(_ s: Series, _ episodes: [Channel], _ index: Int, fromStart: Bool = false) {
        play(PlayRequest(heading: s.name, live: false, items: episodes, index: index, seriesId: s.id, art: s.cover, startAt: fromStart ? 0 : nil))
    }

    // MARK: Sync

    /** Sync is a hidden feature for now: Settings shows it once unlocked, or while this iPad is linked. */
    var syncShown: Bool { meta.syncUnlocked == true || sync != nil }

    /** Shows or hides Settings → Sync; returns whether it's now shown. Hiding never unlinks. */
    func toggleSyncUnlocked() -> Bool {
        meta.syncUnlocked = !syncShown || sync != nil
        Store.write("meta", meta)
        return syncShown
    }

    /** Starts a new household with a fresh code, or joins one with [code]. Throws a readable error. */
    func startSync(code: String?, relay: String = AppModel.defaultRelay) async throws {
        guard let normal = code.map(SyncCrypto.normaliseCode) ?? SyncCrypto.newCode() else {
            throw SyncError(message: "That code isn't right: it's 16 letters and numbers, like ABCD-EFGH-JKMN-PQRS.")
        }
        var address = relay.trimmingCharacters(in: .whitespaces)
        while address.hasSuffix("/") { address.removeLast() }
        guard address.hasPrefix("https://") else { throw SyncError(message: "The relay address must start with https://") }
        let config = SyncConfig(code: normal, device: sync?.device ?? SyncCrypto.newDeviceId(), relay: address)
        Keychain.set("sync", String(decoding: try JSONEncoder().encode(config), as: UTF8.self))
        sync = config
        syncedAt = nil
        await syncNow(force: true)
        if let error = syncError {
            Keychain.delete("sync")
            sync = nil
            throw SyncError(message: error)
        }
    }

    /** Takes this iPad out of sync: its copy leaves the relay; the other devices keep theirs. */
    func stopSync() async {
        guard let config = sync else { return }
        Keychain.delete("sync")
        sync = nil
        syncError = nil
        syncedAt = nil
        try? await SyncClient.leave(config.relay, SyncCrypto.deriveKeys(config.code), device: config.device)
    }

    /** After small changes (My List, removals): soon, but once for a burst of them. */
    private func syncSoon() {
        syncSoonTask?.cancel()
        syncSoonTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { await syncNow(force: true) }
        }
    }

    /** Coming back to the front. */
    func becameActive() {
        Task { await syncNow() }
    }

    /** Fetches the other devices' changes, takes in what's newer and shares the result. Never during playback. */
    func syncNow(force: Bool = false) async {
        guard let config = sync, !syncBusy, player == nil else { return }
        if !force, let at = syncedAt, nowMs() - at < Self.syncGapMs { return }
        syncBusy = true
        syncError = nil
        defer { syncBusy = false }
        do {
            let now = nowMs()
            let local = SyncLocal.Local(progress: progress, history: history, favourites: favourites, ledger: ledger)
            let merged = try await SyncClient.syncOnce(config.relay, SyncCrypto.deriveKeys(config.code), device: config.device,
                                                       own: SyncLocal.toParcel(local, now: now), now: now)
            guard sync == config else { return }
            let next = await SyncLocal.apply(local, merged) { await self.resolve($0) }
            // Playback may have started meanwhile; its own saves win.
            guard player == nil else { return }
            progress = next.progress
            history = next.history
            favourites = next.favourites
            ledger = next.ledger
            Store.write("progress", progress)
            Store.write("history", history)
            Store.write("favourites", favourites)
            Store.write("sync-ledger", ledger)
            syncedAt = nowMs()
        } catch {
            syncError = (error as? SyncError)?.message ?? "Couldn't reach the sync relay."
        }
    }

    /** A shared history entry as one this iPad can play, from its own lists and login. */
    private func resolve(_ e: SyncEntry) async -> LastWatched? {
        switch e.kind {
        case .film:
            guard let f = film(e.id) else { return nil }
            return LastWatched(heading: Playback.film, live: false, index: 0, items: [f], art: f.logo, at: e.at)
        case .live:
            guard let c = liveChannel(e.id) else { return nil }
            let items = liveGroup(of: c)
            return LastWatched(heading: Playback.liveHeading, live: true, index: max(0, items.firstIndex { $0.id == c.id } ?? 0), items: items, at: e.at)
        case .series:
            guard let sid = e.series, let s = seriesItem(sid), let p = provider else { return nil }
            var data = try? await Repo.seriesData(p, s, .cache)
            if data == nil { data = try? await Repo.seriesData(p, s, .network) }
            for season in data?.seasons ?? [] {
                if let i = season.episodes.firstIndex(where: { $0.id == e.id }) {
                    return LastWatched(heading: s.name, live: false, index: i, items: season.episodes, seriesId: s.id, art: s.cover, at: e.at)
                }
            }
            return nil
        }
    }
}

private extension Result where Failure == Error {
    static func of(_ body: () async throws -> Success) async -> Result {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
    var failure: Error? { if case let .failure(e) = self { return e }; return nil }
}

/** "2 hours ago" style. */
func ago(_ ms: Double?, now: Double = Date().timeIntervalSince1970 * 1000) -> String {
    guard let ms else { return "never" }
    let m = Int(((now - ms) / 60_000).rounded())
    if m < 1 { return "just now" }
    if m < 60 { return "\(m) min ago" }
    let h = Int((Double(m) / 60).rounded())
    if h < 24 { return "\(h) hour\(h == 1 ? "" : "s") ago" }
    let d = Int((Double(h) / 24).rounded())
    return "\(d) day\(d == 1 ? "" : "s") ago"
}
