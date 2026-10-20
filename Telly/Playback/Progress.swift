import Foundation

/** Where you got to in a film or episode, in milliseconds, and when it was saved (0 for none). */
struct Progress: Codable, Hashable {
    var position: Double
    var duration: Double
    var at: Double = 0

    var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
    var finished: Bool { duration - position < Playback.endMargin(duration) }
    var minutesLeft: Int { max(1, Int(((duration - position) / 60_000).rounded())) }
}

enum Playback {
    /** The "next episode" prompt shows in the last minute. */
    static let endMarginMs: Double = 60_000
    private static let minResumeMs: Double = 15_000

    /** The credits: the last minute, or the last 5% when that's longer. The same rule as on Fire TV and Mac. */
    static func endMargin(_ duration: Double) -> Double { max(endMarginMs, duration / 20) }

    /**
     * Xtream stream URLs embed the username and password (`/series/user/pass/123.mkv`), so the key
     * keeps only the kind and file name: `series/123.mkv`.
     */
    static func progressKey(_ url: String) -> String {
        guard let u = URL(string: url) else { return url }
        let segs = u.path.split(separator: "/").map(String.init)
        return segs.count >= 4 ? "\(segs[segs.count - 4])/\(segs[segs.count - 1])" : url
    }

    /** Where to start: the saved position, unless barely started or already finished. */
    static func resumePosition(_ p: Progress?) -> Double {
        guard let p, p.position >= minResumeMs, !p.finished else { return 0 }
        return p.position
    }

    static let film = "Film"
    static let liveHeading = "Live TV"
}

/** A recently watched thing with its whole playlist (a live group or a season), newest first. */
struct LastWatched: Codable, Hashable {
    /** "Live TV", "Film", or the series name. */
    var heading: String
    var live: Bool
    var index: Int
    var items: [Channel]
    /** Series only, to open its page. */
    var seriesId: String?
    /** Poster or cover for Continue watching. */
    var art: String?
    var at: Double

    var current: Channel { items[min(max(index, 0), items.count - 1)] }
    var isFilm: Bool { !live && heading == Playback.film }

    /** One slot per series, per film, and one for live TV. */
    var slot: String {
        if live { return "live" }
        if isFilm { return "film:\(current.id)" }
        return "series:\(seriesId ?? heading)"
    }

    /**
     * Where "pick up" should go: the next episode if this one was left in its credits (and there is
     * a next one), otherwise this item.
     */
    func continueIndex(_ progressOf: (String) -> Progress?) -> Int {
        let i = min(max(index, 0), items.count - 1)
        if live || i + 1 >= items.count { return i }
        return progressOf(items[i].url)?.finished == true ? i + 1 : i
    }
}

extension Array where Element == LastWatched {
    func remembering(_ entry: LastWatched, max: Int = 30) -> [LastWatched] {
        Array(([entry] + filter { $0.slot != entry.slot }).prefix(max))
    }
}
