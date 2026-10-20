import Foundation

/** Parses extended M3U playlists (`#EXTINF` with tvg-* and group-title attributes). */
enum M3U {
    private static let attribute = try! NSRegularExpression(pattern: #"([A-Za-z0-9_-]+)="([^"]*)""#)

    private struct Info {
        var name: String
        var attrs: [String: String]
        var extGroup: String?
    }

    static func parse(_ text: String) -> [Channel] {
        var channels: [Channel] = []
        var pending: Info?
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let upper = line.prefix(8).uppercased()
            if upper.hasPrefix("#EXTINF") { pending = info(line) }
            else if upper.hasPrefix("#EXTGRP:") { pending?.extGroup = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("#") { continue }
            else {
                channels.append(channel(pending, line))
                pending = nil
            }
        }
        return channels
    }

    private static func info(_ line: String) -> Info {
        var attrs: [String: String] = [:]
        let range = NSRange(line.startIndex..., in: line)
        for m in attribute.matches(in: line, range: range) {
            if let k = Range(m.range(at: 1), in: line), let v = Range(m.range(at: 2), in: line) { attrs[line[k].lowercased()] = String(line[v]) }
        }
        // Attribute values may contain commas, so drop them before looking for the title separator.
        let stripped = attribute.stringByReplacingMatches(in: line, range: range, withTemplate: "")
        let name = stripped.firstIndex(of: ",").map { String(stripped[stripped.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
        return Info(name: name, attrs: attrs)
    }

    private static func channel(_ info: Info?, _ url: String) -> Channel {
        let a = info?.attrs ?? [:]
        func nonEmpty(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }
        return Channel(id: url, name: nonEmpty(info?.name) ?? nonEmpty(a["tvg-name"]) ?? url,
                       group: nonEmpty(a["group-title"]) ?? nonEmpty(info?.extGroup) ?? uncategorised,
                       logo: nonEmpty(a["tvg-logo"]), url: url, epgId: nonEmpty(a["tvg-id"]))
    }
}
