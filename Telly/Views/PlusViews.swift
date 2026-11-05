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
            if Plus.shared.unlocked && !Plus.shared.bought {
                // Bought by the sync household elsewhere: on a TV, or another Apple Account.
                LabeledContent("telly Plus", value: "On, with your household")
            } else if Plus.shared.unlocked {
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
            Text(!Plus.shared.unlocked
                 ? "A yearly subscription through the App Store. One covers your Family Sharing group, and every device you sync. Everything else in telly stays free."
                 : Plus.shared.bought
                 ? "Sync and Downloads are on, for everyone in your Family Sharing group and every device you sync."
                 : "Sync and Downloads are on: your sync household has telly Plus.")
        }
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $managing)
        #endif
    }
}

/**
 * telly Plus, offered: once after the first proper watch, then from Settings, Home's reminder, or
 * a locked Sync or Download button. The App Store's own sheet, which leads with the free trial
 * while it's still to be had, its price beneath.
 */
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
        // "Not now": telly Plus is offered after the first watch only once.
        .storeButton(.visible, for: .cancellation)
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
    /** telly's privacy policy (PRIVACY.md in this repository), shown with the subscription as App Store rules ask. */
    static let privacyURL = URL(string: "https://github.com/tellyteam/telly-apple/blob/main/PRIVACY.md")!
}

/** Home's one reminder of telly Plus, a few days after it was first offered. Closing it is for good. */
struct PlusReminder: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.title2).foregroundStyle(Theme.accent).frame(width: 32)
            VStack(alignment: .leading, spacing: 8) {
                Text("Pick up where you left off on your other devices").font(.headline)
                Text(Downloads.available ? "With telly Plus: Sync, and Downloads to watch without a connection." : "With telly Plus: Sync across your devices.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                Button("See telly Plus") { Plus.shared.offered = true }.buttonStyle(.borderedProminent)
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
