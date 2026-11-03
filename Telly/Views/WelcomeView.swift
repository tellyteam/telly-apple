import SwiftUI

/**
 * telly's first run, the same on every device: Welcome, then joining the household's other
 * devices (if there are any), then the provider. A device that's linked already goes straight to
 * the provider.
 */
struct FirstRunView: View {
    @Environment(AppModel.self) private var app
    @State private var step: Step = .welcome

    enum Step { case welcome, join, setup }

    var body: some View {
        if app.sync != nil || step == .setup {
            SetupView(onBack: app.sync == nil ? { step = .welcome } : nil)
        } else if step == .join {
            JoinView(onBack: { step = .welcome }, onSetUp: { step = .setup })
        } else {
            WelcomeView(onSetUp: { step = .setup }, onJoin: { step = .join })
                #if DEBUG
                .onAppear { if DevHooks.env["TELLY_DEV_FIRST_RUN"] == "join" { step = .join } }
                #endif
        }
    }
}

/** The first screen: what telly is, and the two ways in. */
private struct WelcomeView: View {
    let onSetUp: () -> Void
    let onJoin: () -> Void

    var body: some View {
        FirstRunCard {
            Wordmark(height: 42)
            Text("Welcome to telly").font(.largeTitle.weight(.bold))
            Text("Watch the TV you already pay for, on all your devices.")
                .foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 12) {
                point("hand.raised", "No ads, no accounts, no tracking.")
                point("lock", "Your login stays on this \(Device.name).")
                point("arrow.triangle.2.circlepath", "Pick up where you left off on your other devices.")
            }
            .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 10) {
                Button("Set up telly", action: onSetUp).buttonStyle(.borderedProminent)
                Button("I use telly on another device", action: onJoin).buttonStyle(.bordered)
            }
            Text("telly doesn't come with any channels: you'll need a TV provider.")
                .font(.caption).foregroundStyle(Theme.faint)
        }
    }

    private func point(_ icon: String, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 26) }
    }
}

/**
 * Joining the household's other devices: this device shows a QR code for one of them to scan (no
 * code to type), or takes that device's code. An iPhone or iPad leads with scanning, since the
 * device it joins is most often a TV, which has no camera; its own QR code is there for joining
 * from another iPhone or iPad.
 */
struct JoinView: View {
    @Environment(AppModel.self) private var app
    let onBack: () -> Void
    /** On to the provider without syncing: there's no telly Plus to sync with, say. */
    let onSetUp: () -> Void

    @State private var join = SyncJoin.new()
    @State private var typing = false
    @State private var code = ""
    @State private var scanning = false
    /** An iPhone or iPad shows its own QR code only when asked: for joining from another one. */
    @State private var showingQR = false
    @State private var linking = false
    /** A code that arrived but couldn't link yet: the household has no telly Plus. */
    @State private var waitingForPlus: String?
    @State private var error: String?

