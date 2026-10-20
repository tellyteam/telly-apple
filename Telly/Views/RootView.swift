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
    @State private var section: Page? = .home

    var body: some View {
        @Bindable var app = app
        Group {
            if !app.ready {
                Text("telly").font(.system(size: 64, weight: .black)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.provider == nil {
                SetupView(existing: nil)
            } else {
                NavigationSplitView {
                    List(selection: $section) {
                        ForEach(sections) { s in Label(s.rawValue, systemImage: s.icon).tag(s) }
                    }
                    .navigationTitle("telly")
                    .safeAreaInset(edge: .bottom) {
                        if app.refreshing {
                            Label("Updating your lists…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(Theme.muted).padding()
                        }
                    }
                } detail: {
                    NavigationStack { page(section ?? .home) }
                        .id(section)
                }
            }
        }
        .background(Theme.background)
        .fullScreenCover(item: $app.player) { request in
            PlayerView(request: request).environment(app)
        }
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
