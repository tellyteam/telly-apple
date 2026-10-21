import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/** What differs between the iPad and Mac apps, so the shared views don't have to. */
enum Device {
    #if os(iOS)
    /** As the user calls this device: "on this iPad". */
    static let name = "iPad"
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

extension View {
    /** A small title in the bar (the iPad's inline style; the Mac's window title anyway). */
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
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
