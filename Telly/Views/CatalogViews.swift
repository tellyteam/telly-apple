import SwiftUI

/** Categories on the left, a poster grid on the right. Shared by Films and Series. */
private struct CatalogLayout<Item: Hashable & Identifiable, Card: View>: View {
    let title: String
    let groups: [ItemGroup<Item>]?
    let loading: Bool
    let name: (Item) -> String
    @ViewBuilder let card: (Item) -> Card
    @State private var group: String?
    @State private var filter = ""

    private static var all: String { "\u{1}all" }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $group) {
                ForEach(groups ?? []) { g in
                    HStack { Text(g.name).lineLimit(1); Spacer(); Text("\(g.items.count)").foregroundStyle(Theme.faint).font(.caption) }.tag(g.name)
                }
            }
            .listStyle(.plain)
            .frame(width: 280)
            Divider()
            if groups == nil {
                Message(title: loading ? "Loading…" : "Nothing here yet")
            } else {
                let items = shown
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 18, alignment: .top)], spacing: 22) {
                        ForEach(items) { card($0) }
                    }
                    .padding(20)
                }
                .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter \(title.lowercased())")
            }
        }
        .navigationTitle(group ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if group == nil { group = groups?.first?.name } }
        .detailDestinations()
    }

    private var shown: [Item] {
        let list = groups?.first { $0.name == group }?.items ?? []
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

struct MyListView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let mine = app.favouriteItems()
        ScrollView {
            if mine.films.isEmpty && mine.series.isEmpty && mine.live.isEmpty {
                Message(title: "Nothing in My List yet", detail: "Touch and hold a film or series and choose Add to My List, or swipe a channel to favourite it.")
                    .padding(.top, 120)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
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
            .padding(20)
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
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Films, series and channels")
        .navigationTitle("Search")
        .detailDestinations()
    }
}
