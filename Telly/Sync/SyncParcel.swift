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

/**
 * One provider's section of a parcel (telly-sync PROTOCOL.md): positions, history and My List, by
 * the provider's own ids. Version 1 parcels were exactly one of these; see [SyncBundle].
 */
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

    /** Version 1's parcel, which is a section with `v` and `at` beside it. */
    func json() -> String {
        var obj = sectionObject()
        obj["v"] = 1
        obj["at"] = num(at)
        return Self.text(obj)
    }

    static func text(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func sectionObject() -> [String: Any] {
        var h: [[String: Any]] = []
        for e in history {
            var o: [String: Any] = ["kind": e.kind.rawValue, "id": e.id, "at": num(e.at)]
            if e.kind == .series, let s = e.series { o["series"] = s }
            if e.removed { o["removed"] = true }
            h.append(o)
        }
        return [
            "progress": progress.mapValues { [num($0.position), num($0.duration), num($0.at)] },
            "history": h,
            "list": list.mapValues { [num($0.at), $0.on] as [Any] },
            "cleared": num(cleared),
        ]
    }

    /** Whole milliseconds as integers, as the other apps write and expect them. */
    func num(_ d: Double) -> Any { d.isFinite && abs(d) < 9e15 ? Int64(d.rounded()) as Any : 0 as Any }

    /** A version 1 parcel, reduced to well-formed entries; nil if it isn't one. */
    static func parse(_ text: String) -> SyncParcel? {
        guard let raw = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              time(raw["v"]) == 1 else { return nil }
        return parseSection(raw, at: time(raw["at"]) ?? 0)
    }

    /** A section another device sent, reduced to well-formed entries. */
    static func parseSection(_ raw: [String: Any], at: Double) -> SyncParcel {
        var p = SyncParcel(at: at, cleared: time(raw["cleared"]) ?? 0)
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
    static func time(_ v: Any?) -> Double? {
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

/**
 * A whole parcel (version 2): a section for each provider the device has, under its provider tag.
 * Reads version 1 parcels too, as one section for the provider the reader says (its only one).
 */
struct SyncBundle: Equatable {
    var at: Double = 0
    var sections: [String: SyncParcel] = [:]
    /** The opt-in logins, by provider tag; nil when this device doesn't share them (or the parcel has none). */
    var logins: [String: SharedLogin]?

    static let maxSections = 20
    private static let tagPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{16}$")
    static func isTag(_ t: String) -> Bool { tagPattern.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil }

    /** The parcel; with [keys] and [device], any logins go in sealed. */
    func json(keys: SyncCrypto.Keys? = nil, device: String? = nil) -> String {
        var providers: [String: Any] = [:]
        for (tag, section) in sections.sorted(by: { $0.value.at > $1.value.at }).prefix(Self.maxSections) {
            providers[tag] = SyncParcel.trim(section, now: at).sectionObject()
        }
        var obj: [String: Any] = ["v": 2, "at": SyncParcel().num(at), "providers": providers]
        if let logins, let keys, let device,
           let box = try? SyncCrypto.sealLogins(keys, device: device, SharedLogin.text(SharedLogin.trim(logins, now: at))) {
            obj["logins"] = box.base64EncodedString()
        }
        return SyncParcel.text(obj)
    }

    /** Another device's parcel; [current] is the tag a version 1 parcel is read as. With [keys] and
     *  the sending [device], its logins are opened too (each checked against its own tag). */
    static func parse(_ text: String, current: String, keys: SyncCrypto.Keys? = nil, device: String? = nil) -> SyncBundle? {
        guard let raw = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        let at = SyncParcel.time(raw["at"]) ?? 0
        switch SyncParcel.time(raw["v"]) {
        case 1:
            return SyncBundle(at: at, sections: [current: SyncParcel.parseSection(raw, at: at)])
        case 2:
            var b = SyncBundle(at: at)
            for (tag, value) in raw["providers"] as? [String: Any] ?? [:] {
                guard isTag(tag), let section = value as? [String: Any], b.sections.count < maxSections else { continue }
                b.sections[tag] = SyncParcel.parseSection(section, at: at)
            }
            if let keys, let device, let b64 = raw["logins"] as? String, let box = Data(base64Encoded: b64),
               let text = SyncCrypto.openLogins(keys, device: device, box) {
                b.logins = SharedLogin.parse(text, keys: keys)
            }
            return b
        default:
            return nil
        }
    }

    /** [own] combined with others, section by section, for the providers [own] has; and the
     *  logins, newest per tag, if [own] shares them. */
    static func merge(_ own: SyncBundle, _ others: [SyncBundle], now: Double) -> SyncBundle {
        var out = SyncBundle(at: now)
        for (tag, section) in own.sections {
            out.sections[tag] = SyncParcel.merge(section, others.compactMap { $0.sections[tag] }, now: now)
        }
        if var logins = own.logins {
            for other in others.compactMap(\.logins) {
                for (tag, login) in other where (logins[tag]?.at ?? -1) < login.at { logins[tag] = login }
            }
            out.logins = SharedLogin.trim(logins, now: now)
        }
        return out
    }
}

/**
 * A provider's login as shared between devices that opt in (PROTOCOL.md, "Logins"), or its removal
 * (no [provider]). Written in the same JSON shape by every telly app.
 */
struct SharedLogin: Equatable {
    var at: Double
    var provider: Provider?

    static let max = 20

    /** Drops removals past the tombstone time, and keeps the newest [max]. */
    static func trim(_ logins: [String: SharedLogin], now: Double) -> [String: SharedLogin] {
        let kept = logins.filter { $0.value.provider != nil || now - $0.value.at < SyncParcel.tombstoneMs }
        return Dictionary(uniqueKeysWithValues: kept.sorted { $0.value.at > $1.value.at }.prefix(max).map { ($0.key, $0.value) })
    }

    func object() -> [String: Any] {
        let at = SyncParcel().num(self.at)
        switch provider {
        case nil:
            return ["at": at, "removed": true]
        case let .xtream(name, server, username, password, allow)?:
            return ["at": at, "kind": "xtream", "name": name, "server": server, "username": username, "password": password, "allowCleartext": allow]
        case let .m3u(name, url, allow)?:
            return ["at": at, "kind": "m3u", "name": name, "url": url, "allowCleartext": allow]
        }
    }

    static func text(_ logins: [String: SharedLogin]) -> String {
        SyncParcel.text(logins.mapValues { $0.object() })
    }

    /** Logins another device shared, keeping only those whose tag matches their own identity. */
    static func parse(_ text: String, keys: SyncCrypto.Keys) -> [String: SharedLogin] {
        guard let raw = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return [:] }
        var out: [String: SharedLogin] = [:]
        for (tag, value) in raw {
            guard SyncBundle.isTag(tag), let o = value as? [String: Any], let at = SyncParcel.time(o["at"]) else { continue }
            if o["removed"] as? Bool == true {
                out[tag] = SharedLogin(at: at, provider: nil)
                continue
            }
            let str = { (k: String) in o[k] as? String }
            let allow = o["allowCleartext"] as? Bool ?? false
            let p: Provider
            switch str("kind") {
            case "xtream":
                guard let server = str("server"), let user = str("username"), let pass = str("password") else { continue }
                p = .xtream(name: str("name") ?? defaultProviderName, server: server, username: user, password: pass, allowCleartext: allow)
            case "m3u":
                guard let url = str("url") else { continue }
                p = .m3u(name: str("name") ?? defaultProviderName, url: url, allowCleartext: allow)
            default:
                continue
            }
            guard SyncCrypto.providerTag(keys, identity: p.syncIdentity) == tag else { continue }
            out[tag] = SharedLogin(at: at, provider: p)
        }
        return out
    }
}
