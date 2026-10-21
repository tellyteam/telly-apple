import SwiftUI

@main
struct TellyApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        #if os(iOS)
        WindowGroup { root }
        #else
        // One window on a Mac: two players at once would only fight over the provider's connection.
        Window("telly", id: "main") { root }
            .defaultSize(width: 1280, height: 800)
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
