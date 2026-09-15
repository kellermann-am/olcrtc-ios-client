import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var proxy: LocalProxyController
    @StateObject private var vpn = VPNController()
    @AppStorage("olcrtc.useSystemVPN") private var useSystemVPN = false
    @State private var importText = ""
    @State private var importError: String?
    @State private var importMessage: String?
    @State private var isImporting = false
    @State private var copiedProxy: ProxyCopyKind?
    @State private var copiedLogs = false
    @State private var isRefreshing = false
    @State private var toastMessage: ToastMessage?
    @State private var showImport = false
    @State private var showAdvanced = false
    @FocusState private var importFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    AppHeader()

                    ConnectionPanel(
                        status: proxy.status,
                        networkName: proxy.networkName,
                        activeProfile: proxy.activeProfile,
                        healthState: proxy.healthState,
                        reconnectCount: proxy.reconnectCount,
                        lastMessage: proxy.lastMessage,
                        systemVPNEnabled: useSystemVPN,
                        vpnStatus: vpn.status,
                        primary: {
                            hapticFeedback(.medium)
                            Task {
                                await toggleConnection()
                            }
                        },
                        canPrimary: canToggleConnection
                    )
                    
                    if proxy.status == .running {
                        ReadinessPanel(
                            state: proxy.readinessState,
                            checks: proxy.readinessChecks,
                            refresh: {
                                Task {
                                    await proxy.checkReadiness()
                                }
                            }
                        )
                    }

                    if store.profiles.isEmpty {
                        ImportPanel(
                            importText: $importText,
                            importError: importError,
                            importMessage: importMessage,
                            isImporting: isImporting,
                            importFocused: $importFocused,
                            paste: pasteProfile,
                            submit: { importProfile(from: importText) }
                        )
                    } else {
                        DisclosureGroup(isExpanded: $showImport) {
                            ImportPanel(
                                importText: $importText,
                                importError: importError,
                                importMessage: importMessage,
                                isImporting: isImporting,
                                importFocused: $importFocused,
                                paste: pasteProfile,
                                submit: { importProfile(from: importText) }
                            )
                            .padding(.top, 8)
                        } label: {
                            Label("Импорт", systemImage: "link.badge.plus")
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 2)
                    }

                    ProfilesPanel(
                        profiles: store.profiles,
                        activeProfile: proxy.activeProfile,
                        pingResults: proxy.profilePingResults,
                        isBusy: proxy.status == .starting || proxy.status == .restarting || proxy.isOperationInProgress,
                        connect: { profile in
                            hapticFeedback(.medium)
                            Task {
                                await startConnection(profile: profile)
                            }
                        },
                        ping: { profile in
                            hapticFeedback(.light)
                            // The ping spins up a second olcRTC engine; while the system VPN
                            // engine is live that second engine joins the same room with the
                            // same clientID and collides (both die by liveness). Never ping
                            // while the tunnel is up — test through the running tunnel instead.
                            if vpn.status == .connected || vpn.status == .connecting {
                                showToast("Тоннель уже поднят — второй движок для проверки не запускаю", type: .info)
                                return
                            }
                            Task {
                                await proxy.pingProfile(profile)
                            }
                        },
                        remove: { profile in
                            hapticFeedback(.light)
                            store.remove(profile)
                            showToast("Профиль удалён", type: .info)
                        }
                    )

                    ProxyPanel(
                        port: proxy.socksPort,
                        credentials: proxy.credentials,
                        copied: copiedProxy,
                        copySocksLink: copySocksLink,
                        copySocks5Link: copySocks5Link,
                        copySettings: copyProxySettings
                    )

                    SystemModePanel(
                        enabled: $useSystemVPN,
                        status: vpn.status,
                        message: vpn.lastMessage,
                        tunnelMode: vpn.tunnelMode,
                        routingPreset: vpn.routingPreset,
                        setTunnelMode: { mode in
                            vpn.tunnelMode = mode
                        },
                        setRoutingPreset: { preset in
                            vpn.routingPreset = preset
                        }
                    )

                    DisclosureGroup(isExpanded: $showAdvanced) {
                        DiagnosticsPanel(
                            logs: proxy.logs,
                            copied: copiedLogs,
                            copy: copyLogs
                        )
                        .padding(.top, 8)
                    } label: {
                        Label("Логи", systemImage: "list.bullet.rectangle")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 2)
                }
                .padding(12)
            }
            .background(Color(.systemGroupedBackground))
            .refreshable {
                await refreshStatus()
            }
            .navigationTitle("Gateway")
            .onOpenURL { url in
                importProfile(from: url.absoluteString)
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    proxy.appDidBecomeActive()
                }
            }
            .onChange(of: useSystemVPN) { _, enabled in
                if enabled {
                    if vpn.tunnelMode == .systemProxy {
                        vpn.tunnelMode = .fullTunnel
                    }
                    return
                }
                Task {
                    if vpn.status == .connected || vpn.status == .connecting {
                        await vpn.stop()
                    }
                }
            }
            .overlay(alignment: .top) {
                if let toast = toastMessage {
                    ToastView(message: toast.text, type: toast.type)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1000)
                        .padding(.top, 60)
                }
            }
        }
    }
    
    private func refreshStatus() async {
        isRefreshing = true
        hapticFeedback(.light)
        try? await Task.sleep(for: .seconds(0.5))
        proxy.appDidBecomeActive()
        await vpn.refresh()
        isRefreshing = false
    }

    private var canToggleConnection: Bool {
        if proxy.isOperationInProgress {
            return false
        }

        if vpn.status == .connected || vpn.status == .connecting {
            return true
        }

        switch proxy.status {
        case .running, .starting, .restarting, .needsTunnelRestart:
            return true
        case .stopped, .failed:
            return proxy.activeProfile != nil || !store.profiles.isEmpty
        }
    }

    private func toggleConnection() async {
        if vpn.status == .connected || vpn.status == .connecting {
            await stopConnection()
            return
        }

        switch proxy.status {
        case .running, .starting, .restarting, .needsTunnelRestart:
            await stopConnection()
        case .stopped, .failed:
            guard let profile = proxy.activeProfile ?? store.profiles.first else {
                showToast("Сначала импортируй профиль", type: .info)
                return
            }
            await startConnection(profile: profile)
        }
    }

    private func startConnection(profile: OlcRTCProfile) async {
        if useSystemVPN {
            if vpn.tunnelMode == .systemProxy {
                vpn.tunnelMode = .fullTunnel
            }
            if vpn.status == .connected || vpn.status == .connecting {
                await vpn.stop()
            }
            if proxy.status != .stopped {
                proxy.stop()
            }
            await vpn.install(profile: profile, socksPort: proxy.socksPort, credentials: proxy.credentials)
            await vpn.start()
            return
        }

        if vpn.status == .connected || vpn.status == .connecting {
            await vpn.stop()
        }
        await proxy.start(profile: profile)
    }

    private func stopConnection() async {
        if vpn.status == .connected || vpn.status == .connecting {
            await vpn.stop()
        }
        if proxy.status != .stopped {
            proxy.stop()
        }
    }
    
    private func showToast(_ text: String, type: ToastType) {
        toastMessage = ToastMessage(text: text, type: type)
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation {
                toastMessage = nil
            }
        }
    }
    
    private func hapticFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
        #endif
    }

    private func pasteProfile() {
        #if canImport(UIKit)
        if let value = UIPasteboard.general.string {
            importText = value
            importError = nil
            importMessage = nil
            hapticFeedback(.light)
            showToast("Вставлено из буфера", type: .success)
        }
        #endif
    }

    private func importProfile(from rawValue: String) {
        guard !isImporting else {
            return
        }

        Task {
            await MainActor.run {
                isImporting = true
                importError = nil
                importMessage = nil
                importFocused = false
            }

            do {
                let result = try await SubscriptionImporter.importValue(rawValue)
                await MainActor.run {
                    store.upsert(result.profiles)
                    importText = ""
                    importMessage = result.userMessage
                    isImporting = false
                    showImport = false
                    hapticFeedback(.medium)
                    showToast("Профили импортированы", type: .success)
                }
            } catch {
                await MainActor.run {
                    importError = error.localizedDescription
                    isImporting = false
                    hapticFeedback(.heavy)
                    showToast("Ошибка импорта", type: .error)
                }
            }
        }
    }

    private func copyProxySettings() {
        #if canImport(UIKit)
        UIPasteboard.general.string = """
        SOCKS5
        Host: 127.0.0.1
        Port: \(proxy.socksPort)
        Username: \(proxy.credentials.username)
        Password: \(proxy.credentials.password)
        """
        markCopied(.settings)
        hapticFeedback(.light)
        showToast("Настройки скопированы", type: .success)
        #endif
    }

    private func copySocksLink() {
        #if canImport(UIKit)
        UIPasteboard.general.string = proxy.credentials.legacySocksURL(port: proxy.socksPort)
        markCopied(.socks)
        hapticFeedback(.light)
        showToast("socks:// скопирован", type: .success)
        #endif
    }

    private func copySocks5Link() {
        #if canImport(UIKit)
        UIPasteboard.general.string = proxy.credentials.socks5URL(port: proxy.socksPort)
        markCopied(.socks5)
        hapticFeedback(.light)
        showToast("socks5:// скопирован", type: .success)
        #endif
    }

    private func copyLogs() {
        #if canImport(UIKit)
        UIPasteboard.general.string = proxy.sanitizedLogText
        copiedLogs = true
        hapticFeedback(.light)
        showToast("Лог скопирован без секретов", type: .success)
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedLogs = false
        }
        #endif
    }

    private func markCopied(_ kind: ProxyCopyKind) {
        copiedProxy = kind
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedProxy == kind {
                copiedProxy = nil
            }
        }
    }
}

