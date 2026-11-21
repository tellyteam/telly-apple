import SwiftUI

/** What the join sheet did, for RootView to show once it has closed. */
enum JoinOutcome {
    case linked, sent, plusNeeded
}

/**
 * Answering a device's join QR code (telly-lg's SETUP-BY-PHONE.md, section 5): link it for sync,
 * send it a provider, or both, in one sealed message. Sending a provider is off every time the
 * sheet opens, and only offered to a device showing the new code; the login is read from the
 * Keychain only when Send is pressed, and the password is never shown.
 */
struct JoinSheet: View {
    let join: SyncJoin
    let done: (JoinOutcome) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var link = true
    @State private var sendProvider = false
    @State private var providerId: String?
    @State private var sending = false
    @State private var error: String?

    private var providerOffered: Bool { join.takesProvider && !app.providers.isEmpty }

    /** The provider that will be sent, if one is. */
    private var chosen: SavedProvider? {
        guard providerOffered, sendProvider else { return nil }
        return app.providers.first { $0.id == providerId } ?? app.providers.first
    }

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section {
                    Toggle("Link it for sync", isOn: $link)
                } footer: {
                    Text("Shares progress, Continue watching and My List with this \(Device.name), end-to-end encrypted. Provider logins are never part of sync."
                         + (app.linkingNeedsPlus ? " Sync is part of telly Plus: you'll be offered it first." : ""))
                }
                if providerOffered {
                    SwiftUI.Section {
                        Toggle("Send a provider", isOn: $sendProvider)
                        if sendProvider {
                            if app.providers.count > 1 {
                                Picker("Provider", selection: $providerId) {
                                    ForEach(app.providers) { Text($0.provider.name).tag(Optional($0.id)) }
                                }
                            }
                            if let p = chosen?.provider { details(p) }
                        }
                    } footer: {
                        Text("It's sealed so only the TV showing the code can read it, and telly's relay can't.")
                    }
                }
                SwiftUI.Section {
                    if let error { Text(error).foregroundStyle(.orange).font(.callout) }
                    Text("Only do this for a device of your own that is showing this code in front of you.")
                        .font(.callout).foregroundStyle(Theme.muted)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(join.takesProvider ? "Set up your TV" : "Link your new device")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Sending…" : "Send") { send() }.disabled(sending || (!link && chosen == nil))
                }
            }
        }
        .interactiveDismissDisabled(sending)
        .onAppear { if providerId == nil { providerId = app.activeId ?? app.providers.first?.id } }
    }

    /** What will be sent, without the password. */
    @ViewBuilder private func details(_ p: Provider) -> some View {
        LabeledContent("Name", value: p.name.isEmpty ? "None" : p.name)
        switch p {
        case let .xtream(_, server, username, _, _):
            LabeledContent("Server", value: server)
            LabeledContent("Username", value: username)
            LabeledContent("Password", value: "Sent, not shown")
        case let .m3u(_, url, _):
            LabeledContent("Playlist link", value: Self.hidingPassword(url))
        }
        if p.allowCleartext { LabeledContent("Plain HTTP", value: "Allowed") }
    }

    /** A playlist link with any `password=` in it blanked out, as the link is shown. */
    static func hidingPassword(_ url: String) -> String {
        guard var c = URLComponents(string: url), let items = c.queryItems, items.contains(where: { $0.name.lowercased() == "password" }) else { return url }
        c.queryItems = items.map { $0.name.lowercased() == "password" ? URLQueryItem(name: $0.name, value: "telly-hidden") : $0 }
        return c.string?.replacingOccurrences(of: "=telly-hidden", with: "=••••") ?? url
    }

    private func send() {
        error = nil
        // Starting a household needs telly Plus: its offer opens instead, and the code can be scanned again.
        if link && app.linkingNeedsPlus {
            done(.plusNeeded)
            dismiss()
            return
        }
        sending = true
        Task {
            do {
                try await app.sendJoin(join, link: link, providerId: chosen?.id)
                done(chosen != nil ? .sent : .linked)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
