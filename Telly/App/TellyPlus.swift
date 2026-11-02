import StoreKit
import SwiftUI

/**
 * telly Plus: a yearly subscription, through the App Store, that unlocks Sync and Downloads. One
 * subscription covers its Family Sharing group. Everything else in telly is free.
 *
 * Whether it's unlocked comes from StoreKit's signed transactions, which it keeps on the device, so
 * it's known offline. The last answer is also saved, for an overnight wake before StoreKit replies.
 * The Mac, sold outside the App Store until it moves there, has Plus included.
 */
@MainActor
@Observable
final class Plus {
    static let shared = Plus()
    static let productId = "io.github.tellyteam.telly.plus.yearly"
    /** Where there's no App Store to buy it from yet: the Mac's own release has it included. */
    #if os(macOS) && PLUS
    static let included = true
    #else
    static let included = false
    #endif

    /** Sync and Downloads are open. */
    private(set) var unlocked: Bool
    /** Set while telly Plus is offered: from Settings, or a locked Sync or Download button. */
    var offered = false

    @ObservationIgnored private var updates: Task<Void, Never>?
    private static let savedKey = "plus.unlocked"

    private init() {
        unlocked = Self.included || UserDefaults.standard.bool(forKey: Self.savedKey)
    }

    /** At launch: reads what's owned, then follows renewals, refunds and Family Sharing changes. */
    func start() {
        guard !Self.included, updates == nil else { return }
        updates = Task {
            await refresh()
            for await result in Transaction.updates {
                if case let .verified(t) = result { await t.finish() }
                await refresh()
            }
        }
    }

    /** Asks StoreKit again: after a purchase, a restore, or any change it reports. */
    func refresh() async {
        guard !Self.included else { return }
        var owned: [Owned] = []
        for await result in Transaction.currentEntitlements {
            // Only transactions Apple signed count.
            guard case let .verified(t) = result else { continue }
            owned.append(Owned(productId: t.productID, expires: t.expirationDate, revoked: t.revocationDate))
            await t.finish()
        }
        set(Self.isUnlocked(owned, now: Date()))
    }

    /** Restore purchases: StoreKit asks the App Store for this Apple Account's purchases. */
    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }

    private func set(_ on: Bool) {
        guard on != unlocked else { return }
        unlocked = on
        UserDefaults.standard.set(on, forKey: Self.savedKey)
        Downloads.shared.plusChanged()
    }

    // MARK: The rule

    /** A transaction StoreKit says this Apple Account (or its family) holds. */
    struct Owned: Equatable {
        var productId: String
        var expires: Date?
        var revoked: Date?
    }

    /** Unlocked while a telly Plus subscription is current: not expired, not refunded. */
    nonisolated static func isUnlocked(_ owned: [Owned], now: Date) -> Bool {
        owned.contains { $0.productId == productId && $0.revoked == nil && ($0.expires.map { $0 > now } ?? true) }
    }
}
