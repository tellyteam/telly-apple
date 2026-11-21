import CryptoKit
import Foundation

/**
 * Joining by QR code from the new device (PROTOCOL.md, and telly-lg's SETUP-BY-PHONE.md): a device
 * shows `https://tv.gettelly.app/#id=…&key=…` (or, on older versions, `telly://join?id=…&key=…`);
 * a device in the household scans it and leaves a sealed message in the relay's join box, for the
 * device showing the code to collect. The message holds this household's link code, a provider, or
 * both; only a device showing the new form understands a provider.
 */
struct SyncJoin: Equatable, Identifiable {
    /** The box's address on the relay: 16 random bytes as hex. */
    let id: String
    /** 32 random bytes, only ever in the QR code. */
    let key: [UInt8]
    /** The code was the `tv.gettelly.app` form, so the device showing it can take a provider too. */
    var takesProvider = false

    /** What a join box holds: at least one of the two. */
    struct Message: Equatable {
        /** A normalised link code. */
        var code: String?
        var provider: Provider?
    }

    /** The receiver's limits (SETUP-BY-PHONE.md section 2), in UTF-16 units as the TV apps count them. */
    static let maxField = 255, maxURL = 2048, maxName = 60

    /** A join for this device's own code. telly for iPhone, iPad and Mac only takes a link code, so it shows the old form. */
    static func new() -> SyncJoin { SyncJoin(id: SyncCrypto.hex(SyncCrypto.randomBytes(16)), key: SyncCrypto.randomBytes(32)) }

    var url: String {
        let key = Self.base64url(Data(key))
        return takesProvider ? "https://tv.gettelly.app/#id=\(id)&key=\(key)" : "telly://join?id=\(id)&key=\(key)"
    }

