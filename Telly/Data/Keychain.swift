import Foundation
import Security

/** Secrets (the provider login, the sync code) in this device's Keychain, never synced to other devices. */
enum Keychain {
    #if os(iOS)
    private static let service = "io.github.tellyteam.telly"
    #else
    // Not the old Mac app's (the same name, in the same login Keychain): sharing it would let each
    // app overwrite the other's login.
    private static let service = "io.github.tellyteam.telly.native"
    #endif

    static func get(_ name: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ name: String, _ value: String) {
        delete(name)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: name, kSecValueData as String: Data(value.utf8),
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ name: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        SecItemDelete(query as CFDictionary)
    }
}

/** The app's own records (progress, history, My List…) as JSON files, with complete file protection. */
enum Store {
    private static var dir: URL {
        Device.dataDirectory.appendingPathComponent("store", isDirectory: true)
    }

    static func read<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(name).json")) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /** [protection] is complete unless the file is needed while the iPad is locked. */
    static func write<T: Encodable>(_ name: String, _ value: T, protection: Data.WritingOptions = Device.fileProtection) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent("\(name).json"), options: [.atomic, protection])
    }

    /** Whether [name] is there but can't be opened yet: a locked iPad, and a file with complete protection. */
    static func locked(_ name: String) -> Bool {
        let file = dir.appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return true }
        try? handle.close()
        return false
    }

    static func delete(_ name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(name).json"))
    }
}

/**
 * One provider's own records on this device: My List, progress, history and the sync ledger, in
 * files named after its [SavedProvider.id]. (Before there could be several providers, they had
 * no suffix.)
 */
enum Records {
    struct Set {
        var favourites: [String] = []
        var progress: [String: Progress] = [:]
        var history: [LastWatched] = []
        var ledger = SyncLedger()
    }

    static func name(_ base: String, _ id: String?) -> String { id.map { "\(base)-\($0)" } ?? base }

    static func load(_ id: String?) -> Set {
        Set(favourites: Store.read(name("favourites", id), as: [String].self) ?? [],
            progress: Store.read(name("progress", id), as: [String: Progress].self) ?? [:],
            history: Store.read(name("history", id), as: [LastWatched].self) ?? [],
            ledger: Store.read(name("sync-ledger", id), as: SyncLedger.self) ?? SyncLedger())
    }

    static func save(_ id: String, _ r: Set) {
        Store.write(name("favourites", id), r.favourites)
        Store.write(name("progress", id), r.progress)
        Store.write(name("history", id), r.history)
        Store.write(name("sync-ledger", id), r.ledger)
    }

    static func move(from: String?, to: String) {
        save(to, load(from))
        delete(from)
    }

    static func delete(_ id: String?) {
        for base in ["favourites", "progress", "history", "sync-ledger"] { Store.delete(name(base, id)) }
    }
}
