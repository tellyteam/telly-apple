import XCTest
@testable import Telly

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
        XCTAssertFalse(Plus.isUnlocked([owned("io.github.tellyteam.telly.something")], now: now))
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

    func testBuyingUnlocksAndExpiringLocksAgain() async throws {
        await Plus.shared.refresh()
        XCTAssertFalse(Plus.shared.unlocked, "nothing bought yet")

        try await session.buyProduct(identifier: Plus.productId)
        await Plus.shared.refresh()
        XCTAssertTrue(Plus.shared.unlocked, "bought")

        try session.expireSubscription(productIdentifier: Plus.productId)
        await Plus.shared.refresh()
        XCTAssertFalse(Plus.shared.unlocked, "the year ran out")
    }

    func testARefundLocks() async throws {
        let transaction = try await session.buyProduct(identifier: Plus.productId)
        await Plus.shared.refresh()
        XCTAssertTrue(Plus.shared.unlocked)

        try session.refundTransaction(identifier: UInt(transaction.id))
        await Plus.shared.refresh()
        XCTAssertFalse(Plus.shared.unlocked, "refunded")
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
