import Foundation

/**
 * Parsing for the Xtream Codes `player_api.php` API. Panels are inconsistent about numbers versus
 * strings and nulls, so every field is read leniently. Mirrors telly-lg's xtream.ts.
 */
enum Xtream {
    typealias Obj = [String: Any]

    /** A JSON string or number as trimmed text; anything else is nil. */
    static func str(_ v: Any?) -> String? {
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            guard d.isFinite else { return nil }
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        }
        return nil
    }

    // MARK: URLs

    /** Accepts `host:port`, `http://host:port/` and so on; defaults to HTTPS when no scheme is given. */
    static func serverURL(_ input: String) throws -> URL {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        let text = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var c = URLComponents(string: text), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty
        else { throw ProviderError("That server address doesn't look right.") }
        if !c.path.hasSuffix("/") { c.path += "/" }
        guard let url = c.url else { throw ProviderError("That server address doesn't look right.") }
        return url
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }

    static func apiURL(_ server: URL, _ username: String, _ password: String, action: String? = nil, extra: [(String, String)] = []) -> URL {
        var params = [("username", username), ("password", password)]
        if let action { params.append(("action", action)) }
        params += extra
        // Spaces as %20, not "+", which some panels misread.
        let query = params.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        return URL(string: server.absoluteString + "player_api.php?" + query)!
    }

    /** A stream address up to its file name: `{server}/{kind}/{user}/{pass}/`. */
    static func streamPrefix(_ server: URL, _ kind: String, _ username: String, _ password: String) -> String {
        server.absoluteString + [kind, username, password].map(encode).joined(separator: "/") + "/"
    }

    /** `{server}/{kind}/{user}/{pass}/{id}.{ext}`, the standard Xtream stream path. */
    static func streamURL(_ server: URL, _ kind: String, _ username: String, _ password: String, _ id: String, _ ext: String) -> String {
        server.absoluteString + [kind, username, password, "\(id).\(ext)"].map(encode).joined(separator: "/")
    }

    // MARK: Account

    struct Account {
        var authenticated: Bool
        var status: String?
        var outputFormats: [String]
    }

    static func account(_ root: Any) -> Account {
        guard let info = (root as? Obj)?["user_info"] as? Obj else { return Account(authenticated: false, outputFormats: []) }
        return Account(
            authenticated: str(info["auth"]) == "1",
            status: str(info["status"]),
            outputFormats: (info["allowed_output_formats"] as? [Any])?.compactMap(str) ?? []
        )
    }

    /** HLS plays natively on iPad, so prefer it when the panel allows it. */
    static func preferredFormat(_ allowed: [String]) -> String {
        allowed.isEmpty || allowed.contains("m3u8") ? "m3u8" : "ts"
    }

    // MARK: Catalogues

    /** Some panels answer an empty catalogue with `{}` or an error object instead of `[]`. */
    static func list(_ root: Any) throws -> [Obj] {
        guard let a = root as? [Any] else { throw ProviderError("The provider sent a list in an unexpected format.") }
        return a.compactMap { $0 as? Obj }
    }

    /** Category id to name, in the provider's order. */
    static func categories(_ root: Any) throws -> [(id: String, name: String)] {
        try list(root).compactMap { c in str(c["category_id"]).map { ($0, str(c["category_name"]) ?? uncategorised) } }
    }

    private static func group(_ cats: [String: String], _ id: Any?) -> String { cats[str(id) ?? ""] ?? uncategorised }

    static func liveChannels(_ server: URL, _ u: String, _ p: String, format: String, cats: [String: String], _ root: Any) throws -> [Channel] {
        try list(root).compactMap { s in
            guard let id = str(s["stream_id"]) else { return nil }
            return Channel(id: id, name: str(s["name"]) ?? "Channel \(id)", group: group(cats, s["category_id"]),
                           logo: str(s["stream_icon"]), url: streamURL(server, "live", u, p, id, format), epgId: str(s["epg_channel_id"]))
        }
    }

    static func films(_ server: URL, _ u: String, _ p: String, cats: [String: String], _ root: Any) throws -> [Channel] {
        try list(root).compactMap { s in
            guard let id = str(s["stream_id"]) else { return nil }
            return Channel(id: id, name: str(s["name"]) ?? "Film \(id)", group: group(cats, s["category_id"]),
                           logo: str(s["stream_icon"]), url: streamURL(server, "movie", u, p, id, str(s["container_extension"]) ?? "mp4"),
                           added: Double(str(s["added"]) ?? "") ?? 0)
        }
    }

    static func series(cats: [String: String], _ root: Any) throws -> [Series] {
        try list(root).compactMap { s in
            guard let id = str(s["series_id"]) else { return nil }
            return Series(id: id, name: str(s["name"]) ?? "Series \(id)", group: group(cats, s["category_id"]),
                          cover: str(s["cover"]), plot: str(s["plot"]), added: Double(str(s["last_modified"]) ?? "") ?? 0)
        }
    }

    /**
     * Seasons from `get_series_info`. `episodes` is usually an object keyed by season number, but
     * some panels send a list of lists instead.
     */
    static func seasons(_ server: URL, _ u: String, _ p: String, _ info: Any) -> [Season] {
        let episodes = (info as? Obj)?["episodes"]
        var bySeason: [(String?, Any)] = []
        if let o = episodes as? Obj { bySeason = o.map { ($0.key, $0.value) } }
        else if let a = episodes as? [Any] { bySeason = a.map { (nil, $0) } }
        let result: [Season] = bySeason.compactMap { key, raw in
            let parsed = (raw as? [Any])?.compactMap { $0 as? Obj } ?? []
            guard let seasonName = key ?? parsed.lazy.compactMap({ str($0["season"]) }).first else { return nil }
            let eps: [Channel] = parsed.compactMap { e in
                guard let id = str(e["id"]) else { return nil }
                let label = [str(e["episode_num"]).map { "E\($0)" }, str(e["title"]).flatMap(episodeTitle)].compactMap { $0 }.joined(separator: "  ")
                let info = e["info"] as? Obj
                return Channel(id: id, name: label.isEmpty ? "Episode \(id)" : label, group: "Season \(seasonName)",
                               logo: str(info?["movie_image"]), url: streamURL(server, "series", u, p, id, str(e["container_extension"]) ?? "mp4"),
                               plot: str(info?["plot"]), runtime: info.flatMap(runtime))
            }
            return eps.isEmpty ? nil : Season(name: "Season \(seasonName)", episodes: eps)
        }
        let n = { (s: Season) in Int(s.name.dropFirst(7)) ?? Int.max }
        return result.sorted { n($0) < n($1) }
    }

    private static let showAndCode = try! NSRegularExpression(pattern: #"^.*?\bS\d{1,2}\s*E\d{1,3}\b\s*[-–:|]?\s*"#, options: .caseInsensitive)

    /** "Ted Lasso - S04E10 - Being Alive" → "Being Alive"; titles without a code are kept as they are. */
    static func episodeTitle(_ raw: String) -> String? {
        let title = raw.trimmingCharacters(in: .whitespaces)
        let stripped = showAndCode.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
        let out = stripped.isEmpty ? title : stripped
        return out.isEmpty ? nil : out
    }

    /** The `info` block of `get_vod_info` or `get_series_info`. */
    static func details(_ root: Any) -> Details {
        guard let info = (root as? Obj)?["info"] as? Obj else { return Details() }
        func text(_ keys: String...) -> String? { keys.lazy.compactMap { str(info[$0]) }.first }
        let b = info["backdrop_path"]
        let backdrop = (b as? [Any])?.lazy.compactMap(str).first ?? str(b)
        var rating: String?
        if let r = Double(text("rating", "rating_5based") ?? ""), r > 0 {
            // rating_5based is out of five; scale it to ten like the rest.
            let ten = (Double(str(info["rating"]) ?? "") ?? 0) > 0 ? r : r * 2
            rating = String(format: "%.1f", ten)
        }
        let year = text("releasedate", "releaseDate", "release_date", "year")
            .flatMap { s in s.range(of: #"\d{4}"#, options: .regularExpression).map { String(s[$0]) } }
        return Details(plot: text("plot", "description"), genre: text("genre"), year: year, rating: rating,
                       runtime: runtime(info), cast: text("cast", "actors"), backdrop: backdrop ?? text("cover_big", "movie_image"))
    }

    static func runtime(_ info: Obj) -> String? {
        if let secs = Double(str(info["duration_secs"]) ?? ""), secs > 0 { return minutesLabel(Int(secs / 60)) }
        if let d = str(info["duration"])?.split(separator: ":").map({ Int($0.trimmingCharacters(in: .whitespaces)) }),
           d.count == 3, let h = d[0], let m = d[1], d[2] != nil { return minutesLabel(h * 60 + m) }
        if let ert = Int(str(info["episode_run_time"]) ?? ""), ert > 0 { return "\(ert) min" }
        return nil
    }

    private static func minutesLabel(_ minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
