import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var editing = false
    @State private var confirmSignOut = false
    @State private var confirmClearProgress = false
    @State private var clearing = false
    @State private var versionTaps = 0
    @State private var lastTap = Date.distantPast
    @State private var note: String?

    var body: some View {
        @Bindable var app = app
        Form {
            if let p = app.provider {
                SwiftUI.Section("Your provider") {
                    LabeledContent(p.name, value: p.isXtream ? "Xtream Codes" : "M3U playlist")
                    Toggle(isOn: Binding(get: { p.allowCleartext }, set: { app.setAllowCleartext($0) })) {
                        VStack(alignment: .leading) {
                            Text("Allow plain HTTP for this provider")
                            Text("Only if it has no HTTPS. Traffic to it won't be encrypted.").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    Button("Edit provider") { editing = true }
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                }
            }
            SwiftUI.Section("Playback") {
                Toggle("Play the next episode automatically", isOn: $app.settings.autoNext)
                    .onChange(of: app.settings.autoNext) { app.saveSettings() }
            }
            if app.syncShown { SyncSection() }
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
                Text("Lists were updated \(ago(app.meta.updatedAt)). Clearing saved lists downloads them again; your login, My List and progress are kept. Clearing watch progress forgets where you got to and empties Continue watching\(app.sync != nil ? ", on your linked devices too" : ""); My List is kept.")
            }
            SwiftUI.Section {
                HStack {
                    Text("telly \(app.version)")
                    if let note { Text("· \(note)").foregroundStyle(Theme.muted) }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: tapVersion)
            } header: {
                Text("About")
            } footer: {
                Text("telly is free software (GPL-3.0). It plays your own IPTV subscription and talks only to your provider\(app.syncShown ? ", and to the sync relay if you turn on sync" : ""). No accounts, analytics or tracking. Plays MKV and other formats with VLCKit (LGPL).")
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $editing) { SetupView(existing: app.provider).environment(app) }
        .confirmationDialog("Sign out and forget your provider?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { app.signOut() }
        } message: { Text("Your login and saved lists are removed from this iPad. My List and progress are kept.") }
        .confirmationDialog("Clear watch progress?", isPresented: $confirmClearProgress, titleVisibility: .visible) {
            Button("Clear it all", role: .destructive) { app.clearProgress() }
        } message: { Text("Forgets where you got to in every film and episode, and empties Continue watching. My List is kept.") }
    }

    /** Seven taps in a row on the version show (or hide) the Sync section. */
    private func tapVersion() {
        let now = Date()
        versionTaps = now.timeIntervalSince(lastTap) < 3 ? versionTaps + 1 : 1
        lastTap = now
        guard versionTaps >= 7 else { return }
        versionTaps = 0
        note = app.toggleSyncUnlocked() ? "Sync is now in Settings" : "Sync hidden"
        Task {
            try? await Task.sleep(for: .seconds(3))
            note = nil
        }
    }
}

private struct SyncSection: View {
    @Environment(AppModel.self) private var app
    @State private var joining = false
    @State private var code = ""
    @State private var relay = AppModel.defaultRelay
    @State private var linking = false
    @State private var showCode = false
    @State private var error: String?
    @State private var confirmStop = false

    var body: some View {
        SwiftUI.Section {
            if let config = app.sync {
                LabeledContent("Keeping your place in sync", value: app.syncBusy ? "Syncing now…" : "Last synced \(ago(app.syncedAt))")
                if let e = app.syncError { Text(e).foregroundStyle(.orange).font(.callout) }
                if showCode {
                    Text(SyncCrypto.formatCode(config.code)).font(.system(size: 28, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                } else {
                    Button("Show code to link another device") { showCode = true }
                }
                Button(app.syncBusy ? "Syncing…" : "Sync now") { Task { await app.syncNow(force: true) } }.disabled(app.syncBusy)
                Button("Stop syncing on this iPad", role: .destructive) { confirmStop = true }
            } else {
                Text("Pick up where you left off on your other devices. Shares progress, Continue watching and My List, end-to-end encrypted. Your provider login is never shared: sign in on each device.")
                    .font(.callout).foregroundStyle(Theme.muted)
                Button(linking && !joining ? "Starting…" : "Start syncing") { link(nil) }.disabled(linking)
                Button("I have a code") { joining.toggle() }
                if joining {
                    HStack {
                        TextField("ABCD-EFGH-JKMN-PQRS", text: $code)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled().font(.body.monospaced())
                        Button(linking ? "Linking…" : "Link") { link(code) }.disabled(linking || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                LabeledContent("Relay") {
                    TextField("https://…", text: $relay).multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            }
        } header: {
            Text("Sync")
        } footer: {
            if app.sync != nil { Text("Enter the code in Settings → Sync on your Fire TV, Mac or other iPad. Keep it private: anyone with it can see what you've watched.") }
            else { Text("Change the relay only if you run your own.") }
        }
        .confirmationDialog("Stop syncing on this iPad?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop syncing", role: .destructive) { Task { await app.stopSync(); showCode = false } }
        } message: { Text("Your other devices keep syncing with each other.") }
    }

    private func link(_ withCode: String?) {
        linking = true
        error = nil
        Task {
            do {
                try await app.startSync(code: withCode, relay: relay)
                joining = false
                code = ""
                showCode = withCode == nil
            } catch {
                self.error = error.localizedDescription
            }
            linking = false
        }
    }
}
