import Foundation

/**
 * Loads catalogues from the user's provider; the only place provider data is fetched. `.cache`
 * reads what was saved last time (nil if nothing yet); `.network` downloads afresh and replaces
 * the saved copy, but only once the new copy parses.
 */
enum Source { case cache, network }

struct XtreamSession {
    let server: URL
    let username: String
    let password: String
    let source: Source
    let scope: String

    init(server: String, username: String, password: String, source: Source) throws {
        self.server = try Xtream.serverURL(server)
        self.username = username
        self.password = password
        self.source = source
        scope = CatalogCache.scope("xtream", self.server.absoluteString, username)
    }

    func api(_ action: String? = nil, _ extra: [(String, String)] = []) -> URL {
        Xtream.apiURL(server, username, password, action: action, extra: extra)
    }

    /** Stream format for live channels; logging in when online (which also checks the account). */
    func format() async throws -> String? {
        if source == .cache { return CatalogCache.read(scope, "format").map { String(decoding: $0, as: UTF8.self) } }
        let acc = Xtream.account(try await HTTP.shared.json(api()))
        if !acc.authenticated { throw ProviderError("Login was rejected\(acc.status.map { " (status: \($0))" } ?? "").") }
        let format = Xtream.preferredFormat(acc.outputFormats)
        CatalogCache.write(scope, "format", Data(format.utf8))
        return format
    }

    func list<T>(_ action: String, extra: [(String, String)] = [], cacheName: String? = nil, _ parse: (Any) throws -> T) async throws -> T? {
        let name = cacheName ?? action
        if source == .cache {
            guard let saved = CatalogCache.read(scope, name) else { return nil }
            return try? parse(parseJSON(saved))
        }
        let data = try await HTTP.shared.data(api(action, extra))
        let parsed = try parse(parseJSON(data))
        CatalogCache.write(scope, name, data)
        return parsed
    }

    func categories(_ action: String) async throws -> [(id: String, name: String)]? {
        try await list(action, Xtream.categories)
    }

    /** Stream addresses for [kind] up to the file name. */
    func streamPrefix(_ kind: String) -> String { Xtream.streamPrefix(server, kind, username, password) }

    /**
     * One of the big lists (PLAYBACK.md, Lists), from its categories and streams. Saved: the
     * compact copy, or once, the raw copy an earlier version saved, converted. Fresh: nil when the
     * provider's answer hasn't changed since it was saved, so it isn't converted again.
     */
    func bigList<T>(_ name: String, categories: String, streams: String, also: Data = Data(),
                    unpack: (Data) -> [ItemGroup<T>]?, pack: ([ItemGroup<T>], String) -> Data,
                    build: ([(id: String, name: String)], Any) throws -> [ItemGroup<T>]) async throws -> [ItemGroup<T>]? {
        if source == .cache {
            if let saved = CatalogCache.read(scope, name) { return unpack(saved) }
            guard let c = CatalogCache.read(scope, categories), let s = CatalogCache.read(scope, streams),
                  let groups = try? autoreleasepool(invoking: { try build(Xtream.categories(parseJSON(c)), parseJSON(s)) }) else { return nil }
            CatalogCache.write(scope, name, pack(groups, ""))
            CatalogCache.delete(scope, streams)
            return groups
        }
        let c = try await HTTP.shared.data(api(categories))
        let s = try await HTTP.shared.data(api(streams))
        let fingerprint = Compact.fingerprint(also, c, s)
        if let saved = CatalogCache.readPrefix(scope, name), Compact.fingerprint(ofSaved: saved) == fingerprint { return nil }
        // The provider's answer as Foundation objects is several times its size: let it go straight after.
        let groups = try autoreleasepool { try build(Xtream.categories(parseJSON(c)), parseJSON(s)) }
        CatalogCache.write(scope, name, pack(groups, fingerprint))
        CatalogCache.delete(scope, streams)
        return groups
    }
}

enum Repo {
    private static func session(_ p: Provider, _ source: Source) throws -> XtreamSession? {
        guard case let .xtream(_, server, u, pw, _) = p else { return nil }
        return try XtreamSession(server: server, username: u, password: pw, source: source)
    }