    /**
     * The join from a scanned link, or nil if it isn't one. Only ever called with what the in-app
     * scanner read: never with a link the system opened (see [AppModel.open]).
     */
    static func parse(_ text: String) -> SyncJoin? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let items: [URLQueryItem]?
        let takesProvider: Bool
        switch c.scheme?.lowercased() {
        case "telly":
            guard c.host?.lowercased() == "join" else { return nil }
            items = c.queryItems
            takesProvider = false
        case "https":
            // Nothing but https://tv.gettelly.app/ with the id and key in the fragment.
            guard c.host?.lowercased() == "tv.gettelly.app", c.port == nil, c.user == nil, c.password == nil,
                  c.path.isEmpty || c.path == "/", c.query == nil, let fragment = c.percentEncodedFragment
            else { return nil }
            var f = URLComponents()
            f.percentEncodedQuery = fragment
            items = f.queryItems
            takesProvider = true
        default:
            return nil
        }
        guard let id = items?.first(where: { $0.name == "id" })?.value?.lowercased(),
              id.count == 32, id.allSatisfy(\.isHexDigit),
              let key = items?.first(where: { $0.name == "key" })?.value.flatMap(unbase64url), key.count == 32
        else { return nil }
        return SyncJoin(id: id, key: [UInt8](key), takesProvider: takesProvider)
    }

    private var aad: Data { Data("telly-join v1|\(id)".utf8) }

    /** A link code and/or a provider, sealed for this join's box. */
    func seal(code: String? = nil, provider: Provider? = nil, nonce: [UInt8] = SyncCrypto.randomBytes(12)) throws -> Data {
        guard code != nil || provider != nil else { throw SyncError(message: "There's nothing to send.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let json = try encoder.encode(Wire(code: code, provider: provider.map(WireProvider.init)))
        let box = try AES.GCM.seal(json, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        return Data([1]) + Data(nonce) + box.ciphertext + box.tag
    }

    /** What's in a box, or nil if it isn't for this join, was altered, or breaks the limits. */
    func open(_ box: Data) -> Message? {
        let b = [UInt8](box)
        guard b.count >= 1 + 12 + 16, b[0] == 1,
              let nonce = try? AES.GCM.Nonce(data: b[1..<13]),
              let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: b[13..<(b.count - 16)], tag: b[(b.count - 16)...]),
              let plain = try? AES.GCM.open(sealed, using: SymmetricKey(data: key), authenticating: aad),
              let json = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
        else { return nil }
        return Self.message(json)
    }

    /** Section 2's rules: unknown fields ignored, any broken limit makes the whole message unreadable. */
    private static func message(_ json: [String: Any]) -> Message? {
        var m = Message()
        if let value = json["code"] {
            guard let text = value as? String, let code = SyncCrypto.normaliseCode(text) else { return nil }
            m.code = code
        }
        if let value = json["provider"] {
            guard let p = value as? [String: Any], let provider = provider(p) else { return nil }
            m.provider = provider
        }
        return m.code == nil && m.provider == nil ? nil : m
    }

    private static func provider(_ p: [String: Any]) -> Provider? {
        func text(_ key: String, max: Int, trim: Bool = true, required: Bool = true) -> String?? {
            guard let value = p[key] else { return required ? nil : .some(nil) }
            guard let s = value as? String else { return nil }
            let t = trim ? s.trimmingCharacters(in: .whitespacesAndNewlines) : s
            return t.utf16.count <= max ? .some(t) : nil
        }
        guard let name = text("name", max: maxName, trim: false, required: false) else { return nil }
        var allow = false
        if let value = p["allowCleartext"] {
            guard let b = value as? Bool else { return nil }
            allow = b
        }
        switch p["kind"] as? String {
        case "xtream":
            guard let server = text("server", max: maxField) ?? nil, !server.isEmpty,
                  let username = text("username", max: maxField) ?? nil,
                  let password = text("password", max: maxField, trim: false) ?? nil
            else { return nil }
            return .xtream(name: name ?? "", server: server, username: username, password: password, allowCleartext: allow)
        case "m3u":
            guard let url = text("url", max: maxURL) ?? nil, !url.isEmpty else { return nil }
            return .m3u(name: name ?? "", url: url, allowCleartext: allow)
        default:
            return nil
        }
    }

    /**
     * [provider] as it goes to a device: trimmed as the receiver trims, the name shortened to fit,
     * or nil if a field is still too long for the receiver to take.
     */
    static func sendable(_ provider: Provider) -> Provider? {
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var name = provider.name
        while name.utf16.count > maxName { name.removeLast() }
        switch provider {
        case let .xtream(_, server, username, password, allow):
            let s = trimmed(server), u = trimmed(username)
            guard !s.isEmpty, s.utf16.count <= maxField, u.utf16.count <= maxField, password.utf16.count <= maxField else { return nil }
            return .xtream(name: name, server: s, username: u, password: password, allowCleartext: allow)
        case let .m3u(_, url, allow):
            let u = trimmed(url)
            guard !u.isEmpty, u.utf16.count <= maxURL else { return nil }
            return .m3u(name: name, url: u, allowCleartext: allow)
        }
    }

    /** The JSON, in the order section 2 writes it. */
    private struct Wire: Encodable {
        var code: String?
        var provider: WireProvider?
    }

    private struct WireProvider: Encodable {
        var kind: String
        var name: String
        var server: String?
        var username: String?
        var password: String?
        var url: String?
        var allowCleartext: Bool

        init(_ p: Provider) {
            switch p {
            case let .xtream(name, server, username, password, allow):
                self.init(kind: "xtream", name: name, server: server, username: username, password: password, url: nil, allowCleartext: allow)
            case let .m3u(name, url, allow):
                self.init(kind: "m3u", name: name, server: nil, username: nil, password: nil, url: url, allowCleartext: allow)
            }
        }

        init(kind: String, name: String, server: String?, username: String?, password: String?, url: String?, allowCleartext: Bool) {
            self.kind = kind
            self.name = name
            self.server = server
            self.username = username
            self.password = password
            self.url = url
            self.allowCleartext = allowCleartext
        }
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func unbase64url(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

extension SyncClient {
    /** Leaves a link code, a provider or both for a device showing [join]'s code. Needs no token: the box's id is its address. */
    static func sendJoin(_ relay: String, _ join: SyncJoin, code: String?, provider: Provider?) async throws {
        let status = try await joinRequest("PUT", relay, join, body: try join.seal(code: code, provider: provider)).status
        switch status {
        case 200..<300: return
        case 409: throw SyncError(message: "That device has already been linked. Show its QR code again for a new one.")
        default: throw SyncError(message: "The sync relay answered \(status).")
        }
    }

    /** The code another device left in [join]'s box, once; nil while it's still empty. */
    static func collectJoin(_ relay: String, _ join: SyncJoin) async throws -> String? {
        let (status, data) = try await joinRequest("GET", relay, join)
        guard status == 200 else { return nil }
        guard let b64 = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["body"] as? String,
              let box = Data(base64Encoded: b64), let code = join.open(box)?.code
        else { throw SyncError(message: "That code couldn't be read. Scan the QR code again.") }
        return code
    }

    private static func joinRequest(_ method: String, _ relay: String, _ join: SyncJoin, body: Data? = nil) async throws -> (status: Int, data: Data) {
        var base = relay
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/v1/join/\(join.id)") else { throw SyncError(message: "The relay address isn't right.") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 20
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            r.httpBody = body
            r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: r)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            throw SyncError(message: "Couldn't reach the sync relay.")
        }
    }
}
