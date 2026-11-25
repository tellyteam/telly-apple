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
    nonisolated static let productId = "app.gettelly.telly.plus.yearly"
    /**
     * Its subscription group in App Store Connect. The App Store's sheet is given the group, not the
     * product: given the product it says "Subscription Unavailable" even though the product loads.
     */
    nonisolated static let groupId = "22576800"
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
    private(set) var householdUntil: Int?
    /**
     * Which store sold the household's telly Plus, as the relay says: "apple" or "paddle" (nil when
     * it doesn't say, for a purchase it recorded before it kept that). Settings → Manage
     * subscription goes to Apple only for "apple": a TV's is managed from Paddle's emails.
     */
    private(set) var householdStore: String?
    /** When this Apple Account's (or its family's) subscription renews or ends. */
    private(set) var boughtUntil: Date?
    /**
     * Set while telly Plus is offered, with what opened the offer: Settings, Home's reminder, the
     * first watch, a locked Download, or a telly code that would add this device to a household.
     */
    var offered: Offer?
    /** Whether this Apple Account can still have the free trial: the buy button says so. */
    private(set) var trialAvailable = false
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
    private static let storeKey = "plus.store"
    private static let offeredAtKey = "plus.offeredAt"
    private static let reminderClosedKey = "plus.reminderClosed"

    private init() {
        bought = UserDefaults.standard.bool(forKey: Self.savedKey)
        householdUntil = UserDefaults.standard.object(forKey: Self.householdKey) as? Int
        householdStore = UserDefaults.standard.string(forKey: Self.storeKey)
        reminderClosed = UserDefaults.standard.bool(forKey: Self.reminderClosedKey)
        unlocked = false
        unlocked = current()
    }

    /** What the relay says about the household's telly Plus (nil: none, or no household any more). */
    func setHousehold(until day: Int?, store: String? = nil) {
        householdUntil = day
        householdStore = day == nil ? nil : store
        UserDefaults.standard.set(day, forKey: Self.householdKey)
        UserDefaults.standard.set(householdStore, forKey: Self.storeKey)
        update()
    }

    /**
     * The last day telly Plus is known to be on for: the household's, or this Apple Account's
     * own subscription, whichever is later. Nil when neither says.
     */
    var onUntil: Date? {
        let household = householdUntil.flatMap { Self.covers($0) ? Date(timeIntervalSince1970: Double($0) * 86_400) : nil }
        let own = bought ? boughtUntil : nil
        return [household, own].compactMap { $0 }.max()
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
        boughtUntil = latest?.expires
        set(Self.isUnlocked(owned, now: Date()))
        trialAvailable = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: Self.groupId)
    }

    /** Where Settings → Manage subscription leads. */
    enum Manage: Equatable {
        /** Apple's subscriptions sheet. */
        case apple
        /** Bought on a TV: managed from Paddle's emails, never linked from an Apple app. */
        case paddle
        /** Nothing to manage from here (the Mac's included telly Plus, say). */
        case none
    }

    /**
     * Apple's sheet only for an App Store purchase: this Apple Account's own, or the relay saying the
     * household's came from the App Store. A household bought on a TV says Paddle's emails.
     */
    nonisolated static func manage(store: String?, bought: Bool) -> Manage {
        if bought || store == "apple" { return .apple }
        if store == "paddle" { return .paddle }
        return .none
    }

    var manage: Manage { Self.manage(store: householdStore, bought: bought) }

    /** The one name for the buy button: the free trial where it's still to be had. */
    var buyTitle: String { trialAvailable ? "Start free trial" : "Get telly Plus" }

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
            offered = .general
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

    /** What opened the offer, so it can lead with that. */
    enum Offer: String, Identifiable {
        /** The first watch, Settings or Home's reminder: the benefit. */
        case general
        /** A locked Download button. */
        case download
        /** A telly code, or a household's link code, that would add this device to the household. */
        case household
        /** A TV's telly code, which needs a household (and so telly Plus) to add it to. */
        case addTV

        var id: String { rawValue }

        /** The offer's headline. */
        @MainActor var headline: String {
            switch self {
            case .general: return "Pick up where you left off on all your devices"
            case .download: return "Download this with telly Plus"
            case .household: return "Add this \(Device.name) to your household with telly Plus"
            case .addTV: return "Add your TV to your household with telly Plus"
            }
        }
    }

    /**
     * The weekly price beside Apple's yearly one: "Under 10p a week" for £4.99 a year, and the next
     * whole unit up of the local currency's smallest coin elsewhere. Nil if it can't be worked out.
     */
    nonisolated static func weekly(yearly price: Decimal, currencyCode: String, locale: Locale = .current) -> String? {
        guard price > 0 else { return nil }
        let week = NSDecimalNumber(decimal: price / 52).doubleValue
        if currencyCode == "GBP" {
            let pence = Int(ceil(week * 100))
            // Rounded up to a tidy figure: 9.6p is "under 10p".
            let tidy = pence <= 10 ? 10 : Int(ceil(Double(pence) / 5) * 5)
            return tidy < 100 ? "Under \(tidy)p a week" : nil
        }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currencyCode
        f.locale = locale
        f.roundingMode = .up
        guard let text = f.string(from: NSNumber(value: week)) else { return nil }
        return "About \(text) a week"
    }

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
