import Foundation
import NetworkExtension

#if canImport(Mobile)
import Mobile
#endif

#if canImport(Tun2SocksKit)
import Tun2SocksKit
#endif

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private enum TunnelMode: String {
        case systemProxy
        case fullTunnel
        case splitTunnel

        var usesPacketEngine: Bool {
            // Только «Весь» реально забирает пакеты в tun (и гоняет Tun2Socks).
            // «Локальный» (splitTunnel) поднимает движок+SOCKS, но трафик не
            // захватывает — через тоннель идут лишь приложения с явно
            // прописанным SOCKS 127.0.0.1:<port>.
            self == .fullTunnel
        }
    }

    private enum RoutingPreset: String {
        case allProxy
        case simpleRU
        case blockedOnly
        case localOnly

        var shouldBypassLocalRoutes: Bool {
            self != .allProxy
        }
    }

    private var socksPort = 18080
    private var tunnelStarted = false
    private var packetEngine: Tun2SocksPacketEngine?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let config = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfiguration = config.providerConfiguration,
              let carrier = providerConfiguration["carrier"] as? String,
              let transport = providerConfiguration["transport"] as? String,
              let roomID = providerConfiguration["roomID"] as? String,
              let keyHex = providerConfiguration["keyHex"] as? String,
              let clientID = providerConfiguration["clientID"] as? String else {
            completionHandler(TunnelError.invalidConfiguration)
            return
        }

        socksPort = providerConfiguration["socksPort"] as? Int ?? 18080
        let socksUser = providerConfiguration["socksUser"] as? String ?? ""
        let socksPass = providerConfiguration["socksPass"] as? String ?? ""
        let payload = providerConfiguration["payload"] as? [String: String] ?? [:]
        let tunnelMode = TunnelMode(rawValue: providerConfiguration["tunnelMode"] as? String ?? "") ?? .systemProxy
        let routingPreset = RoutingPreset(rawValue: providerConfiguration["routingPreset"] as? String ?? "") ?? .simpleRU

        #if canImport(Mobile)
        MobileSetProviders()
        MobileSetDNS("8.8.8.8:53")
        MobileSetTransport(transport)
        MobileSetLivenessOptions(20_000, 15_000, 12)
        configureTransportOptions(transport: transport, payload: payload)

        var startError: NSError?
        let started = MobileStartWithTransport(
            carrier,
            transport,
            roomID,
            clientID,
            keyHex,
            socksPort,
            socksUser,
            socksPass,
            &startError
        )

        if let startError {
            completionHandler(startError)
            return
        }

        guard started else {
            completionHandler(TunnelError.olcrtcStartFailed)
            return
        }

        var waitError: NSError?
        let ready = MobileWaitReady(
            readyTimeoutMilliseconds(carrier: carrier, transport: transport),
            &waitError
        )
        if let waitError {
            MobileStop()
            completionHandler(waitError)
            return
        }
        guard ready else {
            MobileStop()
            completionHandler(TunnelError.olcrtcReadyTimeout)
            return
        }

        let settings = networkSettings(mode: tunnelMode, routingPreset: routingPreset, port: socksPort)
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                MobileStop()
                completionHandler(TunnelError.providerDeallocated)
                return
            }

            if let error {
                MobileStop()
                completionHandler(error)
                return
            }

            if tunnelMode.usesPacketEngine {
                do {
                    let engine = try Tun2SocksPacketEngine(
                        socksPort: self.socksPort,
                        socksUser: socksUser,
                        socksPass: socksPass
                    )
                    try engine.start()
                    self.packetEngine = engine
                } catch {
                    MobileStop()
                    completionHandler(error)
                    return
                }
            }

            self.tunnelStarted = true
            completionHandler(nil)
        }
        #else
        completionHandler(TunnelError.mobileFrameworkMissing)
        #endif
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        packetEngine?.stop()
        packetEngine = nil

        #if canImport(Mobile)
        if tunnelStarted {
            MobileStop()
        }
        #endif
        tunnelStarted = false
        completionHandler()
    }

    private func networkSettings(mode: TunnelMode, routingPreset: RoutingPreset, port: Int) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.88.0.1")
        settings.mtu = 1280

        let ipv4 = NEIPv4Settings(addresses: ["10.88.0.2"], subnetMasks: ["255.255.255.0"])
        if mode == .fullTunnel {
            // Весь трафик устройства в тоннель (локальные сети — по пресету напрямую).
            ipv4.includedRoutes = [NEIPv4Route.default()]
            if routingPreset.shouldBypassLocalRoutes {
                ipv4.excludedRoutes = Self.privateAndLocalRoutes()
            }
        } else {
            // Локальный: тоннель НЕ забирает трафик устройства. Один фиктивный
            // маршрут (TEST-NET 192.0.2.0/24), чтобы iOS принял конфиг tun, но
            // реальные пакеты в него не попадали. SOCKS остаётся доступен по
            // loopback для приложений, где он прописан вручную.
            ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "192.0.2.0", subnetMask: "255.255.255.0")]
        }
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])

        if mode == .systemProxy {
            settings.proxySettings = proxySettings(port: port)
        }
        return settings
    }

    private static func privateAndLocalRoutes() -> [NEIPv4Route] {
        [
            route("10.0.0.0", "255.0.0.0"),
            route("100.64.0.0", "255.192.0.0"),
            route("127.0.0.0", "255.0.0.0"),
            route("169.254.0.0", "255.255.0.0"),
            route("172.16.0.0", "255.240.0.0"),
            route("192.168.0.0", "255.255.0.0"),
            route("224.0.0.0", "240.0.0.0")
        ]
    }

    private static func route(_ destination: String, _ mask: String) -> NEIPv4Route {
        NEIPv4Route(destinationAddress: destination, subnetMask: mask)
    }

    private func proxySettings(port: Int) -> NEProxySettings {
        let settings = NEProxySettings()
        settings.autoProxyConfigurationEnabled = true
        settings.proxyAutoConfigurationJavaScript = """
        function FindProxyForURL(url, host) {
            if (isPlainHostName(host)) { return "DIRECT"; }
            if (host === "localhost" || host === "127.0.0.1") { return "DIRECT"; }
            if (dnsDomainIs(host, ".local")) { return "DIRECT"; }
            return "SOCKS5 127.0.0.1:\(port); SOCKS 127.0.0.1:\(port); DIRECT";
        }
        """
        settings.excludeSimpleHostnames = true
        settings.exceptionList = [
            "*.local",
            "localhost",
            "127.0.0.1"
        ]
        return settings
    }

    private func readyTimeoutMilliseconds(carrier: String, transport: String) -> Int {
        if carrier.lowercased() == "jitsi", transport.lowercased() == "datachannel" {
            return 90_000
        }
        return 30_000
    }

    private func configureTransportOptions(transport: String, payload: [String: String]) {
        #if canImport(Mobile)
        switch transport.lowercased() {
        case "vp8channel":
            MobileSetVP8Options(
                payloadInt(payload, "vp8-fps", default: 60),
                payloadInt(payload, "vp8-batch", default: 64)
            )
        case "seichannel":
            MobileSetSEIOptions(
                payloadInt(payload, "fps", default: 0),
                payloadInt(payload, "batch", default: 0),
                payloadInt(payload, "frag", default: 0),
                payloadInt(payload, "ack-ms", default: 0)
            )
        case "videochannel":
            MobileSetVideoOptions(
                payloadInt(payload, "video-w", default: 0),
                payloadInt(payload, "video-h", default: 0),
                payloadInt(payload, "video-fps", default: 0),
                payload["video-bitrate"] ?? "",
                payload["video-hw"] ?? "",
                payloadInt(payload, "video-qr-size", default: 0),
                payload["video-qr-recovery"] ?? "",
                payload["video-codec"] ?? "",
                payloadInt(payload, "video-tile-module", default: 0),
                payloadInt(payload, "video-tile-rs", default: 0)
            )
        default:
            break
        }
        #endif
    }

    private func payloadInt(_ payload: [String: String], _ key: String, default defaultValue: Int) -> Int {
        Int(payload[key] ?? "") ?? defaultValue
    }
}

