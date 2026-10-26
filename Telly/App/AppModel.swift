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
    /** The saved provider in use ([SavedProvider.id]). */
    var activeProvider: String?
}

/** A provider the user has added. [id] is local: it files the provider's own records on this device. */
struct SavedProvider: Codable, Identifiable, Equatable {
    var id: String
    var provider: Provider
    /** When it was added or last edited here (whole ms). */
    var changedAt: Double?
}

struct PendingLink: Identifiable, Equatable {
    let code: String
    var id: String { code }
}

/** Kept in the Keychain: the link code is the household's only secret. */
struct SyncConfig: Codable, Equatable {
    var code: String
    var device: String
    var relay: String
}

enum FavKind: String { case live, film, series }
func favKey(_ kind: FavKind, _ id: String) -> String { "\(kind.rawValue):\(id)" }

/** Whole milliseconds: the sync format, and the other apps, use integers. */
private func nowMs() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

/** The whole app's state: provider, lists, progress, history, My List and sync. Mirrors the LG app (telly-lg). */
@MainActor
@Observable
final class AppModel {
    /** telly's relay: sync always uses it (a link saved with another one is moved to it). */
    nonisolated static let relay = "https://telly-sync.tellyteam.workers.dev"
    /** Coming back to telly syncs at most this often. */
    private static let syncGapMs: Double = 60_000

    var ready = false
    /** Every provider added on this device; [provider] is the one in use. */
    var providers: [SavedProvider] = []
    var provider: Provider?
    /** The [SavedProvider.id] of [provider]. */
    var activeId: String?
    var live: [ItemGroup<Channel>]?
    var films: [ItemGroup<Channel>]?
    var series: [ItemGroup<Series>]?
    var refreshing = false
    @ObservationIgnored private var refreshingFor: Provider?
    var loadError: String?
    var meta = Meta()

    var favourites: [String] = []
    var progress: [String: Progress] = [:]
    var history: [LastWatched] = []
    var settings = Settings()

    var player: PlayRequest?
    /** The page the sidebar shows (also chosen from the Mac's menu bar). */
    var page: Page? = .home

