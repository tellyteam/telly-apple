import AVFoundation
import Observation
#if os(iOS)
import MobileVLCKit
import UIKit
#else
import AppKit
import VLCKit
#endif

struct Track: Hashable, Identifiable {
    let id: String
    let name: String
}

/**
 * One player surface with two engines: Apple's (AVPlayer) for HLS and MP4, which it plays best and
 * most efficiently, and VLCKit for everything else (MKV, AVI, raw MPEG-TS), or whenever Apple's
 * player gives up. The UI only sees this class.
 */
@MainActor
@Observable
final class PlayerController {
    enum Engine { case apple, vlc }

    private(set) var engine: Engine = .apple
    private(set) var playing = false
    private(set) var buffering = true
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var ended = false
    private(set) var error: String?
    private(set) var audioTracks: [Track] = []
    private(set) var subtitleTracks: [Track] = []
    private(set) var audioTrack: String?
    /** nil: subtitles off (the default). */
    private(set) var subtitleTrack: String?
    var fill = false { didSet { applyFill() } }

    /** The view the video draws into; hosted by PlayerView. */
    let view = VideoView()

    @ObservationIgnored private let av = AVPlayer()
    @ObservationIgnored private var vlc: VLCMediaPlayer?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var startMs: Double = 0
    @ObservationIgnored private var subtitlesSettled = false
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init() {
        av.appliesMediaSelectionCriteriaAutomatically = false
        view.playerLayer.player = av
        view.playerLayer.videoGravity = .resizeAspect
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /** Plays [urlString], starting at [startAt] ms. */
    func load(_ urlString: String, startAt: Double, allowCleartext: Bool) {
        stopEngines()
        (position, duration, ended, error, buffering, playing) = (0, 0, false, nil, true, false)
        (audioTracks, subtitleTracks, audioTrack, subtitleTrack, subtitlesSettled) = ([], [], nil, nil, false)
        guard let u = URL(string: urlString) else { error = "This stream's address isn't valid."; return }
        if u.scheme == "http" && !allowCleartext {
            error = "This stream uses plain HTTP, which is turned off. Allow it in Settings → Your provider."
            return
        }
        url = u
        startMs = startAt
        let ext = u.pathExtension.lowercased()
        log("load .\(ext.isEmpty ? "(none)" : ext) from \(u.scheme ?? "?") start=\(Int(startAt / 1000))s")
        if Self.logging { Task { await Self.probe(u) } }
        if ["m3u8", "mp4", "m4v", "mov", "mp3", "aac", "m4a"].contains(ext) { startApple() } else { startVLC() }
    }

    private func startApple() {
        guard let url else { return }
        engine = .apple
        log("engine: Apple")
        let item = AVPlayerItem(url: url)
        av.replaceCurrentItem(with: item)
        if startMs > 0 { av.seek(to: CMTime(value: CMTimeValue(startMs), timescale: 1000)) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended = true }
        }
        av.play()
        view.showsApple = true
    }

    private func startVLC() {
        guard let url else { return }
        engine = .vlc
        vlcPlayed = false
        log("engine: VLC")
        let player = VLCMediaPlayer()
        player.drawable = view.vlcSurface
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=1500")
        media.addOption(":http-user-agent=\(Device.userAgent)")
        if startMs > 0 { media.addOption(":start-time=\(Int(startMs / 1000))") }
        player.media = media
        vlc = player
        view.showsApple = false
        player.play()
        applyFill()
    }

    private func stopEngines() {
        av.pause()
        av.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        vlc?.stop()
        vlc = nil
    }

    func shutdown() {
        ticker?.invalidate()
        ticker = nil
        stopEngines()
    }

    // MARK: Controls

    func togglePlay() { playing ? pause() : resume() }

    func pause() {
        if engine == .apple { av.pause() } else { vlc?.pause() }
        playing = false
    }

    func resume() {
        if engine == .apple { av.play() } else { vlc?.play() }
        playing = true
    }

