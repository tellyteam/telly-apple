import StoreKit
import SwiftUI

private enum ProviderSheet: Identifiable {
    case add, edit(String)
    var id: String {
        switch self {
        case .add: return "add"
        case let .edit(id): return id
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.compactWidth) private var compact
    @State private var sheet: ProviderSheet?
    @State private var confirmRemove = false
    @State private var confirmClearProgress = false
    @State private var clearing = false

    var body: some View {
        @Bindable var app = app
        Form {
            SwiftUI.Section {
                ForEach(app.providers) { saved in
                    HStack {
                        Button { Task { await app.switchProvider(saved.id) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(saved.provider.name)
                                    Text(saved.provider.isXtream ? "Username and password" : "Playlist link").font(.caption).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                if saved.id == app.activeId { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(saved.id == app.activeId)
                        Button("Edit") { sheet = .edit(saved.id) }
                    }
                }
                Button("Add provider") { sheet = .add }
            } header: {
                Text("Providers")
            } footer: {
                // At a narrow width (an iPhone) there's no sidebar, so no switcher at the bottom of it.
                Text("Each provider keeps its own lists, My List and progress. " + (compact ? "Switch between them here." : "Switch between them here or at the bottom of the sidebar."))
            }
            if let p = app.provider {
                SwiftUI.Section(p.name) {
                    PlainHTTPToggle(title: "Allow plain HTTP for this provider", isOn: Binding(get: { p.allowCleartext }, set: { app.setAllowCleartext($0) }))
                    Button("Remove provider", role: .destructive) { confirmRemove = true }
                }
            }
            SwiftUI.Section("Playback") {
                Toggle("Play the next episode automatically", isOn: $app.settings.autoNext)
                    .onChange(of: app.settings.autoNext) { app.saveSettings() }
            }
            TellyPlusSection()
            if app.provider?.isXtream == true && Downloads.available && Plus.shared.unlocked { DownloadSettingsSection() }
            SwiftUI.Section {
                Button(app.refreshing ? "Refreshing…" : "Refresh lists") { Task { await app.refresh() } }.disabled(app.refreshing)
                Button(clearing ? "Clearing…" : "Clear saved lists") {
                    Task { clearing = true; await app.clearSavedData(); clearing = false }
                }
                .disabled(clearing || app.refreshing)
                Button("Clear watch progress", role: .destructive) { confirmClearProgress = true }
            } header: {
                Text("Data")
            } footer: {
                Text("Lists were updated \(ago(app.listsUpdatedAt)). Clearing saved lists downloads them again; your login, My List and progress are kept. Clearing watch progress forgets where you got to and empties Continue watching\(app.sync != nil ? ", on your linked devices too" : ""); My List is kept.")
            }
            SwiftUI.Section {
                Text("telly \(app.version)")
                #if os(macOS)
                Button("Check for Updates…") { Updates.check() }
                #endif
            } header: {
                Text("About")
            } footer: {
                Text("telly is free for personal use (PolyForm Noncommercial licence). It plays your own IPTV subscription and talks only to your provider\(Device.name == "Mac" ? ", and to GitHub once a day to check for updates" : "")\(Plus.included ? "" : ", to the App Store for telly Plus"), and to the sync relay if you turn on sync. No accounts, analytics or tracking. Plays MKV and other formats with VLCKit (LGPL).")
            }
        }
        // Rounded groups, as on iPad and in the Mac's System Settings (a Mac's default puts labels in a column).
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .sheet(item: $sheet) { s in
            switch s {
            case .add: SetupView(inSheet: true).environment(app)
            case let .edit(id): SetupView(existing: app.providers.first { $0.id == id }, inSheet: true).environment(app)
            }
        }
        .confirmationDialog("Remove \(app.provider?.name ?? "this provider")?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let id = app.activeId { Task { await app.removeProvider(id) } } }
        } message: { Text("Its login, lists, My List and progress are removed from this \(Device.name)." + (app.sync != nil ? " Linked devices keep theirs." : "")) }
        .confirmationDialog("Clear watch progress?", isPresented: $confirmClearProgress, titleVisibility: .visible) {
            Button("Clear it all", role: .destructive) { app.clearProgress() }
        } message: { Text("Forgets where you got to in every film and episode, and empties Continue watching. My List is kept.") }
    }
}

/**
 * Settings → telly Plus: one section for telly Plus and Sync, since the household owns telly Plus.
 * In a household with it: its status, Add a device, Sync now, Show link code and Stop syncing.
 * Otherwise: what it is, the buy button, and joining the household's other devices (scanning a
 * telly code, which also sends a TV a provider, or entering a link code).
 */
private struct TellyPlusSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.compactWidth) private var compact
    @State private var typing = false
    @State private var code = ""
    @State private var linking = false
    @State private var showCode = false
    @State private var error: String?
    @State private var confirmStop = false
    @State private var scanning = false
    @State private var restoring = false
    #if os(iOS)
    @State private var managing = false
    #endif

    private var plus: Plus { Plus.shared }

    var body: some View {
        SwiftUI.Section {
            if let config = app.sync {
                if plus.unlocked {
                    Text(status).font(.callout)
                    LabeledContent("Last synced", value: app.syncBusy ? "Syncing now…" : ago(app.syncedAt))
                    if let e = app.syncError { Text(e).foregroundStyle(.orange).font(.callout) }
                    #if os(iOS)
                    Button("Add a device") { scanning = true }
                    #endif
                    Button(app.syncBusy ? "Syncing…" : "Sync now") { Task { await app.syncNow(force: true) } }.disabled(app.syncBusy)
                    Button(showCode ? "Hide link code" : "Show link code") { showCode.toggle() }
                    if showCode { linkCode(config.code) }
                    #if os(iOS)
                    Toggle("Keep link code in iCloud Keychain", isOn: Binding(get: { app.keepsCodeInICloud }, set: { app.keepCodeInICloud($0) }))
                    #endif
                    manage
                } else {
                    Text("telly Plus has run out for this household, so Sync is off.").font(.callout)
                    buy
                }
                Button("Stop syncing on this \(Device.name)", role: .destructive) { confirmStop = true }
            } else {
                if plus.unlocked {
                    Text(Plus.included ? "Sync is included with telly for Mac." : "telly Plus is on.").font(.callout)
                    Button(linking ? "Turning on…" : "Turn on Sync") { start() }.disabled(linking)
                    manage
                } else {
                    Text("Pick up where you left off on all your devices: progress, Continue watching and My List, end-to-end encrypted."
                         + (Downloads.available ? " And download films and episodes to watch without a connection." : ""))
                        .font(.callout).foregroundStyle(Theme.muted)
                    buy
                }
                join
            }
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
        } header: {
            Text("telly Plus")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if app.sync != nil && showCode {
                    Text("Enter the link code on your other devices. Keep it private: anyone with it can see what you've watched.")
                }
                #if os(iOS)
                if app.sync != nil && Plus.shared.unlocked {
                    Text("In iCloud Keychain, your other iPhones and iPads on this Apple Account join your household by themselves. It's end-to-end encrypted: telly and its relay never see it. Turning it off takes it off all of them.")
                }
                #endif
                Text("One purchase covers your Family Sharing group and every TV in your household: Fire TV, LG and Samsung. Provider logins are never part of sync.")
                Link("The relay keeps no logs. Read its policy", destination: URL(string: "https://github.com/tellyteam/telly-sync/blob/main/PRIVACY.md")!)
            }
        }
        .tellyCodeScanner(isPresented: $scanning)
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $managing)
        #endif
        .confirmationDialog("Stop syncing on this \(Device.name)?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop syncing", role: .destructive) { Task { await app.stopSync(); showCode = false } }
        } message: { Text("Your other devices keep syncing with each other.") }
    }

    /** "telly Plus is on for this household until 3 Dec 2027". */
    private var status: String {
        guard let until = plus.onUntil else { return Plus.included ? "Syncing with your household." : "telly Plus is on for this household." }
        return "telly Plus is on for this household until \(until.formatted(date: .abbreviated, time: .omitted))."
    }

    /** The price line and the one buy button, and Restore. */
    @ViewBuilder private var buy: some View {
        if !Plus.included {
            Text(plus.trialAvailable ? "Free for 3 days, then £4.99 a year for your household." : "£4.99 a year for your household.").font(.callout)
            Button(plus.buyTitle) { Plus.shared.offered = .general }
            Button(restoring ? "Restoring…" : "Restore purchases") {
                Task {
                    restoring = true
                    await Plus.shared.restore()
                    // Restored: the household owns it, as after buying.
                    if Plus.shared.bought { await app.attachPlus() }
                    restoring = false
                }
            }
            .disabled(restoring)
        }
    }

    /** Where the subscription is managed: Apple's sheet only for an App Store purchase. */
    @ViewBuilder private var manage: some View {
        if plus.householdStore == "paddle" && !plus.bought {
            Text("This household's telly Plus was bought on a TV. Manage it from Paddle's emails.")
                .font(.caption).foregroundStyle(Theme.muted)
        } else if plus.householdStore == "apple" || plus.bought {
            #if os(iOS)
            Button("Manage subscription") { managing = true }
            #else
            Link("Manage subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
            #endif
        }
    }

    /** Joining the household's other devices: scanning a telly code, or entering a link code. */
    @ViewBuilder private var join: some View {
        #if os(iOS)
        Button("Scan a telly code") { scanning = true }.disabled(linking)
        #endif
        Button("Enter a link code") { typing.toggle() }
        if typing {
            HStack {
                TextField("Link code", text: $code, prompt: Text("ABCD-EFGH-JKMN-PQRS"))
                    .formField()
                    .plainEntry(capitals: true).font(.body.monospaced())
                Button(linking ? "Joining…" : "Join") { joinWithCode() }.disabled(linking || code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("The link code is in Settings → telly Plus on one of your other devices.").font(.caption).foregroundStyle(Theme.muted)
        }
    }

    /** The household's link code: the 16 characters, and on a Mac the QR code an iPhone or iPad can scan. */
    @ViewBuilder private func linkCode(_ code: String) -> some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14)) : AnyLayout(HStackLayout(spacing: 20))
        layout {
            Text(SyncCrypto.formatCode(code)).font(.system(.title, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                .lineLimit(1).minimumScaleFactor(0.6)
            #if os(macOS)
            if let qr = SyncLink.image(SyncLink.url(code: code)) {
                Image(cgImage: qr).interpolation(.none).resizable().frame(width: 150, height: 150)
                    .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("QR code to link another device")
            }
            #endif
        }
    }

    /** A new household, for telly Plus this Apple Account (or the Mac) already has. */
    private func start() {
        linking = true
        error = nil
        Task {
            do { try await app.startSync(code: nil) } catch { self.error = error.localizedDescription }
            linking = false
        }
    }

    private func joinWithCode() {
        guard let normal = SyncCrypto.normaliseCode(code) else {
            error = "That code isn't right: it's 16 letters and numbers, like ABCD-EFGH-JKMN-PQRS."
            return
        }
        linking = true
        error = nil
        Task {
            do {
                try await app.joinHousehold(.link(normal))
                typing = false
                code = ""
            } catch {
                self.error = error.localizedDescription
            }
            linking = false
        }
    }
}
