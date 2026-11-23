import Foundation
import Combine
import NetworkExtension

struct TunnelStats: Equatable {
    var up: Int64 = 0
    var down: Int64 = 0
    var pingMs: Int = -1
    var link = false
}

/// Starts/stops the Packet Tunnel and reads its live status.
@MainActor
final class VPNManager: ObservableObject {
    @Published var status: NEVPNStatus = .disconnected
    @Published var stats = TunnelStats()
    @Published var log = ""
    @Published var lastError = ""
    @Published var connectedSince: Date?
    @Published var activeName = ""

    private var manager: NETunnelProviderManager?
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init() { Task { await load() } }

    func load() async {
        let all = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        manager = all.first
        attach()
    }

    private func attach() {
        guard let conn = manager?.connection else { return }
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: conn, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.statusChanged() }
        }
        statusChanged()
    }

    private func statusChanged() {
        guard let conn = manager?.connection else { return }
        status = conn.status
        switch conn.status {
        case .connected:
            if connectedSince == nil { connectedSince = conn.connectedDate ?? Date() }
            startPolling()
        case .disconnected, .invalid:
            connectedSince = nil
            stopPolling()
            stats = TunnelStats()
            fetchLastError()
        default:
            break
        }
    }

    var isActive: Bool { status == .connected || status == .connecting || status == .reasserting }

    // MARK: connect / disconnect

    func connect(_ profile: Profile, settings: AppSettings) async {
        lastError = ""
        do {
            let m = manager ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Constants.extensionBundleID
            proto.serverAddress = profile.host
            proto.providerConfiguration = ["profile": profile.name, "forceDNS": settings.forceDNS]
            proto.includeAllNetworks = settings.killSwitch        // kill switch: nothing leaves outside the tunnel
            proto.excludeLocalNetworks = true                      // keep the local network (printers, AirPlay) reachable
            m.protocolConfiguration = proto
            m.localizedDescription = "CK Client"
            m.isEnabled = true
            m.isOnDemandEnabled = settings.onDemand
            m.onDemandRules = settings.onDemand ? [NEOnDemandRuleConnect()] : []
            try await m.saveToPreferences()
            try await m.loadFromPreferences()      // required after the first save
            manager = m
            attach()
            activeName = profile.name
            try (m.connection as? NETunnelProviderSession)?.startVPNTunnel()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disconnect() {
        manager?.isOnDemandEnabled = false      // otherwise iOS reconnects at once
        manager?.saveToPreferences { [weak self] _ in
            Task { @MainActor in self?.manager?.connection.stopVPNTunnel() }
        }
    }

    // MARK: live status (provider message every second)

    private func startPolling() {
        stopPolling()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func stopPolling() { timer?.invalidate(); timer = nil }

    private func poll() {
        guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected else { return }
        try? session.sendProviderMessage(Data()) { [weak self] data in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let st = obj["status"] as? [String: Any] ?? [:]
            let logs = obj["logs"] as? String ?? ""
            Task { @MainActor in
                guard let self else { return }
                self.stats = TunnelStats(
                    up: (st["up"] as? NSNumber)?.int64Value ?? 0,
                    down: (st["down"] as? NSNumber)?.int64Value ?? 0,
                    pingMs: (st["pingMs"] as? NSNumber)?.intValue ?? -1,
                    link: (st["link"] as? Bool) ?? false)
                self.log = logs
            }
        }
    }

    /// Why the tunnel stopped (wrong password, host key changed, ...).
    private func fetchLastError() {
        manager?.connection.fetchLastDisconnectError { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }
    }
}