private struct ConnectionPanel: View {
    let status: LocalProxyController.Status
    let networkName: String
    let activeProfile: OlcRTCProfile?
    let healthState: LocalProxyController.HealthState
    let reconnectCount: Int
    let lastMessage: String?
    let systemVPNEnabled: Bool
    let vpnStatus: VPNController.Status
    let primary: () -> Void
    let canPrimary: Bool

    var body: some View {
        Panel(title: "Подключение", systemImage: displayIcon) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text(systemVPNEnabled ? "VPN" : "SOCKS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(displayTint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(displayTint.opacity(0.12))
                        )
                    Spacer()
                    NetworkBadge(name: networkName)
                }

                HStack(spacing: 12) {
                    Image(systemName: displayIcon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(displayTint)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayStatus)
                            .font(.headline)
                            .foregroundStyle(displayTint)
                        Text(activeProfile?.displayName ?? "Выбери профиль ниже")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let activeProfile {
                            Text("\(activeProfile.carrierDisplayName) / \(activeProfile.transportDisplayName)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }

                Button(action: primary) {
                    Label(primaryTitle, systemImage: primaryIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(primaryTint)
                .disabled(!canPrimary)
                .animation(.spring(response: 0.3), value: canPrimary)

                HStack(spacing: 10) {
                    MetricView(title: "Маршрут", value: systemVPNEnabled ? vpnStatus.rawValue : healthState.rawValue)
                    MetricView(title: "Рестарты", value: "\(reconnectCount)")
                    MetricView(title: "Режим", value: systemVPNEnabled ? "VPN" : "SOCKS")
                }

                if let lastMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                        Text(lastMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.secondarySystemGroupedBackground))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                            )
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }

    private var isActive: Bool {
        if systemVPNEnabled {
            switch vpnStatus {
            case .connected, .connecting, .loading:
                return true
            case .idle, .installed, .disconnected, .failed:
                return false
            }
        }

        switch status {
        case .running, .starting, .restarting, .needsTunnelRestart:
            return true
        case .stopped, .failed:
            return false
        }
    }

    private var primaryTitle: String {
        isActive ? "Выключить" : "Включить"
    }

    private var primaryIcon: String {
        isActive ? "stop.fill" : "power"
    }

    private var primaryTint: Color {
        isActive ? .red : displayTint
    }

    private var displayStatus: String {
        systemVPNEnabled ? vpnStatus.rawValue : status.rawValue
    }

    private var displayIcon: String {
        if systemVPNEnabled {
            switch vpnStatus {
            case .connected:
                return "shield.checkered"
            case .connecting, .loading:
                return "hourglass"
            case .failed:
                return "xmark.octagon.fill"
            default:
                return "shield"
            }
        }
        return status.symbolName
    }

    private var displayTint: Color {
        if systemVPNEnabled {
            switch vpnStatus {
            case .connected:
                return .green
            case .connecting, .loading:
                return .orange
            case .failed:
                return .red
            default:
                return .secondary
            }
        }
        return status.tint
    }
}

private struct AppHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("OlcRTC Gateway")
                    .font(.title3.weight(.bold))
                Text("SOCKS и системный VPN")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }
}

