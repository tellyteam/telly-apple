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

    static func write(_ scope: String, _ name: String, _ data: Data) {
        let url = file(scope, name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, Device.fileProtection])
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: dir)
    }
}
