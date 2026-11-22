import XCTest
@testable import Telly

/** When telly Plus is offered: once, after the first proper watch; Home's reminder a few days on. */
final class PlusOfferTests: XCTestCase {
    func testOfferedOnceAfterAProperFirstWatch() {
        XCTAssertFalse(Plus.offersAfter(seconds: 60, unlocked: false, offeredBefore: false), "a quick look round")
        XCTAssertTrue(Plus.offersAfter(seconds: 5 * 60, unlocked: false, offeredBefore: false))
        XCTAssertFalse(Plus.offersAfter(seconds: 3600, unlocked: false, offeredBefore: true), "Not now is for good")
        XCTAssertFalse(Plus.offersAfter(seconds: 3600, unlocked: true, offeredBefore: false), "already has it")
    }

    func testTheReminderWaitsAFewDays() {
        let offered = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(Plus.reminderDue(offeredAt: offered, now: offered.addingTimeInterval(2 * 86_400)))
        XCTAssertTrue(Plus.reminderDue(offeredAt: offered, now: offered.addingTimeInterval(3 * 86_400)))
    }
}

final class PlusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func owned(_ id: String = Plus.productId, expires: TimeInterval? = 86_400, revoked: Bool = false) -> Plus.Owned {
        Plus.Owned(productId: id, expires: expires.map { now.addingTimeInterval($0) }, revoked: revoked ? now : nil)
    }

    /** A current subscription, the buyer's or shared by their family (StoreKit lists both alike), unlocks. */
    func testACurrentSubscriptionUnlocks() {
        XCTAssertTrue(Plus.isUnlocked([owned()], now: now))
    }

    func testNothingOwnedIsLocked() {
        XCTAssertFalse(Plus.isUnlocked([], now: now))
    }

    /** Lapsed: the year ran out without renewing. */
    func testAnExpiredSubscriptionIsLocked() {
        XCTAssertFalse(Plus.isUnlocked([owned(expires: -1)], now: now))
    }

    /** Apple refunded it, or the family member who shared it left the group. */
    func testARevokedSubscriptionIsLocked() {
        XCTAssertFalse(Plus.isUnlocked([owned(revoked: true)], now: now))
    }

    func testSomeOtherProductDoesntUnlock() {
        XCTAssertFalse(Plus.isUnlocked([owned("app.gettelly.telly.something")], now: now))
    }

    /** An old, expired year alongside the renewed one: the renewal counts. */
    func testARenewalCountsOverAnExpiredYear() {
        XCTAssertTrue(Plus.isUnlocked([owned(expires: -86_400), owned(expires: 300 * 86_400)], now: now))
    }
}

#if os(iOS)
import StoreKitTest

/** The whole round trip through StoreKit, with the project's test file (TellyTests/Telly.storekit). */
@MainActor
final class PlusPurchaseTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "Telly")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        // StoreKit testing needs Xcode's StoreKit service: from the command line the product never loads.
        if try await Product.products(for: [Plus.productId]).isEmpty {
            throw XCTSkip("StoreKit testing isn't available here: run these tests from Xcode.")
        }
    }

    override func tearDown() async throws {
        session.clearTransactions()
        await Plus.shared.refresh()
    }

    /**
     * Buys telly Plus in the test session. Where StoreKit won't make test purchases (a CI runner says
     * "notEntitled", though the product loads), the test is skipped, as when the product won't load.
     */
    @discardableResult
    private func buy() async throws -> Transaction {
        do {
            return try await session.buyProduct(identifier: Plus.productId)
        } catch where String(describing: error).contains("notEntitled") {
            throw XCTSkip("StoreKit won't make test purchases here (notEntitled): run these tests from Xcode.")
        }
    }

    /**
     * Asks StoreKit until telly Plus is [expected], for up to 5 seconds: the test session takes a
     * moment to show a purchase, an expiry or a refund in the current entitlements.
     */
    private func expectUnlocked(_ expected: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            await Plus.shared.refresh()
            if Plus.shared.unlocked == expected { return }
            try? await Task.sleep(for: .milliseconds(200))
        } while Date() < deadline
        XCTAssertEqual(Plus.shared.unlocked, expected, message, file: file, line: line)
    }

    func testBuyingUnlocksAndExpiringLocksAgain() async throws {
        await expectUnlocked(false, "nothing bought yet")

        let transaction = try await buy()
        await expectUnlocked(true, "bought")

        // Cancelled, then it runs out. Left to auto-renew, an expiry just renews it: the free trial
        // becomes the paid year, and telly Plus stays on, as it should.
        try session.disableAutoRenewForTransaction(identifier: UInt(transaction.id))
        try session.expireSubscription(productIdentifier: Plus.productId)
        await expectUnlocked(false, "the year ran out")
    }

    func testARefundLocks() async throws {
        let transaction = try await buy()
        await expectUnlocked(true, "bought")

        try session.refundTransaction(identifier: UInt(transaction.id))
        await expectUnlocked(false, "refunded")
    }

    /** Free trial: the 3-day introductory offer is there, and unlocks like the full year. */
    func testTheTrialIsOffered() async throws {
        let product = try await Product.products(for: [Plus.productId]).first
        let offer = try XCTUnwrap(product?.subscription?.introductoryOffer)
        XCTAssertEqual(offer.paymentMode, .freeTrial)
        XCTAssertEqual(offer.period.value, 3)
        XCTAssertEqual(offer.period.unit, .day)
        XCTAssertEqual(product?.subscription?.subscriptionPeriod.unit, .year)
        XCTAssertTrue(product?.isFamilyShareable == true)
    }
}
#endif
