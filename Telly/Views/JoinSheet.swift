import SwiftUI

/** What the add sheet did, for RootView to show once it has closed. */
enum JoinOutcome {
    /** Added to the household; with [sent], its provider went too. */
    case added(sent: Bool)
    /** Only the provider went. */
    case sent
    case plusNeeded
}

/**
 * "Add this TV to your household?": answering a device's telly code (PROTOCOL.md, "Joining by QR
 * code from the new device"). This device's link code and, ticked by default, a provider go in one
 * sealed message to the box only the device showing the code can open. The login is read from the
 * Keychain only when Add is pressed, and the password is never shown. Adding needs a household with
 * telly Plus; without it, the provider can still be sent on its own.
 */
struct JoinSheet: View {
    let join: SyncJoin
    let done: (JoinOutcome) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var sendProvider = true
    @State private var providerId: String?
    @State private var sending = false
    @State private var error: String?

    private var providerOffered: Bool { join.takesProvider && !app.providers.isEmpty }
    /** A TV's code (the new form); an older device's shows the old one. */
    private var device: String { join.takesProvider ? "TV" : "device" }

    /** The provider that will be sent, if one is. */
    private var chosen: SavedProvider? {
        guard providerOffered, sendProvider else { return nil }
        return app.providers.first { $0.id == providerId } ?? app.providers.first
    }

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section {
                    Text("It will pick up where you left off: progress, Continue watching and My List, end-to-end encrypted.")
                        .foregroundStyle(Theme.muted)
                    if app.linkingNeedsPlus {
                        Text("Your household is part of telly Plus. \(Plus.shared.trialAvailable ? "Free for 3 days, then £4.99 a year for your household." : "")")
                            .font(.callout)
                    }
                }
                if providerOffered {
                    SwiftUI.Section {
                        Toggle("Also send \(chosen?.provider.name ?? app.provider?.name ?? "your provider")", isOn: $sendProvider)
                        if sendProvider {
                            if app.providers.count > 1 {
                                Picker("Provider", selection: $providerId) {
                                    ForEach(app.providers) { Text($0.provider.name).tag(Optional($0.id)) }
                                }
                            }
                            if let p = chosen?.provider { details(p) }
                        }
                    } footer: {
                        Text("It's sealed so only the TV showing the code can read it, and telly's relay can't. Provider logins are never part of sync.")
                    }
                }
                SwiftUI.Section {
                    if let error { Text(error).foregroundStyle(.orange).font(.callout) }
                    if app.linkingNeedsPlus, chosen != nil {
                        Button(sending ? "Sending…" : "Just send \(chosen?.provider.name ?? "the provider")") { send(link: false) }.disabled(sending)
                    }
                    Text("Only do this for a \(device) of your own that is showing this code in front of you.")
                        .font(.callout).foregroundStyle(Theme.muted)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add this \(device) to your household?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Adding…" : "Add") { send(link: true) }.disabled(sending)
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

    private func send(link: Bool) {
        error = nil
        // Starting a household needs telly Plus: its offer opens instead, and this sheet comes back
        // once it's on (the TV's code lasts 10 minutes).
        if link && app.linkingNeedsPlus {
            done(.plusNeeded)
            dismiss()
            return
        }
        sending = true
        Task {
            do {
                try await app.sendJoin(join, link: link, providerId: chosen?.id)
                done(link ? .added(sent: chosen != nil) : .sent)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
