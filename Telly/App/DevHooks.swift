#if DEBUG
import SwiftUI

/**
 * Testing on a simulator without tapping (debug builds only). Set as launch environment, for
 * example `SIMCTL_CHILD_TELLY_DEV_PROVIDER=… xcrun simctl launch …`:
 *
 * - `TELLY_DEV_PROVIDER=server|username|password`: with no provider yet, signs in to that one
 *   (plain HTTP allowed), such as the fake provider `npm run dev` serves in telly-lg.
 * - `TELLY_DEV_TAB=home|browse|library|search|settings`: the iPhone tab to open on.
 * - `TELLY_DEV_OPEN=film|series`: opens the newest film or series from Home.
 * - `TELLY_DEV_PLAY=film|live`: plays the newest film, or the first channel.
 * - `TELLY_DEV_LANDSCAPE=1`: turns an iPhone to landscape, as if held sideways.
 * - `TELLY_DEV_WATCH=film|series`: puts the newest film, or the newest series, in My List and
 *   watches it to the end (a series' last season), as if played through.
 */
enum DevHooks {
    static let env = ProcessInfo.processInfo.environment

    @MainActor static func signIn(_ app: AppModel) async {
        guard app.providers.isEmpty, let value = env["TELLY_DEV_PROVIDER"] else { return }
        let parts = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return }
        try? await app.saveProvider(.xtream(name: "Test provider", server: parts[0], username: parts[1], password: parts[2], allowCleartext: true))
    }
}

/** Home's side of TELLY_DEV_OPEN and TELLY_DEV_PLAY: once the lists are in, opens or plays. */
private struct DevOpen: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var film: Channel?
    @State private var series: Series?

    func body(content: Content) -> some View {
        content
            .navigationDestination(item: $film) { FilmDetailView(film: $0) }
            .navigationDestination(item: $series) { SeriesDetailView(series: $0) }
            .task {
                if DevHooks.env["TELLY_DEV_LANDSCAPE"] != nil { Device.watchingOrientation(true) }
                guard DevHooks.env["TELLY_DEV_OPEN"] != nil || DevHooks.env["TELLY_DEV_PLAY"] != nil || DevHooks.env["TELLY_DEV_WATCH"] != nil else { return }
                while app.films == nil || app.series == nil { try? await Task.sleep(for: .milliseconds(300)) }
                await watch(DevHooks.env["TELLY_DEV_WATCH"])
                if DevHooks.env["TELLY_DEV_PLAY"] == "film", let f = app.recentlyAdded().first { app.playFilm(f) }
                if DevHooks.env["TELLY_DEV_PLAY"] == "live", let c = app.live?.first?.items.first { app.playChannel(c) }
                switch DevHooks.env["TELLY_DEV_OPEN"] {
                case "film": film = app.recentlyAdded().first
                case "series": series = app.recentlyUpdatedSeries().first
                default: break
                }
            }
    }
}

extension DevOpen {
    @MainActor private func watch(_ kind: String?) async {
        if kind == "film", let f = app.recentlyAdded().first {
            if !app.isFavourite(.film, f.id) { app.toggleFavourite(.film, f.id) }
            app.saveProgress(f.url, position: 5_390_000, duration: 5_400_000)
        }
        if kind == "series", let s = app.recentlyUpdatedSeries().first, let p = app.provider,
           let data = try? await Repo.seriesData(p, s, .network), let season = data.seasons.last(where: { !$0.episodes.isEmpty }) {
            if !app.isFavourite(.series, s.id) { app.toggleFavourite(.series, s.id) }
            for e in season.episodes { app.saveProgress(e.url, position: 2_690_000, duration: 2_700_000) }
            let last = season.episodes.count - 1
            app.recordWatching(PlayRequest(heading: s.name, live: false, items: season.episodes, index: last, seriesId: s.id, art: s.cover), index: last)
            await app.checkForNewEpisodes()
        }
    }
}

extension View {
    func devOpen() -> some View { modifier(DevOpen()) }
}
#endif