private struct ImportPanel: View {
    @Binding var importText: String
    let importError: String?
    let importMessage: String?
    let isImporting: Bool
    var importFocused: FocusState<Bool>.Binding
    let paste: () -> Void
    let submit: () -> Void

    var body: some View {
        Panel(title: "Импорт профиля", systemImage: "link.badge.plus") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("olcrtc://, https://subscription или sub.md", text: $importText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused(importFocused)
                    .lineLimit(2...5)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.secondarySystemGroupedBackground))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(importFocused.wrappedValue ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 2)
                            )
                    )
                    .animation(.easeInOut(duration: 0.2), value: importFocused.wrappedValue)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Button("Отмена") {
                                importFocused.wrappedValue = false
                            }
                            Spacer()
                            Button("Готово") {
                                importFocused.wrappedValue = false
                            }
                            .fontWeight(.semibold)
                        }
                    }

                HStack(spacing: 10) {
                    Button(action: paste) {
                        Label("Вставить", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button(action: submit) {
                        if isImporting {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .tint(.white)
                                Text("Загрузка")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("Импорт", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isImporting || importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let importError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(importError)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.1))
                    )
                    .transition(.scale.combined(with: .opacity))
                } else if let importMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(importMessage)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.green.opacity(0.1))
                    )
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }
}

private struct ProfilesPanel: View {
    let profiles: [OlcRTCProfile]
    let activeProfile: OlcRTCProfile?
    let pingResults: [String: ProfilePingResult]
    let isBusy: Bool
    let connect: (OlcRTCProfile) -> Void
    let ping: (OlcRTCProfile) -> Void
    let remove: (OlcRTCProfile) -> Void

