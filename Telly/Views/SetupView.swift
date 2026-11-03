import SwiftUI

/** Adding (or editing) the provider. The login stays on this device, in its Keychain. */
struct SetupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /** The provider being edited, if any. */
    var existing: SavedProvider? = nil
    /** In a sheet (adding another provider, or editing), rather than the first screen. */
    var inSheet = false
    /** On the first run, back to Welcome. */
    var onBack: (() -> Void)? = nil

    @State private var xtream = true
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var url = ""
    @State private var allowCleartext = false
    @State private var showPassword = false
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Wordmark(height: 42)
                if !inSheet { Text("Add your provider").font(.title.weight(.bold)) }
                Text("Sign in with the details your TV provider gave you. telly doesn't come with any channels.")
                    .foregroundStyle(Theme.muted)
                Picker("Type", selection: $xtream) {
                    Text("Xtream Codes").tag(true)
                    Text("M3U playlist").tag(false)
                }
                .pickerStyle(.segmented)
                field("Name (optional)", $name, placeholder: "Leave blank to use the server's name")
                if xtream {
                    field("Server address", $server, placeholder: "example.com:8080", url: true)
                    HStack(spacing: 12) {
                        field("Username", $username)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Password").font(.caption).foregroundStyle(Theme.muted)
                            HStack(spacing: 6) {
                                if showPassword {
                                    TextField("", text: $password).textFieldStyle(.roundedBorder).plainEntry()
                                } else {
                                    SecureField("", text: $password).textFieldStyle(.roundedBorder).textContentType(.password)
                                }
                                Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                                    .buttonStyle(.borderless)
                                    .help(showPassword ? "Hide the password" : "Show the password")
                                    .accessibilityLabel(showPassword ? "Hide the password" : "Show the password")
                            }
                        }
                    }
                } else {
                    field("Playlist URL", $url, placeholder: "https://…/playlist.m3u", url: true)
                }
                PlainHTTPToggle(title: "Allow plain HTTP", isOn: $allowCleartext)
                if let error { Text(error).foregroundStyle(.orange).font(.callout) }
                HStack {
                    Button(connecting ? "Connecting…" : "Connect") { Task { await connect() } }
                        .buttonStyle(.borderedProminent).disabled(connecting || !complete)
                    if inSheet { Button("Cancel") { dismiss() }.buttonStyle(.bordered) }
                    if let onBack { Button("Back", action: onBack).buttonStyle(.bordered) }
                }
                Text("Your login stays on this \(Device.name), in its Keychain. telly only talks to your provider.")
                    .font(.caption).foregroundStyle(Theme.faint)
                if !inSheet && app.sync != nil { stillLinked }
            }
            .padding(32)
            .frame(maxWidth: 560)
            // A card on the page when signing in; editing is already in a sheet, so no card in a card.
            .background(inSheet ? .clear : Theme.surface, in: RoundedRectangle(cornerRadius: 20))
            .padding(.vertical, inSheet ? 0 : 60)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .onAppear(perform: fill)
    }

    /** Still linked for sync with no provider left: says so, and offers a way out. */
    private var stillLinked: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.vertical, 6)
            Text("This \(Device.name) is linked with your other devices").font(.headline)
            Text("Add your provider to pick up where you left off on them. Use the same one, signed in the same way.")
                .font(.caption).foregroundStyle(Theme.muted)
            Button("Stop syncing on this \(Device.name)", role: .destructive) { Task { await app.stopSync() } }
                .buttonStyle(.bordered)
        }
    }

    private func field(_ label: String, _ text: Binding<String>, placeholder: String = "", url: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(Theme.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .plainEntry(url: url)
        }
    }

    private var complete: Bool {
        xtream ? !server.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty : !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func fill() {
        switch existing?.provider {
        case let .xtream(n, s, u, p, c)?: (xtream, name, server, username, password, allowCleartext) = (true, n, s, u, p, c)
        case let .m3u(n, u, c)?: (xtream, name, url, allowCleartext) = (false, n, u, c)
        case nil: break
        }
        if name == defaultProviderName { name = "" }
    }

    private func connect() async {
        connecting = true
        error = nil
        // Unnamed providers go by their server's name, so several can be told apart.
        let address = (xtream ? server : url).trimmingCharacters(in: .whitespaces)
        let host = URL(string: address.contains("://") ? address : "http://\(address)")?.host
        let n = name.trimmingCharacters(in: .whitespaces).isEmpty ? (host ?? defaultProviderName) : name.trimmingCharacters(in: .whitespaces)
        let p: Provider = xtream
            ? .xtream(name: n, server: server.trimmingCharacters(in: .whitespaces), username: username.trimmingCharacters(in: .whitespaces), password: password, allowCleartext: allowCleartext)
            : .m3u(name: n, url: url.trimmingCharacters(in: .whitespaces), allowCleartext: allowCleartext)
        do {
            try await app.saveProvider(p, editing: existing?.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        connecting = false
    }
}

/**
 * The "Allow plain HTTP" switch, on the sign-in form and in Settings. Turning it on asks first, and
 * while it's on an orange note says what that exposes.
 */
struct PlainHTTPToggle: View {
    let title: String
    @Binding var isOn: Bool
    @State private var confirm = false

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { if $0 { confirm = true } else { isOn = false } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if isOn {
                    Text("Not encrypted. Anyone on the same network, such as public Wi-Fi, or along the way to your provider can read your username, password and what you watch.")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Only if your provider has no HTTPS. Your login and what you watch would be sent unencrypted.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
        .alert("Send your login unencrypted?", isPresented: $confirm) {
            Button("Allow plain HTTP", role: .destructive) { isOn = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("With plain HTTP, anyone on the same network, such as public Wi-Fi, or along the way to your provider can read your username, password and what you watch. Only allow it if your provider has no HTTPS.")
        }
    }
}
