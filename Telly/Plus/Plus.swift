#if !PLUS
import SwiftUI

// The free build. Downloads are part of telly's paid extras, which come from a private repo
// (scripts/plus.sh) and build with the PLUS flag. These stand-ins have the same names, do nothing,
// and say there are no downloads, so the rest of the app is the same in both builds.

/** A film or episode saved on the device: never, in the free build. */
struct DownloadItem: Equatable {
    enum Kind: String { case film, episode }
    var art: String?
}

@MainActor
@Observable
final class Downloads {
    static let shared = Downloads()
    static let available = false
    static let sessionId = ""
    var watching = false
    @ObservationIgnored var backgroundEventsDone: (() -> Void)?

    static func registerWake() {}
    static func canDownload(_ url: String) -> Bool { false }
    func item(_ providerId: String?, _ url: String) -> DownloadItem? { nil }
    func items(for providerId: String?) -> [DownloadItem] { [] }
    func localURL(_ providerId: String?, _ url: String) -> URL? { nil }
    func add(providerId: String, _ c: Channel, kind: DownloadItem.Kind, show: String? = nil, seriesId: String? = nil, art: String? = nil) {}
    func removeAll(providerId: String) {}
    func removeWatched(_ providerId: String?, playing: String? = nil, watched: (String) -> Bool) {}
}

struct DownloadButton: View {
    let item: Channel
    let kind: DownloadItem.Kind
    var show: String?
    var seriesId: String?
    var art: String?
    var compact = false
    var body: some View { EmptyView() }
}

struct DownloadsView: View {
    var body: some View { EmptyView() }
}

struct DownloadSettingsSection: View {
    var body: some View { EmptyView() }
}
#endif
