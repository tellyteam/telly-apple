import XCTest
@testable import Telly

/**
 * Against the live relay (sync.gettelly.app), only when asked: `TEST_RUNNER_TELLY_LIVE=1` on the
 * xcodebuild command line. Uses the test household's link code (never a real one) and a fresh,
 * random join box, which lapses on its own in 10 minutes.
 */
@MainActor
final class LiveRelayTests: XCTestCase {
    private static let testHousehold = "19MJMVJ72B2AQV8R"

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["TELLY_LIVE"] == "1" else { throw XCTSkip("Live relay tests run only with TELLY_LIVE=1.") }
    }

    /** An add code: the showing device fills its own box; the scanner collects it once. */
    func testAnAddCodeIsCollectedOnce() async throws {
        var join = SyncJoin.new()
        join.takesProvider = true
        try await SyncClient.sendJoin(AppModel.relay, join, code: Self.testHousehold, provider: nil)
        let link = join.url + "&add=1"
        XCTAssertEqual(ScannedCode.parse(link).map { if case .joinHousehold = $0 { return true } else { return false } }, true)
        let found = try await SyncClient.collectJoin(AppModel.relay, join)
        XCTAssertEqual(found, Self.testHousehold)
        let again = try await SyncClient.collectJoin(AppModel.relay, join)
        XCTAssertNil(again, "collected once")
    }

    /** GET …/plus answers in the new shape for the test household. */
    func testTheRelayAnswersAboutTellyPlus() async throws {
        let p = try await SyncClient.plus(AppModel.relay, SyncCrypto.deriveKeys(Self.testHousehold), device: SyncCrypto.newDeviceId())
        print("TELLY_LIVE test household plus: until=\(String(describing: p.until)) store=\(String(describing: p.store))")
        if p.until == nil { XCTAssertNil(p.store) }
    }

    /** Leaves an add code for the Simulator to scan (TELLY_DEV_JOIN), and prints it. */
    func testLeaveAnAddCodeForTheSimulator() async throws {
        guard ProcessInfo.processInfo.environment["TELLY_LIVE_LEAVE"] == "1" else { throw XCTSkip("Only when leaving one for the Simulator.") }
        var join = SyncJoin.new()
        join.takesProvider = true
        try await SyncClient.sendJoin(AppModel.relay, join, code: Self.testHousehold, provider: nil)
        print("TELLY_LIVE add code: \(join.url)&add=1")
    }
}
