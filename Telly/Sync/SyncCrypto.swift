import CryptoKit
import Foundation
import Security

/** Keys and sealing for sync, exactly as telly-sync's PROTOCOL.md (version 2) describes. */
enum SyncCrypto {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let salt = Data("telly-sync v1".utf8)
    private static let version: UInt8 = 1

    struct Keys {
        let mailbox: String
        let key: SymmetricKey
        let auth: String
        /** Keys provider tags (see [providerTag]). */
        let provider: SymmetricKey
        /** Seals the opt-in logins box (see [sealLogins]). */
        let logins: SymmetricKey
    }

    static func randomBytes(_ n: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return b
    }

    /** A new link code: 16 characters, 80 random bits. */
    static func newCode(_ bytes: [UInt8] = randomBytes(10)) -> String {
        var out = "", value = 0, bits = 0
        for b in bytes {
            value = (value << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
            value &= (1 << bits) - 1
        }
        return out
    }

    /** Uppercase, no spaces or dashes, O→0, I/L→1; nil unless it's 16 valid characters. */
    static func normaliseCode(_ input: String) -> String? {
        let code = String(input.uppercased().filter { !$0.isWhitespace && $0 != "-" }.map { c -> Character in
            switch c { case "O": return "0"; case "I", "L": return "1"; default: return c }
        })
        return code.count == 16 && code.allSatisfy(alphabet.contains) ? code : nil
    }

    static func formatCode(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { i in
            let s = code.index(code.startIndex, offsetBy: i)
            return String(code[s..<code.index(s, offsetBy: min(4, code.count - i))])
        }.joined(separator: "-")
    }

    static func newDeviceId() -> String { hex(randomBytes(8)) }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }

    static func deriveKeys(_ code: String) -> Keys {
        let ikm = SymmetricKey(data: Data(code.utf8))
        func derive(_ info: String) -> Data {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data(info.utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
        }
        let auth = derive("auth").base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return Keys(mailbox: hex(derive("mailbox").prefix(16)), key: SymmetricKey(data: derive("key")), auth: auth,
                    provider: SymmetricKey(data: derive("provider")), logins: SymmetricKey(data: derive("logins")))
    }

    /** A provider's tag: meaningless without the link code; with it, only "same provider or not". */
    static func providerTag(_ keys: Keys, identity: String) -> String {
        hex(HMAC<SHA256>.authenticationCode(for: Data(identity.utf8), using: keys.provider).prefix(8))
    }

    private static func aad(_ keys: Keys, _ device: String) -> Data { Data("telly-sync v1|\(keys.mailbox)|\(device)".utf8) }

    static func seal(_ keys: Keys, device: String, _ plaintext: String, nonce: [UInt8] = randomBytes(12)) throws -> Data {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: keys.key, nonce: AES.GCM.Nonce(data: nonce), authenticating: aad(keys, device))
        return Data([version]) + Data(nonce) + box.ciphertext + box.tag
    }

    /** The plaintext, or nil if the parcel isn't ours, was altered, or is from a newer version. */
    static func open(_ keys: Keys, device: String, _ box: Data) -> String? {
        openBox(box, key: keys.key, aad: aad(keys, device))
    }

    private static func loginsAad(_ keys: Keys, _ device: String) -> Data { Data("telly-sync v1|logins|\(keys.mailbox)|\(device)".utf8) }

    /** The opt-in logins box: sealed again, with its own key, inside the (already sealed) parcel. */
    static func sealLogins(_ keys: Keys, device: String, _ plaintext: String, nonce: [UInt8] = randomBytes(12)) throws -> Data {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: keys.logins, nonce: AES.GCM.Nonce(data: nonce), authenticating: loginsAad(keys, device))
        return Data([version]) + Data(nonce) + box.ciphertext + box.tag
    }

    static func openLogins(_ keys: Keys, device: String, _ box: Data) -> String? {
        openBox(box, key: keys.logins, aad: loginsAad(keys, device))
    }

    private static func openBox(_ box: Data, key: SymmetricKey, aad: Data) -> String? {
        let b = [UInt8](box)
        guard b.count >= 1 + 12 + 16, b[0] == version,
              let nonce = try? AES.GCM.Nonce(data: b[1..<13]),
              let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: b[13..<(b.count - 16)], tag: b[(b.count - 16)...]),
              let plain = try? AES.GCM.open(sealed, using: key, authenticating: aad)
        else { return nil }
        return String(data: plain, encoding: .utf8)
    }
}
