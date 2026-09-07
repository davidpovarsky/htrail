import NetworkExtension
import HTTrailCore
import PurelineSupport
import os.log

private let tunnelLog = Logger(subsystem: "com.davidpovarsky.pureline.PacketTunnel", category: "capture")

/// HTTrail's iOS capture engine. `NETransparentProxyProvider` is macOS-only, so
/// on iOS we use a `NEPacketTunnelProvider` whose job is to (a) run the HTTrail
/// MITM proxy **inside the always-alive extension process** (the app itself gets
/// suspended in the background) and (b) inject system-wide proxy settings that
/// point every HTTP/HTTPS connection at that on-device proxy.
///
/// Captured flows are written to the shared App Group container; the app tails
/// them for display. The CA is also loaded from the App Group, so the leaf certs
/// minted here chain to the exact root the user trusted on the device.
final class PacketTunnelProvider: NEPacketTunnelProvider {

    private var proxy: ProxyServer?
    private let engine = InterceptEngine()
    private let configStore = SharedConfigStore()
    private let diagnostics = PurelinePacketTunnelDiagnostics.shared
    private let bypassStore = PurelineCompatibilityBypassStore()
    private var configSyncTask: Task<Void, Never>?

    override func startTunnel(options: [String: NSObject]?,
                             completionHandler: @escaping (Error?) -> Void) {
        let startCount = diagnostics.beginRun()
        // The app and this extension are separate processes; the app writes the
        // rules / SSL allowlist / port / pinning into the shared config, which we
        // load here (and keep polling) so interception actually takes effect.
        let config = configStore.load() ?? SharedConfig()
        let port = config.proxyPort
        configurePinningDiagnostics()
        applyRuntimeConfig(config)
        let restored = bypassStore.load()
        engine.restoreDetectedPinnedHosts(restored.active)
        for entry in restored.expired {
            diagnostics.record(category: "tls", event: "compatibility bypass expired", details: ["host": entry.host])
        }

        // Remote target: forward to a Mac's proxy on the LAN — do NOT run a local
        // proxy; the Mac decrypts and records. Otherwise capture on-device.
        if let remoteHost = config.remoteProxyHost {
            let remotePort = config.remoteProxyPort ?? port
            tunnelLog.log("startTunnel: remote target \(remoteHost):\(remotePort)")
            diagnostics.record(category: "proxy", event: "remote proxy selected", details: [
                "host": remoteHost, "port": String(remotePort), "startCount": String(startCount)
            ])
            applyNetworkSettings(proxyHost: remoteHost, port: remotePort, completionHandler: completionHandler)
            return
        }

        diagnostics.record(category: "proxy", event: "local proxy starting", details: [
            "port": String(port), "startCount": String(startCount)
        ])
        tunnelLog.log("startTunnel: on-device port=\(port) rules=\(config.rules.filter { $0.enabled }.count) allowlist=\(config.sslAllowlist.count)")

        guard let ca = try? CertificateAuthority.loadOrCreate(in: AppPaths.certificatesDirectory) else {
            diagnostics.record(category: "proxy", event: "local proxy start failure", details: ["reason": "CA unavailable"])
            completionHandler(NSError(domain: "HTTrail", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not load HTTrail CA from the App Group."]))
            return
        }
        let boundedSink = PurelineBoundedFlowSink(limits: .packetTunnel)
        boundedSink?.onSnapshot = { [diagnostics] snapshot in
            diagnostics.record(category: "resources", event: "capture counters", details: [
                "flows": String(snapshot.flowCount),
                "retainedBodyBytes": String(snapshot.retainedBodyBytes),
                "truncatedRequests": String(snapshot.truncatedRequestCount),
                "truncatedResponses": String(snapshot.truncatedResponseCount)
            ])
        }
        let sink: FlowSink = boundedSink ?? NullFlowSink()
        let server = ProxyServer(port: port, certificateAuthority: ca, sink: sink, engine: engine)
        server.bindHost = "127.0.0.1"
        server.captureBodyCap = PurelineCaptureLimits.packetTunnel.responsePreviewBytes
        server.streamRequestBodies = true
        server.requestInspectionBodyCap = 1024 * 1024
        server.requestCaptureBodyCap = PurelineCaptureLimits.packetTunnel.requestPreviewBytes
        ImageFilterProxyBridge.configure(server: server, diagnostics: diagnostics)
        self.proxy = server
        startConfigSync()

        Task {
            do {
                try await server.start()
            } catch {
                self.diagnostics.record(category: "proxy", event: "local proxy start failure", details: [
                    "error": String(describing: error)
                ])
                completionHandler(error)
                return
            }
            self.diagnostics.record(category: "proxy", event: "local proxy start success", details: [
                "listenerPort": String(server.boundPort)
            ])
            self.applyNetworkSettings(proxyHost: "127.0.0.1", port: port, completionHandler: completionHandler)
        }
    }

    /// Live-sync configuration with the app: re-apply rules/allowlist/pinning the
    /// user edits while capturing, and publish auto-detected pinned hosts back so
    /// the app's Setup/Rules UI can show and manage them.
    private func startConfigSync() {
        configSyncTask?.cancel()
        configSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { break }
                let config = self.configStore.load() ?? SharedConfig()
                self.applyRuntimeConfig(config)
                let pinnedInfo = self.engine.detectedPinnedHosts()
                self.bypassStore.save(pinnedInfo)
                let pinned = pinnedInfo.map(\.host)
                self.configStore.savePinnedHosts(pinned)
                // Publish what the engine is actually running so the app can show it.
                var status = EngineStatus()
                status.ruleCount = config.rules.filter { $0.enabled }.count
                status.allowlistCount = config.sslAllowlist.count
                status.pinnedCount = pinned.count
                status.port = config.proxyPort
                status.updatedAt = Date()
                self.configStore.saveEngineStatus(status)
            }
        }
    }

