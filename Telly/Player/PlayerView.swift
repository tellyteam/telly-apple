import SwiftUI

/** Full-screen playback with touch controls that hide after a few seconds. */
struct PlayerView: View {
    @Environment(AppModel.self) private var app
    let request: PlayRequest

    @State private var player = PlayerController()
    @ScaledMetric(relativeTo: .title) private var textScale: CGFloat = 1
    /** Up to half as big again, so the controls still fit a phone held sideways. */
    private var controlScale: CGFloat { min(textScale, 1.5) }
    @State private var index = 0
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    @State private var lastSaved = Date()
    @State private var nextCountdown: Int?
    @State private var dismissedPrompt = false
    /** Offline with nothing downloaded after this: said at the end instead of playing on. */
    @State private var endNote: String?
    #if os(macOS)
    @FocusState private var focused: Bool
    #endif

    private var item: Channel { request.items[min(max(index, 0), request.items.count - 1)] }
    /** Live: the next channel. Otherwise what plays next (PLAYBACK.md): offline, the next downloaded item. */
    private var nextIndex: Int? {
        if request.live { return index + 1 < request.items.count ? index + 1 : nil }
        return PlaybackRules.nextPlayable(index, count: request.items.count,
                                          downloaded: { Downloads.shared.localURL(app.activeId, request.items[$0].url) != nil },
                                          online: Connectivity.shared.online)
    }
    private var hasNext: Bool { nextIndex != nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(view: player.view).ignoresSafeArea()
            // Taps land here, not on the video views (VLC's would swallow them).
            Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                #if os(macOS)
                .onTapGesture(count: 2) { toggleFullScreen() }
                #endif
                .onTapGesture { toggleControls() }
            if player.buffering && player.error == nil { ProgressView().controlSize(.large).tint(.white) }
            if let error = player.error {
                VStack(spacing: 14) {
                    Text(error).multilineTextAlignment(.center).frame(maxWidth: 440)
                    HStack {
                        Button("Try again") { start(at: player.position) }.buttonStyle(.borderedProminent)
                        Button("Close") { close() }.buttonStyle(.bordered)
                    }
                }
                .padding(24).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        // Overlays rather than ZStack siblings, so they always sit above the video's UIKit layer.
        .overlay { if controlsVisible { controls.transition(.opacity) } }
        // The small prompt stays out of the way: not while the controls show.
        .overlay { if let n = nextCountdown, hasNext, !controlsVisible { nextPrompt(n) } }
        .overlay(alignment: .top) {
            if let endNote, controlsVisible {
                Text(endNote).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule()).padding(.top, 70)
            }
        }
        .playerChrome(visible: controlsVisible)
        #if os(macOS)
        .onContinuousHover { phase in
            // Moving the mouse brings the controls back; they hide again, with the pointer, after a pause.
            if case .active = phase { showControls() }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(action: key)
        #endif
        .onAppear {
            index = request.index
            Device.keepAwake(true)
            Device.watchingOrientation(true)
            #if os(macOS)
            // Once the pages underneath have let go of the keyboard.
            DispatchQueue.main.async { focused = true }
            #endif
            start(at: request.startAt ?? (request.live ? 0 : Playback.resumePosition(app.progressOf(item.url))))
            scheduleHide()
            beginNowPlaying()
        }
        .onDisappear {
            Device.keepAwake(false)
            Device.watchingOrientation(false)
            NowPlaying.shared.end()
            player.shutdown()
        }
        .onChange(of: player.position) { tick() }
        .onChange(of: player.playing) { updateNowPlaying() }
        .onChange(of: player.ended) { _, ended in if ended { finished() } }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Button(action: close) { Image(systemName: "xmark").font(.title2.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(subtitleText).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                menu
            }
            .padding(.horizontal, 24).padding(.top, 18)
            Spacer()
            HStack(spacing: 56) {
                if request.live {
                    roundButton("chevron.up", "Previous channel") { zap(-1) }.disabled(index == 0)
                } else {
                    roundButton("gobackward.10", "Back 10 seconds") { player.skip(-10); scheduleHide() }
                }
                roundButton(player.playing ? "pause.fill" : "play.fill", player.playing ? "Pause" : "Play", big: true) {
                    player.togglePlay(); scheduleHide()
                }
                if request.live {
                    roundButton("chevron.down", "Next channel") { zap(1) }.disabled(!hasNext)
                } else {
                    roundButton("goforward.10", "Forward 10 seconds") { player.skip(10); scheduleHide() }
                }
            }
            Spacer()
            if !request.live && player.duration > 0 {
                VStack(spacing: 6) {
                    Slider(value: Binding(get: { scrubbing ?? player.position }, set: { scrubbing = $0 }), in: 0...max(player.duration, 1)) { editing in
                        if !editing, let s = scrubbing { player.seek(to: s); scrubbing = nil }
                        scheduleHide(editing ? nil : 3)
                    }
                    HStack {
                        Text(clock(scrubbing ?? player.position))
                        Spacer()
                        if hasNext { Button("Next episode") { advance(markWatched: true) }.font(.callout.weight(.semibold)) }
                        Spacer()
                        Text("-" + clock(max(0, player.duration - (scrubbing ?? player.position))))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 28).padding(.bottom, 24)
            }
        }
        .background(LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false))
        .foregroundStyle(.white)
    }

    private var menu: some View {
        Menu {
            if !player.audioTracks.isEmpty {
                Picker("Audio", selection: Binding(get: { player.audioTrack }, set: { if let id = $0 { player.selectAudio(id) } })) {
                    ForEach(player.audioTracks) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
            }
            Picker("Subtitles", selection: Binding(get: { player.subtitleTrack }, set: { player.selectSubtitle($0) })) {
                Text("Off").tag(String?.none)
                ForEach(player.subtitleTracks) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.menu)
            Toggle("Fill the screen", isOn: Binding(get: { player.fill }, set: { player.fill = $0 }))
        } label: {
            Image(systemName: "ellipsis.circle").font(.title2).frame(width: 44, height: 44)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func roundButton(_ icon: String, _ label: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Sizes follow the reader's text size (Dynamic Type), from these at the default.
            Image(systemName: icon).font(.system(size: (big ? 44 : 30) * controlScale, weight: .semibold))
                .frame(width: (big ? 96 : 72) * controlScale, height: (big ? 96 : 72) * controlScale)
                .background(.black.opacity(0.35), in: Circle())
        }
        // Plain: a Mac otherwise draws its own square bezel around the round button.
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /** PLAYBACK.md's prompt: small, bottom-right; a tap (or Return) plays next now, ✕ (or Esc) cancels it for this item. */
    private func nextPrompt(_ n: Int) -> some View {
        HStack(spacing: 6) {
            Button { advance(markWatched: true) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("▶ Next in \(n)s").font(.caption.weight(.bold))
                    if let next = nextIndex { Text(request.items[next].name).font(.caption2).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A full 44-point target, however small the prompt looks.
            Button { dismissPrompt() } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .padding(.vertical, -10)
                .accessibilityLabel("Cancel the next episode")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(width: 220)
        .background(Color(red: 0.06, green: 0.08, blue: 0.09).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent, lineWidth: 1))
        .opacity(0.9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(16)
    }

    private func dismissPrompt() {
        nextCountdown = nil
        dismissedPrompt = true
    }

    private var title: String { request.live || request.heading == Playback.film ? item.name : request.heading }
    private var subtitleText: String {
        if request.live { return "\(index + 1) of \(request.items.count) · \(item.group)" }
        if request.heading == Playback.film { return item.group }
        return "\(item.group) · \(item.name)"
    }

    private func clock(_ ms: Double) -> String {
        let s = Int(ms / 1000), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() }
    }

    private func scheduleHide(_ seconds: Double? = 4) {
        hideTask?.cancel()
        guard let seconds else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled && player.playing && scrubbing == nil {
                withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
                #if os(macOS)
                NSCursor.setHiddenUntilMouseMoves(true)
                #endif
            }
        }
    }

    #if os(macOS)
    private func showControls() {
        if !controlsVisible { withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true } }
        scheduleHide()
    }

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    /** The keyboard: space, arrows, F for full screen, Esc to leave full screen or the player. */
    private func key(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .space: player.togglePlay()
        case .leftArrow where !request.live: player.skip(-10)
        case .rightArrow where !request.live: player.skip(10)
        case .upArrow where request.live: zap(-1)
        case .downArrow where request.live: zap(1)
        case .return where nextCountdown != nil && !controlsVisible:
            advance(markWatched: true)
            return .handled
        case .escape where nextCountdown != nil && !controlsVisible:
            dismissPrompt()
            return .handled
        case .escape:
            if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true { toggleFullScreen() } else { close() }
        default:
            guard press.characters.lowercased() == "f" else { return .ignored }
            toggleFullScreen()
        }
        showControls()
        return .handled
    }
    #endif

    // MARK: Playback

    private func start(at ms: Double) {
        nextCountdown = nil
        dismissedPrompt = false
        endNote = nil
        NowPlaying.shared.refresh()
        // A downloaded film or episode plays from the device.
        let source = Downloads.shared.localURL(app.activeId, item.url)?.absoluteString ?? item.url
        player.load(source, startAt: ms, allowCleartext: app.provider?.allowCleartext ?? false)
    }

    /** Twice a second: save every 10 s, and count down to the next episode in the last minute. */
    private func tick() {
        updateNowPlaying()
        guard !request.live, player.duration > 0 else { return }
        if Date().timeIntervalSince(lastSaved) >= 10 { save() }
        nextCountdown = PlaybackRules.promptSeconds(duration: player.duration, position: player.position, hasNext: hasNext,
                                                    autoNext: app.settings.autoNext, dismissed: dismissedPrompt, live: request.live)
    }

    private func save() {
        lastSaved = Date()
        guard !request.live, player.duration > 0 else { return }
        app.saveProgress(item.url, position: player.position, duration: player.duration)
    }

    private func finished() {
        guard !request.live else { return }
        app.saveProgress(item.url, position: player.duration, duration: player.duration)
        if PlaybackRules.advanceAtEnd(hasNext: hasNext, autoNext: app.settings.autoNext, dismissed: dismissedPrompt) {
            advance(markWatched: false)
            return
        }
        if index + 1 < request.items.count && !hasNext { endNote = "The next episode isn't downloaded, and there's no connection." }
        controlsVisible = true
    }

    private func advance(markWatched: Bool) {
        guard let next = nextIndex else { return }
        if markWatched && player.duration > 0 { app.saveProgress(item.url, position: player.duration, duration: player.duration) } else { save() }
        index = next
        app.recordWatching(request, index: index)
        start(at: Playback.resumePosition(app.progressOf(item.url)))
    }

    private func zap(_ by: Int) {
        let next = index + by
        guard request.items.indices.contains(next) else { return }
        index = next
        app.recordWatching(request, index: index)
        start(at: 0)
        scheduleHide()
    }

    private func beginNowPlaying() {
        let player = player
        NowPlaying.shared.begin(.init(
            togglePlay: { player.togglePlay() },
            play: { player.resume() },
            pause: { player.pause() },
            skip: { player.skip($0) },
            seek: { player.seek(to: $0); NowPlaying.shared.refresh() },
            next: { request.live ? zap(1) : advance(markWatched: true) },
            previous: { zap(-1) }
        ))
    }

    private func updateNowPlaying() {
        NowPlaying.shared.update(title: title, subtitle: subtitleText, live: request.live, hasNext: hasNext, hasPrevious: index > 0,
                                 position: player.position, duration: player.duration, playing: player.playing)
    }

    private func close() {
        save()
        player.shutdown()
        app.closePlayer()
    }
}

#if os(iOS)
private struct VideoSurface: UIViewRepresentable {
    let view: VideoView
    func makeUIView(context: Context) -> VideoView { view }
    func updateUIView(_ uiView: VideoView, context: Context) {}
}
#else
private struct VideoSurface: NSViewRepresentable {
    let view: VideoView
    func makeNSView(context: Context) -> VideoView { view }
    func updateNSView(_ nsView: VideoView, context: Context) {}
}
#endif