    static func liveGroups(_ p: Provider, _ source: Source) async throws -> [ItemGroup<Channel>]? {
        var groups: [ItemGroup<Channel>]
        switch p {
        case .xtream:
            let x = try session(p, source)!
            // Saved, the format isn't needed: each channel's file name is in the compact copy.
            let format = source == .cache ? CatalogCache.read(x.scope, "format").map { String(decoding: $0, as: UTF8.self) } ?? "ts" : try await x.format()
            guard let format else { return nil }
            guard let fresh = try await x.bigList(
                "compact_live", categories: "get_live_categories", streams: "get_live_streams", also: Data(format.utf8),
                unpack: { Compact.unpackChannels($0, streamPrefix: x.streamPrefix("live")) }, pack: Compact.pack,
                build: { cats, root in
                    let map = Dictionary(cats.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                    let channels = try Xtream.liveChannels(x.server, x.username, x.password, format: format, cats: map, root)
                    return groupInOrder(channels, categoryOrder: cats.map(\.name)) { $0.group }
                }) else { return nil }
            groups = fresh
        case let .m3u(_, raw, _):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let scope = CatalogCache.scope("m3u", text)
            let data: Data?
            if source == .cache {
                data = CatalogCache.read(scope, "playlist")
            } else {
                guard let url = URL(string: text), url.scheme == "http" || url.scheme == "https" else {
                    throw ProviderError("That playlist address doesn't look right.")
                }
                data = try await HTTP.shared.data(url)
            }
            guard let data else { return nil }
            let channels = M3U.parse(String(decoding: data, as: UTF8.self))
            if source == .network && !channels.isEmpty { CatalogCache.write(scope, "playlist", data) }
            // First-seen order matches the playlist's own ordering.
            groups = groupInOrder(channels, categoryOrder: []) { $0.group }
        }
        if groups.isEmpty && source == .network { throw ProviderError("The provider returned no channels.") }
        return groups
    }

    /** Fresh, nil when unchanged since saved (as for every big list). */
    static func filmGroups(_ p: Provider, _ source: Source) async throws -> [ItemGroup<Channel>]? {
        guard let x = try session(p, source) else { return [] }
        return try await x.bigList(
            "compact_films", categories: "get_vod_categories", streams: "get_vod_streams",
            unpack: { Compact.unpackChannels($0, streamPrefix: x.streamPrefix("movie")) }, pack: Compact.pack,
            build: { cats, root in
                let map = Dictionary(cats.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                return groupInOrder(try Xtream.films(x.server, x.username, x.password, cats: map, root), categoryOrder: cats.map(\.name)) { $0.group }
            })
    }

    static func seriesGroups(_ p: Provider, _ source: Source) async throws -> [ItemGroup<Series>]? {
        guard let x = try session(p, source) else { return [] }
        return try await x.bigList(
            "compact_series", categories: "get_series_categories", streams: "get_series",
            unpack: Compact.unpackSeries, pack: Compact.pack,
            build: { cats, root in
                let map = Dictionary(cats.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                return groupInOrder(try Xtream.series(cats: map, root), categoryOrder: cats.map(\.name)) { $0.group }
            })
    }

    static func seriesData(_ p: Provider, _ series: Series, _ source: Source) async throws -> SeriesData? {
        guard let x = try session(p, source) else { return nil }
        return try await x.list("get_series_info", extra: [("series_id", series.id)], cacheName: "series_info_\(series.id)") {
            SeriesData(details: Xtream.details($0), seasons: Xtream.seasons(x.server, x.username, x.password, $0))
        }
    }

    static func filmDetails(_ p: Provider, _ film: Channel, _ source: Source) async throws -> Details? {
        guard let x = try session(p, source) else { return nil }
        return try await x.list("get_vod_info", extra: [("vod_id", film.id)], cacheName: "vod_info_\(film.id)", Xtream.details)
    }

    /** Checks a login before it's saved: Xtream logs in, M3U downloads the playlist. */
    static func verify(_ p: Provider) async throws {
        _ = try await liveGroups(p, .network)
    }
}
