import SwiftUI

/** Categories on the left, their channels on the right; tap a channel to watch. */
struct LiveView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.compactWidth) private var compact
    @State private var group: String?
    @State private var filter = ""
    /** What the filter matched, worked out off the main thread; nil while there's no filter. */
    @State private var matches: [Channel]?

    var body: some View {
        let groups = app.live ?? []
        HStack(spacing: 0) {
            // At a narrow width the categories are a menu in the bar instead.
            if !compact { categories(groups); Divider() }
            let channels = matches ?? inGroup
            if app.live == nil {
                Message(title: app.refreshing ? "Loading channels…" : "No channels yet", detail: app.loadError)
            } else if group == Self.favourites && channels.isEmpty && filter.isEmpty {
                Message(title: "No favourite channels yet", detail: Self.howToFavourite)
            } else {
                List(channels) { c in
                    Button { app.playChannel(c, in: group == Self.favourites ? channels : nil) } label: { ChannelRow(channel: c) }
                        .swipeActions { favouriteSwipe(c) }
                        .contextMenu { favouriteSwipe(c) }
                }
                .listStyle(.plain)
                .filterField($filter, prompt: "Filter channels")
            }
        }
        .navigationTitle(group == Self.favourites ? "Favourites" : group == Self.all ? "All channels" : group ?? "Live TV")
        .inlineTitle()
        .toolbar { if compact, !groups.isEmpty { ToolbarItem(placement: .primaryAction) { groupMenu(groups) } } }
        // All, so the filter searches every channel from the start.
        .onAppear { if group == nil { group = Self.all } }
        .task(id: FilterKey(text: filter, group: group, list: app.liveCatalogue?.version, favourites: app.favourites.count)) { await runFilter() }
    }

    private struct FilterKey: Equatable { let text: String; let group: String?; let list: UUID?; let favourites: Int }

    /** After a short pause in typing, so each key press doesn't search every channel. */
    private func runFilter() async {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let catalogue = app.liveCatalogue else { matches = nil; return }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let items: [Channel]? = group == Self.all ? nil : inGroup
        let found = await Task.detached(priority: .userInitiated) { catalogue.filter(q, in: items) }.value
        if !Task.isCancelled { matches = found }
    }

    private func groupMenu(_ groups: [ItemGroup<Channel>]) -> some View {
        Menu {
            Picker("Category", selection: $group) {
                // Always first, even when empty (PLAYBACK.md, Lists).
                Label("Favourites", systemImage: "star.fill").tag(Optional(Self.favourites))
                Text("All channels").tag(Optional(Self.all))
                ForEach(groups) { g in Text(g.name).tag(Optional(g.name)) }
            }
        } label: {
            Label("Categories", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private func categories(_ groups: [ItemGroup<Channel>]) -> some View {
            List(selection: $group) {
                // Always first, even when empty (PLAYBACK.md, Lists).
                Label("Favourites", systemImage: "star.fill").tag(Self.favourites)
                if !groups.isEmpty {
                    HStack { Text("All channels"); Spacer(); Text("\(app.liveCatalogue?.all.count ?? 0)").foregroundStyle(Theme.faint).font(.caption) }
                        .tag(Self.all)
                }
                ForEach(groups) { g in
                    HStack { Text(g.name).lineLimit(1); Spacer(); Text("\(g.items.count)").foregroundStyle(Theme.faint).font(.caption) }.tag(g.name)
                }
            }
            .listStyle(.plain)
            .frame(width: 300)
    }

    private static let favourites = "\u{1}favourites"
    #if os(macOS)
    private static let howToFavourite = "Right-click a channel and choose Favourite."
    #else
    private static let howToFavourite = "Swipe left on a channel, or touch and hold it, and choose Favourite."
    #endif
    private static let all = "\u{1}all"

    /** The chosen category: Favourites, every channel once (prepared with the list), or one category. */
    private var inGroup: [Channel] {
        group == Self.favourites ? app.favouriteItems().live
            : group == Self.all ? app.liveCatalogue?.all ?? []
            : app.live?.first { $0.name == group }?.items ?? []
    }

    @ViewBuilder private func favouriteSwipe(_ c: Channel) -> some View {
        let on = app.isFavourite(.live, c.id)
        Button { app.toggleFavourite(.live, c.id) } label: { Label(on ? "Unfavourite" : "Favourite", systemImage: on ? "star.slash" : "star") }
            .tint(.yellow)
    }
}

struct ChannelRow: View {
    @Environment(AppModel.self) private var app
    let channel: Channel
    var body: some View {
        HStack(spacing: 14) {
            Artwork(url: channel.logo, title: "", contentMode: .fit)
                .frame(width: 64, height: 40)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(channel.name).lineLimit(1)
            Spacer()
            if app.isFavourite(.live, channel.id) { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
        }
        .contentShape(Rectangle())
    }
}
