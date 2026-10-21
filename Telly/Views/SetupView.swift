import SwiftUI

/** Adding (or editing) the provider. The login stays on this device, in its Keychain. */
struct SetupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /** The provider being edited, if any. */
    var existing: SavedProvider? = nil
    /** In a sheet (adding another provider, or editing), rather than the first screen. */
    var inSheet = false

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
                Text("Add your IPTV provider to start watching. telly doesn't come with any channels.")
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
                Toggle(isOn: $allowCleartext) {
                    VStack(alignment: .leading) {
                        Text("Allow plain HTTP")
                        Text("Only if your provider has no HTTPS. Traffic to it won't be encrypted.").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                if let error { Text(error).foregroundStyle(.orange).font(.callout) }
                HStack {
                    Button(connecting ? "Connecting…" : "Connect") { Task { await connect() } }
                        .buttonStyle(.borderedProminent).disabled(connecting || !complete)
                    if inSheet { Button("Cancel") { dismiss() }.buttonStyle(.bordered) }
                }
                Text("Your login stays on this \(Device.name), in its Keychain. telly only talks to your provider.")
                    .font(.caption).foregroundStyle(Theme.faint)
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
