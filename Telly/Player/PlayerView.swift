import SwiftUI

/** Full-screen playback with touch controls that hide after a few seconds. */
struct PlayerView: View {
    @Environment(AppModel.self) private var app
    let request: PlayRequest

    @State private var player = PlayerController()
    @State private var index = 0
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing: Double?
    @State private var lastSaved = Date()
    @State private var nextCountdown: Int?
    @State private var dismissedPrompt = false
    @State private var promptDeadline: Date?
    #if os(macOS)
    @FocusState private var focused: Bool
    #endif

    private var item: Channel { request.items[min(max(index, 0), request.items.count - 1)] }
    private var hasNext: Bool { index + 1 < request.items.count }

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
        .overlay { if let n = nextCountdown, hasNext { nextPrompt(n) } }
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
            #if os(macOS)
            // Once the pages underneath have let go of the keyboard.
            DispatchQueue.main.async { focused = true }
            #endif
            start(at: request.startAt ?? (request.live ? 0 : Playback.resumePosition(app.progressOf(item.url))))
            scheduleHide()
        }
        .onDisappear {
            Device.keepAwake(false)
            player.shutdown()
        }
        .onChange(of: player.position) { tick() }
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
            Image(systemName: icon).font(.system(size: big ? 44 : 30, weight: .semibold))
                .frame(width: big ? 96 : 72, height: big ? 96 : 72)
                .background(.black.opacity(0.35), in: Circle())
        }
        // Plain: a Mac otherwise draws its own square bezel around the round button.
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func nextPrompt(_ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Next episode in \(n)").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            Text(request.items[index + 1].name).font(.headline).lineLimit(1)
            HStack {
                Button("Play now") { advance(markWatched: true) }.buttonStyle(.borderedProminent)
                Button("Cancel") { nextCountdown = nil; dismissedPrompt = true }.buttonStyle(.bordered)
            }
        }
        .padding(18).frame(width: 340, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(28).padding(.bottom, 60)
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
        promptDeadline = nil
        dismissedPrompt = false
        // A downloaded film or episode plays from the device.
        let source = Downloads.shared.localURL(app.activeId, item.url)?.absoluteString ?? item.url
        player.load(source, startAt: ms, allowCleartext: app.provider?.allowCleartext ?? false)
    }

    /** Twice a second: save every 10 s, and offer the next episode in the credits. */
    private func tick() {
        guard !request.live, player.duration > 0 else { return }
        if Date().timeIntervalSince(lastSaved) >= 10 { save() }
        let inCredits = player.duration - player.position < Playback.endMargin(player.duration)
        if hasNext && app.settings.autoNext && !dismissedPrompt && inCredits {
            // A 15-second countdown from when the credits start.
            let deadline = promptDeadline ?? Date().addingTimeInterval(15)
            promptDeadline = deadline
            nextCountdown = max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
            if nextCountdown == 0 { advance(markWatched: true) }
        } else if !inCredits {
            nextCountdown = nil
            promptDeadline = nil
        }
    }

    private func save() {
        lastSaved = Date()
        guard !request.live, player.duration > 0 else { return }
        app.saveProgress(item.url, position: player.position, duration: player.duration)
    }

    private func finished() {
        guard !request.live else { return }
        app.saveProgress(item.url, position: player.duration, duration: player.duration)
        if hasNext && app.settings.autoNext { advance(markWatched: false) } else { controlsVisible = true }
    }

    private func advance(markWatched: Bool) {
        guard hasNext else { return }
        if markWatched && player.duration > 0 { app.saveProgress(item.url, position: player.duration, duration: player.duration) } else { save() }
        index += 1
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
