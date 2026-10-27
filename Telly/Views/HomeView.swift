import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.compactWidth) private var compact
    /** On iPhone: Downloads and Settings as small icons at the top right, with no bar for them. */
    var shortcuts = false

    var body: some View {
        // No billboard on iPhone: Continue watching, first, shows the same.
        let hero = shortcuts ? nil : app.continueWatching.first
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if let hero { Hero(entry: hero) } else if app.continueWatching.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Welcome to telly").font(.largeTitle.weight(.bold))
                        Text(app.provider?.isXtream == true
                             ? "Pick something from Live TV, Series or Films, and it'll show up here next time."
                             : "Pick something from Live TV, and it'll show up here next time.").foregroundStyle(Theme.muted)
                    }
                    // Below Downloads and Settings, when they're over the top.
                    .padding(.horizontal, pageInset(compact)).padding(.top, shortcuts ? 60 : 20)
                }
                if !app.continueWatching.isEmpty {
                    Shelf(title: "Continue watching") {
                        ForEach(app.continueWatching, id: \.slot) { h in ContinueCard(entry: h) }
                    }
                }
                let mine = app.favouriteItems()
                // Films and series in one row, channels in their own: each row's cards are one shape.
                if !(mine.films.isEmpty && mine.series.isEmpty) {
                    Shelf(title: "My List") {
                        ForEach(mine.series) { s in
                            NavigationLink(value: s) { PosterCard(title: s.name, image: s.cover, watched: app.isWatched(.series, s.id), dimmed: true) }.buttonStyle(.plain)
                        }
                        ForEach(mine.films) { f in
                            NavigationLink(value: FilmLink(film: f)) { PosterCard(title: f.name, image: f.logo, watched: app.isWatched(.film, f.id), dimmed: true) }.buttonStyle(.plain)
                        }
                    }
                }
                if !mine.live.isEmpty {
                    Shelf(title: "Favourite channels") {
                        ForEach(mine.live) { c in
                            Button { app.playChannel(c) } label: { ChannelTile(channel: c) }.buttonStyle(.plain)
                        }
                    }
                }
                let films = app.recentlyAdded()
                if !films.isEmpty {
                    Shelf(title: "Recently added films") {
                        ForEach(films) { f in
                            NavigationLink(value: FilmLink(film: f)) {
                                PosterCard(title: f.name, image: f.logo, progress: app.progressOf(f.url).map(\.fraction), watched: app.isWatched(.film, f.id))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { FavouriteMenuItem(kind: .film, id: f.id) }
                        }
                    }
                }
                let series = app.recentlyUpdatedSeries()
                if !series.isEmpty {
                    Shelf(title: "Recently updated series") {
                        ForEach(series) { s in
                            NavigationLink(value: s) { PosterCard(title: s.name, image: s.cover, watched: app.isWatched(.series, s.id)) }
                                .buttonStyle(.plain)
                                .contextMenu { FavouriteMenuItem(kind: .series, id: s.id) }
                        }
                    }
                }
                if let error = app.loadError { Text(error).foregroundStyle(.orange).padding(.horizontal, pageInset(compact)) }
            }
            .overlay(alignment: .topTrailing) {
                if shortcuts {
                    HStack(spacing: 10) {
                        if Downloads.available && app.provider?.isXtream == true { ShortcutIcon(page: .downloads) }
                        ShortcutIcon(page: .settings)
                    }
                    .padding(.trailing, pageInset(compact))
                }
            }
            .padding(.bottom, 40)
            // Smaller cards on a phone, so a row shows more than two.
            .environment(\.cardScale, compact ? 0.78 : 1)
        }
        .refreshable { await app.refresh() }
        .navigationTitle("")
        .inlineTitle()
        // Only the billboard's artwork runs up under the status bar; without one, Home starts below it.
        .ignoresSafeArea(edges: hero == nil ? [] : .top)
        .background(Theme.background.ignoresSafeArea())
        // A see-through bar rather than none, so the sidebar button stays.
        .clearBar()
        .detailDestinations()
    }
}

/** The big "pick up where you left off" banner. */
private struct Hero: View {
    @Environment(AppModel.self) private var app
    @Environment(\.compactWidth) private var compact
    let entry: LastWatched

