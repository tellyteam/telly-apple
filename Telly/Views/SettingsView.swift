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
                                    Text(saved.provider.isXtream ? "Xtream Codes" : "M3U playlist").font(.caption).foregroundStyle(Theme.muted)
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
            if !Plus.included { PlusSection() }
            if app.provider?.isXtream == true && Downloads.available && Plus.shared.unlocked { DownloadSettingsSection() }
            SyncSection()
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

private struct SyncSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.compactWidth) private var compact
    @State private var joining = false
    @State private var code = ""
    @State private var linking = false
    @State private var showCode = true
    @State private var error: String?
    @State private var confirmStop = false
    @State private var scanning = false

    var body: some View {
        SwiftUI.Section {
            if !Plus.shared.unlocked {
                // Sync is part of telly Plus. A linked device keeps its link while it's off.
                Text(app.sync != nil
                     ? "Sync is paused: it's part of telly Plus. This \(Device.name) stays linked, and picks up again with telly Plus."
                     : "Pick up where you left off on your other devices, with telly Plus. Shares progress, Continue watching and My List, end-to-end encrypted.")
                    .font(.callout).foregroundStyle(Theme.muted)
                Button("See telly Plus") { Plus.shared.offered = true }
                if app.sync != nil { Button("Stop syncing on this \(Device.name)", role: .destructive) { confirmStop = true } }
            } else if let config = app.sync {
                LabeledContent("Keeping your place in sync", value: app.syncBusy ? "Syncing now…" : "Last synced \(ago(app.syncedAt))")
                if let e = app.syncError { Text(e).foregroundStyle(.orange).font(.callout) }
                Button(showCode ? "Hide code" : "Show code to link another device") { showCode.toggle() }
                if showCode {
                    // Side by side where there's room; on a phone the code goes above the QR code.
                    let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14)) : AnyLayout(HStackLayout(spacing: 20))
                    layout {
                        Text(SyncCrypto.formatCode(config.code)).font(.system(.title, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        if let qr = SyncLink.image(SyncLink.url(code: config.code)) {
                            Image(cgImage: qr).interpolation(.none).resizable().frame(width: 150, height: 150)
                                .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityLabel("QR code to link another device")
                        }
                    }
                }
                Button(app.syncBusy ? "Syncing…" : "Sync now") { Task { await app.syncNow(force: true) } }.disabled(app.syncBusy)
                Text("Provider logins are never shared: sign in on each device.").font(.caption).foregroundStyle(Theme.muted)
                Button("Stop syncing on this \(Device.name)", role: .destructive) { confirmStop = true }
            } else {
                Text("Pick up where you left off on your other devices. Shares progress, Continue watching and My List, end-to-end encrypted. Provider logins are never shared, and the relay keeps no logs.")
                    .font(.callout).foregroundStyle(Theme.muted)
                Button(linking && !joining ? "Starting…" : "Start syncing") { link(nil) }.disabled(linking)
                #if os(iOS)
                Button("Scan a QR code") { scanning = true }.disabled(linking)
                #endif
                Button("I have a code") { joining.toggle() }
                if joining {
                    HStack {
                        TextField("Code", text: $code, prompt: Text("ABCD-EFGH-JKMN-PQRS"))
                            .formField()
                            .plainEntry(capitals: true).font(.body.monospaced())
                        Button(linking ? "Linking…" : "Link") { link(code) }.disabled(linking || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            }
        } header: {
            Text("Sync")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if app.sync != nil { Text("Scan the QR code with an iPhone or iPad's camera, or enter the code in Settings → Sync on your other devices. Keep it private: anyone with it can see what you've watched.") }
                else if Plus.shared.unlocked { Text("Scan the QR code your Fire TV or Mac shows under Settings → Sync → Show code.") }
                Link("The relay keeps no logs. Read its policy", destination: URL(string: "https://github.com/tellyteam/telly-sync/blob/main/PRIVACY.md")!)
            }
        }
        .qrScanner(isPresented: $scanning) { text in
            if let found = SyncLink.parse(text) {
                link(found)
            } else {
                error = "That QR code isn't a telly sync code."
            }
        }
        .confirmationDialog("Stop syncing on this \(Device.name)?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop syncing", role: .destructive) { Task { await app.stopSync(); showCode = true } }
        } message: { Text("Your other devices keep syncing with each other.") }
    }

    private func link(_ withCode: String?) {
        linking = true
        error = nil
        Task {
            do {
                try await app.startSync(code: withCode)
                joining = false
                code = ""
                showCode = true
            } catch {
                self.error = error.localizedDescription
            }
            linking = false
        }
    }
}
