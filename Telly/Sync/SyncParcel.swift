import Foundation

/** A Continue watching entry as shared: ids and a time only. */
struct SyncEntry: Hashable {
    enum Kind: String { case live, film, series }
    var kind: Kind
    /** The channel, film or episode id. */
    var id: String
    /** Series only. */
    var series: String?
    var at: Double
    var removed = false

    var slot: String {
        switch kind {
        case .live: return "live"
        case .film: return "film:\(id)"
        case .series: return "series:\(series ?? "")"
        }
    }
}

/** What one device shares (telly-sync PROTOCOL.md): positions, history and My List, by id. */
struct SyncParcel: Equatable {
    var at: Double = 0
    /** key → (position ms, duration ms, saved at). */
    var progress: [String: Progress] = [:]
    var history: [SyncEntry] = []
    /** My List key → (changed at, on the list). */
    var list: [String: ListChange] = [:]
    /** When watch progress was last cleared on any device (0 if never). */
    var cleared: Double = 0

    struct ListChange: Equatable, Codable {
        var at: Double
        var on: Bool
    }

    static let maxProgress = 2000, maxHistory = 40, maxList = 2000
    /** Removals are shared for this long, then forgotten. */
    static let tombstoneMs: Double = 90 * 86_400_000

    /** Plain keys only (`series/123.mkv`, `film:456`): anything URL-like might carry a login. */
    private static let key = try! NSRegularExpression(pattern: "^[a-z]{1,8}[/:][A-Za-z0-9._-]{1,40}$")
    private static let idPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]{1,40}$")
    private static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    static func isSyncableKey(_ k: String) -> Bool { matches(key, k) }
    static func isSyncableId(_ id: String?) -> Bool { id.map { matches(idPattern, $0) } ?? false }

    /** Whether something saved at [at] survives a clear at [cleared] (0: never cleared). */
    static func keptAfterClear(_ at: Double, _ cleared: Double) -> Bool { cleared == 0 || at > cleared }

    // MARK: JSON

    func json() -> String {
        var h: [[String: Any]] = []
        for e in history {
            var o: [String: Any] = ["kind": e.kind.rawValue, "id": e.id, "at": num(e.at)]
            if e.kind == .series, let s = e.series { o["series"] = s }
            if e.removed { o["removed"] = true }
            h.append(o)
        }
        let obj: [String: Any] = [
            "v": 1, "at": num(at),
            "progress": progress.mapValues { [num($0.position), num($0.duration), num($0.at)] },
            "history": h,
            "list": list.mapValues { [num($0.at), $0.on] as [Any] },
            "cleared": num(cleared),
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /** Whole milliseconds as integers, as the other apps write them. */
    private func num(_ d: Double) -> Any { d.isFinite && d == d.rounded() && abs(d) < 9e15 ? Int64(d) as Any : d as Any }

    /** Whatever another device sent, reduced to well-formed entries; nil if it isn't a parcel. */
    static func parse(_ text: String) -> SyncParcel? {
        guard let raw = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              time(raw["v"]) == 1 else { return nil }
        var p = SyncParcel(at: time(raw["at"]) ?? 0, cleared: time(raw["cleared"]) ?? 0)
        for (k, v) in raw["progress"] as? [String: Any] ?? [:] {
            guard isSyncableKey(k), let a = v as? [Any], a.count == 3,
                  let pos = time(a[0]), let dur = time(a[1]), let at = time(a[2]), dur > 0 else { continue }
            p.progress[k] = Progress(position: pos, duration: dur, at: at)
        }
        for item in raw["history"] as? [Any] ?? [] {
            guard let h = item as? [String: Any], let kind = (h["kind"] as? String).flatMap(SyncEntry.Kind.init(rawValue:)),
                  let id = h["id"] as? String, isSyncableId(id), let at = time(h["at"]) else { continue }
            let series = h["series"] as? String
            if kind == .series && !isSyncableId(series) { continue }
            p.history.append(SyncEntry(kind: kind, id: id, series: kind == .series ? series : nil, at: at, removed: isTrue(h["removed"])))
        }
        for (k, v) in raw["list"] as? [String: Any] ?? [:] {
            guard isSyncableKey(k), let a = v as? [Any], a.count == 2, let at = time(a[0]), let on = bool(a[1]) else { continue }
            p.list[k] = ListChange(at: at, on: on)
        }
        return p
    }

    private static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }
    private static func time(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, !isBool(n) else { return nil }
        let d = n.doubleValue
        return d.isFinite && d >= 0 ? d : nil
    }
    private static func bool(_ v: Any?) -> Bool? { isBool(v) ? (v as! NSNumber).boolValue : nil }
    private static func isTrue(_ v: Any?) -> Bool { bool(v) == true }

    // MARK: Combining

    /** Keeps a parcel within its limits, drops old removals and anything from before the last clear. */
    static func trim(_ p: SyncParcel, now: Double) -> SyncParcel {
        func fresh(_ at: Double, _ removal: Bool) -> Bool { !removal || now - at < tombstoneMs }
        var out = SyncParcel(at: p.at, cleared: p.cleared)
        out.progress = Dictionary(uniqueKeysWithValues: p.progress.filter { keptAfterClear($0.value.at, p.cleared) }
            .sorted { $0.value.at > $1.value.at }.prefix(maxProgress).map { ($0.key, $0.value) })
        out.history = Array(p.history.filter { fresh($0.at, $0.removed) && keptAfterClear($0.at, p.cleared) }
            .sorted { $0.at > $1.at }.prefix(maxHistory))
        out.list = Dictionary(uniqueKeysWithValues: p.list.filter { fresh($0.value.at, !$0.value.on) }
            .sorted { $0.value.at > $1.value.at }.prefix(maxList).map { ($0.key, $0.value) })
        return out
    }

    /** [own] combined with other devices' parcels: newest wins per key and slot; [own] wins a tie. */
    static func merge(_ own: SyncParcel, _ others: [SyncParcel], now: Double) -> SyncParcel {
        var progress = own.progress, list = own.list, cleared = own.cleared
        var history: [String: SyncEntry] = [:]
        var order: [String] = []
        for h in own.history where history[h.slot] == nil { history[h.slot] = h; order.append(h.slot) }
        for p in others {
            cleared = max(cleared, p.cleared)
            for (k, v) in p.progress where (progress[k]?.at ?? -1) < v.at { progress[k] = v }
            for (k, v) in p.list where (list[k]?.at ?? -1) < v.at { list[k] = v }
            for h in p.history where (history[h.slot]?.at ?? -1) < h.at {
                if history[h.slot] == nil { order.append(h.slot) }
                history[h.slot] = h
            }
        }
        return trim(SyncParcel(at: now, progress: progress, history: order.compactMap { history[$0] }, list: list, cleared: cleared), now: now)
    }
}