    var body: some View {
        Panel(title: "Профили", systemImage: "rectangle.stack.fill") {
            if profiles.isEmpty {
                ContentUnavailableView("Профилей нет", systemImage: "link")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                VStack(spacing: 10) {
                    HStack {
                        Label("\(profiles.count) профилей", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    ForEach(profiles) { profile in
                        ProfileRow(
                            profile: profile,
                            isActive: activeProfile?.id == profile.id,
                            pingResult: pingResults[profile.id] ?? .idle,
                            isBusy: isBusy,
                            connect: { connect(profile) },
                            ping: { ping(profile) },
                            remove: { remove(profile) }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                remove(profile)
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                connect(profile)
                            } label: {
                                Label("Подключить", systemImage: "power")
                            }
                            .tint(.green)
                        }
                        .transition(.asymmetric(
                            insertion: .scale.combined(with: .opacity),
                            removal: .scale.combined(with: .opacity)
                        ))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: profiles.count)
            }
        }
    }
}

private struct ProfileRow: View {
    let profile: OlcRTCProfile
    let isActive: Bool
    let pingResult: ProfilePingResult
    let isBusy: Bool
    let connect: () -> Void
    let ping: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isActive ? .green : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        MiniPill(text: profile.carrierDisplayName)
                        MiniPill(text: profile.transportDisplayName)
                    }
                    Text(profile.roomLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button(action: ping) {
                    Image(systemName: pingIcon)
                        .frame(width: 24)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy || pingResult.state.isChecking)
                .symbolEffect(.pulse, options: .repeating, value: pingResult.state.isChecking)

                Button(action: connect) {
                    Image(systemName: "power")
                        .frame(width: 24)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || pingResult.state.isChecking)

                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                        .frame(width: 24)
                }
                .buttonStyle(.bordered)
            }

            if let pingMessage {
                HStack(spacing: 8) {
                    Image(systemName: pingIcon)
                        .foregroundStyle(pingColor)
                    Text(pingMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(pingColor.opacity(0.10))
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.green.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    private var pingIcon: String {
        switch pingResult.state {
        case .idle:
            return "dot.radiowaves.left.and.right"
        case .checking:
            return "hourglass"
        case .success:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    private var pingColor: Color {
        switch pingResult.state {
        case .idle:
            return .secondary
        case .checking:
            return .orange
        case .success:
            return .green
        case .failed:
            return .red
        }
    }

    private var pingMessage: String? {
        switch pingResult.state {
        case .idle:
            return nil
        case .checking:
            return "Проверяю профиль до Google..."
        case let .success(elapsed):
            return "Google доступен через профиль за \(String(format: "%.1f", elapsed)) с"
        case let .failed(message):
            return message
        }
    }
}

private struct MiniPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(.tertiarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.1), lineWidth: 0.5)
                    )
            )
    }
}

private struct ProxyPanel: View {
    let port: Int
    let credentials: SocksCredentials
    let copied: ProxyCopyKind?
    let copySocksLink: () -> Void
    let copySocks5Link: () -> Void
    let copySettings: () -> Void

    var body: some View {
        Panel(title: "Локальный прокси", systemImage: "network") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    ProxyInfoRow(label: "Адрес", value: "127.0.0.1:\(port)", icon: "server.rack")
                    ProxyInfoRow(label: "Логин", value: credentials.username, icon: "person.fill")
                    ProxyInfoRow(label: "Пароль", value: credentials.password, icon: "key.fill")
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.secondarySystemGroupedBackground))
                )

                HStack(spacing: 10) {
                    Button(action: copySocksLink) {
                        Label(copied == .socks ? "Скопировано" : "socks://", systemImage: copied == .socks ? "checkmark" : "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .animation(.spring(response: 0.3), value: copied)

                    Button(action: copySocks5Link) {
                        Label(copied == .socks5 ? "Скопировано" : "socks5://", systemImage: copied == .socks5 ? "checkmark" : "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .animation(.spring(response: 0.3), value: copied)
                }

                Button(action: copySettings) {
                    Label(copied == .settings ? "Скопировано" : "Настройки", systemImage: copied == .settings ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .animation(.spring(response: 0.3), value: copied)
            }
        }
    }
}

private struct ProxyInfoRow: View {
    let label: String
    let value: String
    let icon: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            
            Text(value)
                .font(.caption.monospaced().weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
        }
    }
}

private struct SystemModePanel: View {
    @Binding var enabled: Bool
    let status: VPNController.Status
    let message: String?
    let tunnelMode: VPNController.TunnelMode
    let routingPreset: RoutingPreset
    let setTunnelMode: (VPNController.TunnelMode) -> Void
    let setRoutingPreset: (RoutingPreset) -> Void

    var body: some View {
        Panel(title: "Режим", systemImage: "switch.2") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Toggle(isOn: $enabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Системный VPN")
                                .font(.subheadline.weight(.semibold))
                            Text(enabled ? "Кнопка включит системный туннель" : "Кнопка включит локальный SOCKS")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.green)
                }

                if enabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Режим", selection: Binding(
                            get: { tunnelMode },
                            set: { setTunnelMode($0) }
                        )) {
                            ForEach(VPNController.TunnelMode.selectableModes) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Picker("Маршрутизация", selection: Binding(
                            get: { routingPreset },
                            set: { setRoutingPreset($0) }
                        )) {
                            ForEach(RoutingPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .pickerStyle(.menu)

                        Text(routingPreset.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Image(systemName: statusIcon)
                                .foregroundStyle(statusColor)
                                .frame(width: 18)
                            Text(status.rawValue)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(statusColor)
                            if let message {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private var statusIcon: String {
        switch status {
        case .connected:
            return "shield.checkered"
        case .connecting, .loading:
            return "hourglass"
        case .failed:
            return "xmark.octagon.fill"
        default:
            return "shield"
        }
    }

    private var statusColor: Color {
        switch status {
        case .connected:
            return .green
        case .connecting, .loading:
            return .orange
        case .failed:
            return .red
        default:
            return .secondary
        }
    }
}

private struct DiagnosticsPanel: View {
    let logs: [ProxyLogEntry]
    let copied: Bool
    let copy: () -> Void

    var body: some View {
        Panel(title: "Диагностика", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Последние события", systemImage: "clock.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: copy) {
                        Label(copied ? "Скопировано" : "Без секретов", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(logs.isEmpty)
                    .animation(.spring(response: 0.3), value: copied)
                }

                if logs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("Лог пуст")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(logs.prefix(6))) { entry in
                            LogRow(entry: entry)
                        }
                    }
                }
            }
        }
    }
}

