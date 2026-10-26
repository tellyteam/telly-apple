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
            guard let format = try await x.format(), let cats = try await x.categories("get_live_categories") else { return nil }
            let map = Dictionary(cats.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            guard let channels = try await x.list("get_live_streams", { try Xtream.liveChannels(x.server, x.username, x.password, format: format, cats: map, $0) })
            else { return nil }
            groups = groupInOrder(channels, categoryOrder: cats.map(\.name)) { $0.group }
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

    static func filmGroups(_ p: Provider, _ source: Source) async throws -> [ItemGroup<Channel>]? {
        guard let x = try session(p, source) else { return [] }
        guard let cats = try await x.categories("get_vod_categories") else { return nil }
        let map = Dictionary(cats.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        guard let films = try await x.list("get_vod_streams", { try Xtream.films(x.server, x.username, x.password, cats: map, $0) }) else { return nil }
        return groupInOrder(films, categoryOrder: cats.map(\.name)) { $0.group }
    }

    static func seriesGroups(_ p: Provider, _ source: Source) async throws -> [ItemGroup<Series>]? {
        guard let x = try session(p, source) else { return [] }
        guard let cats = try await x.categories("get_series_categories") else { return nil }
        let map = Dictionary(cats.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        guard let series = try await x.list("get_series", { try Xtream.series(cats: map, $0) }) else { return nil }
        return groupInOrder(series, categoryOrder: cats.map(\.name)) { $0.group }
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