    var body: some View {
        let item = entry.current
        let p = entry.live ? nil : app.progressOf(item.url)
        ZStack(alignment: .bottomLeading) {
            // Runs up under the status bar, so the top of the screen matches the rest of Home.
            ZStack { if let art = entry.art ?? item.logo { Artwork(url: art, title: "") } }
                .frame(maxWidth: .infinity).frame(height: compact ? 260 : 340)
                .clipped()
                .background(LinearGradient(colors: [Theme.accent.opacity(0.18), Theme.background], startPoint: .topTrailing, endPoint: .bottomLeading))
                .overlay(LinearGradient(colors: [.clear, Theme.background], startPoint: .top, endPoint: .bottom))
                .overlay(LinearGradient(colors: [Theme.background.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing))
            VStack(alignment: .leading, spacing: 8) {
                Text("PICK UP WHERE YOU LEFT OFF").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(entry.isFilm || entry.live ? item.name : entry.heading).font((compact ? Font.title : .largeTitle).weight(.bold)).lineLimit(2)
                Text(subtitle(entry)).foregroundStyle(Theme.muted)
                if let p { ProgressBar(fraction: p.fraction).frame(width: 240) }
                Button { app.resume(entry) } label: { Label(p.map { Playback.resumePosition($0) > 0 } == true ? "Resume" : "Play", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).padding(.top, 4)
            }
            .padding(pageInset(compact))
        }
    }
}

/** Downloads or Settings over the top of Home: an icon on a dark disc, legible over any artwork. */
private struct ShortcutIcon: View {
    let page: Page

    var body: some View {
        NavigationLink(value: page) {
            Image(systemName: page.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(page.rawValue)
    }
}

func subtitle(_ h: LastWatched) -> String {
    if h.live { return "Live TV · \(h.current.group)" }
    if h.isFilm { return "Film" }
    return "\(h.current.group) · \(h.current.name)"
}

private struct ContinueCard: View {
    @Environment(AppModel.self) private var app
    let entry: LastWatched

    var body: some View {
        let item = entry.items[entry.continueIndex(app.progressOf)]
        Button { app.resume(entry) } label: {
            LandscapeCard(title: entry.isFilm || entry.live ? item.name : entry.heading,
                          subtitle: entry.isFilm ? "Film" : entry.live ? item.group : "\(item.group) · \(item.name)",
                          image: entry.live ? item.logo : (entry.isFilm ? item.logo : item.logo ?? entry.art),
                          badge: entry.live ? "Live" : entry.isFilm ? "Film" : entry.newEpisodes == true ? "New episodes" : nil,
                          progress: entry.live ? nil : app.progressOf(item.url).map(\.fraction))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { app.removeFromHistory(entry) } label: { Label("Remove from Continue watching", systemImage: "xmark.circle") }
        }
    }
}

/**
 * A live channel in a row. Providers send either a logo, shown whole on a dark tile, or a wide
 * picture (a banner for the channel), which fills the tile instead of sitting small inside it.
 */
struct ChannelTile: View {
    @Environment(AppModel.self) private var app
    @Environment(\.cardScale) private var scale
    let channel: Channel
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let image {
                    let wide = Double(image.width) / Double(max(image.height, 1)) >= 1.45
                    Theme.surface
                    Image(decorative: image, scale: 1).resizable()
                        .aspectRatio(contentMode: wide ? .fill : .fit)
                        .padding(wide ? 0 : 18)
                } else {
                    Artwork(url: nil, title: channel.name).placeholder
                }
            }
            .frame(width: 200 * scale, height: 112 * scale)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            Text(channel.name).font(.footnote).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 200 * scale, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(channel.name)
        .task(id: channel.logo) {
            guard let url = Artwork.allowed(channel.logo, app) else { return }
            image = await ArtCache.image(url, providerId: app.activeId)
        }
    }
}

/** Films travel as their own navigation value, so a Channel never means two things. */
struct FilmLink: Hashable { let film: Channel }

extension View {
    /** Film and series pages, reachable from any page. */
    func detailDestinations() -> some View {
        navigationDestination(for: Series.self) { SeriesDetailView(series: $0) }
            .navigationDestination(for: FilmLink.self) { FilmDetailView(film: $0.film) }
    }
}
