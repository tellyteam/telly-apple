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
                            // Beside Downloads and Settings: lists are otherwise fetched only when 12 hours old.
                            Button { Task { await app.refresh() } } label: {
                                Label(app.refreshing ? "Updating your lists…" : "Refresh lists", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .disabled(app.refreshing)
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
                // Taken now: closing the alert clears the pending link before the task runs.
                guard let link = app.pendingLink else { return }
                Task {
                    do { try await app.confirmLink(link) } catch { linkError = error.localizedDescription }
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
 * A narrow width (iPhone, or an iPad in a narrow Split View): a tab bar instead of the sidebar, five
 * tabs on every iOS: Live TV, Films and Series share Browse, My List and Downloads share Library.
 */
private struct PhoneTabs: View {
    @Environment(AppModel.self) private var app
    @State private var tab: Tab = .home
    /** Library's page, here so Home's Downloads icon can open it there. */
    @SceneStorage("library") private var library: Page = .myList

    enum Tab: String, Hashable { case home, browse, library, search, settings }

    var body: some View {
        TabView(selection: $tab) {
            stack { home }
                .environment(\.showDownloads) { library = .downloads; tab = .library }
                .tabItem { Label("Home", systemImage: "house") }.tag(Tab.home)
            stack { BrowseView().refreshInBar() }
                .tabItem { Label("Browse", systemImage: "tv") }.tag(Tab.browse)
            stack { LibraryView(choice: $library).refreshInBar() }
                .tabItem { Label("Library", systemImage: "heart") }.tag(Tab.library)
            stack { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(Tab.search)
            stack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(Tab.settings)
        }
        // Switching or adding a provider goes back to Home, as the sidebar does.
        .onChange(of: app.page) { _, page in
            if page == .home { tab = .home } else if page == .settings { tab = .settings }
        }
        #if DEBUG
        .onAppear { if let t = DevHooks.env["TELLY_DEV_TAB"].flatMap(Tab.init) { tab = t } }
        #endif
    }

    /** Home with no bar: Refresh and Downloads float over its top right instead. */
    @ViewBuilder private var home: some View {
        let page = HomeView(shortcuts: true).hiddenBar()
        #if DEBUG
        page.devOpen()
        #else
        page
        #endif
    }

    private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
                .scrollContentBackground(.hidden)
                .background(Theme.background.ignoresSafeArea())
        }
    }
}

extension EnvironmentValues {
    /** Opens Downloads where it lives at a narrow width: in Library (for Home's Downloads icon). */
    @Entry var showDownloads: (() -> Void)? = nil
}

/** A tab's pages switched at the top, as one control in the bar; a single page shows on its own. */
private struct Switched<Choice: Hashable, Page: View>: View {
    let label: String
    let choices: [(Choice, String)]
    @Binding var choice: Choice
    @ViewBuilder let page: (Choice) -> Page

    var body: some View {
        // A choice that's gone (a playlist provider has no films) falls back to the first.
        let shown = choices.contains { $0.0 == choice } ? choice : choices[0].0
        // The switcher stands in for the page's title, so no large title repeats it below.
        page(shown)
            .inlineTitle()
            .toolbar {
                if choices.count > 1 {
                    ToolbarItem(placement: .principal) {
                        Picker(label, selection: $choice) {
                            ForEach(choices, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
            }
    }
}

/** Live TV, films and series in one tab at a narrow width. Films and series come only from Xtream providers. */
struct BrowseView: View {
    @Environment(AppModel.self) private var app
    /** The last one chosen, Live TV at first: what most people watch most. */
    @SceneStorage("browse") private var choice: Page = .live

    var body: some View {
        let choices: [(Page, String)] = app.provider?.isXtream == true
            ? [(.live, "Live TV"), (.films, "Films"), (.series, "Series")] : [(.live, "Live TV")]
        Switched(label: "Browse", choices: choices, choice: $choice) { page in
            switch page {
            case .films: FilmsView()
            case .series: SeriesListView()
            default: LiveView()
            }
        }
    }
}

/** My List and Downloads in one tab at a narrow width. Downloads only come from Xtream providers. */
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Binding var choice: Page

    var body: some View {
        let choices: [(Page, String)] = Downloads.available && app.provider?.isXtream == true
            ? [(.myList, "My List"), (.downloads, "Downloads")] : [(.myList, "My List")]
        Switched(label: "Library", choices: choices, choice: $choice) { page in
            if page == .downloads { DownloadsView() } else { MyListView() }
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
