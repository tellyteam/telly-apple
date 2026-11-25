import StoreKit
import SwiftUI

/**
 * telly Plus, offered: once after the first proper watch, then from Settings, Home's reminder, a
 * locked Download, or a telly code that would add this device to a household. The App Store's own
 * sheet, which leads with the free trial while it's still to be had, its price beneath. The
 * headline says what opened it.
 */
struct PlusOfferView: View {
    let reason: Plus.Offer
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    /** "Under 10p a week", from the App Store's own price for this storefront. */
    @State private var weekly: String?

    var body: some View {
        SubscriptionStoreView(groupID: Plus.groupId) {
            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Text(reason.headline).font(.title.weight(.bold)).multilineTextAlignment(.center)
                    if reason == .general { Text("telly Plus").font(.title3.weight(.semibold)).foregroundStyle(Theme.accent) }
                }
                VStack(alignment: .leading, spacing: 14) {
                    feature("arrow.triangle.2.circlepath", "Sync", "Progress, Continue watching and My List, end-to-end encrypted.")
                    if Downloads.available {
                        feature("arrow.down.circle", "Downloads", "Save films and episodes to watch without a connection.")
                    }
                    feature("person.2", "Your whole household", "One purchase covers your Family Sharing group and every TV in your household: Fire TV, LG and Samsung.")
                }
                VStack(spacing: 4) {
                    if let weekly { Text(weekly).font(.headline) }
                    Text("Everything else in telly stays free.").font(.footnote).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .frame(maxWidth: 520)
        }
        .storeButton(.visible, for: .restorePurchases)
        // "Not now": telly Plus is offered after the first watch only once.
        .storeButton(.visible, for: .cancellation)
        .subscriptionStorePolicyDestination(url: Plus.termsURL, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: Plus.privacyURL, for: .privacyPolicy)
        .onInAppPurchaseCompletion { _, _ in
            await Plus.shared.refresh()
            guard Plus.shared.unlocked else { return }
            // The household owns telly Plus: it's made (or joined) and given the purchase before
            // telly says it's on.
            await app.attachPlus()
            dismiss()
        }
        .task {
            guard let p = try? await Product.products(for: [Plus.productId]).first else { return }
            weekly = Plus.weekly(yearly: p.price, currencyCode: p.priceFormatStyle.currencyCode, locale: p.priceFormatStyle.locale)
        }
        .background(Theme.background)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(Theme.accent).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                // Wrapped, not cut short, under a two-line headline.
                Text(text).font(.subheadline).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension Plus {
    /** Apple's standard licence for App Store apps. */
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    /** telly's privacy policy (PRIVACY.md in this repository), shown with the subscription as App Store rules ask. */
    static let privacyURL = URL(string: "https://github.com/tellyteam/telly-apple/blob/main/PRIVACY.md")!
}

/** Home's one reminder of telly Plus, a few days after it was first offered. Closing it is for good. */
struct PlusReminder: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.title2).foregroundStyle(Theme.accent).frame(width: 32)
            VStack(alignment: .leading, spacing: 8) {
                Text("Pick up where you left off on all your devices").font(.headline)
                Text(Downloads.available ? "With telly Plus: Sync, and Downloads to watch without a connection." : "With telly Plus: Sync across your devices.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                Button(Plus.shared.buyTitle) { Plus.shared.offered = .general }.buttonStyle(.borderedProminent)
            }
            Spacer(minLength: 0)
            Button { Plus.shared.closeReminder() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close")
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}
