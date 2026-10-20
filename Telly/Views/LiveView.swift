import SwiftUI

/** Categories on the left, their channels on the right; tap a channel to watch. */
struct LiveView: View {
    @Environment(AppModel.self) private var app
    @State private var group: String?
    @State private var filter = ""

    var body: some View {
        let groups = app.live ?? []
        HStack(spacing: 0) {
            List(selection: $group) {
                if !app.favouriteItems().live.isEmpty { Label("Favourites", systemImage: "star.fill").tag(Self.favourites) }
                ForEach(groups) { g in
                    HStack { Text(g.name).lineLimit(1); Spacer(); Text("\(g.items.count)").foregroundStyle(Theme.faint).font(.caption) }.tag(g.name)
                }
            }
            .listStyle(.plain)
            .frame(width: 300)
            Divider()
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
                .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter channels")
            }
        }
        .navigationTitle(group == Self.favourites ? "Favourites" : group ?? "Live TV")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if group == nil { group = app.live?.first?.name } }
    }

    private static let favourites = "\u{1}favourites"

    private func shown(_ groups: [ItemGroup<Channel>]) -> [Channel] {
        let list = group == Self.favourites ? app.favouriteItems().live : groups.first { $0.name == group }?.items ?? []
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
