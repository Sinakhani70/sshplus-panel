import NetworkExtension
import Ckcore

/// The VPN itself. Runs in its own process (tight memory limit): all packet work is done by the Go core.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var engine: CkcoreEngine?
    private var profileName = ""
    private let sink = Sink()
    private let events = Events()

    // MARK: lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        CkcoreSetMemoryLimitMB(30)

        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let cfg = proto.providerConfiguration,
              let name = cfg["profile"] as? String,
              let profile = ProfileFile.profile(named: name),
              let secrets = Keychain.load(name) else {
            completionHandler(Self.error("Profile or saved password not found. Open CK Client and save the profile again."))
            return
        }
        profileName = name
        let forceDNS = (cfg["forceDNS"] as? Bool) ?? true

        let json: [String: Any] = [
            "name": profile.name, "host": profile.host, "port": profile.port, "user": profile.user,
            "password": secrets.password, "privateKey": secrets.privateKey,
            "transport": profile.transport, "sni": profile.sni,
            "udpgwEnabled": profile.udpgwEnabled, "udpgwAddr": profile.udpgwAddr,
            "dns": profile.dns, "pingTarget": profile.pingTarget, "hostKey": profile.hostKey,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else {
            completionHandler(Self.error("Cannot encode the profile"))
            return
        }

        sink.provider = self
        events.provider = self
        events.profileName = name

        var err: NSError?
        guard let eng = CkcoreNewEngine(text, sink, events, &err) else {
            completionHandler(err ?? Self.error("Cannot create the engine"))
            return
        }
        engine = eng

        // SSH login can take a few seconds: never block the extension's main queue.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do { try eng.start() } catch {
                completionHandler(error)
                return
            }
            let settings = self.networkSettings(host: profile.host, dns: profile.dns, forceDNS: forceDNS)
            self.setTunnelNetworkSettings(settings) { error in
                if let error {
                    eng.stop()
                    completionHandler(error)
                    return
                }
                self.readLoop()
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        engine?.stop()
        engine = nil
        completionHandler()
    }

    /// The app polls this for live numbers and the log.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let engine else { completionHandler?(nil); return }
        let status = (try? JSONSerialization.jsonObject(with: Data(engine.statusJSON().utf8))) ?? [:]
        let reply: [String: Any] = ["status": status, "logs": engine.logs()]
        completionHandler?(try? JSONSerialization.data(withJSONObject: reply))
    }

    // MARK: network settings

    private func networkSettings(host: String, dns: [String], forceDNS: Bool) -> NEPacketTunnelNetworkSettings {
        // tunnelRemoteAddress is informational; the extension's own sockets (the SSH link) never enter the tunnel.
        let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: host)

        let v4 = NEIPv4Settings(addresses: [Constants.tunnelAddress], subnetMasks: [Constants.tunnelMask])
        v4.includedRoutes = [NEIPv4Route.default()]
        s.ipv4Settings = v4

        // IPv6 goes into the tunnel too, so it cannot leak around it.
        let v6 = NEIPv6Settings(addresses: [Constants.tunnelAddress6], networkPrefixLengths: [64])
        v6.includedRoutes = [NEIPv6Route.default()]
        s.ipv6Settings = v6

        if forceDNS && !dns.isEmpty {
            let d = NEDNSSettings(servers: dns)
            d.matchDomains = [""]            // all names, not only a search domain
            s.dnsSettings = d
        }
        s.mtu = NSNumber(value: Constants.mtu)
        return s
    }

    // MARK: packets

    private func readLoop() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, let engine = self.engine else { return }
            for p in packets { engine.inputPacket(p) }
            self.readLoop()
        }
    }

    fileprivate static func error(_ text: String) -> NSError {
        NSError(domain: "CKClient", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

/// Go -> device packets.
private final class Sink: NSObject, CkcorePacketSinkProtocol {
    weak var provider: PacketTunnelProvider?

    func writePacket(_ packet: Data?) {
        guard let packet, !packet.isEmpty, let provider else { return }
        let isV6 = (packet[packet.startIndex] >> 4) == 6
        provider.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: isV6 ? AF_INET6 : AF_INET)])
    }
}

/// Go -> extension events.
private final class Events: NSObject, CkcoreEventHandlerProtocol {
    weak var provider: PacketTunnelProvider?
    var profileName = ""

    func onLog(_ line: String?) {}                      // the log is read back through handleAppMessage

    func onHostKey(_ fingerprint: String?) {            // trust on first use: remember it
        guard let fingerprint, !profileName.isEmpty else { return }
        ProfileFile.setHostKey(fingerprint, for: profileName)
    }

    func onLink(_ up: Bool) {                           // SSH link down/up -> iOS shows "reasserting"
        provider?.reasserting = !up
    }
}
