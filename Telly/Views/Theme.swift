import SwiftUI

enum Theme {
    static let accent = Color(red: 0x4F / 255, green: 0xC3 / 255, blue: 0xF7 / 255)
    static let background = Color(red: 0x0E / 255, green: 0x11 / 255, blue: 0x16 / 255)
    static let surface = Color.white.opacity(0.06)
    static let muted = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.4)
    static let cardRadius: CGFloat = 12
}

/** Artwork from the provider, respecting its "allow plain HTTP" setting. Falls back to a titled tile. */
struct Artwork: View {
    @Environment(AppModel.self) private var app
    let url: String?
    let title: String
    var contentMode: ContentMode = .fill

    var body: some View {
        // Exactly the space it's given: a filled image would otherwise spill outside its frame.
        Color.clear.overlay {
            if let allowed = Artwork.allowed(url, app) {
                AsyncImage(url: allowed, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    // The titled tile only until the image arrives, never behind it.
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: contentMode) } else { placeholder }
                }
            } else {
                placeholder
            }
        }
        .clipped()
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
                Text(title).font(.system(size: 15, weight: .heavy)).foregroundStyle(.white.opacity(0.85)).lineLimit(3).padding(10)
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

/** A 2:3 poster for films and series. */
struct PosterCard: View {
    let title: String
    let image: String?
    var progress: Double?
    var width: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: image, title: title)
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .bottom) {
                    if let progress { ProgressBar(fraction: progress).padding(8) }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            Text(title).font(.footnote).foregroundStyle(Theme.muted).lineLimit(1).frame(width: width, alignment: .leading)
        }
    }
}

/** A 16:9 card with a caption, for Continue watching. */
struct LandscapeCard: View {
    let title: String
    let subtitle: String
    let image: String?
    var badge: String?
    var progress: Double?
    var width: CGFloat = 300

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
    }
}

/** A titled, horizontally scrolling row. */
struct Shelf<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold)).padding(.horizontal, 24)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) { content }.padding(.horizontal, 24)
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

/** The telly wordmark: one drawing shared by every app and icon (SimpleIPTV/brand). */
struct Wordmark: View {
    var height: CGFloat = 28
    var body: some View {
        Image("Wordmark").resizable().renderingMode(.template).aspectRatio(contentMode: .fit)
            .frame(height: height).foregroundStyle(.white).accessibilityLabel("telly")
    }
}