    var body: some View {
        FirstRunCard {
            Text("Join your other devices").font(.title.weight(.bold))
            if !Plus.shared.unlocked {
                Text("Syncing is part of telly Plus. Without it, each device keeps its own progress.")
                    .font(.callout).foregroundStyle(Theme.muted)
            }
            #if os(iOS)
            Text("On your TV, go to Settings → Sync → Show code, then scan the QR code it shows.")
                .foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 10) {
                Button(linking ? "Linking…" : "Scan your TV's code") { scanning = true }
                    .buttonStyle(.borderedProminent).disabled(linking)
                Button("Type the code instead") { typing.toggle() }.buttonStyle(.bordered)
            }
            codeEntry
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            DisclosureGroup("Joining from another iPhone or iPad?", isExpanded: $showingQR) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("On that one, open telly and go to Settings → Sync → Scan a new device's QR code.")
                        .font(.callout).foregroundStyle(Theme.muted)
                    ownQR
                }
                .padding(.top, 8)
            }
            .tint(Theme.accent)
            Divider().padding(.vertical, 4)
            #else
            Text("On your iPhone or iPad, open telly and go to Settings → Sync → Scan a new device's QR code.")
                .foregroundStyle(Theme.muted)
            ownQR
            Divider().padding(.vertical, 4)
            Text("Or use its code, from Settings → Sync → Show code.").font(.callout).foregroundStyle(Theme.muted)
            Button("I have a code") { typing.toggle() }.buttonStyle(.bordered)
            codeEntry
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            #endif
            HStack(spacing: 16) {
                // The way on once telly Plus was turned down for the code that came in.
                if declinedPlus {
                    Button("Set up without syncing", action: onSetUp).buttonStyle(.borderedProminent)
                } else {
                    Button("Set up without syncing", action: onSetUp).buttonStyle(.bordered)
                }
                Button("Back", action: onBack).buttonStyle(.borderless)
            }
            Text("Provider logins are never shared: you'll sign in on this \(Device.name) next.")
                .font(.caption).foregroundStyle(Theme.faint)
        }
        .qrScanner(isPresented: $scanning) { text in
            if let found = SyncLink.parse(text) { link(found) } else { error = "That QR code isn't a telly sync code." }
        }
        // While the QR code shows, the relay is asked every few seconds whether a code has been left.
        .task(id: JoinWait(join: join, showing: qrShown)) {
            guard qrShown else { return }
            #if DEBUG
            print("TELLY_DEV join QR: \(join.url)")
            #endif
            for _ in 0..<300 {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled || linking || waitingForPlus != nil { continue }
                do {
                    if let found = try await SyncClient.collectJoin(AppModel.relay, join) {
                        link(found)
                        return
                    }
                } catch {
                    self.error = error.localizedDescription
                    join = SyncJoin.new()
                    return
                }
            }
            // Left for a long while: a fresh QR code rather than one that's gone stale.
            join = SyncJoin.new()
        }
        // Bought in the sheet: the code that came in links now.
        .onChange(of: Plus.shared.unlocked) { _, on in if on, let waiting = waitingForPlus { link(waiting) } }
    }

    /** A code came in, telly Plus was offered for it, and the offer was closed without buying. */
    private var declinedPlus: Bool { waitingForPlus != nil && !Plus.shared.offered && !Plus.shared.unlocked }

    /** Whether this device's QR code is on screen (always, where there's no camera to scan with). */
    private var qrShown: Bool {
        #if os(iOS)
        showingQR
        #else
        true
        #endif
    }

    private struct JoinWait: Equatable {
        let join: SyncJoin
        let showing: Bool
    }

    /** This device's QR code, for one in the household to scan. */
    @ViewBuilder private var ownQR: some View {
        if let qr = SyncLink.image(join.url) {
            Image(cgImage: qr).interpolation(.none).resizable().frame(width: 170, height: 170)
                .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("QR code for your other device to scan")
        }
        HStack(spacing: 8) {
            if linking { ProgressView().controlSize(.small) }
            Text(linking ? "Linking…" : "Waiting for your other device…").font(.callout).foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder private var codeEntry: some View {
        if typing {
            HStack {
                TextField("Code", text: $code, prompt: Text("ABCD-EFGH-JKMN-PQRS"))
                    .textFieldStyle(.roundedBorder)
                    .plainEntry(capitals: true).font(.body.monospaced())
                Button("Link") { link(code) }.buttonStyle(.borderedProminent)
                    .disabled(linking || code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func link(_ withCode: String) {
        linking = true
        error = nil
        Task {
            do {
                try await app.startSync(code: withCode)
                waitingForPlus = nil
            } catch {
                if !Plus.shared.unlocked {
                    // The household has no telly Plus: offer it, and link once it's on.
                    waitingForPlus = SyncCrypto.normaliseCode(withCode)
                    self.error = "Sync is part of telly Plus, and your devices don't have it yet."
                    Plus.shared.offered = true
                } else {
                    self.error = error.localizedDescription
                }
            }
            linking = false
        }
    }
}

/** The first run's card on the page, as the sign-in form has. */
struct FirstRunCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(32)
                .frame(maxWidth: 560, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                .padding(.vertical, 60)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
    }
}
