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
    nonisolated static let productId = "io.github.tellyteam.telly.plus.yearly"
    /** Where there's no App Store to buy it from yet: the Mac's own release has it included. */
    #if os(macOS) && PLUS
    static let included = true
    #else
    static let included = false
    #endif

    /** Sync and Downloads are open: bought here (or by the family), or by the sync household elsewhere. */
    private(set) var unlocked: Bool
    /** Bought through this Apple Account or its Family Sharing group. */
    private(set) var bought: Bool
    /**
     * The last day the sync household has telly Plus for, as the relay says: bought on a TV (Paddle)
     * or another Apple Account. Days since 1970, like the relay's. Nil when there's none.
     */
    @ObservationIgnored private var householdUntil: Int? {
        didSet { householdConfirmed = Self.covers(householdUntil) }
    }
    /** The relay has confirmed the sync household's telly Plus: until then, its code isn't shown. */
    private(set) var householdConfirmed = false
    /** Set while telly Plus is offered: from Settings, or a locked Sync or Download button. */
    var offered = false
    /**
     * The current subscription as Apple signed it, for the sync relay: it opens Sync for the whole
     * household, Fire TV and LG included. Nil without one.
     */
    @ObservationIgnored private(set) var signedTransaction: String?

    /** Home's one reminder, a few days after telly Plus was first offered, until it's closed. */
    private(set) var reminderClosed: Bool

    @ObservationIgnored private var updates: Task<Void, Never>?
    private static let savedKey = "plus.unlocked"
    private static let householdKey = "plus.household"
    private static let offeredAtKey = "plus.offeredAt"
    private static let reminderClosedKey = "plus.reminderClosed"

    private init() {
        bought = UserDefaults.standard.bool(forKey: Self.savedKey)
        householdUntil = UserDefaults.standard.object(forKey: Self.householdKey) as? Int
        householdConfirmed = Self.covers(householdUntil)
        reminderClosed = UserDefaults.standard.bool(forKey: Self.reminderClosedKey)
        unlocked = false
        unlocked = current()
    }

    /** What the relay says about the household's telly Plus (nil: none, or no household any more). */
    func setHousehold(until day: Int?) {
        householdUntil = day
        UserDefaults.standard.set(day, forKey: Self.householdKey)
        update()
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
        var latest: (expires: Date, jws: String)?
        for await result in Transaction.currentEntitlements {
            // Only transactions Apple signed count.
            guard case let .verified(t) = result else { continue }
            owned.append(Owned(productId: t.productID, expires: t.expirationDate, revoked: t.revocationDate))
            if t.productID == Self.productId, t.revocationDate == nil, let e = t.expirationDate, e > (latest?.expires ?? .distantPast) {
                latest = (e, result.jwsRepresentation)
            }
            await t.finish()
        }
        signedTransaction = latest?.jws
        set(Self.isUnlocked(owned, now: Date()))
    }

    /** Restore purchases: StoreKit asks the App Store for this Apple Account's purchases. */
    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }

    private func set(_ on: Bool) {
        bought = on
        UserDefaults.standard.set(on, forKey: Self.savedKey)
        update()
    }

    private func current() -> Bool {
        Self.included || bought || Self.covers(householdUntil)
    }

    /** Whether [day], the relay's last paid day, is today or later. */
    private static func covers(_ day: Int?) -> Bool {
        day.map { $0 >= Int(Date().timeIntervalSince1970 / 86_400) } ?? false
    }

    private func update() {
        let on = current()
        guard on != unlocked else { return }
        unlocked = on
        Downloads.shared.plusChanged()
    }

    // MARK: Offered after the first watch

    /**
     * Leaving the player after [seconds]: the first time that's a proper watch (five minutes or
     * more), telly Plus is offered, once. After "Not now" it's only offered where it's needed: a
     * locked Download or Sync, Settings, and Home's one reminder.
     */
    func watched(seconds: TimeInterval) {
        let d = UserDefaults.standard
        guard Self.offersAfter(seconds: seconds, unlocked: unlocked || Self.included, offeredBefore: d.object(forKey: Self.offeredAtKey) != nil) else { return }
        d.set(Date().timeIntervalSince1970, forKey: Self.offeredAtKey)
        // Once the player has gone: a sheet can't open while it's still closing.
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            offered = true
        }
    }

    /** Home's reminder: shown from a few days after the first offer, until closed or telly Plus is on. */
    var reminderDue: Bool {
        guard !unlocked, !reminderClosed, let at = UserDefaults.standard.object(forKey: Self.offeredAtKey) as? Double else { return false }
        return Self.reminderDue(offeredAt: Date(timeIntervalSince1970: at), now: Date())
    }

    func closeReminder() {
        reminderClosed = true
        UserDefaults.standard.set(true, forKey: Self.reminderClosedKey)
    }

    /** A proper first watch: long enough to have seen telly working, not a quick look round. */
    #if DEBUG
    nonisolated static let firstWatchSeconds: TimeInterval = ProcessInfo.processInfo.environment["TELLY_DEV_FIRST_WATCH"].flatMap(Double.init) ?? 5 * 60
    #else
    nonisolated static let firstWatchSeconds: TimeInterval = 5 * 60
    #endif
    nonisolated static let reminderDays = 3.0

    nonisolated static func offersAfter(seconds: TimeInterval, unlocked: Bool, offeredBefore: Bool) -> Bool {
        seconds >= firstWatchSeconds && !unlocked && !offeredBefore
    }

    nonisolated static func reminderDue(offeredAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(offeredAt) >= reminderDays * 86_400
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
