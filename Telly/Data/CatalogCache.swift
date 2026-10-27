import CryptoKit
import Foundation

/**
 * Saved catalogues: the provider's raw answers, kept on the device so telly opens instantly and
 * refreshes in the background. Scoped by a hash of server and username, so switching providers
 * never mixes lists. On iPad, stored with complete file protection: unreadable while it's locked.
 */
enum CatalogCache {
    private static var dir: URL {
        Device.dataDirectory.appendingPathComponent("catalog", isDirectory: true)
    }

    static func scope(_ parts: String...) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func file(_ scope: String, _ name: String) -> URL {
        dir.appendingPathComponent(scope, isDirectory: true).appendingPathComponent(name.replacingOccurrences(of: "/", with: "_"))
    }

    static func read(_ scope: String, _ name: String) -> Data? {
        try? Data(contentsOf: file(scope, name))
    }

    /** The start of a saved file, for its header, without reading the rest. */
    static func readPrefix(_ scope: String, _ name: String, _ count: Int = 256) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: file(scope, name)) else { return nil }
        defer { try? h.close() }
        return try? h.read(upToCount: count)
    }

    static func delete(_ scope: String, _ name: String) {
        try? FileManager.default.removeItem(at: file(scope, name))
    }

    static func write(_ scope: String, _ name: String, _ data: Data) {
        let url = file(scope, name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, Device.fileProtection])
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: dir)
    }

    /** One provider's saved lists (as Repo scopes them). */
    static func clear(for provider: Provider) {
        let scope: String
        switch provider {
        case let .xtream(_, server, username, _, _):
            guard let url = try? Xtream.serverURL(server) else { return }
            scope = Self.scope("xtream", url.absoluteString, username)
        case let .m3u(_, raw, _):
            scope = Self.scope("m3u", raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(scope, isDirectory: true))
    }
}