private final class Tun2SocksPacketEngine {
    private let config: String

    init(socksPort: Int, socksUser: String, socksPass: String) throws {
        #if canImport(Tun2SocksKit)
        config = Self.makeConfig(socksPort: socksPort, socksUser: socksUser, socksPass: socksPass)
        #else
        throw TunnelError.tun2socksUnavailable
        #endif
    }

    func start() throws {
        #if canImport(Tun2SocksKit)
        Socks5Tunnel.run(withConfig: .string(content: config)) { code in
            NSLog("Tun2SocksKit exited with code \(code)")
        }
        #else
        throw TunnelError.tun2socksUnavailable
        #endif
    }

    func stop() {
        #if canImport(Tun2SocksKit)
        Socks5Tunnel.quit()
        #endif
    }

    private static func makeConfig(socksPort: Int, socksUser: String, socksPass: String) -> String {
        var auth = ""
        if !socksUser.isEmpty || !socksPass.isEmpty {
            auth = """
              username: '\(escape(socksUser))'
              password: '\(escape(socksPass))'
            """
        }

        return """
        tunnel:
          mtu: 1280

        socks5:
          port: \(socksPort)
          address: '127.0.0.1'
          udp: 'udp'
        \(auth)

        misc:
          task-stack-size: 24576
          connect-timeout: 5000
          read-write-timeout: 60000
          log-file: stderr
          log-level: warn
        """
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

private enum TunnelError: LocalizedError {
    case invalidConfiguration
    case providerDeallocated
    case mobileFrameworkMissing
    case olcrtcStartFailed
    case olcrtcReadyTimeout
    case tun2socksUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "OlcRTC VPN configuration is incomplete."
        case .providerDeallocated:
            return "OlcRTC VPN provider was deallocated."
        case .mobileFrameworkMissing:
            return "Mobile.xcframework is not linked to the packet tunnel."
        case .olcrtcStartFailed:
            return "olcRTC failed to start inside the packet tunnel."
        case .olcrtcReadyTimeout:
            return "olcRTC started but SOCKS was not ready before timeout."
        case .tun2socksUnavailable:
            return "Tun2SocksKit is not linked to the packet tunnel."
        }
    }
}
