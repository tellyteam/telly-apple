import SwiftUI

/** Categories on the left, a poster grid on the right. Shared by Films and Series. */
private struct CatalogLayout<Item: Hashable & Identifiable, Card: View>: View {
    let title: String
    let groups: [ItemGroup<Item>]?
    let loading: Bool
    let name: (Item) -> String
    @ViewBuilder let card: (Item) -> Card
    @Environment(\.compactWidth) private var compact
    @State private var group: String?
    @State private var filter = ""

    private static var all: String { "\u{1}all" }

    var body: some View {
        HStack(spacing: 0) {
            // At a narrow width the categories are a menu in the bar instead (see groupMenu).
            if !compact { categories; Divider() }
            if groups == nil {
                Message(title: loading ? "Loading…" : "Nothing here yet")
            } else {
                let items = shown
                PosterGrid { ForEach(items) { card($0) } }
                    .filterField($filter, prompt: "Filter \(title.lowercased())")
            }
        }
        .navigationTitle(group == Self.all || group == nil ? title : group!)
        .inlineTitle()
        .toolbar { if compact, let groups, !groups.isEmpty { ToolbarItem(placement: .primaryAction) { groupMenu(groups) } } }
        // All, so the filter searches everything from the start.
        .onAppear { if group == nil { group = Self.all } }
        .detailDestinations()
    }

    private var categories: some View {
            List(selection: $group) {
                if let groups, !groups.isEmpty {
                    HStack { Text("All \(title.lowercased())").lineLimit(1); Spacer(); Text("\(everything.count)").foregroundStyle(Theme.faint).font(.caption) }
                        .tag(Self.all)
                }
                ForEach(groups ?? []) { g in
                    HStack { Text(g.name).lineLimit(1); Spacer(); Text("\(g.items.count)").foregroundStyle(Theme.faint).font(.caption) }.tag(g.name)
                }
            }
            .listStyle(.plain)
            .frame(width: 280)
    }

    private func groupMenu(_ groups: [ItemGroup<Item>]) -> some View {
        Menu {
            Picker("Category", selection: $group) {
                Text("All \(title.lowercased())").tag(Optional(Self.all))
                ForEach(groups) { g in Text(g.name).tag(Optional(g.name)) }
            }
        } label: {
            Label("Categories", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    /** Every item once (providers list some in several categories). */
    private var everything: [Item] {
        var seen = Set<Item.ID>()
        return (groups ?? []).flatMap(\.items).filter { seen.insert($0.id).inserted }
    }

    private var shown: [Item] {
        let list = group == Self.all ? everything : groups?.first { $0.name == group }?.items ?? []
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? list : list.filter { name($0).localizedCaseInsensitiveContains(q) }
    }
}

struct FilmsView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        CatalogLayout(title: "Films", groups: app.films, loading: app.refreshing, name: \.name) { f in
            NavigationLink(value: FilmLink(film: f)) {
                PosterCard(title: f.name, image: f.logo, progress: app.progressOf(f.url).map(\.fraction))
            }
            .buttonStyle(.plain)
            .contextMenu { FavouriteMenuItem(kind: .film, id: f.id) }
        }
    }
}

struct SeriesListView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        CatalogLayout(title: "Series", groups: app.series, loading: app.refreshing, name: \.name) { s in
            NavigationLink(value: s) { PosterCard(title: s.name, image: s.cover) }
                .buttonStyle(.plain)
                .contextMenu { FavouriteMenuItem(kind: .series, id: s.id) }
        }
    }
}

/**
 * Posters in as many columns as fit: at least three at a narrow width (a phone), each poster
 * exactly its column's width.
 */
struct PosterGrid<Content: View>: View {
    @Environment(\.compactWidth) private var compact
    @ViewBuilder let content: Content
    @State private var width: CGFloat = 0

    var body: some View {
        let inset = compact ? 16.0 : 20.0, gap = compact ? 12.0 : 18.0
        let usable = max(0, width - inset * 2)
        let columns = max(compact ? 3 : 2, Int((usable + gap) / ((compact ? 104 : 150) + gap)))
        let poster = columns > 0 ? floor((usable - gap * Double(columns - 1)) / Double(columns)) : 150
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(poster), spacing: gap, alignment: .top), count: columns), alignment: .leading, spacing: compact ? 18 : 22) {
                content
            }
            .environment(\.posterWidth, poster > 0 ? poster : nil)
            .padding(inset)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

struct MyListView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.compactWidth) private var compact
    var body: some View {
        let mine = app.favouriteItems()
        ScrollView {
            if mine.films.isEmpty && mine.series.isEmpty && mine.live.isEmpty {
                Message(title: "Nothing in My List yet", detail: "Touch and hold a film or series and choose Add to My List, or swipe a channel to favourite it.")
                    .padding(.top, 120)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 104 : 150, maximum: 180), spacing: compact ? 12 : 18, alignment: .top)], alignment: .leading, spacing: 22) {
                ForEach(mine.series) { s in
                    NavigationLink(value: s) { PosterCard(title: s.name, image: s.cover) }.buttonStyle(.plain)
                        .contextMenu { FavouriteMenuItem(kind: .series, id: s.id) }
                }
                ForEach(mine.films) { f in
                    NavigationLink(value: FilmLink(film: f)) { PosterCard(title: f.name, image: f.logo, progress: app.progressOf(f.url).map(\.fraction)) }
                        .buttonStyle(.plain)
                        .contextMenu { FavouriteMenuItem(kind: .film, id: f.id) }
                }
            }
            .environment(\.posterWidth, compact ? 104 : nil)
            .padding(pageInset(compact))
            if !mine.live.isEmpty {
                Shelf(title: "Favourite channels") {
                    ForEach(mine.live) { c in Button { app.playChannel(c) } label: { ChannelTile(channel: c) }.buttonStyle(.plain) }
                }
            }
        }
        .navigationTitle("My List")
        .detailDestinations()
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""

    var body: some View {
        let r = app.search(query)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Message(title: "Search films, series and channels").padding(.top, 120)
                } else if r.live.isEmpty && r.films.isEmpty && r.series.isEmpty {
                    Message(title: "Nothing matches “\(query)”").padding(.top, 120)
                }
                if !r.series.isEmpty {
                    Shelf(title: "Series") { ForEach(r.series) { s in NavigationLink(value: s) { PosterCard(title: s.name, image: s.cover) }.buttonStyle(.plain) } }
                }
                if !r.films.isEmpty {
                    Shelf(title: "Films") {
                        ForEach(r.films) { f in NavigationLink(value: FilmLink(film: f)) { PosterCard(title: f.name, image: f.logo) }.buttonStyle(.plain) }
                    }
                }
                if !r.live.isEmpty {
                    Shelf(title: "Channels") { ForEach(r.live) { c in Button { app.playChannel(c) } label: { ChannelTile(channel: c) }.buttonStyle(.plain) } }
                }
            }
            .padding(.vertical, 20)
        }
        .filterField($query, prompt: "Films, series and channels")
        .navigationTitle("Search")
        .detailDestinations()
    }
}