    func seek(to ms: Double) {
        let target = max(0, duration > 0 ? min(ms, duration - 1000) : ms)
        if engine == .apple {
            av.seek(to: CMTime(value: CMTimeValue(target), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            vlc?.time = VLCTime(int: Int32(clamping: Int(target)))
        }
        position = target
        ended = false
    }

    func skip(_ seconds: Double) { seek(to: position + seconds * 1000) }

    func selectAudio(_ id: String) {
        if engine == .apple {
            Task { await selectApple(.audible, id) }
        } else if let i = Int32(id) {
            vlc?.currentAudioTrackIndex = i
        }
        audioTrack = id
    }

    func selectSubtitle(_ id: String?) {
        if engine == .apple {
            Task { await selectApple(.legible, id) }
        } else {
            vlc?.currentVideoSubTitleIndex = id.flatMap(Int32.init) ?? -1
        }
        subtitleTrack = id
    }

    private func selectApple(_ c: AVMediaCharacteristic, _ id: String?) async {
        guard let item = av.currentItem, let group = try? await item.asset.loadMediaSelectionGroup(for: c) else { return }
        item.select(id.flatMap { Int($0) }.flatMap { group.options.indices.contains($0) ? group.options[$0] : nil }, in: group)
    }

    private func applyFill() {
        if engine == .apple {
            view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        } else if let vlc {
            let size = view.bounds.size
            if fill, size.width > 0, size.height > 0 {
                vlc.videoCropGeometry = strdup("\(Int(size.width)):\(Int(size.height))")
            } else {
                vlc.videoCropGeometry = nil
            }
        }
    }

    // MARK: State

    private func tick() {
        if engine == .apple { tickApple() } else { tickVLC() }
    }

    private func tickApple() {
        guard let item = av.currentItem else { return }
        if item.status == .failed {
            log("Apple failed: \(item.error.map { ($0 as NSError).domain + " " + String(($0 as NSError).code) + " " + $0.localizedDescription } ?? "no error"); trying VLC")
            // Apple's player can't open it: VLC usually can.
            startMs = position > 0 ? position : startMs
            startVLC()
            return
        }
        let d = item.duration.seconds
        duration = d.isFinite ? d * 1000 : 0
        let t = av.currentTime().seconds
        if t.isFinite { position = t * 1000 }
        playing = av.timeControlStatus == .playing || av.rate > 0
        buffering = av.timeControlStatus == .waitingToPlayAtSpecifiedRate || item.status == .unknown
        if item.status == .readyToPlay && audioTracks.isEmpty { Task { await loadAppleTracks(item) } }
    }

    private func loadAppleTracks(_ item: AVPlayerItem) async {
        let asset = item.asset
        if let g = try? await asset.loadMediaSelectionGroup(for: .audible) {
            audioTracks = g.options.enumerated().map { Track(id: "\($0.offset)", name: $0.element.displayName) }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: g), let i = g.options.firstIndex(of: selected) { audioTrack = "\(i)" }
        }
        if let g = try? await asset.loadMediaSelectionGroup(for: .legible) {
            subtitleTracks = g.options.enumerated().map { Track(id: "\($0.offset)", name: $0.element.displayName) }
            // Subtitles start off, even when a stream marks a track as default.
            item.select(nil, in: g)
        }
    }

    private func tickVLC() {
        guard let vlc else { return }
        if vlc.state != lastState {
            lastState = vlc.state
            log("VLC state \(VLCMediaPlayerStateToString(vlc.state) ?? "?") playing=\(vlc.isPlaying)")
        }
        position = Double(vlc.time.intValue)
        duration = Double(vlc.media?.length.intValue ?? 0)
        playing = vlc.isPlaying
        if vlc.isPlaying { vlcPlayed = true }
        switch vlc.state {
        case .error:
            failed()
        case .stopped where !vlcPlayed && error == nil:
            // VLC gives up on a refused stream by stopping before it ever plays.
            failed()
        case .ended:
            ended = true
        case .buffering, .opening:
            buffering = !vlc.isPlaying
        default:
            buffering = false
        }
        if vlc.isPlaying {
            let names = vlc.audioTrackNames as? [String] ?? []
            let ids = (vlc.audioTrackIndexes as? [NSNumber] ?? []).map { "\($0.intValue)" }
            let tracks = zip(ids, names).filter { $0.0 != "-1" }.map { Track(id: $0.0, name: $0.1) }
            if tracks != audioTracks { audioTracks = tracks; audioTrack = "\(vlc.currentAudioTrackIndex)" }
            let subNames = vlc.videoSubTitlesNames as? [String] ?? []
            let subIds = (vlc.videoSubTitlesIndexes as? [NSNumber] ?? []).map { "\($0.intValue)" }
            let subs = zip(subIds, subNames).filter { $0.0 != "-1" }.map { Track(id: $0.0, name: $0.1) }
            if subs != subtitleTracks { subtitleTracks = subs }
            if !subtitlesSettled {
                // Subtitles start off, even when a file marks a track as default.
                vlc.currentVideoSubTitleIndex = -1
                subtitlesSettled = true
            }
            logStats(vlc)
        }
    }

    /** Troubleshooting (TELLY_PLAYER_LOG): pictures shown and lost, every 5 s. Never the address. */
    private func logStats(_ vlc: VLCMediaPlayer) {
        guard Self.logging, let stats = vlc.media?.statistics, Date().timeIntervalSince(lastLog) >= 5 else { return }
        lastLog = Date()
        let line = "player: \(Int(position / 1000))s shown=\(stats.displayedPictures) lost=\(stats.lostPictures) audio lost=\(stats.lostAudioBuffers) \(Int(stats.inputBitrate * 8000)) kbit/s\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    @ObservationIgnored private var lastLog = Date.distantPast
    @ObservationIgnored private var lastState: VLCMediaPlayerState?
    @ObservationIgnored private var vlcPlayed = false
    @ObservationIgnored private var explaining = false

    /** Neither engine could play it: says why, from how the provider answers for the stream. */
    private func failed() {
        guard error == nil, !explaining, let url else { return }
        explaining = true
        buffering = false
        Task {
            let status = await Self.status(of: url)
            explaining = false
            guard self.url == url else { return }
            error = Self.explain(status)
            log("failed: provider answered \(status.map(String.init) ?? "nothing")")
        }
    }

    /** What the provider answers for [url] (the status only), or nil if it can't be reached. */
    private static func status(of url: URL) async -> Int? {
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        r.setValue("\(Device.userAgent)/1", forHTTPHeaderField: "User-Agent")
        return ((try? await URLSession.shared.data(for: r))?.1 as? HTTPURLResponse)?.statusCode
    }

    static func explain(_ status: Int?) -> String {
        switch status {
        case nil: return "Couldn't reach your provider. Check your internet connection."
        case 401: return "Your provider didn't accept the login for this stream. Check it in Settings → Providers."
        case 403, 511:
            return "Your provider refused this stream. This often happens on a VPN: try turning it off. If not, the channel may be off air, or not part of your subscription."
        case 404, 410: return "This stream isn't on your provider any more. Refreshing your lists in Settings may help."
        case 458, 509: return "Your provider says the account is already in use, perhaps on another device. Stop watching there and try again."
        case 429, 503: return "Your provider is busy. Try again in a minute."
        default: return "This stream won't play. It may be off air, or in a format telly can't open."
        }
    }

    /**
     * Troubleshooting: asks for the stream as each player would, and logs only what came back
     * (status, type, the host it was redirected to, the playlist's first line). Never the address.
     */
    private static func probe(_ url: URL) async {
        // The same stream in the other live format, too.
        let other = url.pathExtension == "m3u8" ? url.deletingPathExtension().appendingPathExtension("ts") : nil
        for (agent, target) in [("AppleCoreMedia/1.0.0 (Macintosh)", url), ("VLC/3.0.21 LibVLC/3.0.21", url), ("\(Device.userAgent)/1", url)]
            + (other.map { [("VLC/3.0.21 .ts", $0)] } ?? []) {
            let url = target
            var r = URLRequest(url: url, timeoutInterval: 15)
            r.setValue(agent, forHTTPHeaderField: "User-Agent")
            r.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            do {
                let (data, response) = try await URLSession.shared.data(for: r)
                let h = response as? HTTPURLResponse
                let moved = response.url?.host != url.host ? " redirected to \(response.url?.host ?? "?")" : ""
                let first = String(decoding: data.prefix(60), as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
                let safeFirst = first.hasPrefix("#") ? first : "(\(data.count) bytes)"
                FileHandle.standardError.write(Data("player: probe [\(agent.prefix(14))] \(h?.statusCode ?? 0) \(h?.value(forHTTPHeaderField: "Content-Type") ?? "-")\(moved) \(safeFirst)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("player: probe [\(agent.prefix(14))] failed: \((error as NSError).code) \(error.localizedDescription)\n".utf8))
            }
        }
    }

    /** Troubleshooting (TELLY_PLAYER_LOG): what the player does. Never the address (it holds the login). */
    private func log(_ line: String) {
        guard Self.logging else { return }
        FileHandle.standardError.write(Data("player: \(line)\n".utf8))
    }
    private static let logging = ProcessInfo.processInfo.environment["TELLY_PLAYER_LOG"] != nil
}

#if os(iOS)
/** Hosts both engines' output: an AVPlayerLayer, and a plain view VLC draws into. */
final class VideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    let vlcSurface = UIView()

    var showsApple = true {
        didSet { vlcSurface.isHidden = showsApple }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        vlcSurface.isUserInteractionEnabled = false
        vlcSurface.backgroundColor = .black
        vlcSurface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vlcSurface.isHidden = true
        addSubview(vlcSurface)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        vlcSurface.frame = bounds
    }
}
#else
/** Hosts both engines' output: an AVPlayerLayer, and a plain view VLC draws into. */
final class VideoView: NSView {
    let playerLayer = AVPlayerLayer()
    let vlcSurface = NSView()

    var showsApple = true {
        didSet { vlcSurface.isHidden = showsApple }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
        vlcSurface.wantsLayer = true
        vlcSurface.layer?.backgroundColor = NSColor.black.cgColor
        vlcSurface.autoresizingMask = [.width, .height]
        vlcSurface.isHidden = true
        addSubview(vlcSurface)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        vlcSurface.frame = bounds
    }

    /** Clicks and hovers go to the player's controls, not the video. */
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
