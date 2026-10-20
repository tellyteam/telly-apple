import CryptoKit
import Foundation

/**
 * Saved catalogues: the provider's raw answers, kept on the iPad so telly opens instantly and
 * refreshes in the background. Scoped by a hash of server and username, so switching providers
 * never mixes lists. Stored with complete file protection: unreadable while the iPad is locked.
 */
enum CatalogCache {
    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("catalog", isDirectory: true)
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

    static func write(_ scope: String, _ name: String, _ data: Data) {
        let url = file(scope, name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: dir)
    }
}