private struct LogRow: View {
    let entry: ProxyLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(entry.level.tint.opacity(0.15))
                    .frame(width: 24, height: 24)
                
                Image(systemName: entry.level.symbolName)
                    .font(.caption)
                    .foregroundStyle(entry.level.tint)
            }

            Text(entry.line)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(entry.level.tint.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

private struct Panel<Content: View>: View {
    let title: String
    let systemImage: String
    private let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 3)
        )
    }
}

private struct StatusBadge: View {
    let status: LocalProxyController.Status
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if status == .running {
                    Circle()
                        .fill(status.tint.opacity(0.3))
                        .frame(width: 10, height: 10)
                        .scaleEffect(isAnimating ? 1.8 : 1.0)
                        .opacity(isAnimating ? 0 : 1)
                }
                
                Circle()
                    .fill(status.tint)
                    .frame(width: 10, height: 10)
            }
            .onAppear {
                if status == .running {
                    withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                        isAnimating = true
                    }
                }
            }
            .onChange(of: status) { _, newStatus in
                isAnimating = newStatus == .running
            }
            
            Text(status.rawValue)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(status.tint.opacity(0.15))
                .overlay(
                    Capsule()
                        .stroke(status.tint.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

private struct NetworkBadge: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "antenna.radiowaves.left.and.right")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color(.secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
            )
            .symbolEffect(.variableColor.iterative, options: .repeating)
    }
}

private struct MetricView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.03), radius: 4, x: 0, y: 2)
        )
    }
}

