import CryptoKit
import Foundation

/**
 * Catalogues saved as telly uses them (telly-sync PLAYBACK.md, Lists): only the fields shown, one
 * item per line, read back many times faster than the provider's own answer, which can run to tens
 * of megabytes. Stream addresses are left out, as they carry the login, and rebuilt from each
 * item's id when read. The first line holds a fingerprint of the provider's answer, so a fresh
 * answer that hasn't changed needn't be converted again.
 */
enum Compact {
    /** Version 2 drops series plots. Older saved copies still load; the next refresh rewrites them. */
    private static let header = "telly-compact 2"
    private static let anyVersion = "telly-compact "
    private static let groupMark = "\u{1E}"
    private static let field = "\u{1F}"

    /** A fingerprint of the provider's answer (its parts in order). */
    static func fingerprint(_ parts: Data...) -> String {
        var hash = SHA256()
        for p in parts { hash.update(data: p) }
        return hash.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /** The fingerprint a saved catalogue was made from; nil if it isn't one. */
    static func fingerprint(ofSaved prefix: Data) -> String? {
        let line = String(decoding: prefix.prefix { $0 != 0x0A }, as: UTF8.self)
        let parts = line.components(separatedBy: field)
        return parts.count == 2 && parts[0] == header ? parts[1] : nil
    }

    // MARK: Channels and films

    /** Live channels or films, in their groups. */
    static func pack(_ groups: [ItemGroup<Channel>], fingerprint: String) -> Data {
        pack(groups, fingerprint) { c in
            let ext = c.url.split(separator: ".").last.map(String.init) ?? ""
            return [c.id, c.name, c.logo ?? "", c.epgId ?? "", c.added > 0 ? String(Int(c.added)) : "", ext]
        }
    }

    /**
     * The groups again, each item's stream address made from [streamPrefix] (everything up to the
     * file name, as `Xtream.streamPrefix` gives it); nil if [data] isn't a saved catalogue.
     */
    static func unpackChannels(_ data: Data, streamPrefix: String) -> [ItemGroup<Channel>]? {
        unpack(data) { f, group in
            guard f.count == 6 else { return nil }
            let id = String(f[0])
            return Channel(id: id, name: String(f[1]), group: group, logo: f[2].isEmpty ? nil : String(f[2]),
                           url: streamPrefix + Xtream.encode("\(id).\(f[5])"), epgId: f[3].isEmpty ? nil : String(f[3]),
                           added: Double(f[4]) ?? 0)
        }
    }

    // MARK: Series

    static func pack(_ groups: [ItemGroup<Series>], fingerprint: String) -> Data {
        // No plot: it's shown only on the series' page, which fetches it, and it's most of the list's size.
        pack(groups, fingerprint) { s in [s.id, s.name, s.cover ?? "", "", s.added > 0 ? String(Int(s.added)) : ""] }
    }

    static func unpackSeries(_ data: Data) -> [ItemGroup<Series>]? {
        unpack(data) { f, group in
            guard f.count == 5 else { return nil }
            return Series(id: String(f[0]), name: String(f[1]), group: group, cover: f[2].isEmpty ? nil : String(f[2]),
                          plot: f[3].isEmpty ? nil : String(f[3]), added: Double(f[4]) ?? 0)
        }
    }

    // MARK: The format

    private static func pack<T>(_ groups: [ItemGroup<T>], _ fingerprint: String, _ fields: (T) -> [String]) -> Data {
        var out = header + field + fingerprint + "\n"
        out.reserveCapacity(groups.reduce(0) { $0 + $1.items.count } * 120)
        for g in groups {
            out += groupMark + clean(g.name) + "\n"
            for item in g.items { out += fields(item).map(clean).joined(separator: field) + "\n" }
        }
        return Data(out.utf8)
    }

    /** Works on the bytes, not characters: tens of megabytes split as text would take seconds. */
    private static func unpack<T>(_ data: Data, _ make: ([Substring], String) -> T?) -> [ItemGroup<T>]? {
        let bytes = [UInt8](data)
        var groups: [ItemGroup<T>] = []
        var start = 0, first = true
        while start < bytes.count {
            let end = bytes[start...].firstIndex(of: 0x0A) ?? bytes.count
            defer { start = end + 1 }
            if first {
                first = false
                guard String(decoding: bytes[start..<end], as: UTF8.self).hasPrefix(anyVersion) else { return nil }
                continue
            }
            guard end > start else { continue }
            if bytes[start] == 0x1E {
                groups.append(ItemGroup(name: String(decoding: bytes[(start + 1)..<end], as: UTF8.self), items: []))
                continue
            }
            guard !groups.isEmpty else { continue }
            var fields: [Substring] = []
            var a = start
            for i in start...end where i == end || bytes[i] == 0x1F {
                fields.append(Substring(String(decoding: bytes[a..<i], as: UTF8.self)))
                a = i + 1
            }
            if let item = make(fields, groups[groups.count - 1].name) { groups[groups.count - 1].items.append(item) }
        }
        return first ? nil : groups
    }

    /** Fields can't hold the format's own separators: line breaks become spaces. */
    private static func clean(_ s: String) -> String {
        func bad(_ c: Character) -> Bool { c.isNewline || c == "\u{1E}" || c == "\u{1F}" }
        guard s.contains(where: bad) else { return s }
        return String(s.map { bad($0) ? " " : $0 })
    }
}
