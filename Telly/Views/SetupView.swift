import SwiftUI

/** Adding (or editing) the provider. The login stays on this iPad, in its Keychain. */
struct SetupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let existing: Provider?

    @State private var xtream = true
    @State private var name = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var url = ""
    @State private var allowCleartext = false
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("telly").font(.system(size: 44, weight: .black))
                Text("Add your IPTV provider to start watching. telly doesn't come with any channels.")
                    .foregroundStyle(Theme.muted)
                Picker("Type", selection: $xtream) {
                    Text("Xtream Codes").tag(true)
                    Text("M3U playlist").tag(false)
                }
                .pickerStyle(.segmented)
                field("Name (optional)", $name, placeholder: defaultProviderName)
                if xtream {
                    field("Server address", $server, placeholder: "example.com:8080", keyboard: .URL)
                    HStack(spacing: 12) {
                        field("Username", $username)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Password").font(.caption).foregroundStyle(Theme.muted)
                            SecureField("", text: $password).textFieldStyle(.roundedBorder).textContentType(.password)
                        }
                    }
                } else {
                    field("Playlist URL", $url, placeholder: "https://…/playlist.m3u", keyboard: .URL)
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
                    if existing != nil { Button("Cancel") { dismiss() }.buttonStyle(.bordered) }
                }
                Text("Your login stays on this iPad, in its Keychain. telly only talks to your provider.")
                    .font(.caption).foregroundStyle(Theme.faint)
            }
            .padding(32)
            .frame(maxWidth: 560)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .onAppear(perform: fill)
    }

    private func field(_ label: String, _ text: Binding<String>, placeholder: String = "", keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(Theme.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var complete: Bool {
        xtream ? !server.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty : !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func fill() {
        switch existing {
        case let .xtream(n, s, u, p, c)?: (xtream, name, server, username, password, allowCleartext) = (true, n, s, u, p, c)
        case let .m3u(n, u, c)?: (xtream, name, url, allowCleartext) = (false, n, u, c)
        case nil: break
        }
        if name == defaultProviderName { name = "" }
    }

    private func connect() async {
        connecting = true
        error = nil
        let n = name.trimmingCharacters(in: .whitespaces).isEmpty ? defaultProviderName : name.trimmingCharacters(in: .whitespaces)
        let p: Provider = xtream
            ? .xtream(name: n, server: server.trimmingCharacters(in: .whitespaces), username: username.trimmingCharacters(in: .whitespaces), password: password, allowCleartext: allowCleartext)
            : .m3u(name: n, url: url.trimmingCharacters(in: .whitespaces), allowCleartext: allowCleartext)
        do {
            try await app.saveProvider(p)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        connecting = false
    }
}
