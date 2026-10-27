import SwiftUI

enum Theme {
    static let accent = Color(red: 0x4F / 255, green: 0xC3 / 255, blue: 0xF7 / 255)
    static let background = Color(red: 0x0E / 255, green: 0x11 / 255, blue: 0x16 / 255)
    static let surface = Color.white.opacity(0.06)
    static let muted = Color.white.opacity(0.62)
    /** 55%: at 40% small text fell short of the 4.5:1 contrast it needs on the background. */
    static let faint = Color.white.opacity(0.55)
    static let cardRadius: CGFloat = 12
}

/** Artwork from the provider, respecting its "allow plain HTTP" setting. Falls back to a titled tile. */
struct Artwork: View {
    @Environment(AppModel.self) private var app
    let url: String?
    let title: String
    var contentMode: ContentMode = .fill
    @State private var image: CGImage?

    var body: some View {
        // Exactly the space it's given: a filled image would otherwise spill outside its frame.
        Color.clear.overlay {
            // The titled tile only until the image arrives, never behind it.
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: contentMode).transition(.opacity) } else { placeholder }
        }
        .clipped()
        .task(id: Artwork.allowed(url, app)) {
            image = nil
            guard let allowed = Artwork.allowed(url, app) else { return }
            let loaded = await ArtCache.image(allowed, providerId: app.activeId)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }

    /** The address, if the provider's plain-HTTP setting allows it. */
    static func allowed(_ url: String?, _ app: AppModel) -> URL? {
        url.flatMap(URL.init(string:)).flatMap { u -> URL? in
            guard u.scheme == "https" || (u.scheme == "http" && app.provider?.allowCleartext == true) else { return nil }
            return u
        }
    }

    var placeholder: some View {
        let hue = Double(title.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        return LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.45), Color(hue: hue, saturation: 0.4, brightness: 0.16)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .bottomLeading) {
                Text(title).font(.subheadline.weight(.heavy)).foregroundStyle(.white.opacity(0.85)).lineLimit(3).padding(10)
            }
    }
}

struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(Theme.accent).frame(width: g.size.width * fraction)
            }
        }
        .frame(height: 4)
    }
}

/** Card sizes for the width a page has: smaller on a phone (see HomeView), exact in a grid. */
private struct CardScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
private struct PosterWidthKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
extension EnvironmentValues {
    var cardScale: CGFloat {
        get { self[CardScaleKey.self] }
        set { self[CardScaleKey.self] = newValue }
    }
    /** Set by a grid so each poster fills its column. */
    var posterWidth: CGFloat? {
        get { self[PosterWidthKey.self] }
        set { self[PosterWidthKey.self] = newValue }
    }
}

/** A 2:3 poster for films and series. */
struct PosterCard: View {
    @Environment(\.cardScale) private var scale
    @Environment(\.posterWidth) private var gridWidth
    let title: String
    let image: String?
    var progress: Double?
    var fixedWidth: CGFloat?
    /** Watched (PLAYBACK.md, Watched titles): labelled ✓ Watched, with no progress bar. */
    var watched = false
    /** In My List, a watched poster is dimmed a little; the label and title stay at full strength. */
    var dimmed = false

    private var width: CGFloat { fixedWidth ?? gridWidth ?? 150 * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: image, title: title)
                .frame(width: width, height: width * 1.5)
                .opacity(watched && dimmed ? 0.5 : 1)
                .overlay(alignment: .bottom) {
                    if let progress, !watched { ProgressBar(fraction: progress).padding(8) }
                }
                .overlay(alignment: .topLeading) { if watched { WatchedBadge().padding(8) } }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            Text(title).font(.footnote).foregroundStyle(Theme.muted).lineLimit(1).frame(width: width, alignment: .leading)
        }
        // VoiceOver reads a card as one thing: its name, and how much is watched.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(watched ? "Watched" : progress.map { "\(Int(($0 * 100).rounded())) percent watched" } ?? "")
    }
}

/** "✓ Watched", on a poster or beside a page's title. */
struct WatchedBadge: View {
    var body: some View {
        Label("Watched", systemImage: "checkmark").labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
    }
}

/** A 16:9 card with a caption, for Continue watching. */
struct LandscapeCard: View {
    @Environment(\.cardScale) private var scale
    let title: String
    let subtitle: String
    let image: String?
    var badge: String?
    var progress: Double?

    private var width: CGFloat { 300 * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: image, title: title)
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Text(badge).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5)).padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress { ProgressBar(fraction: progress).padding(10) }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle, badge].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(progress.map { "\(Int(($0 * 100).rounded())) percent watched" } ?? "")
    }
}

/** A titled, horizontally scrolling row. */
struct Shelf<Content: View>: View {
    @Environment(\.compactWidth) private var compact
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold)).padding(.horizontal, pageInset(compact))
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: compact ? 12 : 16) { content }.padding(.horizontal, pageInset(compact))
            }
        }
    }
}

/** For a heart or star toggle in context menus. */
struct FavouriteMenuItem: View {
    @Environment(AppModel.self) private var app
    let kind: FavKind
    let id: String

    var body: some View {
        let on = app.isFavourite(kind, id)
        Button { app.toggleFavourite(kind, id) } label: {
            Label(on ? "Remove from My List" : "Add to My List", systemImage: on ? "heart.slash" : "heart")
        }
    }
}

/** The telly wordmark: one drawing shared by every app and icon (telly-brand). */
struct Wordmark: View {
    var height: CGFloat = 28
    var body: some View {
        Image("Wordmark").resizable().renderingMode(.template).aspectRatio(contentMode: .fit)
            .frame(height: height).foregroundStyle(.white).accessibilityLabel("telly")
    }
}
