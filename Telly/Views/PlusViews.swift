import StoreKit
import SwiftUI

/** Settings → telly Plus: what it unlocks, and the subscription. */
struct PlusSection: View {
    @State private var restoring = false
    #if os(iOS)
    @State private var managing = false
    #endif

    var body: some View {
        SwiftUI.Section {
            if Plus.shared.unlocked {
                LabeledContent("telly Plus", value: "On")
                #if os(iOS)
                Button("Manage subscription") { managing = true }
                #else
                Link("Manage subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                #endif
            } else {
                Text("Sync your place across your devices, and download films and episodes to watch without a connection.")
                    .font(.callout).foregroundStyle(Theme.muted)
                Button("See telly Plus") { Plus.shared.offered = true }
                Button(restoring ? "Restoring…" : "Restore purchases") {
                    Task { restoring = true; await Plus.shared.restore(); restoring = false }
                }
                .disabled(restoring)
            }
        } header: {
            Text("telly Plus")
        } footer: {
            Text(Plus.shared.unlocked
                 ? "Sync and Downloads are on, for everyone in your Family Sharing group."
                 : "A yearly subscription through the App Store. One covers your Family Sharing group. Everything else in telly stays free.")
        }
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $managing)
        #endif
    }
}

/** telly Plus, offered: from Settings, or a locked Sync or Download button. The App Store's own sheet. */
struct PlusOfferView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SubscriptionStoreView(productIDs: [Plus.productId]) {
            VStack(spacing: 18) {
                Text("telly Plus").font(.largeTitle.weight(.bold))
                VStack(alignment: .leading, spacing: 14) {
                    feature("arrow.triangle.2.circlepath", "Sync", "Pick up where you left off on your other devices. Progress, Continue watching and My List, end-to-end encrypted.")
                    if Downloads.available {
                        feature("arrow.down.circle", "Downloads", "Save films and episodes to watch without a connection.")
                    }
                }
                Text("Everything else in telly stays free.").font(.footnote).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .frame(maxWidth: 520)
        }
        .storeButton(.visible, for: .restorePurchases)
        .subscriptionStorePolicyDestination(url: Plus.termsURL, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: Plus.privacyURL, for: .privacyPolicy)
        .onInAppPurchaseCompletion { _, _ in
            await Plus.shared.refresh()
            if Plus.shared.unlocked { dismiss() }
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
                Text(text).font(.subheadline).foregroundStyle(Theme.muted)
            }
        }
    }
}

extension Plus {
    /** Apple's standard licence for App Store apps. */
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    /** telly's privacy policy. To be written before telly Plus goes on sale (an App Store requirement). */
    static let privacyURL = URL(string: "https://github.com/tellyteam/telly-apple/blob/main/PRIVACY.md")!
}
