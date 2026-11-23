import Foundation

/// profiles.json in the App Group container. Both the app and the extension read it;
/// the extension also writes the pinned host key.
enum ProfileFile {
    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Constants.appGroup)?
            .appendingPathComponent("profiles.json")
    }

    static func load() -> [Profile] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Profile].self, from: data)) ?? []
    }

    static func save(_ profiles: [Profile]) {
        guard let url, let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    static func profile(named name: String) -> Profile? { load().first { $0.name == name } }

    /// Called by the extension when the server key is trusted on first use.
    static func setHostKey(_ fingerprint: String, for name: String) {
        var all = load()
        guard let i = all.firstIndex(where: { $0.name == name }) else { return }
        all[i].hostKey = fingerprint
        save(all)
    }
}
