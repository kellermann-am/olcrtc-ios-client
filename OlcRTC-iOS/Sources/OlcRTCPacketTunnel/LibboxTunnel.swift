import Foundation
import Network
import NetworkExtension
#if canImport(Libbox)
import Libbox
#endif

#if canImport(Libbox)
// sing-box (Libbox) tun stack for the «Весь» mode. Gives fake-ip DNS so the
// device resolves names through the olcRTC engine (which does SOCKS
// domain-CONNECT) instead of the broken UDP path. The engine's own SOCKS is
// the single outbound; the engine keeps running in this same NE process, and
// iOS does not route the extension's own sockets back into its tun — no loop.
final class OlcRTCBoxTunnel: NSObject {
    private weak var provider: NEPacketTunnelProvider?
    private var commandServer: LibboxCommandServer?
    private var monitor: NWPathMonitor?
    private var listener: LibboxInterfaceUpdateListenerProtocol?
    private static var didSetup = false

    init(provider: NEPacketTunnelProvider) {
        self.provider = provider
        super.init()
    }

    func start(configContent: String) throws {
        try Self.setupOnce()
        var err: NSError?
        guard let server = LibboxNewCommandServer(self, self, &err) else {
            throw err ?? NSError(domain: "olcrtc.box", code: 1)
        }
        if let err { throw err }
        try server.start()
        try server.startOrReloadService(configContent, options: LibboxOverrideOptions())
        commandServer = server
    }

    func stop() {
        try? commandServer?.closeService()
        commandServer?.close()
        commandServer = nil
        monitor?.cancel()
        monitor = nil
    }

    private static func setupOnce() throws {
        if didSetup { return }
        let base = NSTemporaryDirectory().appending("olcrtc-box")
        let work = base + "/work"
        let tmp = base + "/tmp"
        for p in [base, work, tmp] {
            try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        }
        let opts = LibboxSetupOptions()
        opts.basePath = base
        opts.workingPath = work
        opts.tempPath = tmp
        opts.logMaxLines = 3000
        var err: NSError?
        LibboxSetup(opts, &err)
        if let err { throw err }
        didSetup = true
    }

    // fake-ip config validated offline with sing-box 1.13.11 `check`.
    static func config(socksPort: Int, socksUser: String, socksPass: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        return """
        {
          "log": { "level": "warn" },
          "dns": {
            "servers": [
              { "tag": "remote", "type": "tcp", "server": "8.8.8.8", "detour": "socks-out" },
              { "tag": "fake", "type": "fakeip", "inet4_range": "198.18.0.0/15" }
            ],
            "rules": [
              { "query_type": ["AAAA"], "action": "reject" },
              { "query_type": ["A"], "server": "fake" }
            ],
            "final": "remote",
            "independent_cache": true
          },
          "inbounds": [
            { "type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true, "strict_route": false, "mtu": 9000, "stack": "gvisor" }
          ],
          "outbounds": [
            { "type": "socks", "tag": "socks-out", "server": "127.0.0.1", "server_port": \(socksPort), "version": "5", "username": "\(esc(socksUser))", "password": "\(esc(socksPass))" },
            { "type": "direct", "tag": "direct" }
          ],
          "route": {
            "rules": [ { "action": "sniff" }, { "protocol": "dns", "action": "hijack-dns" } ],
            "final": "socks-out",
            "default_domain_resolver": { "server": "remote" },
            "auto_detect_interface": false
          }
        }
        """
    }
}

extension OlcRTCBoxTunnel: LibboxPlatformInterfaceProtocol {
    func openTun(_ options: LibboxTunOptionsProtocol?) throws -> Int32 {
        guard let options, let provider = provider else {
            throw NSError(domain: "olcrtc.box", code: 2)
        }
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        var addrs: [String] = []
        var masks: [String] = []
        if let it = options.getInet4Address() {
            while it.hasNext(), let p = it.next() { addrs.append(p.address()); masks.append(p.mask()) }
        }
        if addrs.isEmpty { addrs = ["172.19.0.1"]; masks = ["255.255.255.252"] }
        let v4 = NEIPv4Settings(addresses: addrs, subnetMasks: masks)

        var included: [NEIPv4Route] = []
        if let it = options.getInet4RouteAddress() {
            while it.hasNext(), let p = it.next() {
                included.append(NEIPv4Route(destinationAddress: p.address(), subnetMask: p.mask()))
            }
        }
        v4.includedRoutes = included.isEmpty ? [NEIPv4Route.default()] : included

        var excluded: [NEIPv4Route] = []
        if let it = options.getInet4RouteExcludeAddress() {
            while it.hasNext(), let p = it.next() {
                excluded.append(NEIPv4Route(destinationAddress: p.address(), subnetMask: p.mask()))
            }
        }
        if !excluded.isEmpty { v4.excludedRoutes = excluded }
        settings.ipv4Settings = v4

        if let box = try? options.getDNSServerAddress(), !box.value.isEmpty {
            settings.dnsSettings = NEDNSSettings(servers: [box.value])
        } else {
            settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8"])
        }

        let sem = DispatchSemaphore(value: 0)
        var applyErr: Error?
        provider.setTunnelNetworkSettings(settings) { e in applyErr = e; sem.signal() }
        sem.wait()
        if let applyErr { throw applyErr }

        var fd: Int32 = -1
        if let v = (provider.packetFlow as NSObject).value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            fd = v
        }
        if fd < 0 { fd = LibboxGetTunnelFileDescriptor() }
        if fd < 0 { throw NSError(domain: "olcrtc.box", code: 3) }
        return fd
    }

    func useProcFS() -> Bool { false }
    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_ fd: Int32) throws {}
    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }
    func clearDNSCache() {}
    func readWIFIState() -> LibboxWIFIState? { nil }
    func systemCertificates() -> LibboxStringIteratorProtocol? { nil }
    func localDNSTransport() -> LibboxLocalDNSTransportProtocol? { nil }
    func send(_ notification: LibboxNotification?) throws {}
    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        throw NSError(domain: "olcrtc.box", code: 4)
    }
    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        EmptyInterfaceIterator()
    }
    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        self.listener = listener
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard let self, let l = self.listener else { return }
            let iface = path.availableInterfaces.first
            let name = iface?.name ?? ""
            let idx = Int32(iface?.index ?? 0)
            l.updateDefaultInterface(name, interfaceIndex: idx, isExpensive: path.isExpensive, isConstrained: path.isConstrained)
        }
        m.start(queue: DispatchQueue(label: "olcrtc.box.path"))
        monitor = m
    }
    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        monitor?.cancel()
        monitor = nil
        self.listener = nil
    }
}

extension OlcRTCBoxTunnel: LibboxCommandServerHandlerProtocol {
    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let s = LibboxSystemProxyStatus()
        s.available = false
        s.enabled = false
        return s
    }
    func serviceReload() throws {}
    func serviceStop() throws { provider?.cancelTunnelWithError(nil) }
    func setSystemProxyEnabled(_ enabled: Bool) throws {}
    func writeDebugMessage(_ message: String?) {
        if let message { NSLog("[olcrtc-box] %@", message) }
    }
}

final class EmptyInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    func hasNext() -> Bool { false }
    func next() -> LibboxNetworkInterface? { nil }
}
#endif
