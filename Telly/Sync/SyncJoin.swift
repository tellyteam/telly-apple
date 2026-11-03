import CryptoKit
import Foundation

/**
 * Joining by QR code from the new device (PROTOCOL.md): a device that isn't linked shows
 * `telly://join?id=…&key=…`; a device in the household scans it and leaves its link code in the
 * relay's join box, sealed with the key, for the new device to collect.
 */
struct SyncJoin: Equatable, Identifiable {
    /** The box's address on the relay: 16 random bytes as hex. */
    let id: String
    /** 32 random bytes, only ever in the QR code. */
    let key: [UInt8]

    static func new() -> SyncJoin { SyncJoin(id: SyncCrypto.hex(SyncCrypto.randomBytes(16)), key: SyncCrypto.randomBytes(32)) }

    var url: String { "telly://join?id=\(id)&key=\(Self.base64url(Data(key)))" }

    /** The join from a scanned link, or nil if it isn't one. */
    static func parse(_ text: String) -> SyncJoin? {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "telly", c.host?.lowercased() == "join",
              let id = c.queryItems?.first(where: { $0.name == "id" })?.value?.lowercased(),
              id.count == 32, id.allSatisfy(\.isHexDigit),
              let key = c.queryItems?.first(where: { $0.name == "key" })?.value.flatMap(unbase64url), key.count == 32
        else { return nil }
        return SyncJoin(id: id, key: [UInt8](key))
    }

    private var aad: Data { Data("telly-join v1|\(id)".utf8) }

    /** The household's link code, sealed for this join's box. */
    func seal(code: String, nonce: [UInt8] = SyncCrypto.randomBytes(12)) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: ["code": code])
        let box = try AES.GCM.seal(json, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        return Data([1]) + Data(nonce) + box.ciphertext + box.tag
    }

    /** The link code in a box, or nil if it isn't for this join or was altered. */
    func open(_ box: Data) -> String? {
        let b = [UInt8](box)
        guard b.count >= 1 + 12 + 16, b[0] == 1,
              let nonce = try? AES.GCM.Nonce(data: b[1..<13]),
              let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: b[13..<(b.count - 16)], tag: b[(b.count - 16)...]),
              let plain = try? AES.GCM.open(sealed, using: SymmetricKey(data: key), authenticating: aad),
              let code = ((try? JSONSerialization.jsonObject(with: plain)) as? [String: Any])?["code"] as? String
        else { return nil }
        return SyncCrypto.normaliseCode(code)
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
    /** Leaves this household's code for a new device. Needs no token: the box's id is its address. */
    static func sendJoin(_ relay: String, _ join: SyncJoin, code: String) async throws {
        let status = try await joinRequest("PUT", relay, join, body: try join.seal(code: code)).status
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
              let box = Data(base64Encoded: b64), let code = join.open(box)
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
