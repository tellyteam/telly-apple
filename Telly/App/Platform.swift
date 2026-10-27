import Network
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/** What differs between the iPad and Mac apps, so the shared views don't have to. */
enum Device {
    #if os(iOS)
    /** As the user calls this device: "on this iPad", "on this iPhone". */
    @MainActor static var name: String { UIDevice.current.userInterfaceIdiom == .phone ? "iPhone" : "iPad" }
    static let userAgent = "telly-ipad"
    #else
    static let name = "Mac"
    static let userAgent = "telly-mac"
    #endif

    /**
     * Where telly keeps its files. On iPad, Application Support is the app's own; on a Mac it's
     * shared by every app, so telly uses its own folder in it (apart from the old Mac app's).
     */
    static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(iOS)
        return base
        #else
        return base.appendingPathComponent("io.github.tellyteam.telly/native", isDirectory: true)
        #endif
    }

    /** Files unreadable while an iPad is locked. Macs encrypt the whole disk with FileVault instead. */
    static var fileProtection: Data.WritingOptions {
        #if os(iOS)
        return .completeFileProtection
        #else
        return []
        #endif
    }

    /** Files telly needs while the iPad is locked (overnight downloads): readable once it's been unlocked since starting. */
    static var fileProtectionAfterFirstUnlock: Data.WritingOptions {
        #if os(iOS)
        return .completeFileProtectionUntilFirstUserAuthentication
        #else
        return []
        #endif
    }

    /**
     * On iPhone: turns the screen to landscape for watching ([watching] true), and back to
     * portrait after. An iPad (and a Mac) stays as it is.
     */
    @MainActor static func watchingOrientation(_ watching: Bool) {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        // What the app allows (AppDelegate asks): only landscape while watching.
        orientations = watching ? .landscape : .allButUpsideDown
        // After the player's presentation has settled: asked during it, iOS ignores the request.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
            for window in scene.windows { window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: watching ? .landscape : .portrait)) { _ in }
        }
        #endif
    }

    #if os(iOS)
    /** The orientations the app allows now (see [watchingOrientation]). */
    @MainActor static var orientations: UIInterfaceOrientationMask = .all
    #endif

    /** Keeps the screen awake while something plays. */
    @MainActor static func keepAwake(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #else
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playing video")
        } else if !on, let token = awake {
            ProcessInfo.processInfo.endActivity(token)
            awake = nil
        }
        #endif
    }

    #if os(macOS)
    @MainActor private static var awake: NSObjectProtocol?
    #endif
}

extension EnvironmentValues {
    /**
     * A narrow width: an iPhone, or an iPad in a narrow Split View. Pages lay out for the width
     * they have, not the device (tabs instead of the sidebar, one column instead of two).
     */
    var compactWidth: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }
}

extension EnvironmentValues {
    /** A short height: an iPhone held sideways, where every line at the top counts. */
    var shortHeight: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }
}

/** A page's side margin: tighter at a narrow width. */
func pageInset(_ compact: Bool) -> CGFloat { compact ? 16 : 24 }

/**
 * A page's buttons in one line when they fit, else the first on its own line and the rest below,
 * so none is ever squashed.
 */
struct ActionButtons<Primary: View, Rest: View>: View {
    @ViewBuilder let primary: Primary
    @ViewBuilder let rest: Rest

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { primary.fixedSize(); Group { rest }.fixedSize() }
            VStack(alignment: .leading, spacing: 12) {
                primary.fixedSize()
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 12) { Group { rest }.fixedSize() } }
            }
        }
    }
}

extension View {
    /** A small title in the bar (the iPad's inline style; the Mac's window title anyway). */
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /** No title in the window's bar (pages whose artwork runs up behind it). */
    @ViewBuilder func noBarTitle() -> some View {
        #if os(iOS)
        self
        #else
        if #available(macOS 15, *) { toolbar(removing: .title) } else { navigationTitle("") }
        #endif
    }

    /**
     * A text field inside a Form, typed into where its placeholder is. On a Mac a Form would
     * otherwise show the field's title as a label beside it, and put the typing on the right.
     */
    func formField(trailing: Bool = false) -> some View {
        #if os(iOS)
        labelsHidden().multilineTextAlignment(trailing ? .trailing : .leading)
        #else
        labelsHidden().textFieldStyle(.roundedBorder)
        #endif
    }

    /** A bar that shows what's behind it. */
    func clearBar() -> some View {
        #if os(iOS)
        toolbarBackground(.hidden, for: .navigationBar)
        #else
        toolbarBackground(.hidden, for: .windowToolbar)
        #endif
    }

    /** A filter field that stays visible above a list. */
    func filterField(_ text: Binding<String>, prompt: String) -> some View {
        #if os(iOS)
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        #else
        searchable(text: text, placement: .toolbar, prompt: prompt)
        #endif
    }

    /**
     * A page whose artwork runs up behind the bar (a film's or series' page): the bar shows what's
     * behind it, without the shade iOS 26 puts under it, over telly's dark slate.
     */
    @ViewBuilder func artworkPage() -> some View {
        let page = clearBar().background(Theme.background.ignoresSafeArea())
        #if os(iOS)
        if #available(iOS 26, *) { page.scrollEdgeEffectHidden(true, for: .top) } else { page }
        #else
        page
        #endif
    }

    /** No bar at all, nor the shade iOS 26 puts under one: the page runs to the top of the screen. */
    @ViewBuilder func hiddenBar() -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            toolbar(.hidden, for: .navigationBar).scrollEdgeEffectHidden(true, for: .top)
        } else {
            toolbar(.hidden, for: .navigationBar)
        }
        #else
        self
        #endif
    }

    /** Text that isn't prose: addresses, logins, codes. No capitals or corrections added. */
    func plainEntry(url: Bool = false, capitals: Bool = false) -> some View {
        #if os(iOS)
        textInputAutocapitalization(capitals ? .characters : .never)
            .autocorrectionDisabled()
            .keyboardType(url ? .URL : .default)
        #else
        autocorrectionDisabled()
        #endif
    }

    /** While playing: no status bar or home indicator on iPad. */
    func playerChrome(visible: Bool) -> some View {
        #if os(iOS)
        statusBarHidden(!visible).persistentSystemOverlays(.hidden)
        #else
        self
        #endif
    }
}

extension Image {
    /** An image from Core Graphics, at the given scale. */
    init(cgImage: CGImage) {
        self.init(decorative: cgImage, scale: 1)
    }
}

/** Whether there's a connection now: offline, what plays next is the next downloaded item. */
@MainActor @Observable
final class Connectivity {
    static let shared = Connectivity()
    private(set) var online = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in Connectivity.shared.online = path.status == .satisfied }
        }
        monitor.start(queue: .main)
    }
}
