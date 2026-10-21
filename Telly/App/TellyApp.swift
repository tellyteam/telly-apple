import SwiftUI

@main
struct TellyApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        // Downloads start with the app, so ones the system kept going reconnect (and, on iPad,
        // so an overnight wake finds its handler).
        _ = Downloads.shared
        #if os(iOS)
        Downloads.registerWake()
        #else
        Updates.start()
        #endif
    }

    var body: some Scene {
        #if os(iOS)
        WindowGroup { root }
        #else
        // One window on a Mac: two players at once would only fight over the provider's connection.
        Window("telly", id: "main") { root }
            .defaultSize(width: 1280, height: 800)
            .commands { TellyCommands(model: model) }
        #endif
    }

    private var root: some View {
        RootView()
            .environment(model)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .task { await model.start() }
            .onChange(of: phase) { _, now in if now == .active { model.becameActive() } }
            .onOpenURL { model.open($0) }
    }
}

#if os(macOS)
/** The menu bar: a Go menu for the pages, and Settings where a Mac app keeps it (⌘,). */
struct TellyCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updates.check() }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { go(.settings) }.keyboardShortcut(",")
        }
        CommandMenu("Go") {
            Button("Home") { go(.home) }.keyboardShortcut("1")
            Button("Search") { go(.search) }.keyboardShortcut("f")
            Button("Live TV") { go(.live) }.keyboardShortcut("2")
            if model.provider?.isXtream == true {
                Button("Films") { go(.films) }.keyboardShortcut("3")
                Button("Series") { go(.series) }.keyboardShortcut("4")
            }
            Button("My List") { go(.myList) }.keyboardShortcut("5")
            if model.provider?.isXtream == true {
                Button("Downloads") { go(.downloads) }.keyboardShortcut("6")
            }
            Divider()
            Button(model.refreshing ? "Refreshing Lists…" : "Refresh Lists") { Task { await model.refresh() } }
                .keyboardShortcut("r")
                .disabled(model.refreshing || model.provider == nil)
        }
    }

    /** Pages aren't reachable while signing in or watching. */
    private func go(_ page: Page) {
        guard model.provider != nil, model.player == nil else { return }
        model.page = page
    }
}
#endif

#if os(iOS)
/** Hands iOS's "background downloads have news" call to the downloads session. */
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Downloads.sessionId else { return completionHandler() }
        Downloads.shared.backgroundEventsDone = completionHandler
    }
}
#endif