    private func applyRuntimeConfig(_ config: SharedConfig) {
        ImageFilterProxyBridge.apply(config: config, to: engine)
        var pinning = PinningConfig(enabled: config.pinningEnabled)
        pinning.failureThreshold = 1
        pinning.ttl = 24 * 60 * 60
        pinning.requirePriorSuccess = true
        engine.setPinningConfig(pinning)
    }

    private func configurePinningDiagnostics() {
        engine.pinningEventHandler = { [weak self] event in
            guard let self else { return }
            switch event {
            case .mitmAttempted(let host):
                self.diagnostics.record(category: "tls", event: "MITM attempted", details: ["host": host])
            case .mitmHandshakeSucceeded(let host):
                self.diagnostics.record(category: "tls", event: "MITM handshake succeeded", details: ["host": host])
                self.bypassStore.save(self.engine.detectedPinnedHosts())
            case .mitmHandshakeFailed(let host):
                self.diagnostics.record(category: "tls", event: "MITM handshake failed", details: ["host": host])
            case .compatibilitySuspected(let info):
                self.bypassStore.save(self.engine.detectedPinnedHosts())
                self.diagnostics.record(category: "tls", event: "compatibility/pinning suspected; host persisted", details: [
                    "host": info.host, "expiresAt": ISO8601DateFormatter().string(from: info.expiresAt)
                ])
            case .restored(let info):
                self.diagnostics.record(category: "tls", event: "persisted bypass restored", details: ["host": info.host])
            case .expired(let info):
                self.bypassStore.save(self.engine.detectedPinnedHosts())
                self.diagnostics.record(category: "tls", event: "compatibility bypass expired", details: ["host": info.host])
            case .blindTunneled(let host):
                self.diagnostics.record(category: "tls", event: "host blind-tunneled", details: ["host": host])
            case .forceDecryptOverride(let host):
                self.diagnostics.record(category: "tls", event: "force-decrypt override", details: ["host": host])
            }
        }
    }

    /// Builds a "proxy-only" tunnel: no packets are routed through us (all routes
    /// excluded), but the proxy settings are published so the system funnels
    /// HTTP/HTTPS through the on-device HTTrail proxy on 127.0.0.1.
    private func applyNetworkSettings(proxyHost: String, port: Int, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let ipv4 = NEIPv4Settings(addresses: ["10.13.37.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = []                       // capture nothing at the IP layer…
        ipv4.excludedRoutes = [NEIPv4Route.default()]  // …leave raw packets alone
        settings.ipv4Settings = ipv4

        let proxy = NEProxySettings()
        let server = NEProxyServer(address: proxyHost, port: port)
        proxy.httpEnabled = true
        proxy.httpServer = server
        proxy.httpsEnabled = true
        proxy.httpsServer = server
        proxy.excludeSimpleHostnames = false
        proxy.matchDomains = [""]                       // "" matches every host
        settings.proxySettings = proxy

        setTunnelNetworkSettings(settings) { error in
            if let error {
                self.diagnostics.record(category: "network", event: "tunnel network settings failure", details: [
                    "error": String(describing: error)
                ])
            } else {
                self.diagnostics.record(category: "network", event: "tunnel network settings applied", details: [
                    "proxyHost": proxyHost, "proxyPort": String(port)
                ])
            }
            completionHandler(error)
            if error == nil { self.drainPackets() }
        }
    }

    /// Nothing is routed into the tunnel, but keep the read loop alive so the
    /// flow stays connected and any stray packets are consumed.
    private func drainPackets() {
        packetFlow.readPacketObjects { [weak self] _ in
            self?.drainPackets()
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                            completionHandler: @escaping () -> Void) {
        diagnostics.endRun(stopReason: reason.rawValue)
        configSyncTask?.cancel()
        configSyncTask = nil
        let server = proxy
        proxy = nil
        Task {
            try? await server?.stop()
            completionHandler()
        }
    }
}

/// Used only if the App Group container is unavailable (misconfigured build);
/// keeps the proxy alive without persisting flows rather than crashing.
private final class NullFlowSink: FlowSink, @unchecked Sendable {
    func record(_ flow: Flow) {}
}
