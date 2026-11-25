import SwiftUI

/**
 * telly's first run: watch first. Welcome, then the provider. Joining the household's other
 * devices comes later (Settings → telly Plus), or now by scanning a telly code or entering a link
 * code. A device that's linked already goes straight to the provider.
 */
struct FirstRunView: View {
    @Environment(AppModel.self) private var app
    @State private var settingUp = false
    #if os(macOS)
    @State private var joining = false
    #endif

    var body: some View {
        if app.sync != nil || settingUp {
            SetupView(onBack: app.sync == nil ? { settingUp = false } : nil)
        } else {
            #if os(macOS)
            if joining {
                JoinView(onBack: { joining = false }, onSetUp: { settingUp = true })
            } else {
                WelcomeView(onSetUp: { settingUp = true }, onJoin: { joining = true })
            }
            #else
            WelcomeView(onSetUp: { settingUp = true })
            #endif
        }
    }
}

/** The first screen: what telly is, and the ways in. */
private struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    let onSetUp: () -> Void
    #if os(macOS)
    let onJoin: () -> Void
    #endif
    @State private var scanning = false
    @State private var typing = false
    @State private var code = ""
    @State private var linking = false
    @State private var error: String?

    var body: some View {
        FirstRunCard {
            Wordmark(height: 42)
            Text("Welcome to telly").font(.largeTitle.weight(.bold))
            Text("Watch the TV you already pay for, on all your devices.")
                .foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 12) {
                point("hand.raised", "No ads, no accounts, no tracking.")
                point("lock", "Your login stays on this \(Device.name) unless you send it to your TV.")
                point("arrow.triangle.2.circlepath", "Pick up where you left off on your other devices.")
            }
            .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 10) {
                Button("Set up telly", action: onSetUp).buttonStyle(.borderedProminent)
                #if os(iOS)
                Button("Scan a telly code") { scanning = true }.buttonStyle(.bordered)
                Button("Enter a link code") { typing.toggle() }.buttonStyle(.borderless)
                #else
                Button("I use telly on another device", action: onJoin).buttonStyle(.bordered)
                #endif
            }
            if typing {
                HStack {
                    TextField("Link code", text: $code, prompt: Text("ABCD-EFGH-JKMN-PQRS"))
                        .textFieldStyle(.roundedBorder)
                        .plainEntry(capitals: true).font(.body.monospaced())
                    Button(linking ? "Joining…" : "Join") { link() }.buttonStyle(.borderedProminent)
                        .disabled(linking || code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("The link code is in Settings → telly Plus on one of your other devices.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            Text("telly doesn't come with any channels: you'll need a TV provider.")
                .font(.caption).foregroundStyle(Theme.faint)
        }
        .tellyCodeScanner(isPresented: $scanning)
    }

    private func point(_ icon: String, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 26) }
    }

    /** Joins the household the typed link code is for; without telly Plus, it's offered first. */
    private func link() {
        guard let normal = SyncCrypto.normaliseCode(code) else {
            error = "That code isn't right: it's 16 letters and numbers, like ABCD-EFGH-JKMN-PQRS."
            return
        }
        linking = true
        error = nil
        Task {
            do { try await app.joinHousehold(.link(normal)) } catch { self.error = error.localizedDescription }
            linking = false
        }
    }
}

#if os(macOS)
/**
 * The Mac's Join step, kept while the Mac is on hold: it shows a QR code for an iPhone or iPad in
 * the household to scan (no code to type), or takes a link code. iPhone and iPad have no Join step:
 * their Welcome scans a telly code instead.
 */
struct JoinView: View {
    @Environment(AppModel.self) private var app
    let onBack: () -> Void
    /** On to the provider without syncing: there's no telly Plus to sync with, say. */
    let onSetUp: () -> Void

    @State private var join = SyncJoin.new()
    @State private var typing = false
    @State private var code = ""
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
            Text("On your iPhone or iPad, open telly and go to Settings → telly Plus → Add a device.")
                .foregroundStyle(Theme.muted)
            ownQR
            Divider().padding(.vertical, 4)
            Text("Or use its link code, from Settings → telly Plus → Show link code.").font(.callout).foregroundStyle(Theme.muted)
            Button("Enter a link code") { typing.toggle() }.buttonStyle(.bordered)
            codeEntry
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack(spacing: 16) {
                // The way on once telly Plus was turned down for the code that came in.
                if declinedPlus {
                    Button("Set up without syncing", action: onSetUp).buttonStyle(.borderedProminent)
                } else {
                    Button("Set up without syncing", action: onSetUp).buttonStyle(.bordered)
                }
                Button("Back", action: onBack).buttonStyle(.borderless)
            }
            Text("Provider logins are never part of sync: you'll sign in on this \(Device.name) next.")
                .font(.caption).foregroundStyle(Theme.faint)
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
    private var declinedPlus: Bool { waitingForPlus != nil && Plus.shared.offered == nil && !Plus.shared.unlocked }

    /** Whether this device's QR code is on screen: always, as a Mac has no camera to scan with. */
    private var qrShown: Bool { true }

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
                    Plus.shared.offered = .household
                } else {
                    self.error = error.localizedDescription
                }
            }
            linking = false
        }
    }
}
#endif

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
