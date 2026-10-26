import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home = "Home", search = "Search", live = "Live TV", films = "Films", series = "Series", myList = "My List", downloads = "Downloads", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house"
        case .search: return "magnifyingglass"
        case .live: return "tv"
        case .films: return "film"
        case .series: return "rectangle.stack"
        case .myList: return "heart"
        case .downloads: return "arrow.down.circle"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.compactWidth) private var compact
    @State private var linkError: String?

    var body: some View {
        @Bindable var app = app
        Group {
            if !app.ready {
                Wordmark(height: 62).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.provider == nil {
                SetupView()
            } else if compact {
                PhoneTabs()
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
                #if os(macOS)
                // Under the player, the pages take no clicks, keys or focus: AppKit-backed lists
                // would otherwise catch them before the player does.
                .allowsHitTesting(app.player == nil)
                .disabled(app.player != nil)
                .opacity(app.player == nil ? 1 : 0)
                .accessibilityHidden(app.player != nil)
                #endif
            }
        }
        .background(Theme.background)
        .background { if app.provider != nil { ArtKeeper() } }
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
        // Films and series (and so downloads) only come from Xtream providers.
        let pages = Downloads.available ? Page.allCases : Page.allCases.filter { $0 != .downloads }
        return app.provider?.isXtream == true ? pages : pages.filter { $0 != .films && $0 != .series && $0 != .downloads }
    }

    @ViewBuilder private func page(_ s: Page) -> some View {
        switch s {
        case .home: HomeView()
        case .search: SearchView()
        case .live: LiveView()
        case .films: FilmsView()
        case .series: SeriesListView()
        case .myList: MyListView()
        case .downloads: DownloadsView()
        case .settings: SettingsView()
        }
    }
}

/**
 * A narrow width (iPhone, or an iPad in a narrow Split View): a tab bar instead of the sidebar.
 * Films and Series share Browse; Downloads and Settings open from Home.
 */
private struct PhoneTabs: View {
    @Environment(AppModel.self) private var app
    @State private var tab: Tab = .home

    enum Tab: String, Hashable { case home, live, browse, myList = "mylist", search }

    var body: some View {
        TabView(selection: $tab) {
            stack { home }
                .tabItem { Label("Home", systemImage: "house") }.tag(Tab.home)
            stack { LiveView() }
                .tabItem { Label("Live TV", systemImage: "tv") }.tag(Tab.live)
            if app.provider?.isXtream == true {
                stack { BrowseView() }
                    .tabItem { Label("Browse", systemImage: "film") }.tag(Tab.browse)
            }
            stack { MyListView() }
                .tabItem { Label("My List", systemImage: "heart") }.tag(Tab.myList)
            stack { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(Tab.search)
        }
        // Switching or adding a provider goes back to Home, as the sidebar does.
        .onChange(of: app.page) { _, page in if page == .home { tab = .home } }
        #if DEBUG
        .onAppear { if let t = DevHooks.env["TELLY_DEV_TAB"].flatMap(Tab.init) { tab = t } }
        #endif
    }

    @ViewBuilder private var home: some View {
        #if DEBUG
        HomeView().toolbar { homeButtons }.devOpen()
        #else
        HomeView().toolbar { homeButtons }
        #endif
    }

    private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
                .scrollContentBackground(.hidden)
                .background(Theme.background.ignoresSafeArea())
                .navigationDestination(for: Page.self) { page in
                    Group {
                        switch page {
                        case .downloads: DownloadsView()
                        default: SettingsView()
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Theme.background.ignoresSafeArea())
                }
        }
    }

    @ToolbarContentBuilder private var homeButtons: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if Downloads.available && app.provider?.isXtream == true {
                NavigationLink(value: Page.downloads) { Label("Downloads", systemImage: Page.downloads.icon) }
            }
            NavigationLink(value: Page.settings) { Label("Settings", systemImage: Page.settings.icon) }
        }
    }
}

/** Films and series in one tab at a narrow width, switched at the top. */
struct BrowseView: View {
    @State private var series = false

    var body: some View {
        Group { if series { SeriesListView() } else { FilmsView() } }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Browse", selection: $series) {
                        Text("Films").tag(false)
                        Text("Series").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
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
