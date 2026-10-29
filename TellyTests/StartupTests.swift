import XCTest
@testable import Telly

@MainActor
final class StartupTests: XCTestCase {
    /** Woken overnight with the phone locked, telly reads nothing (lists, My List, progress) until it's unlocked. */
    func testStartsOnlyOnceTheDeviceIsUnlocked() async {
        let app = AppModel()
        let (unlocked, unlock) = AsyncStream<Void>.makeStream()
        app.untilUnlocked = { for await _ in unlocked { return } }
        let starting = Task { await app.start() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(app.ready, "locked: nothing is read")
        unlock.yield()
        await starting.value
        XCTAssertTrue(app.ready)
    }

    /** A list that couldn't be read when telly started comes back on the next refresh, even unchanged. */
    func testARefreshShowsTheSavedCopyOfAnUnchangedListThatIsntShowing() async {
        var reads = 0
        let saved: () async -> [Int]? = { reads += 1; return [1] }
        let changed = await AppModel.listToShow([2], showing: true, saved: saved)
        let unchangedShowing = await AppModel.listToShow(nil as [Int]?, showing: true, saved: saved)
        let unchangedMissing = await AppModel.listToShow(nil as [Int]?, showing: false, saved: saved)
        XCTAssertEqual(changed, [2], "a changed list is shown")
        XCTAssertNil(unchangedShowing, "unchanged and on screen: left as it is")
        XCTAssertEqual(unchangedMissing, [1], "unchanged and missing: the saved copy")
        XCTAssertEqual(reads, 1, "the saved copy is read only when it's needed")
    }
}
