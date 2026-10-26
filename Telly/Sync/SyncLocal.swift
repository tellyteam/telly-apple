import Foundation

/** What sync remembers beside the app's own records: when My List changed, removals, the last clear. */
struct SyncLedger: Codable, Equatable {
    var list: [String: SyncParcel.ListChange] = [:]
    /** History slot → when it was taken out of Continue watching. */
    var removed: [String: Double] = [:]
    var cleared: Double = 0
}

/**
 * Between this iPad's own records and a sync parcel. The parcel gets ids and times only; what comes
 * back is turned into playable history using this iPad's own lists and login.
 */
enum SyncLocal {
    struct Local {
        var progress: [String: Progress]
        var history: [LastWatched]
        var favourites: [String]
        var ledger: SyncLedger
    }

    static func entry(_ h: LastWatched) -> SyncEntry? {
        let id = h.current.id
        guard SyncParcel.isSyncableId(id) else { return nil }
        if h.live { return SyncEntry(kind: .live, id: id, at: h.at) }
        if h.isFilm { return SyncEntry(kind: .film, id: id, at: h.at) }
        return SyncParcel.isSyncableId(h.seriesId) ? SyncEntry(kind: .series, id: id, series: h.seriesId, at: h.at) : nil
    }

    private static func removal(_ slot: String, _ at: Double) -> SyncEntry? {
        if slot == "live" { return SyncEntry(kind: .live, id: "0", at: at, removed: true) }
        guard let colon = slot.firstIndex(of: ":") else { return nil }
        let kind = String(slot[..<colon]), id = String(slot[slot.index(after: colon)...])
        guard SyncParcel.isSyncableId(id) else { return nil }
        switch kind {
        case "film": return SyncEntry(kind: .film, id: id, at: at, removed: true)
        case "series": return SyncEntry(kind: .series, id: id, series: id, at: at, removed: true)
        default: return nil
        }
    }

    static func toParcel(_ local: Local, now: Double) -> SyncParcel {
        var p = SyncParcel(at: now, cleared: local.ledger.cleared)
        for (k, v) in local.progress where SyncParcel.isSyncableKey(k) && v.duration > 0 { p.progress[k] = v }
        var bySlot: [String: SyncEntry] = [:]
        var order: [String] = []
        for h in local.history {
            guard let e = entry(h), bySlot[e.slot] == nil else { continue }
            bySlot[e.slot] = e
            order.append(e.slot)
        }
        for (slot, at) in local.ledger.removed {
            guard let e = removal(slot, at), (bySlot[slot]?.at ?? -1) < at else { continue }
            if bySlot[slot] == nil { order.append(slot) }
            bySlot[slot] = e
        }
        p.history = order.compactMap { bySlot[$0] }
        for (k, v) in local.ledger.list where SyncParcel.isSyncableKey(k) && !v.on { p.list[k] = v }
        for k in local.favourites where SyncParcel.isSyncableKey(k) { p.list[k] = .init(at: local.ledger.list[k]?.at ?? 0, on: true) }
        return SyncParcel.trim(p, now: now)
    }

    /** This iPad's records after taking in [merged]. Only newer things replace local ones. */
    static func apply(_ local: Local, _ merged: SyncParcel, maxHistory: Int = 30,
                      resolve: (SyncEntry) async -> LastWatched?) async -> Local {
        let cleared = max(local.ledger.cleared, merged.cleared)
        var progress = local.progress.filter { SyncParcel.keptAfterClear($0.value.at, cleared) }
        for (k, v) in merged.progress where (progress[k]?.at ?? -1) < v.at { progress[k] = v }

        var ledger = SyncLedger(list: local.ledger.list, removed: local.ledger.removed, cleared: cleared)
        var on = local.favourites
        for (k, v) in merged.list {
            let mine = ledger.list[k]?.at ?? (on.contains(k) ? 0 : -1)
            guard v.at > mine else { continue }
            ledger.list[k] = v
            if v.on { if !on.contains(k) { on.append(k) } } else { on.removeAll { $0 == k } }
        }

        var bySlot: [String: LastWatched] = [:]
        for h in local.history where SyncParcel.keptAfterClear(h.at, cleared) && bySlot[h.slot] == nil { bySlot[h.slot] = h }
        for e in merged.history {
            let mine = bySlot[e.slot]
            if e.removed {
                if let m = mine, m.at < e.at { bySlot[e.slot] = nil }
                if (ledger.removed[e.slot] ?? -1) < e.at && (mine == nil || mine!.at < e.at) { ledger.removed[e.slot] = e.at }
                continue
            }
            if let m = mine, m.at >= e.at { continue }
            if (ledger.removed[e.slot] ?? -1) >= e.at { continue }
            if var resolved = await resolve(e) {
                resolved.at = e.at
                bySlot[e.slot] = resolved
            }
        }
        let history = Array(bySlot.values.sorted { $0.at > $1.at }.prefix(maxHistory))
        return Local(progress: progress, history: history, favourites: on, ledger: ledger)
    }
}
