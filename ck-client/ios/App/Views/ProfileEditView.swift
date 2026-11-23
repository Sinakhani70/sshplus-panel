import SwiftUI

struct ProfileEditView: View {
    let original: Profile?
    @EnvironmentObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var password = ""
    @State private var privateKey = ""
    @State private var tls = false
    @State private var sni = ""
    @State private var udpgw = true
    @State private var udpgwAddr = "127.0.0.1:7300"
    @State private var dns = "1.1.1.1, 8.8.8.8"
    @State private var ping = "1.1.1.1:443"
    @State private var error = ""
    @State private var hasSavedSecret = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Profile name", text: $name).disabled(original != nil)
                    TextField("Server (IP or domain)", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("SSH port", text: $port).keyboardType(.numberPad)
                    TextField("Username", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(hasSavedSecret ? "Password (saved - leave empty to keep)" : "Password", text: $password)
                }
                Section("Private key (optional)") {
                    TextEditor(text: $privateKey).font(.system(size: 11, design: .monospaced)).frame(minHeight: 70)
                }
                Section("Connection") {
                    Toggle("SSH over TLS (SNI)", isOn: $tls)
                    if tls { TextField("SNI", text: $sni).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    Toggle("UDPGW", isOn: $udpgw)
                    if udpgw { TextField("UDPGW address (as seen from the server)", text: $udpgwAddr).autocorrectionDisabled() }
                    TextField("DNS servers (comma separated)", text: $dns).autocorrectionDisabled()
                    TextField("Ping target host:port (or off)", text: $ping).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if let o = original, !o.hostKey.isEmpty {
                    Section("Server key") {
                        Text(o.hostKey).font(.caption2).foregroundColor(Theme.muted)
                        Button("Forget saved server key", role: .destructive) { store.forgetHostKey(o.name); dismiss() }
                    }
                }
                if !error.isEmpty { Section { Text(error).foregroundColor(Theme.error) } }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(original == nil ? "New profile" : "Edit profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let p = original else { return }
        name = p.name; host = p.host; port = String(p.port); user = p.user
        tls = p.isTLS; sni = p.sni; udpgw = p.udpgwEnabled; udpgwAddr = p.udpgwAddr
        dns = p.dns.joined(separator: ", "); ping = p.pingTarget
        hasSavedSecret = !(Keychain.load(p.name)?.password.isEmpty ?? true)
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        let h = host.trimmingCharacters(in: .whitespaces)
        let u = user.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !h.isEmpty, !u.isEmpty else { error = String(localized: "Name, server and username are required."); return }
        guard let prt = Int(port), (1...65535).contains(prt) else { error = String(localized: "Port must be a number from 1 to 65535."); return }
        let pt = ping.trimmingCharacters(in: .whitespaces)
        if !pt.isEmpty, pt.lowercased() != "off", !pt.contains(":") {
            error = String(localized: "Ping target must look like host:port (for example 1.1.1.1:443) or off."); return
        }
        if original == nil, store.profile(named: n) != nil { error = String(localized: "A profile with this name already exists."); return }
        let hasKey = !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if password.isEmpty && !hasKey && !hasSavedSecret { error = String(localized: "Enter a password or a private key."); return }

        var p = original ?? Profile(name: n, host: h, user: u)
        p.host = h; p.port = prt; p.user = u
        p.transport = tls ? "tls" : "direct"; p.sni = sni.trimmingCharacters(in: .whitespaces)
        p.udpgwEnabled = udpgw
        p.udpgwAddr = udpgwAddr.trimmingCharacters(in: .whitespaces).isEmpty ? "127.0.0.1:7300" : udpgwAddr.trimmingCharacters(in: .whitespaces)
        let list = dns.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        p.dns = list.isEmpty ? ["1.1.1.1", "8.8.8.8"] : list
        p.pingTarget = pt.isEmpty ? "1.1.1.1:443" : pt
        store.save(p, secrets: Secrets(password: password, privateKey: privateKey.trimmingCharacters(in: .whitespacesAndNewlines)))
        dismiss()
    }
}
