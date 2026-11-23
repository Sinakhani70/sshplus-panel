import SwiftUI
import NetworkExtension

struct HomeView: View {
    @EnvironmentObject var store: ProfileStore
    @EnvironmentObject var vpn: VPNManager
    @EnvironmentObject var settings: AppSettings
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var selected: Profile? {
        store.profile(named: settings.activeProfile) ?? store.profiles.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                statusCard
                Button(action: toggle) { Text(buttonTitle) }
                    .buttonStyle(BigButtonStyle(color: vpn.isActive ? Theme.error : Theme.primary,
                                                foreground: vpn.isActive ? .white : Color(hex: 0x031116)))
                profilePicker
                if let p = selected { udpgwCard(p) }
            }
            .padding(18)
        }
        .background(Theme.bg.ignoresSafeArea())
        .onReceive(tick) { now = $0 }
        .onAppear { store.reload() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("Logo").resizable().frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text("CK Client").font(.title2.bold()).foregroundColor(Theme.text)
                Text("SSH · UDPGW · VPN").font(.caption).foregroundColor(Theme.muted)
            }
            Spacer()
        }
    }

    private var statusColor: Color {
        switch vpn.status {
        case .connected: return Theme.ok
        case .connecting, .reasserting: return Theme.warn
        default: return vpn.lastError.isEmpty ? Theme.muted : Theme.error
        }
    }

    private var statusText: LocalizedStringKey {
        switch vpn.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .reasserting: return "Reconnecting..."
        case .disconnecting: return "Disconnecting..."
        default: return vpn.lastError.isEmpty ? "Disconnected" : "Error"
        }
    }

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Circle().fill(statusColor).frame(width: 12, height: 12)
                        .shadow(color: statusColor.opacity(0.8), radius: vpn.status == .connected ? 5 : 0)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusText).font(.headline).foregroundColor(Theme.text)
                        if vpn.isActive, !vpn.activeName.isEmpty {
                            Text(subtitle).font(.caption).foregroundColor(Theme.muted)
                        }
                    }
                }
                if vpn.status == .disconnected || vpn.status == .invalid, !vpn.lastError.isEmpty {
                    Text(vpn.lastError).font(.caption).foregroundColor(Theme.error)
                }
                HStack {
                    stat("UPLOAD", vpn.status == .connected ? formatBytes(vpn.stats.up) : "-")
                    stat("DOWNLOAD", vpn.status == .connected ? formatBytes(vpn.stats.down) : "-")
                    pingStat
                }
            }
        }
    }

    private var subtitle: String {
        guard vpn.status == .connected, let since = vpn.connectedSince else { return vpn.activeName }
        let s = Int(now.timeIntervalSince(since))
        return String(format: "%@ · %02d:%02d:%02d", vpn.activeName, s / 3600, (s / 60) % 60, s % 60)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title)).font(.system(size: 10)).foregroundColor(Theme.muted)
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pingStat: some View {
        let ms = vpn.stats.pingMs
        let connected = vpn.status == .connected
        let text = !connected ? "-" : (!vpn.stats.link ? "…" : (ms < 0 ? "…" : "\(ms) ms"))
        let color: Color = !connected || ms < 0 ? Theme.text : (ms < 120 ? Theme.ok : (ms < 300 ? Theme.warn : Theme.error))
        return VStack(alignment: .leading, spacing: 2) {
            Text("PING").font(.system(size: 10)).foregroundColor(Theme.muted)
            Text(text).font(.system(size: 15, weight: .semibold)).foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var profilePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROFILE").font(.caption).foregroundColor(Theme.muted)
            if store.profiles.isEmpty {
                Text("No profile yet. Open the Profiles tab and import one from the panel.")
                    .font(.footnote).foregroundColor(Theme.muted)
            } else {
                Picker("Profile", selection: Binding(
                    get: { selected?.name ?? "" },
                    set: { settings.activeProfile = $0 })) {
                    ForEach(store.profiles) { Text($0.name).tag($0.name) }
                }
                .pickerStyle(.menu)
                .disabled(vpn.isActive)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.input)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func udpgwCard(_ p: Profile) -> some View {
        Card {
            HStack {
                Text("UDPGW").foregroundColor(Theme.text)
                Text(p.udpgwAddr).foregroundColor(Theme.muted)
                Spacer()
                Text(p.udpgwEnabled ? "ON" : "OFF")
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background((p.udpgwEnabled ? Theme.ok : Theme.muted).opacity(0.15))
                    .foregroundColor(p.udpgwEnabled ? Theme.ok : Theme.muted)
                    .clipShape(Capsule())
            }.font(.subheadline)
        }
    }

    private var buttonTitle: LocalizedStringKey { vpn.isActive ? "Disconnect" : "Connect" }

    private func toggle() {
        if vpn.isActive {
            vpn.disconnect()
        } else if let p = selected {
            settings.activeProfile = p.name
            Task { await vpn.connect(p, settings: settings) }
        }
    }
}
