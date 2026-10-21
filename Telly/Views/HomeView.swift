import ImageIO
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if let hero = app.continueWatching.first { Hero(entry: hero) } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Welcome to telly").font(.largeTitle.weight(.bold))
                        Text(app.provider?.isXtream == true
                             ? "Pick something from Live TV, Series or Films, and it'll show up here next time."
                             : "Pick something from Live TV, and it'll show up here next time.").foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 24).padding(.top, 20)
                }
                if !app.continueWatching.isEmpty {
                    Shelf(title: "Continue watching") {
                        ForEach(app.continueWatching, id: \.slot) { h in ContinueCard(entry: h) }
                    }
                }
                let mine = app.favouriteItems()
                if !(mine.films.isEmpty && mine.series.isEmpty && mine.live.isEmpty) {
                    Shelf(title: "My List") {
                        ForEach(mine.series) { s in
                            NavigationLink(value: s) { PosterCard(title: s.name, image: s.cover) }.buttonStyle(.plain)
                        }
                        ForEach(mine.films) { f in
                            NavigationLink(value: FilmLink(film: f)) { PosterCard(title: f.name, image: f.logo) }.buttonStyle(.plain)
                        }
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
                                PosterCard(title: f.name, image: f.logo, progress: app.progressOf(f.url).map(\.fraction))
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
                            NavigationLink(value: s) { PosterCard(title: s.name, image: s.cover) }
                                .buttonStyle(.plain)
                                .contextMenu { FavouriteMenuItem(kind: .series, id: s.id) }
                        }
                    }
                }
                if let error = app.loadError { Text(error).foregroundStyle(.orange).padding(.horizontal, 24) }
            }
            .padding(.bottom, 40)
        }
        .refreshable { await app.refresh() }
        .navigationTitle("")
        .inlineTitle()
        .ignoresSafeArea(edges: .top)
        .background(Theme.background.ignoresSafeArea())
        // A see-through bar rather than none, so the sidebar button stays.
        .clearBar()
        .detailDestinations()
    }
}

/** The big "pick up where you left off" banner. */
private struct Hero: View {
    @Environment(AppModel.self) private var app
    let entry: LastWatched

    var body: some View {
        let item = entry.current
        let p = entry.live ? nil : app.progressOf(item.url)
        ZStack(alignment: .bottomLeading) {
            // Runs up under the status bar, so the top of the screen matches the rest of Home.
            ZStack { if let art = entry.art ?? item.logo { Artwork(url: art, title: "") } }
                .frame(maxWidth: .infinity).frame(height: 340)
                .clipped()
                .background(LinearGradient(colors: [Theme.accent.opacity(0.18), Theme.background], startPoint: .topTrailing, endPoint: .bottomLeading))
                .overlay(LinearGradient(colors: [.clear, Theme.background], startPoint: .top, endPoint: .bottom))
                .overlay(LinearGradient(colors: [Theme.background.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing))
            VStack(alignment: .leading, spacing: 8) {
                Text("PICK UP WHERE YOU LEFT OFF").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(entry.isFilm || entry.live ? item.name : entry.heading).font(.largeTitle.weight(.bold)).lineLimit(2)
                Text(subtitle(entry)).foregroundStyle(Theme.muted)
                if let p { ProgressBar(fraction: p.fraction).frame(width: 240) }
                Button { app.resume(entry) } label: { Label(p.map { Playback.resumePosition($0) > 0 } == true ? "Resume" : "Play", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).padding(.top, 4)
            }
            .padding(24)
        }
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
                          badge: entry.live ? "Live" : entry.isFilm ? "Film" : nil,
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
            .frame(width: 200, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            Text(channel.name).font(.footnote).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 200, alignment: .leading)
        }
        .task(id: channel.logo) {
            guard let url = Artwork.allowed(channel.logo, app),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
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
