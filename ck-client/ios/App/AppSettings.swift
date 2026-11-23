import Foundation
import Combine

/// User settings, stored in the App Group defaults (the extension could read them too).
final class AppSettings: ObservableObject {
    private static let defaults = UserDefaults(suiteName: Constants.appGroup) ?? .standard

    @Published var killSwitch: Bool { didSet { Self.defaults.set(killSwitch, forKey: "killSwitch") } }
    @Published var forceDNS: Bool { didSet { Self.defaults.set(forceDNS, forKey: "forceDNS") } }
    @Published var onDemand: Bool { didSet { Self.defaults.set(onDemand, forKey: "onDemand") } }
    @Published var activeProfile: String { didSet { Self.defaults.set(activeProfile, forKey: "activeProfile") } }

    init() {
        let d = Self.defaults
        killSwitch = d.bool(forKey: "killSwitch")
        forceDNS = d.object(forKey: "forceDNS") as? Bool ?? true
        onDemand = d.bool(forKey: "onDemand")
        activeProfile = d.string(forKey: "activeProfile") ?? ""
    }
}
