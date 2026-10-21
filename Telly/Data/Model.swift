import Foundation

/** Where the lists come from. The login never leaves the iPad except to this provider. */
enum Provider: Codable, Equatable {
    case xtream(name: String, server: String, username: String, password: String, allowCleartext: Bool)
    case m3u(name: String, url: String, allowCleartext: Bool)

    var name: String {
        switch self {
        case let .xtream(name, _, _, _, _), let .m3u(name, _, _): return name
        }
    }

    var allowCleartext: Bool {
        switch self {
        case let .xtream(_, _, _, _, allow), let .m3u(_, _, allow): return allow
        }
    }

    var isXtream: Bool {
        if case .xtream = self { return true }
        return false
    }

    /**
     * Who this provider is, for its sync tag (telly-sync PROTOCOL.md, "Provider tag"): the kind,
     * the normalised server and the username, or the playlist URL. Never sent anywhere as it is.
     */
    var syncIdentity: String {
        switch self {
        case let .xtream(_, server, username, _, _): return "xtream\n\(Provider.normaliseServer(server))\n\(username)"
        case let .m3u(_, url, _): return "m3u\n\(url.trimmingCharacters(in: .whitespaces))"
        }
    }

    /** ` Example.com:8080/ ` → `http://example.com:8080`, as the sync protocol defines it. */
    static func normaliseServer(_ server: String) -> String {
        var s = server.trimmingCharacters(in: .whitespaces).lowercased()
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        for (scheme, port) in [("http://", ":80"), ("https://", ":443")] where s.hasPrefix(scheme) {
            let rest = s.dropFirst(scheme.count)
            let host = rest.prefix { $0 != "/" }
            if host.hasSuffix(port) { s = scheme + host.dropLast(port.count) + rest.dropFirst(host.count) }
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    func with(allowCleartext allow: Bool) -> Provider {
        switch self {
        case let .xtream(n, s, u, p, _): return .xtream(name: n, server: s, username: u, password: p, allowCleartext: allow)
        case let .m3u(n, url, _): return .m3u(name: n, url: url, allowCleartext: allow)
        }
    }
}

/** Anything the player can play: a live channel, a film or a series episode. */
struct Channel: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var group: String
    /** Channel logo, film poster or episode still. */
    var logo: String?
    var url: String
    /** XMLTV channel id (live channels only). */
    var epgId: String?
    /** When the provider added it (epoch seconds; 0 if unknown), for "Recently added". */
    var added: Double = 0
    /** Episodes only. */
    var plot: String?
    var runtime: String?
}

struct Series: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var group: String
    var cover: String?
    var plot: String?
    var added: Double = 0
}

struct ItemGroup<T: Hashable>: Hashable, Identifiable {
    var name: String
    var items: [T]
    var id: String { name }
}

struct Season: Hashable, Identifiable {
    var name: String
    var episodes: [Channel]
    var id: String { name }
}

/** Extra information for a detail page; every field is optional because panels vary. */
struct Details: Hashable {
    var plot: String?
    var genre: String?
    var year: String?
    /** Already formatted, e.g. "7.4". */
    var rating: String?
    /** Already formatted, e.g. "1h 52m". */
    var runtime: String?
    var cast: String?
    var backdrop: String?
}

struct SeriesData: Hashable {
    var details: Details
    var seasons: [Season]
}

let uncategorised = "Uncategorised"
let defaultProviderName = "Your provider"

/**
 * Groups [items] in the provider's category order (which providers curate), then any categories
 * it didn't list, keeping each group's items in their original order.
 */
func groupInOrder<T: Hashable>(_ items: [T], categoryOrder: [String], groupOf: (T) -> String) -> [ItemGroup<T>] {
    var byGroup: [String: [T]] = [:]
    var seen: [String] = []
    for item in items {
        let g = groupOf(item)
        if byGroup[g] == nil { seen.append(g) }
        byGroup[g, default: []].append(item)
    }
    var ordered: [String] = []
    for name in categoryOrder + seen where byGroup[name] != nil && !ordered.contains(name) { ordered.append(name) }
    return ordered.map { ItemGroup(name: $0, items: byGroup[$0]!) }
}

/** Thrown with a message that's safe to show: never a URL (Xtream URLs carry the login). */
struct ProviderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
