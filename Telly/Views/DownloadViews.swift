import SwiftUI

/** Download, and how it's going, for a film or an episode. [compact] for episode rows. */
struct DownloadButton: View {
    @Environment(AppModel.self) private var app
    let item: Channel
    let kind: DownloadItem.Kind
    var show: String?
    var seriesId: String?
    var art: String?
    var compact = false

    var body: some View {
        let downloads = Downloads.shared
        if let id = app.activeId, Downloads.canDownload(item.url) {
            let d = downloads.item(id, item.url)
            Menu {
                switch d?.state {
                case nil:
                    Button("Download") { downloads.add(providerId: id, item, kind: kind, show: show, seriesId: seriesId, art: art) }
                case .queued?, .downloading?:
                    if d?.state == .queued && !downloads.inWindow() { Button("Download now") { downloads.startNow() } }
                    if d?.state == .downloading { Button("Pause") { downloads.pause(d!.id) } }
                    Button("Cancel download", role: .destructive) { downloads.remove(d!.id) }
                case .paused?:
                    Button("Resume") { downloads.resume(d!.id) }
                    Button("Cancel download", role: .destructive) { downloads.remove(d!.id) }
                case .failed?:
                    Button("Try again") { downloads.resume(d!.id) }
                    Button("Remove", role: .destructive) { downloads.remove(d!.id) }
                case .done?:
                    Button("Delete download", role: .destructive) { downloads.remove(d!.id) }
                }
            } label: {
                if compact { Image(systemName: icon(d)).font(.title3).frame(width: 36, height: 36) } else { Label(text(d), systemImage: icon(d)) }
            } primaryAction: {
                if d == nil { downloads.add(providerId: id, item, kind: kind, show: show, seriesId: seriesId, art: art) }
            }
            .menuIndicator(compact ? .hidden : .visible)
            .fixedSize()
            .foregroundStyle(d?.state == .done ? Theme.accent : (d?.state == .failed ? .orange : .primary))
            .help(text(d))
        }
    }

    private func icon(_ d: DownloadItem?) -> String {
        switch d?.state {
        case nil: return "arrow.down.circle"
        case .queued?: return "clock"
        case .downloading?: return "arrow.down.circle.dotted"
        case .paused?: return "pause.circle"
        case .failed?: return "exclamationmark.circle"
        case .done?: return "checkmark.circle.fill"
        }
    }

    private func text(_ d: DownloadItem?) -> String {
        switch d?.state {
        case nil: return "Download"
        case .queued?: return Downloads.shared.inWindow() ? "Waiting to download" : "Downloads tonight"
        case .downloading?: return "Downloading \(Int((d!.fraction * 100).rounded()))%"
        case .paused?: return "Download paused"
        case .failed?: return "Download failed"
        case .done?: return "Downloaded"
        }
    }
}

/** Downloads: what's saved on this device, what's coming, and the space it takes. */
struct DownloadsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let downloads = Downloads.shared
        let mine = downloads.items(for: app.activeId)
        let coming = mine.filter { $0.state != .done }
        let saved = mine.filter { $0.state == .done }.sorted { $0.added > $1.added }
        Group {
            if mine.isEmpty {
                Message(title: "Nothing downloaded",
                        detail: "Download films and episodes from their pages to watch without a connection. \(schedule(downloads.settings))")
            } else {
                List {
                    if !coming.isEmpty {
                        Section {
                            ForEach(coming) { row($0) }
                        } header: {
                            HStack {
                                Text("Downloading")
                                Spacer()
                                if !downloads.inWindow() { Button("Start now") { downloads.startNow() }.buttonStyle(.borderless) }
                            }
                        } footer: {
                            Text(app.player != nil ? "Paused while you watch." : schedule(downloads.settings))
                        }
                    }
                    if !saved.isEmpty {
                        Section {
                            ForEach(saved) { row($0) }
                        } header: {
                            Text("On this \(Device.name)")
                        } footer: {
                            Text("Using \(bytes(downloads.usedBytes))\(downloads.freeBytes.map { ", \(bytes($0)) free" } ?? "").")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Downloads")
    }

    private func row(_ d: DownloadItem) -> some View {
        HStack(spacing: 14) {
            Artwork(url: d.art, title: d.title).frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(d.show ?? d.title).font(.headline).lineLimit(1)
                if d.show != nil { Text(d.title).font(.subheadline).foregroundStyle(Theme.muted).lineLimit(1) }
                switch d.state {
                case .downloading: ProgressView(value: d.fraction).frame(maxWidth: 260)
                case .failed: Text(d.message ?? "Failed").font(.caption).foregroundStyle(.orange).lineLimit(2)
                case .paused: Text("Paused").font(.caption).foregroundStyle(Theme.muted)
                case .queued: Text(Downloads.shared.inWindow() ? "Waiting" : "Tonight").font(.caption).foregroundStyle(Theme.muted)
                case .done: Text(bytes(d.total)).font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            if d.state == .done {
                Button { play(d) } label: { Image(systemName: "play.circle.fill").font(.title2) }.buttonStyle(.borderless)
            }
            Menu {
                switch d.state {
                case .downloading: Button("Pause") { Downloads.shared.pause(d.id) }
                case .paused, .failed: Button(d.state == .failed ? "Try again" : "Resume") { Downloads.shared.resume(d.id) }
                default: EmptyView()
                }
                Button(d.state == .done ? "Delete download" : "Cancel download", role: .destructive) { Downloads.shared.remove(d.id) }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    /** Plays a download: a film on its own, an episode with its season (from the saved lists). */
    private func play(_ d: DownloadItem) {
        let c = Channel(id: d.itemId ?? d.id, name: d.title, group: d.show ?? "", logo: d.art, url: d.url)
        if d.kind == .episode, let sid = d.seriesId, let s = app.seriesItem(sid) {
            app.playEpisode(s, [c], 0)
        } else {
            app.playFilm(c)
        }
    }

    private func schedule(_ s: DownloadSettings) -> String {
        s.overnight ? "Downloads run overnight, \(hour(s.startHour))–\(hour(s.endHour)). Change this in Settings." : "Downloads start straight away."
    }
}

/** An hour of the overnight window, as 01:00. */
func hour(_ h: Int) -> String { String(format: "%02d:00", h) }

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
