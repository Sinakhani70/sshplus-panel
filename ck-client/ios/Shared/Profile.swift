import Foundation

/// One saved server connection. Secrets (password / private key) live in the Keychain, not here.
struct Profile: Codable, Identifiable, Equatable, Hashable {
    var name: String
    var host: String
    var port: Int = 22
    var user: String
    var transport: String = "direct"        // "direct" | "tls"
    var sni: String = ""
    var udpgwEnabled: Bool = true
    var udpgwAddr: String = "127.0.0.1:7300"
    var dns: [String] = ["1.1.1.1", "8.8.8.8"]
    var pingTarget: String = "1.1.1.1:443"  // "off" = time the SSH server only
    var hostKey: String = ""                // pinned on first connect (trust on first use)

    var id: String { name }
    var isTLS: Bool { transport == "tls" }
}

struct Secrets: Codable, Equatable {
    var password: String = ""
    var privateKey: String = ""
}

/// What `CkcoreImportText` returns (the Go `profile` JSON, with secrets).
struct ImportedProfile: Decodable {
    var name: String
    var host: String
    var port: Int?
    var user: String
    var password: String?
    var privateKey: String?
    var transport: String?
    var sni: String?
    var udpgwEnabled: Bool?
    var udpgwAddr: String?
    var dns: [String]?
    var pingTarget: String?

    var profile: Profile {
        var p = Profile(name: name, host: host, user: user)
        p.port = port ?? 22
        p.transport = transport ?? "direct"
        p.sni = sni ?? ""
        p.udpgwEnabled = udpgwEnabled ?? true
        if let a = udpgwAddr, !a.isEmpty { p.udpgwAddr = a }
        if let d = dns, !d.isEmpty { p.dns = d }
        if let t = pingTarget, !t.isEmpty { p.pingTarget = t }
        return p
    }
    var secrets: Secrets { Secrets(password: password ?? "", privateKey: privateKey ?? "") }
}