    var sync: SyncConfig?
    /** A sync link opened from a QR code, waiting for the user to confirm. */
    var pendingLink: PendingLink?
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
        settings = Store.read("settings", as: Settings.self) ?? Settings()
        meta = Store.read("meta", as: Meta.self) ?? Meta()
        sync = Keychain.get("sync").flatMap { try? JSONDecoder().decode(SyncConfig.self, from: Data($0.utf8)) }
            .flatMap { SyncCrypto.normaliseCode($0.code) != nil ? SyncConfig(code: $0.code, device: $0.device, relay: Self.relay) : nil }
        providers = loadProviders()
        guard let active = providers.first(where: { $0.id == meta.activeProvider }) ?? providers.first else {
            #if DEBUG
            await DevHooks.signIn(self)
            #endif
            ready = true
            return
        }
        await activate(active)
        ready = true
    }

    // MARK: Saved providers

    private static func newProviderId() -> String { SyncCrypto.hex(SyncCrypto.randomBytes(6)) }

    /** The saved providers. Before there could be several, the one provider and its records were
     *  kept unscoped: they become the first saved provider's. */
    private func loadProviders() -> [SavedProvider] {
        if let text = Keychain.get("providers"), let list = try? JSONDecoder().decode([SavedProvider].self, from: Data(text.utf8)) {
            // Sharing logins between devices was removed: forget what it kept.
            Store.delete("login-ledger")
            return list
        }
        guard let old = Keychain.get("provider").flatMap({ try? JSONDecoder().decode(Provider.self, from: Data($0.utf8)) }) else { return [] }
        let saved = SavedProvider(id: Self.newProviderId(), provider: old, changedAt: nowMs())
        Records.move(from: nil, to: saved.id)
        saveProviders([saved])
        Keychain.delete("provider")
        meta.activeProvider = saved.id
        Store.write("meta", meta)
        return [saved]
    }

    private func saveProviders(_ list: [SavedProvider]) {
        providers = list
        Keychain.set("providers", String(decoding: (try? JSONEncoder().encode(list)) ?? Data("[]".utf8), as: UTF8.self))
    }

    /** Makes [saved] the provider in use: its records, then its lists (saved ones straight away). */
    private func activate(_ saved: SavedProvider) async {
        let r = Records.load(saved.id)
        (favourites, progress, history, ledger) = (r.favourites, r.progress, r.history, r.ledger)
        activeId = saved.id
        meta.activeProvider = saved.id
        Store.write("meta", meta)
        live = nil; films = nil; series = nil
        setCatalogues(nil, nil, nil)
        await use(saved.provider)
    }

    /** Switches to another saved provider. Not while something plays. */
    func switchProvider(_ id: String) async {
        guard id != activeId, player == nil, let saved = providers.first(where: { $0.id == id }) else { return }
        page = .home
        await activate(saved)
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
        guard let p = provider, refreshingFor != p else { return }
        // A refresh for the provider switched away from may still be running; this one replaces it.
        refreshing = true
        refreshingFor = p
        defer { if refreshingFor == p { refreshing = false; refreshingFor = nil } }
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
        await checkForNewEpisodes()
    }

    // MARK: Provider

    /** Checks [p] with the provider, then saves it: in place of [editing], or as a new provider
     *  that becomes the one in use. Throws a readable error. */
    func saveProvider(_ p: Provider, editing: String? = nil) async throws {
        if providers.contains(where: { $0.id != editing && $0.provider.syncIdentity == p.syncIdentity }) {
            throw ProviderError("You've already added this provider.")
        }
        HTTP.shared.allowCleartext = p.allowCleartext
        do {
            try await Repo.verify(p)
        } catch {
            if let current = provider { HTTP.shared.allowCleartext = current.allowCleartext }
            throw error
        }
        var list = providers
        let saved: SavedProvider
        if let editing, let i = list.firstIndex(where: { $0.id == editing }) {
            // A new server or login means new lists: the old ones go.
            if list[i].provider.syncIdentity != p.syncIdentity {
                CatalogCache.clear(for: list[i].provider)
            }
            list[i].provider = p
            list[i].changedAt = nowMs()
            saved = list[i]
        } else {
            saved = SavedProvider(id: Self.newProviderId(), provider: p, changedAt: nowMs())
            list.append(saved)
        }
        saveProviders(list)
        if saved.id == activeId {
            live = nil; films = nil; series = nil
            await use(p)
        } else if editing == nil {
            // A new provider comes into use; editing another one leaves the one in use alone.
            page = .home
            await activate(saved)
        }
    }

    /** Removes a provider from this device, with its lists and everything watched with it. */
    func removeProvider(_ id: String) async {
        guard let gone = providers.first(where: { $0.id == id }), player == nil else { return }
        saveProviders(providers.filter { $0.id != id })
        // Its history holds stream URLs, which carry the login.
        Records.delete(id)
        CatalogCache.clear(for: gone.provider)
        Downloads.shared.removeAll(providerId: id)
        guard id == activeId else { return }
        if let next = providers.first {
            page = .home
            await activate(next)
        } else {
            (favourites, progress, history, ledger) = ([], [:], [], SyncLedger())
            activeId = nil
            meta.activeProvider = nil
            Store.write("meta", meta)
            provider = nil
            live = nil; films = nil; series = nil
        }
    }

    func setAllowCleartext(_ allow: Bool) {
        guard let p = provider?.with(allowCleartext: allow), let id = activeId,
              let i = providers.firstIndex(where: { $0.id == id }) else { return }
        var list = providers
        list[i].provider = p
        list[i].changedAt = nowMs()
        saveProviders(list)
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
        keep("favourites", favourites)
        ledger.list[key] = .init(at: nowMs(), on: on)
        keep("sync-ledger", ledger)
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
        let p = Progress(position: min(max(position, 0), duration).rounded(), duration: duration.rounded(), at: nowMs())
        progress[Playback.progressKey(url)] = p
        if p.finished { Downloads.shared.watched(activeId, url) }
        keep("progress", progress)
    }

    /** Continue watching: history with something left to watch (PLAYBACK.md). */
    var continueWatching: [LastWatched] {
        history.filter { $0.shownInContinue(progressOf) }
    }

    func seriesHistory(_ seriesId: String) -> LastWatched? { history.first { $0.seriesId == seriesId } }

    func play(_ req: PlayRequest) {
        Downloads.shared.watching = true
        player = req
        recordWatching(req, index: req.index)
    }

    /** Called when playback starts and on every episode change, so "pick up" always lands right. */
    func recordWatching(_ req: PlayRequest, index: Int) {
        history = history.remembering(LastWatched(heading: req.heading, live: req.live, index: index, items: req.items,
                                                  seriesId: req.seriesId, art: req.art, at: nowMs()))
        keep("history", history)
    }

    /** Plays a history entry: the next episode if the last one reached its credits. */
    func resume(_ h: LastWatched) {
        play(PlayRequest(heading: h.heading, live: h.live, items: h.items, index: h.continueIndex(progressOf), seriesId: h.seriesId, art: h.art))
    }

    func removeFromHistory(_ h: LastWatched) {
        history.removeAll { $0.slot == h.slot }
        keep("history", history)
        ledger.removed[h.slot] = nowMs()
        keep("sync-ledger", ledger)
        syncSoon()
    }

    /** Forgets every position and Continue watching (My List stays). With sync on, on every linked device too. */
    func clearProgress() {
        progress = [:]
        history = []
        ledger.removed = [:]
        ledger.cleared = nowMs()
        keep("progress", progress)
        keep("history", history)
        keep("sync-ledger", ledger)
        Task { await syncNow(force: true) }
    }

    /** Leaving the player shares what was watched, and looks for new episodes of anything finished. */
    func closePlayer() {
        player = nil
        Downloads.shared.watching = false
        Task {
            await syncNow(force: true)
            await checkForNewEpisodes()
        }
    }

    // MARK: New episodes

    @ObservationIgnored private var checkingEpisodes = false

    /**
     * Brings back series watched to the end of what they had, once the provider adds more: at the
     * next episode, marked "New episodes" when they arrived after it was watched. Each series is
     * only fetched again after the provider has changed it (PLAYBACK.md).
     */
    func checkForNewEpisodes() async {
        guard let p = provider, let id = activeId, !checkingEpisodes, series != nil else { return }
        checkingEpisodes = true
        defer { checkingEpisodes = false }
        var checks = Store.read("episode-checks-\(id)", as: [String: NewEpisodes.Check].self) ?? [:]
        for entry in history where !entry.live && !entry.isFilm && !entry.shownInContinue(progressOf) {
            guard let sid = entry.seriesId, let show = seriesById[sid],
                  NewEpisodes.due(show, checked: checks[sid], now: nowMs()),
                  let data = try? await Repo.seriesData(p, show, .network), provider == p else { continue }
            checks[sid] = NewEpisodes.Check(added: show.added, at: nowMs())
            guard let (season, i) = NewEpisodes.after(data.seasons, entry.current.id) else { continue }
            // Never moved to the front: Continue watching leads with what was last watched.
            var back = entry
            back.items = season.episodes
            back.index = i
            back.newEpisodes = NewEpisodes.isNew(show, watchedAt: entry.at)
            history = history.map { $0.slot == entry.slot ? back : $0 }
            keep("history", history)
        }
        Store.write("episode-checks-\(id)", checks)
    }

    func saveSettings() { Store.write("settings", settings) }

    /** Saves one of the active provider's records. */
    private func keep<T: Encodable>(_ base: String, _ value: T) {
        guard let id = activeId else { return }
        Store.write(Records.name(base, id), value)
    }

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

    /** A `telly://sync` link (from the Camera app or the in-app scanner): asks before linking. */
    func open(_ url: URL) {
        guard let code = SyncLink.parse(url.absoluteString) else { return }
        if sync?.code == code { return }
        pendingLink = PendingLink(code: code)
    }

    /** Links with a confirmed QR code; scanning one also shows Settings → Sync from then on. */
    func confirmPendingLink() async throws {
        guard let link = pendingLink else { return }
        pendingLink = nil
        meta.syncUnlocked = true
        Store.write("meta", meta)
        try await startSync(code: link.code)
    }

    /** Starts a new household with a fresh code, or joins one with [code]. Throws a readable error. */
    func startSync(code: String?) async throws {
        guard let normal = code.map(SyncCrypto.normaliseCode) ?? SyncCrypto.newCode() else {
            throw SyncError(message: "That code isn't right: it's 16 letters and numbers, like ABCD-EFGH-JKMN-PQRS.")
        }
        let config = SyncConfig(code: normal, device: sync?.device ?? SyncCrypto.newDeviceId(), relay: Self.relay)
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

    /**
     * Fetches the other devices' changes, takes in what's newer and shares the result: a section for
     * each saved provider, matched to other devices' by provider tag. The provider in use takes in
     * everything; the others take in progress, My List and removals now, and Continue watching
     * when they're next in use (resolving it needs their lists). Never during playback.
     */
    func syncNow(force: Bool = false) async {
        guard let config = sync, !syncBusy, player == nil else { return }
        // Without a provider there's nothing to sync.
        guard activeId != nil else { return }
        if !force, let at = syncedAt, nowMs() - at < Self.syncGapMs { return }
        syncBusy = true
        syncError = nil
        defer { syncBusy = false }
        do {
            let now = nowMs()
            let keys = SyncCrypto.deriveKeys(config.code)
            var locals: [String: (id: String, local: SyncLocal.Local)] = [:]
            for saved in providers {
                let tag = SyncCrypto.providerTag(keys, identity: saved.provider.syncIdentity)
                let r = saved.id == activeId ? Records.Set(favourites: favourites, progress: progress, history: history, ledger: ledger)
                                             : Records.load(saved.id)
                locals[tag] = (saved.id, SyncLocal.Local(progress: r.progress, history: r.history, favourites: r.favourites, ledger: r.ledger))
            }
            // A version 1 parcel doesn't say whose it is, so it's read as this device's provider only
            // when there's just the one. With several, it's read as nothing: taken as the provider in
            // use, a Fire TV's My List would turn up under every provider switched to.
            let current = providers.count == 1 ? locals.first(where: { $0.value.id == activeId })?.key ?? "0000000000000000" : "0000000000000000"
            let own = SyncBundle(at: now, sections: locals.mapValues { SyncLocal.toParcel($0.local, now: now) })
            let merged = try await SyncClient.syncOnce(config.relay, keys, device: config.device, own: own, current: current, now: now)
            guard sync == config else { return }
            for (tag, entry) in locals {
                guard let section = merged.sections[tag] else { continue }
                let isActive = entry.id == activeId
                let next = await SyncLocal.apply(entry.local, section) { isActive ? await self.resolve($0) : nil }
                let r = Records.Set(favourites: next.favourites, progress: next.progress, history: next.history, ledger: next.ledger)
                if !isActive {
                    if providers.contains(where: { $0.id == entry.id }) { Records.save(entry.id, r) }
                    continue
                }
                // Playback (or a switch of provider) may have started meanwhile; its own saves win.
                guard player == nil, entry.id == self.activeId else { continue }
                (progress, history, favourites, ledger) = (r.progress, r.history, r.favourites, r.ledger)
                Records.save(entry.id, r)
            }
            syncedAt = nowMs()
        } catch {
            syncError = (error as? SyncError)?.message ?? "Couldn't reach the sync relay."
        }
    }

    /** A shared history entry as one this device can play, from its own lists and login. */
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
