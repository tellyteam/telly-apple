import SwiftUI

@main
struct TellyApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await model.start() }
                .onChange(of: phase) { _, now in if now == .active { model.becameActive() } }
        }
    }
}
