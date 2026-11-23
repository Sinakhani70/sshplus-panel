import Foundation
import Combine
import Ckcore

/// The app's view of the saved profiles (file in the App Group + secrets in the Keychain).
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [Profile] = []

    init() { reload() }

    /// Re-read from disk (the extension may have pinned a host key meanwhile).
    func reload() { profiles = ProfileFile.load() }

    func profile(named name: String) -> Profile? { profiles.first { $0.name == name } }
    func secrets(for name: String) -> Secrets? { Keychain.load(name) }

    /// Create or update. Empty secret fields keep the stored value.
    func save(_ p: Profile, secrets: Secrets?) {
        var list = profiles
        var p = p
        if let i = list.firstIndex(where: { $0.name == p.name }) {
            if list[i].host == p.host && list[i].port == p.port { p.hostKey = list[i].hostKey }   // keep the pin unless the server changed
            list[i] = p
        } else {
            list.append(p)
        }
        profiles = list
        ProfileFile.save(list)
        if var s = secrets {
            let old = Keychain.load(p.name) ?? Secrets()
            if s.password.isEmpty { s.password = old.password }
            if s.privateKey.isEmpty { s.privateKey = old.privateKey }
            Keychain.save(s, for: p.name)
        }
    }

    func delete(_ name: String) {
        profiles.removeAll { $0.name == name }
        ProfileFile.save(profiles)
        Keychain.delete(name)
    }

    func forgetHostKey(_ name: String) {
        guard var p = profile(named: name) else { return }
        p.hostKey = ""
        save(p, secrets: nil)
    }

    // MARK: import (clipboard text, scanned QR, ckclient:// URL)

    /// Parses text copied from the CK.VPN panel (ssh:// links, a list, base64, or a subscription URL).
    /// Runs the network part (subscription URL) off the main thread.
    func importText(_ text: String) async throws -> [ImportedProfile] {
        try await Task.detached(priority: .userInitiated) {
            var err: NSError?
            let json = CkcoreImportText(text, &err)
            if let err { throw err }
            return try JSONDecoder().decode([ImportedProfile].self, from: Data(json.utf8))
        }.value
    }

    /// Saves imported profiles; the same account on the same server just updates the password.
    @discardableResult
    func add(_ imported: [ImportedProfile]) -> [String] {
        var names: [String] = []
        for imp in imported {
            var p = imp.profile
            if let old = profile(named: p.name), old.host == p.host, old.port == p.port, old.user == p.user {
                var merged = old
                merged.transport = p.transport
                merged.sni = p.sni
                save(merged, secrets: Secrets(password: imp.password ?? "", privateKey: ""))
                names.append(old.name)
                continue
            }
            let base = p.name
            var n = 2
            while profile(named: p.name) != nil { p.name = "\(base) (\(n))"; n += 1 }
            save(p, secrets: imp.secrets)
            names.append(p.name)
        }
        return names
    }
}
