import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var vpn: VPNManager

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $settings.killSwitch) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Kill switch")
                            Text("Block all traffic if the tunnel drops").font(.caption).foregroundColor(Theme.muted)
                        }
                    }
                    Toggle(isOn: $settings.forceDNS) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Force DNS through tunnel")
                            Text("Use the profile's DNS servers for every name").font(.caption).foregroundColor(Theme.muted)
                        }
                    }
                    Toggle(isOn: $settings.onDemand) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connect on demand")
                            Text("Reconnect automatically on network change").font(.caption).foregroundColor(Theme.muted)
                        }
                    }
                } footer: {
                    Text(vpn.isActive ? "Changes apply the next time you connect." : "")
                }

                Section("Language") {
                    Button("Open iOS language settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }

                Section("About") {
                    HStack { Text("CK Client"); Spacer(); Text(version).foregroundColor(Theme.muted) }
                    Text("Works with the CK.VPN panel: create an account in the panel, then import its link here.")
                        .font(.footnote).foregroundColor(Theme.muted)
                    Text("Use it only with servers you own or administer.").font(.footnote).foregroundColor(Theme.muted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Settings")
        }
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "v\(v)"
    }
}
