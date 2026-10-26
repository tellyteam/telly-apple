import MediaPlayer

/**
 * What's playing, for the lock screen, Control Center and the Mac's media keys,
 * and the commands they send back. One player at a time: [begin] when it opens, [end] when it closes.
 */
@MainActor
final class NowPlaying {
    struct Commands {
        var togglePlay: () -> Void
        var play: () -> Void
        var pause: () -> Void
        var skip: (Double) -> Void
        var seek: (Double) -> Void
        /** The next episode, or the next channel. */
        var next: () -> Void
        /** The previous channel (live only). */
        var previous: () -> Void
    }

    static let shared = NowPlaying()

    private var tokens: [(MPRemoteCommand, Any)] = []
    private var last: (title: String, playing: Bool, duration: Double, at: Date)?

    func begin(_ c: Commands) {
        end()
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ f: @escaping (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            tokens.append((command, command.addTarget { e in
                MainActor.assumeIsolated { f(e) }
                return .success
            }))
        }
        on(center.togglePlayPauseCommand) { _ in c.togglePlay() }
        on(center.playCommand) { _ in c.play() }
        on(center.pauseCommand) { _ in c.pause() }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        on(center.skipForwardCommand) { _ in c.skip(10) }
        on(center.skipBackwardCommand) { _ in c.skip(-10) }
        on(center.changePlaybackPositionCommand) { e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { c.seek(e.positionTime * 1000) }
        }
        on(center.nextTrackCommand) { _ in c.next() }
        on(center.previousTrackCommand) { _ in c.previous() }
    }

    /** Twice a second from the player; passed on only when something changed, or every 10 s. */
    func update(title: String, subtitle: String, live: Bool, hasNext: Bool, hasPrevious: Bool, position: Double, duration: Double, playing: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.isEnabled = !live
        center.skipBackwardCommand.isEnabled = !live
        center.changePlaybackPositionCommand.isEnabled = !live && duration > 0
        center.nextTrackCommand.isEnabled = hasNext
        center.previousTrackCommand.isEnabled = live && hasPrevious
        if let last, last.title == title, last.playing == playing, last.duration == duration, Date().timeIntervalSince(last.at) < 10 { return }
        last = (title, playing, duration, Date())
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: subtitle,
            MPNowPlayingInfoPropertyIsLiveStream: live,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        if !live && duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration / 1000
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position / 1000
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
        #endif
    }

    /** A seek or a new item: pass the next update on straight away. */
    func refresh() { last = nil }

    func end() {
        for (command, token) in tokens { command.removeTarget(token) }
        tokens = []
        last = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }
}
