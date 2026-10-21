import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home = "Home", search = "Search", live = "Live TV", films = "Films", series = "Series", myList = "My List", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house"
        case .search: return "magnifyingglass"
        case .live: return "tv"
        case .films: return "film"
        case .series: return "rectangle.stack"
        case .myList: return "heart"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var linkError: String?

    var body: some View {
        @Bindable var app = app
        Group {
            if !app.ready {
                Wordmark(height: 62).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.provider == nil {
                SetupView()
            } else {
                NavigationSplitView {
                    List(selection: $app.page) {
                        ForEach(sections) { s in Label(s.rawValue, systemImage: s.icon).tag(s) }
                    }
                    // The wordmark, as large as on Fire TV and Mac, in place of a small bar title.
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Wordmark(height: 38)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 12)
                    }
                    .inlineTitle()
                    .safeAreaInset(edge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            if app.refreshing {
                                Label("Updating your lists…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(Theme.muted)
                            }
                            if app.providers.count > 1 { providerSwitcher }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                } detail: {
                    NavigationStack {
                        // One dark-slate background on every page, as on the Mac and Fire TV.
                        page(app.page ?? .home)
                            .scrollContentBackground(.hidden)
                            .background(Theme.background.ignoresSafeArea())
                    }
                        .id(app.page)
                }
            }
        }
        .background(Theme.background)
        #if os(iOS)
        .fullScreenCover(item: $app.player) { request in
            PlayerView(request: request).environment(app)
        }
        #else
        // On a Mac the player fills the window, title bar and all, and can go full screen (F, or double-click).
        .toolbar(app.player == nil ? .automatic : .hidden, for: .windowToolbar)
        .overlay {
            if let request = app.player {
                PlayerView(request: request).environment(app).id(request.id).ignoresSafeArea()
            }
        }
        #endif
        .alert("Link this \(Device.name) for sync?", isPresented: Binding(get: { app.pendingLink != nil && app.provider != nil }, set: { if !$0 { app.pendingLink = nil } })) {
            Button("Link") {
                Task {
                    do { try await app.confirmPendingLink() } catch { linkError = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { app.pendingLink = nil }
        } message: {
            Text(app.sync == nil
                 ? "Your progress, Continue watching and My List will be shared with the device that showed this code, end-to-end encrypted."
                 : "This replaces the devices this \(Device.name) syncs with now.")
        }
        .alert("Couldn't link", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(linkError ?? "") }
    }

    /** Which provider is in use, and a quick switch to another. */
    private var providerSwitcher: some View {
        Menu {
            ForEach(app.providers) { saved in
                Button { Task { await app.switchProvider(saved.id) } } label: {
                    if saved.id == app.activeId { Label(saved.provider.name, systemImage: "checkmark") } else { Text(saved.provider.name) }
                }
            }
            Divider()
            Button("Manage providers…") { app.page = .settings }
        } label: {
            Label(app.provider?.name ?? "Provider", systemImage: "antenna.radiowaves.left.and.right")
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .disabled(app.player != nil)
    }

    /** Films and Series only for Xtream providers; M3U playlists are live channels only. */
    private var sections: [Page] {
        app.provider?.isXtream == true ? Page.allCases : Page.allCases.filter { $0 != .films && $0 != .series }
    }

    @ViewBuilder private func page(_ s: Page) -> some View {
        switch s {
        case .home: HomeView()
        case .search: SearchView()
        case .live: LiveView()
        case .films: FilmsView()
        case .series: SeriesListView()
        case .myList: MyListView()
        case .settings: SettingsView()
        }
    }
}

/** A full-page message for empty or failed loads. */
struct Message: View {
    let title: String
    var detail: String?
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            if let detail { Text(detail).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 460) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
