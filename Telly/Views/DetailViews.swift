import SwiftUI

struct FilmDetailView: View {
    @Environment(AppModel.self) private var app
    let film: Channel
    @State private var details: Details?

    var body: some View {
        let p = app.progressOf(film.url)
        let resumable = Playback.resumePosition(p) > 0
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Artwork(url: details?.backdrop ?? film.logo, title: "")
                    .frame(height: 320)
                    .overlay(LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom))
                HStack(alignment: .top, spacing: 28) {
                    PosterCard(title: "", image: film.logo, width: 180).offset(y: -90).padding(.bottom, -90)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(film.name).font(.largeTitle.weight(.bold))
                        Text(facts(details, group: film.group)).foregroundStyle(Theme.muted)
                        if let p, resumable {
                            HStack { ProgressBar(fraction: p.fraction).frame(width: 200); Text("\(p.minutesLeft) min left").font(.caption).foregroundStyle(Theme.muted) }
                        }
                        HStack(spacing: 12) {
                            Button { app.playFilm(film) } label: { Label(resumable ? "Resume" : "Play", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                            if resumable { Button("Play from the start") { app.playFilm(film, fromStart: true) }.buttonStyle(.bordered) }
                            let fav = app.isFavourite(.film, film.id)
                            Button { app.toggleFavourite(.film, film.id) } label: { Label(fav ? "In My List" : "My List", systemImage: fav ? "checkmark" : "plus") }
                                .buttonStyle(.bordered)
                            DownloadButton(item: film, kind: .film).buttonStyle(.bordered)
                        }
                        if let plot = details?.plot { Text(plot).frame(maxWidth: 640, alignment: .leading) }
                        if let cast = details?.cast { Text("Cast: \(cast)").font(.callout).foregroundStyle(Theme.muted).frame(maxWidth: 640, alignment: .leading) }
                    }
                }
                .padding(.horizontal, 28)
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .noBarTitle()
        .task(id: film.id) { await load() }
    }

    private func load() async {
        guard let p = app.provider else { return }
        if let cached = try? await Repo.filmDetails(p, film, .cache) { details = cached }
        if let fresh = try? await Repo.filmDetails(p, film, .network) { details = fresh }
    }
}

func facts(_ d: Details?, group: String) -> String {
    [d?.year, d?.runtime, d?.genre ?? group, d?.rating.map { "★ \($0)" }].compactMap { $0 }.joined(separator: " · ")
}

struct SeriesDetailView: View {
    @Environment(AppModel.self) private var app
    let series: Series
    @State private var data: SeriesData?
    @State private var failed: String?
    @State private var season = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Artwork(url: data?.details.backdrop ?? series.cover, title: "")
                    .frame(height: 300)
                    .overlay(LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom))
                VStack(alignment: .leading, spacing: 12) {
                    Text(series.name).font(.largeTitle.weight(.bold))
                    Text(facts(data?.details, group: series.group)).foregroundStyle(Theme.muted)
                    HStack(spacing: 12) {
                        if let (s, i) = resumeAt {
                            let ep = data!.seasons[s].episodes[i]
                            let started = Playback.resumePosition(app.progressOf(ep.url)) > 0
                            Button { app.playEpisode(series, data!.seasons[s].episodes, i) } label: {
                                Label("\(started ? "Resume" : "Play") \(data!.seasons[s].name.replacingOccurrences(of: "Season ", with: "S")):E\(i + 1)", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        let fav = app.isFavourite(.series, series.id)
                        Button { app.toggleFavourite(.series, series.id) } label: { Label(fav ? "In My List" : "My List", systemImage: fav ? "checkmark" : "plus") }
                            .buttonStyle(.bordered)
                    }
                    if let plot = data?.details.plot ?? series.plot { Text(plot).frame(maxWidth: 680, alignment: .leading) }
                }
                .padding(.horizontal, 28)
                if let data {
                    HStack(spacing: 16) {
                        if data.seasons.count > 1 {
                            Picker("Season", selection: $season) {
                                ForEach(data.seasons.indices, id: \.self) { Text(data.seasons[$0].name).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        if data.seasons.indices.contains(season), let id = app.activeId,
                           data.seasons[season].episodes.contains(where: { Downloads.canDownload($0.url) && Downloads.shared.item(id, $0.url) == nil }) {
                            Button {
                                for ep in data.seasons[season].episodes {
                                    Downloads.shared.add(providerId: id, ep, kind: .episode, show: series.name, seriesId: series.id, art: series.cover)
                                }
                            } label: { Label("Download season", systemImage: "arrow.down.circle") }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 28)
                    if data.seasons.indices.contains(season) {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(data.seasons[season].episodes.enumerated()), id: \.element.id) { i, ep in
                                EpisodeRow(episode: ep, series: series) { app.playEpisode(series, data.seasons[season].episodes, i) }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                } else {
                    Text(failed ?? "Loading episodes…").foregroundStyle(Theme.muted).padding(.horizontal, 28)
                }
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .noBarTitle()
        .task(id: series.id) { await load() }
    }

    /** The episode to resume: from history, else the first. */
    private var resumeAt: (Int, Int)? {
        guard let data, !data.seasons.isEmpty else { return nil }
        if let h = app.seriesHistory(series.id) {
            let target = h.items[h.continueIndex(app.progressOf)].id
            for (s, season) in data.seasons.enumerated() {
                if let i = season.episodes.firstIndex(where: { $0.id == target }) { return (s, i) }
            }
        }
        return (0, 0)
    }

    private func load() async {
        guard let p = app.provider else { return }
        if let cached = try? await Repo.seriesData(p, series, .cache) { apply(cached) }
        do {
            if let fresh = try await Repo.seriesData(p, series, .network) { apply(fresh) }
        } catch {
            if data == nil { failed = error.localizedDescription }
        }
    }

    private func apply(_ d: SeriesData) {
        let first = data == nil
        data = d
        if first, let (s, _) = resumeAt { season = s }
    }
}

private struct EpisodeRow: View {
    @Environment(AppModel.self) private var app
    let episode: Channel
    let series: Series
    let play: () -> Void

    var body: some View {
        let p = app.progressOf(episode.url)
        Button(action: play) {
            HStack(alignment: .top, spacing: 16) {
                Artwork(url: episode.logo, title: "")
                    .frame(width: 200, height: 112)
                    .overlay(alignment: .bottom) { if let p, !p.finished { ProgressBar(fraction: p.fraction).padding(8) } }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    Text(episode.name).font(.headline).lineLimit(2)
                    HStack(spacing: 8) {
                        if let r = episode.runtime { Text(r) }
                        if let p, p.finished { Text("✓ Watched").foregroundStyle(Theme.accent) }
                        else if let p, Playback.resumePosition(p) > 0 { Text("\(p.minutesLeft) min left") }
                    }
                    .font(.caption).foregroundStyle(Theme.muted)
                    if let plot = episode.plot { Text(plot).font(.callout).foregroundStyle(Theme.muted).lineLimit(3) }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            DownloadButton(item: episode, kind: .episode, show: series.name, seriesId: series.id, art: series.cover, compact: true)
                .buttonStyle(.borderless)
                .padding(8)
        }
    }
}
