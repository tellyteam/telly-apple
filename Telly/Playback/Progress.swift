import Foundation

/** Where you got to in a film or episode, in milliseconds, and when it was saved (0 for none). */
struct Progress: Codable, Hashable {
    var position: Double
    var duration: Double
    var at: Double = 0

    var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
    var finished: Bool { PlaybackRules.watched(position: position, duration: duration) }
    var minutesLeft: Int { max(1, Int(((duration - position) / 60_000).rounded())) }
}

/**
 * telly-sync's PLAYBACK.md as functions, so every app decides the same way; the unit tests run its
 * playback-cases.json. Change the spec and the cases first, then every app.
 */
enum PlaybackRules {
    /** The prompt shows for the last minute, whatever the length. */
    static let promptMs: Double = 60_000
    /** Earlier than this, an item starts from the beginning. */
    static let minResumeMs: Double = 15_000

    /** Seconds the next-episode prompt shows, or nil when it doesn't. */
    static func promptSeconds(duration: Double, position: Double, hasNext: Bool, autoNext: Bool, dismissed: Bool, live: Bool) -> Int? {
        guard !live, hasNext, autoNext, !dismissed, duration > 0 else { return nil }
        let left = (duration - position).rounded()
        guard left >= 1, left <= promptMs else { return nil }
        return Int((left / 1000).rounded(.up))
    }

    /** Whether the next item starts when this one plays to its end. */
    static func advanceAtEnd(hasNext: Bool, autoNext: Bool, dismissed: Bool) -> Bool { hasNext && autoNext && !dismissed }

    /** Within its credits: the last minute or the last 5%, whichever is longer. */
    static func watched(position: Double, duration: Double) -> Bool { duration - position < max(promptMs, duration / 20) }

    /** Where an item starts: its saved position, unless barely started or watched. */
    static func startAt(position: Double?, duration: Double?) -> Double {
        guard let position, let duration, position >= minResumeMs, !watched(position: position, duration: duration) else { return 0 }
        return position
    }

    /** "Pick up" goes to the next item when this one was left watched (and there is one). */
    static func continueIndex(_ index: Int, count: Int, watched: (Int) -> Bool) -> Int {
        index + 1 < count && watched(index) ? index + 1 : index
    }

    /** A Continue watching entry stays while something in it is left: not a watched film, nor a watched last episode. */
    static func shownInContinue(_ index: Int, count: Int, watched: (Int) -> Bool) -> Bool {
        !watched(continueIndex(index, count: count, watched: watched))
    }

    /** My List with watched titles after the rest, each part in My List order. */
    static func myListOrder(_ list: [String], watched: (String) -> Bool) -> [String] {
        list.filter { !watched($0) } + list.filter(watched)
    }

    /** Whether a title leaves My List once watched: a film does, a series stays. */
    static func leavesMyList(kind: String) -> Bool { kind == "film" }

    /** What plays after [index]: the next item, or offline the next downloaded one; nil when nothing can. */
    static func nextPlayable(_ index: Int, count: Int, downloaded: (Int) -> Bool, online: Bool) -> Int? {
        guard index + 1 < count else { return nil }
        return (index + 1 ..< count).first { online || downloaded($0) }
    }
}

/**
 * Spotting new episodes of series watched up to the latest episode they had (PLAYBACK.md,
 * Continue watching). The same rules as on Fire TV and LG.
 */
enum NewEpisodes {
    /**
     * Where watching continues after [watchedId]: that season and the episode's index, or nil if it's
     * the latest, when the series counts as watched (PLAYBACK.md, Watched titles).
     */
    static func after(_ seasons: [Season], _ watchedId: String) -> (Season, Int)? {
        for (s, season) in seasons.enumerated() {
            guard let i = season.episodes.firstIndex(where: { $0.id == watchedId }) else { continue }
            if i + 1 < season.episodes.count { return (season, i + 1) }
            return seasons.dropFirst(s + 1).first { !$0.episodes.isEmpty }.map { ($0, 0) }
        }
        return nil
    }

    /** Whether a series needs fetching again: after the provider changes it, or daily if it doesn't say. */
    static func due(_ series: Series, checked: Check?, now: Double) -> Bool {
        guard let checked else { return true }
        return series.added > 0 ? series.added != checked.added : now - checked.at >= 86_400_000
    }

    /** Whether what comes next arrived after it was watched (older history has no time, so never). */
    static func isNew(_ series: Series, watchedAt: Double) -> Bool {
        watchedAt > 0 && series.added > 0 && series.added * 1000 > watchedAt
    }

    struct Check: Codable { var added: Double; var at: Double }
}

enum Playback {
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
    static func resumePosition(_ p: Progress?) -> Double { PlaybackRules.startAt(position: p?.position, duration: p?.duration) }

    /** A film's id from its progress key (`movie/123.mkv`); nil for anything else. */
    static func filmId(progressKey key: String) -> String? {
        guard key.hasPrefix("movie/") else { return nil }
        let file = key.dropFirst("movie/".count)
        return String(file[..<(file.lastIndex(of: ".") ?? file.endIndex)])
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
    /** The provider added episodes after the last one watched; cleared once something is played. */
    var newEpisodes: Bool? = nil

    var current: Channel { items[min(max(index, 0), items.count - 1)] }
    var isFilm: Bool { !live && heading == Playback.film }

    /** Whether it stays in Continue watching: something in it is left to watch (PLAYBACK.md). */
    func shownInContinue(_ progressOf: (String) -> Progress?) -> Bool {
        live || PlaybackRules.shownInContinue(min(max(index, 0), items.count - 1), count: items.count) { progressOf(items[$0].url)?.finished == true }
    }

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
        if live { return i }
        return PlaybackRules.continueIndex(i, count: items.count) { progressOf(items[$0].url)?.finished == true }
    }
}

extension Array where Element == LastWatched {
    func remembering(_ entry: LastWatched, max: Int = 30) -> [LastWatched] {
        Array(([entry] + filter { $0.slot != entry.slot }).prefix(max))
    }
}
