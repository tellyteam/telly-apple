import Foundation

/**
 * Keeps provider logins out of the app's saved files. Xtream stream addresses carry the login as
 * `/{user}/{pass}/`, and those files (Continue watching, the Downloads list…) go into iCloud and
 * computer backups, which the Keychain's copy never does. So on saving, each saved provider's login
 * is swapped for a marker naming the provider, and on reading it's put back from the Keychain.
 */
enum LoginMask {
    /** Each saved provider's login as its addresses carry it, by provider id. Set by the app as its
     *  providers change; read from the Keychain until then (Downloads load before the app does). */
    nonisolated(unsafe) private static var known: [String: String]?

    static func set(_ providers: [SavedProvider]) {
        known = logins(providers)
    }

    /** [data] (JSON) with every saved login swapped for its marker. */
    static func hide(_ data: Data) -> Data {
        replace(data) { login, marker in (login, marker) }
    }

    /** [data] (JSON) with every marker swapped back for its provider's login. */
    static func show(_ data: Data) -> Data {
        replace(data) { login, marker in (marker, login) }
    }

    private static func replace(_ data: Data, _ pair: (String, String) -> (String, String)) -> Data {
        let all = current()
        guard !all.isEmpty, var text = String(data: data, encoding: .utf8) else { return data }
        for (id, login) in all {
            // As JSON writes them: slashes escaped.
            let (from, to) = pair(json("/\(login)/"), json("/telly-login-\(id)/"))
            text = text.replacingOccurrences(of: from, with: to)
        }
        return Data(text.utf8)
    }

    private static func json(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "\\/") }

    private static func current() -> [String: String] {
        if let known, !known.isEmpty { return known }
        // Not unlocked yet, perhaps: asked again next time rather than remembered as none.
        guard let text = Keychain.get("providers"),
              let list = try? JSONDecoder().decode([SavedProvider].self, from: Data(text.utf8)) else { return [:] }
        known = logins(list)
        return known ?? [:]
    }

    /** "user/pass" as a provider's stream addresses carry it: Xtream's own, or an M3U link's query. */
    static func logins(_ providers: [SavedProvider]) -> [String: String] {
        var out: [String: String] = [:]
        for saved in providers {
            switch saved.provider {
            case let .xtream(_, _, username, password, _):
                if !username.isEmpty, !password.isEmpty { out[saved.id] = "\(Xtream.encode(username))/\(Xtream.encode(password))" }
            case let .m3u(_, url, _):
                let query = URLComponents(string: url)?.queryItems ?? []
                if let u = query.first(where: { $0.name == "username" })?.value, let p = query.first(where: { $0.name == "password" })?.value,
                   !u.isEmpty, !p.isEmpty {
                    out[saved.id] = "\(Xtream.encode(u))/\(Xtream.encode(p))"
                }
            }
        }
        return out
    }
}
