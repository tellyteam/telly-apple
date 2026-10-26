import SwiftUI

/** Categories on the left, their channels on the right; tap a channel to watch. */
struct LiveView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.compactWidth) private var compact
    @State private var group: String?
    @State private var filter = ""

    var body: some View {
        let groups = app.live ?? []
        HStack(spacing: 0) {
            // At a narrow width the categories are a menu in the bar instead.
            if !compact { categories(groups); Divider() }
            let channels = shown(groups)
            if app.live == nil {
                Message(title: app.refreshing ? "Loading channels…" : "No channels yet", detail: app.loadError)
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
    }

    private func groupMenu(_ groups: [ItemGroup<Channel>]) -> some View {
        Menu {
            Picker("Category", selection: $group) {
                if !app.favouriteItems().live.isEmpty { Label("Favourites", systemImage: "star.fill").tag(Optional(Self.favourites)) }
                Text("All channels").tag(Optional(Self.all))
                ForEach(groups) { g in Text(g.name).tag(Optional(g.name)) }
            }
        } label: {
            Label("Categories", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private func categories(_ groups: [ItemGroup<Channel>]) -> some View {
            List(selection: $group) {
                if !app.favouriteItems().live.isEmpty { Label("Favourites", systemImage: "star.fill").tag(Self.favourites) }
                if !groups.isEmpty {
                    HStack { Text("All channels"); Spacer(); Text("\(Self.everything(groups).count)").foregroundStyle(Theme.faint).font(.caption) }
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
    private static let all = "\u{1}all"

    /** Every channel once (providers list some in several categories). */
    private static func everything(_ groups: [ItemGroup<Channel>]) -> [Channel] {
        var seen = Set<String>()
        return groups.flatMap(\.items).filter { seen.insert($0.id).inserted }
    }

    private func shown(_ groups: [ItemGroup<Channel>]) -> [Channel] {
        let list = group == Self.favourites ? app.favouriteItems().live
            : group == Self.all ? Self.everything(groups)
            : groups.first { $0.name == group }?.items ?? []
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? list : list.filter { $0.name.localizedCaseInsensitiveContains(q) }
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
