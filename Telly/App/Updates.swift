#if os(macOS)
import Sparkle

/**
 * Mac updates, with Sparkle: a daily check of the feed each telly-apple release publishes (see
 * Info-Mac.plist), and Check for Updates… in the menu and Settings. An update installs only if
 * it's signed with telly's key, and only when the user says so.
 */
@MainActor
enum Updates {
    private static let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    /** Starts the daily check. Called once, at launch. */
    static func start() {
        _ = controller
    }

    static func check() {
        controller.checkForUpdates(nil)
    }
}
#endif