private extension ProxyLogEntry.Level {
    var tint: Color {
        switch self {
        case .info:
            return .blue
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    var symbolName: String {
        switch self {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }
}

private extension LocalProxyController.Status {
    var tint: Color {
        switch self {
        case .running:
            return .green
        case .starting, .restarting, .needsTunnelRestart:
            return .orange
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .running:
            return "checkmark.shield.fill"
        case .starting:
            return "hourglass"
        case .restarting:
            return "arrow.triangle.2.circlepath"
        case .needsTunnelRestart:
            return "exclamationmark.arrow.triangle.2.circlepath"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .stopped:
            return "power"
        }
    }
}

private enum ProxyCopyKind: Equatable {
    case socks
    case socks5
    case settings
}

// MARK: - Metrics Panel

private struct ReadinessPanel: View {
    let state: ReadinessState
    let checks: [ReadinessCheck]
    let refresh: () -> Void
    @State private var showingDetails = false
    
    var body: some View {
        Panel(title: "Готовность", systemImage: "checkmark.shield.fill") {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: state.icon)
                        .font(.headline)
                        .foregroundStyle(stateColor)
                        .frame(width: 24)
                        .symbolEffect(.pulse, options: .repeating, value: state == .checking)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(stateColor)

                        Text(state.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }

                HStack(spacing: 10) {
                    Button(action: refresh) {
                        Label("Проверить", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(stateColor)
                    .disabled(state == .checking)
                    
                    if !checks.isEmpty {
                        Button(action: { showingDetails = true }) {
                            Image(systemName: "info.circle")
                                .frame(width: 36)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .sheet(isPresented: $showingDetails) {
            ReadinessDetailView(state: state, checks: checks)
        }
    }
    
    private var stateColor: Color {
        switch state {
        case .notReady: return .red
        case .checking: return .orange
        case .ready: return .green
        case .readyWithIssues: return .orange
        }
    }
}

private struct ReadinessDetailView: View {
    let state: ReadinessState
    let checks: [ReadinessCheck]
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: state.icon)
                            .font(.title)
                            .foregroundStyle(stateColor)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(state.rawValue)
                                .font(.title3.weight(.bold))
                            Text(state.message)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                Section("Проверки") {
                    ForEach(checks) { check in
                        HStack(spacing: 12) {
                            Image(systemName: check.icon)
                                .font(.title3)
                                .foregroundStyle(check.passed ? Color.green : Color.red)
                                .frame(width: 30)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(check.name)
                                    .font(.headline)
                                if let message = check.message {
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            
                            Spacer()
                            
                            Text(check.passed ? "OK" : "Fail")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(check.passed ? .green : .red)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                Section("Рекомендации") {
                    if state == .notReady {
                        Text("Запустите профиль для начала работы")
                    } else if state == .readyWithIssues {
                        Text("Некоторые проверки не прошли. Попробуйте перезапустить SOCKS.")
                    } else if state == .ready {
                        Text("Всё готово! Теперь можно включить профиль во внешнем VPN-клиенте.")
                    }
                }
            }
            .navigationTitle("Проверка готовности")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var stateColor: Color {
        switch state {
        case .notReady: return .red
        case .checking: return .orange
        case .ready: return .green
        case .readyWithIssues: return .orange
        }
    }
}

// MARK: - Metrics Panel

private struct MetricsPanel: View {
    let metrics: ConnectionMetrics
    let reset: () -> Void
    @State private var showingDetails = false
    
    var body: some View {
        Panel(title: "Статистика", systemImage: "chart.bar.fill") {
            VStack(alignment: .leading, spacing: 14) {
                // Quick stats
                HStack(spacing: 12) {
                    StatCard(title: "Uptime", value: metrics.formattedTotalUptime, icon: "clock.fill", color: .blue)
                    StatCard(title: "Успех", value: String(format: "%.0f%%", metrics.successRate), icon: "checkmark.circle.fill", color: .green)
                    StatCard(title: "Здоровье", value: String(format: "%.0f", metrics.healthScore), icon: "heart.fill", color: healthColor)
                }
                
                // Reconnects
                HStack(spacing: 12) {
                    MiniStatCard(title: "Реконнекты", value: "\(metrics.totalReconnects)", icon: "arrow.triangle.2.circlepath")
                    MiniStatCard(title: "Сеть", value: "\(metrics.networkChanges)", icon: "network")
                    MiniStatCard(title: "Watchdog", value: "\(metrics.watchdogRestarts)", icon: "eye.fill")
                }
                
                // Session info
                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(label: "Средняя сессия", value: metrics.formattedAverageSession)
                    InfoRow(label: "Самая длинная", value: metrics.formattedLongestSession)
                    if let lastConnection = metrics.lastSuccessfulConnection {
                        InfoRow(label: "Последнее подключение", value: formatRelativeTime(lastConnection))
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                
                // Actions
                HStack(spacing: 10) {
                    Button(action: { showingDetails = true }) {
                        Label("Подробнее", systemImage: "chart.xyaxis.line")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    
                    Button(role: .destructive, action: reset) {
                        Label("Сбросить", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .sheet(isPresented: $showingDetails) {
            MetricsDetailView(metrics: metrics)
        }
    }
    
    private var healthColor: Color {
        if metrics.healthScore >= 80 {
            return .green
        } else if metrics.healthScore >= 50 {
            return .orange
        } else {
            return .red
        }
    }
    
    private func formatRelativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "только что"
        } else if interval < 3600 {
            return "\(Int(interval / 60))м назад"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))ч назад"
        } else {
            return "\(Int(interval / 86400))д назад"
        }
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(color.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

private struct MiniStatCard: View {
    let title: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
    }
}

private struct MetricsDetailView: View {
    let metrics: ConnectionMetrics
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section("Общая статистика") {
                    DetailRow(label: "Всего запусков", value: "\(metrics.successfulStarts + metrics.failedStarts)")
                    DetailRow(label: "Успешных", value: "\(metrics.successfulStarts)")
                    DetailRow(label: "Неудачных", value: "\(metrics.failedStarts)")
                    DetailRow(label: "Процент успеха", value: String(format: "%.1f%%", metrics.successRate))
                }
                
                Section("Реконнекты") {
                    DetailRow(label: "Всего", value: "\(metrics.totalReconnects)")
                    DetailRow(label: "Ручных", value: "\(metrics.manualRestarts)")
                    DetailRow(label: "Watchdog", value: "\(metrics.watchdogRestarts)")
                    DetailRow(label: "Смен сети", value: "\(metrics.networkChanges)")
                    DetailRow(label: "В среднем/день", value: String(format: "%.1f", metrics.averageReconnectsPerDay))
                }
                
                Section("Сессии") {
                    DetailRow(label: "Общее время", value: metrics.formattedTotalUptime)
                    DetailRow(label: "Средняя длина", value: metrics.formattedAverageSession)
                    DetailRow(label: "Самая длинная", value: metrics.formattedLongestSession)
                }
                
                if !metrics.failureReasons.isEmpty {
                    Section("Причины ошибок") {
                        ForEach(Array(metrics.failureReasons.sorted(by: { $0.value > $1.value })), id: \.key) { reason, count in
                            HStack {
                                Text(reason)
                                    .font(.caption)
                                    .lineLimit(2)
                                Spacer()
                                Text("\(count)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
                
                if !metrics.networkTypeUsage.isEmpty {
                    Section("Использование сетей") {
                        ForEach(Array(metrics.networkTypeUsage.sorted(by: { $0.value > $1.value })), id: \.key) { type, duration in
                            HStack {
                                Text(type)
                                Spacer()
                                Text(formatDuration(duration))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                
                if !metrics.sessionHistory.isEmpty {
                    Section("История (последние 20)") {
                        ForEach(Array(metrics.sessionHistory.prefix(20))) { record in
                            HStack {
                                Text(record.formattedDate)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(record.event)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Подробная статистика")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 {
            return "\(hours)ч \(minutes)м"
        } else {
            return "\(minutes)м"
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Notifications Panel

private struct NotificationsPanel: View {
    @EnvironmentObject private var notifications: NotificationManager
    @State private var showingSettings = false
    @AppStorage("notifications.enabled") private var notificationsEnabled = true
    @AppStorage("notifications.connectionRestored") private var connectionRestored = true
    @AppStorage("notifications.connectionFailed") private var connectionFailed = true
    @AppStorage("notifications.networkChanged") private var networkChanged = true
    @AppStorage("notifications.actionRequired") private var actionRequired = true
    @AppStorage("notifications.longUptime") private var longUptime = true
    
    var body: some View {
        Panel(title: "Уведомления", systemImage: "bell.fill") {
            VStack(alignment: .leading, spacing: 14) {
                // Status
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.15))
                            .frame(width: 50, height: 50)
                        
                        Image(systemName: statusIcon)
                            .font(.title3)
                            .foregroundStyle(statusColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusText)
                            .font(.headline)
                            .foregroundStyle(statusColor)
                        
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                
                // Quick toggles
                if notifications.isAuthorized {
                    VStack(spacing: 10) {
                        Toggle(isOn: $notificationsEnabled) {
                            Label("Включить уведомления", systemImage: "bell.fill")
                                .font(.subheadline)
                        }
                        .tint(.blue)
                        
                        if notificationsEnabled {
                            Divider()
                            
                            VStack(spacing: 8) {
                                NotificationToggle(
                                    isOn: $connectionRestored,
                                    title: "Соединение восстановлено",
                                    icon: "checkmark.circle.fill",
                                    color: .green
                                )
                                
                                NotificationToggle(
                                    isOn: $connectionFailed,
                                    title: "Ошибка подключения",
                                    icon: "xmark.circle.fill",
                                    color: .red
                                )
                                
                                NotificationToggle(
                                    isOn: $networkChanged,
                                    title: "Сеть изменилась",
                                    icon: "network",
                                    color: .orange
                                )
                                
                                NotificationToggle(
                                    isOn: $actionRequired,
                                    title: "Требуется действие",
                                    icon: "exclamationmark.triangle.fill",
                                    color: .orange
                                )
                                
                                NotificationToggle(
                                    isOn: $longUptime,
                                    title: "Долгая работа (6/12/24ч)",
                                    icon: "star.fill",
                                    color: .yellow
                                )
                            }
                            .padding(.leading, 8)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
                
                // Actions
                HStack(spacing: 10) {
                    if !notifications.isAuthorized {
                        Button(action: requestPermission) {
                            Label("Разрешить уведомления", systemImage: "bell.badge")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(action: { showingSettings = true }) {
                            Label("Настройки", systemImage: "gear")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        
                        Button(action: sendTestNotification) {
                            Label("Тест", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            NotificationSettingsView()
        }
    }
    
    private var statusColor: Color {
        switch notifications.authorizationStatus {
        case .authorized:
            return .green
        case .denied:
            return .red
        case .notDetermined:
            return .orange
        default:
            return .secondary
        }
    }
    
    private var statusIcon: String {
        switch notifications.authorizationStatus {
        case .authorized:
            return "checkmark.circle.fill"
        case .denied:
            return "xmark.circle.fill"
        case .notDetermined:
            return "questionmark.circle.fill"
        default:
            return "bell.slash.fill"
        }
    }
    
    private var statusText: String {
        switch notifications.authorizationStatus {
        case .authorized:
            return notificationsEnabled ? "Включены" : "Отключены"
        case .denied:
            return "Запрещены"
        case .notDetermined:
            return "Не настроены"
        default:
            return "Недоступны"
        }
    }
    
    private var statusMessage: String {
        switch notifications.authorizationStatus {
        case .authorized:
            return notificationsEnabled ? "Вы будете получать уведомления о важных событиях" : "Уведомления отключены в настройках приложения"
        case .denied:
            return "Разрешите уведомления в Настройках iOS"
        case .notDetermined:
            return "Нажмите кнопку ниже для настройки"
        default:
            return "Уведомления недоступны"
        }
    }
    
    private func requestPermission() {
        Task {
            _ = await notifications.requestAuthorization()
        }
    }
    
    private func sendTestNotification() {
        if notificationsEnabled {
            notifications.send(.connectionRestored, context: "Это тестовое уведомление")
        }
    }
}

private struct NotificationToggle: View {
    @Binding var isOn: Bool
    let title: String
    let icon: String
    let color: Color
    
    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                    .frame(width: 20)
                
                Text(title)
                    .font(.caption)
            }
        }
        .tint(color)
    }
}

private struct NotificationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var notifications: NotificationManager
    @AppStorage("notifications.enabled") private var notificationsEnabled = true
    @AppStorage("notifications.connectionRestored") private var connectionRestored = true
    @AppStorage("notifications.connectionFailed") private var connectionFailed = true
    @AppStorage("notifications.networkChanged") private var networkChanged = true
    @AppStorage("notifications.actionRequired") private var actionRequired = true
    @AppStorage("notifications.longUptime") private var longUptime = true
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: statusIcon)
                            .font(.title)
                            .foregroundStyle(statusColor)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(statusText)
                                .font(.headline)
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                if notifications.isAuthorized {
                    Section {
                        Toggle("Включить уведомления", isOn: $notificationsEnabled)
                    } header: {
                        Text("Основные")
                    } footer: {
                        Text("Отключите, чтобы временно не получать уведомления")
                    }
                    
                    if notificationsEnabled {
                        Section {
                            Toggle(isOn: $connectionRestored) {
                                Label("Соединение восстановлено", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            
                            Toggle(isOn: $connectionFailed) {
                                Label("Ошибка подключения", systemImage: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            
                            Toggle(isOn: $networkChanged) {
                                Label("Сеть изменилась", systemImage: "network")
                                    .foregroundStyle(.orange)
                            }
                            
                            Toggle(isOn: $actionRequired) {
                                Label("Требуется действие", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            
                            Toggle(isOn: $longUptime) {
                                Label("Долгая работа", systemImage: "star.fill")
                                    .foregroundStyle(.yellow)
                            }
                        } header: {
                            Text("Типы уведомлений")
                        } footer: {
                            Text("Выберите, какие события должны вызывать уведомления")
                        }
                        
                        Section {
                            Button(action: sendTestNotification) {
                                Label("Отправить тестовое уведомление", systemImage: "paperplane.fill")
                            }
                            
                            Button(action: clearAll) {
                                Label("Очистить все уведомления", systemImage: "trash")
                            }
                            .foregroundStyle(.red)
                        } header: {
                            Text("Действия")
                        }
                    }
                } else {
                    Section {
                        Button(action: openSettings) {
                            Label("Открыть Настройки iOS", systemImage: "gear")
                        }
                    } footer: {
                        Text("Разрешите уведомления в настройках iOS, чтобы получать важные обновления о состоянии подключения")
                    }
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        NotificationTypeInfo(
                            icon: "checkmark.circle.fill",
                            color: .green,
                            title: "Соединение восстановлено",
                            description: "Когда SOCKS прокси снова заработал после сбоя"
                        )
                        
                        Divider()
                        
                        NotificationTypeInfo(
                            icon: "xmark.circle.fill",
                            color: .red,
                            title: "Ошибка подключения",
                            description: "Когда не удалось запустить SOCKS прокси"
                        )
                        
                        Divider()
                        
                        NotificationTypeInfo(
                            icon: "network",
                            color: .orange,
                            title: "Сеть изменилась",
                            description: "Когда произошла смена сети (Wi-Fi ↔ LTE)"
                        )
                        
                        Divider()
                        
                        NotificationTypeInfo(
                            icon: "exclamationmark.triangle.fill",
                            color: .orange,
                            title: "Требуется действие",
                            description: "Когда нужно перезапустить SOCKS и внешний VPN"
                        )
                        
                        Divider()
                        
                        NotificationTypeInfo(
                            icon: "star.fill",
                            color: .yellow,
                            title: "Долгая работа",
                            description: "Поздравление при достижении 6, 12 или 24 часов работы"
                        )
                    }
                } header: {
                    Text("О типах уведомлений")
                }
            }
            .navigationTitle("Уведомления")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var statusColor: Color {
        switch notifications.authorizationStatus {
        case .authorized:
            return .green
        case .denied:
            return .red
        case .notDetermined:
            return .orange
        default:
            return .secondary
        }
    }
    
    private var statusIcon: String {
        switch notifications.authorizationStatus {
        case .authorized:
            return "checkmark.circle.fill"
        case .denied:
            return "xmark.circle.fill"
        case .notDetermined:
            return "questionmark.circle.fill"
        default:
            return "bell.slash.fill"
        }
    }
    
    private var statusText: String {
        switch notifications.authorizationStatus {
        case .authorized:
            return "Разрешены"
        case .denied:
            return "Запрещены"
        case .notDetermined:
            return "Не настроены"
        default:
            return "Недоступны"
        }
    }
    
    private var statusMessage: String {
        switch notifications.authorizationStatus {
        case .authorized:
            return "Уведомления разрешены в iOS"
        case .denied:
            return "Разрешите в Настройках iOS"
        case .notDetermined:
            return "Требуется разрешение"
        default:
            return "Уведомления недоступны"
        }
    }
    
    private func sendTestNotification() {
        notifications.send(.connectionRestored, context: "Это тестовое уведомление")
    }
    
    private func clearAll() {
        notifications.removeAllDeliveredNotifications()
    }
    
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

private struct NotificationTypeInfo: View {
    let icon: String
    let color: Color
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Toast System

private struct ToastMessage: Identifiable {
    let id = UUID()
    let text: String
    let type: ToastType
}

private enum ToastType {
    case success
    case error
    case info
    
    var color: Color {
        switch self {
        case .success: return .green
        case .error: return .red
        case .info: return .blue
        }
    }
    
    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

private struct ToastView: View {
    let message: String
    let type: ToastType
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: type.icon)
                .font(.title3)
                .foregroundStyle(type.color)
            
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(type.color.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }
}
