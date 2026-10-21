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
        // Rounded groups, as on iPad and in the Mac's System Settings (a Mac's default puts labels in a column).
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .sheet(isPresented: $editing) { SetupView(existing: app.provider).environment(app) }
        .confirmationDialog("Sign out and forget your provider?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { app.signOut() }
        } message: { Text("Your login and saved lists are removed from this \(Device.name). My List and progress are kept.") }
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
    @State private var showCode = true
    @State private var error: String?
    @State private var confirmStop = false
    @State private var scanning = false

    var body: some View {
        SwiftUI.Section {
            if let config = app.sync {
                LabeledContent("Keeping your place in sync", value: app.syncBusy ? "Syncing now…" : "Last synced \(ago(app.syncedAt))")
                if let e = app.syncError { Text(e).foregroundStyle(.orange).font(.callout) }
                Button(showCode ? "Hide code" : "Show code to link another device") { showCode.toggle() }
                if showCode {
                    HStack(spacing: 20) {
                        if let qr = SyncLink.image(SyncLink.url(code: config.code, relay: config.relay, defaultRelay: AppModel.defaultRelay)) {
                            Image(cgImage: qr).interpolation(.none).resizable().frame(width: 150, height: 150)
                                .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 10))
                        }
                        Text(SyncCrypto.formatCode(config.code)).font(.system(size: 28, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    }
                }
                Button(app.syncBusy ? "Syncing…" : "Sync now") { Task { await app.syncNow(force: true) } }.disabled(app.syncBusy)
                Button("Stop syncing on this \(Device.name)", role: .destructive) { confirmStop = true }
            } else {
                Text("Pick up where you left off on your other devices. Shares progress, Continue watching and My List, end-to-end encrypted. Your provider login is never shared: sign in on each device.")
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
                LabeledContent("Relay") {
                    TextField("Relay", text: $relay, prompt: Text("https://…"))
                        .formField(trailing: true)
                        .plainEntry(url: true)
                }
                if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            }
        } header: {
            Text("Sync")
        } footer: {
            if app.sync != nil { Text("Scan the QR code with an iPad's camera, or enter the code in Settings → Sync on your other devices. Keep it private: anyone with it can see what you've watched.") }
            else { Text("Scan the QR code your Fire TV or Mac shows under Settings → Sync → Show code. Change the relay only if you run your own.") }
        }
        .qrScanner(isPresented: $scanning) { text in
            if let found = SyncLink.parse(text, defaultRelay: AppModel.defaultRelay) {
                relay = found.relay
                link(found.code)
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
                try await app.startSync(code: withCode, relay: relay)
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
