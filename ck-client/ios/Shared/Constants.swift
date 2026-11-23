import Foundation

/// Identifiers shared by the app and the Packet Tunnel extension.
/// They come from Info.plist (filled from project.yml build settings), so nothing is hard-coded.
enum Constants {
    static var appGroup: String { info("CKAppGroup") }
    static var keychainGroup: String { info("CKKeychainGroup") }

    /// Bundle id of the Packet Tunnel extension (app id + ".PacketTunnel").
    static var extensionBundleID: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        return id.hasSuffix(".PacketTunnel") ? id : id + ".PacketTunnel"
    }

    static let tunnelAddress = "10.77.0.2"
    static let tunnelMask = "255.255.255.0"
    static let tunnelAddress6 = "fd77:77::2"
    static let mtu = 1200   // same as CkcoreMTU

    private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }
}
