import Foundation
import NetworkExtension

@MainActor
final class VPNController: ObservableObject {
    enum TunnelMode: String, CaseIterable, Identifiable {
        case systemProxy
        case fullTunnel
        case splitTunnel

        static let selectableModes: [TunnelMode] = [.fullTunnel, .splitTunnel]

        var id: String { rawValue }

        var title: String {
            switch self {
            case .systemProxy:
                return "Прокси"
            case .fullTunnel:
                return "Весь"
            case .splitTunnel:
                return "Локальный"
            }
        }

        var subtitle: String {
            switch self {
            case .systemProxy:
                return "HTTP/HTTPS через системный SOCKS/PAC"
            case .fullTunnel:
                return "Весь трафик устройства через тоннель"
            case .splitTunnel:
                return "Только приложения с прописанным SOCKS 127.0.0.1:18080"
            }
        }
    }

    enum Status: String {
        case idle = "Не настроен"
        case loading = "Проверка"
        case installed = "Готов"
        case connecting = "Подключается"
        case connected = "VPN включен"
        case disconnected = "Отключен"
        case failed = "Ошибка"
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastMessage: String?
    @Published var routingPreset: RoutingPreset {
        didSet {
            UserDefaults.standard.set(routingPreset.rawValue, forKey: Self.routingPresetKey)
            guard oldValue != routingPreset else {
                return
            }
            if status == .installed || status == .connected || status == .disconnected {
                lastMessage = "Маршрутизация изменена на «\(routingPreset.title)». Перезапусти VPN, чтобы применить."
            }
        }
    }
    @Published var tunnelMode: TunnelMode {
        didSet {
            UserDefaults.standard.set(tunnelMode.rawValue, forKey: Self.tunnelModeKey)
            guard oldValue != tunnelMode else {
                return
            }
            if status == .installed || status == .connected || status == .disconnected {
                lastMessage = "Режим изменен на «\(tunnelMode.title)». Переустанови VPN профиль, чтобы применить его."
            }
        }
    }

    private let tunnelBundleIdentifier = "ru.pasklove.olcrtc.tunnel"
    private let managerDescription = "OlcRTC Gateway"
    private static let tunnelModeKey = "olcrtc.vpn.tunnelMode"
    private static let routingPresetKey = "olcrtc.vpn.routingPreset"
    private var statusRefreshTask: Task<Void, Never>?

    init() {
        let savedMode = UserDefaults.standard.string(forKey: Self.tunnelModeKey)
        tunnelMode = TunnelMode(rawValue: savedMode ?? "") ?? .fullTunnel
        let savedRoutingPreset = UserDefaults.standard.string(forKey: Self.routingPresetKey)
        routingPreset = RoutingPreset(rawValue: savedRoutingPreset ?? "") ?? .simpleRU
        Task {
            await refresh()
        }
    }

    func refresh() async {
        status = .loading
        do {
            if let manager = try await loadManager() {
                updateStatus(from: manager)
            } else {
                status = .idle
                lastMessage = "VPN профиль еще не установлен."
            }
        } catch {
            status = .failed
            lastMessage = error.localizedDescription
        }
    }

    func install(profile: OlcRTCProfile, socksPort: Int, credentials: SocksCredentials) async {
        status = .loading
        do {
            let manager = try await loadManager() ?? NETunnelProviderManager()
            let tunnelProtocol = NETunnelProviderProtocol()
            tunnelProtocol.providerBundleIdentifier = tunnelBundleIdentifier
            tunnelProtocol.serverAddress = profile.roomLabel
            tunnelProtocol.providerConfiguration = [
                "carrier": profile.carrier,
                "transport": profile.transport,
                "roomID": profile.roomID,
                "keyHex": profile.keyHex,
                "clientID": profile.runtimeClientID(),
                "payload": profile.payload,
                "tunnelMode": tunnelMode.rawValue,
                "routingPreset": routingPreset.rawValue,
                "socksPort": socksPort,
                "socksUser": credentials.username,
                "socksPass": credentials.password
            ]

            manager.localizedDescription = managerDescription
            manager.protocolConfiguration = tunnelProtocol
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            status = .installed
            lastMessage = "VPN профиль установлен: \(tunnelMode.subtitle), \(routingPreset.title)."
        } catch {
            status = .failed
            lastMessage = error.localizedDescription
        }
    }

    func start() async {
        status = .connecting
        do {
            guard let manager = try await loadManager() else {
                status = .idle
                lastMessage = "Сначала установи VPN профиль."
                return
            }
            try manager.connection.startVPNTunnel()
            updateStatus(from: manager)
            scheduleStatusRefresh()
        } catch {
            status = .failed
            lastMessage = error.localizedDescription
        }
    }

    func stop() async {
        do {
            guard let manager = try await loadManager() else {
                status = .idle
                return
            }
            manager.connection.stopVPNTunnel()
            updateStatus(from: manager)
            scheduleStatusRefresh()
        } catch {
            status = .failed
            lastMessage = error.localizedDescription
        }
    }

    private func loadManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first { $0.localizedDescription == managerDescription }
    }

    private func updateStatus(from manager: NETunnelProviderManager) {
        switch manager.connection.status {
        case .connected:
            status = .connected
        case .connecting, .reasserting:
            status = .connecting
        case .disconnected:
            status = .disconnected
        case .disconnecting:
            status = .disconnected
        case .invalid:
            status = .installed
        @unknown default:
            status = .installed
        }
    }

    private func scheduleStatusRefresh() {
        statusRefreshTask?.cancel()
        statusRefreshTask = Task { [weak self] in
            let delays: [UInt64] = [
                700_000_000,
                1_500_000_000,
                3_000_000_000,
                5_000_000_000
            ]

            for delay in delays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else {
                    return
                }
                await self?.refresh()
            }
        }
    }
}
