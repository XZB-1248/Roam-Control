import Foundation
import Network
import NetworkExtension
import Observation

/// Deliberately repeated in `RoamControlTunnel/PacketTunnelProvider.swift`: the
/// extension is a separate module, and this is a contract between two processes
/// rather than shared implementation.
enum LocalTunnel {
    static let deviceAddress = "10.7.0.0"
    static let peerAddress = "10.7.0.1"
}

enum LocalTunnelStatus: Equatable {
    case unavailable
    case notConfigured
    case disconnected
    case connecting
    case connected
    case failed(String)

    var isConnected: Bool { self == .connected }
}

enum LocalTunnelError: LocalizedError {
    case unavailable
    case notPermitted
    case timedOut
    case system(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The local tunnel needs a physical iPhone."
        case .notPermitted:
            "Roam Control needs permission to add its local tunnel. Allow the VPN configuration and try again."
        case .timedOut:
            "The local tunnel did not come up in time."
        case .system(let message):
            message
        }
    }
}

/// Owns the lifecycle of the bundled packet tunnel.
@MainActor
@Observable
final class LocalTunnelController {
    private static let keepRunningKey = "com.clover.roamcontrol.tunnel.keepRunning"
    private static let connectionTimeout: Duration = .seconds(12)
    private static let pollInterval: Duration = .milliseconds(120)

    private(set) var status: LocalTunnelStatus = .notConfigured

    var keepsRunningBetweenSessions: Bool {
        didSet {
            guard keepsRunningBetweenSessions != oldValue else { return }
            preferences.set(keepsRunningBetweenSessions, forKey: Self.keepRunningKey)
        }
    }

    private let preferences: UserDefaults
    private var manager: NETunnelProviderManager?
    private var statusObserver: (any NSObjectProtocol)?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.keepsRunningBetweenSessions = preferences.bool(forKey: Self.keepRunningKey)
#if targetEnvironment(simulator)
        status = .unavailable
#endif
    }

    var isConnected: Bool { status.isConnected }

    /// The first call of an install saves a VPN configuration, which prompts the
    /// user, so it has to happen in the foreground.
    func start() async throws {
#if targetEnvironment(simulator)
        status = .unavailable
        throw LocalTunnelError.unavailable
#else
        let manager = try await preparedManager()

        guard manager.connection.status != .connected else {
            status = .connected
            return
        }

        status = .connecting
        do {
            try manager.connection.startVPNTunnel()
        } catch {
            let failure = LocalTunnelError.system(error.localizedDescription)
            status = .failed(failure.localizedDescription)
            throw failure
        }

        try await waitUntilConnected(manager.connection)
#endif
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    func stopUnlessKeptRunning() {
        guard !keepsRunningBetweenSessions else { return }
        stop()
    }

    func restart() async throws {
        stop()
        try? await Task.sleep(for: .milliseconds(400))
        try await start()
    }

    // MARK: - Configuration

    private var providerBundleIdentifier: String {
        let containerIdentifier = Bundle.main.bundleIdentifier ?? "com.clover.RoamControl"
        return containerIdentifier + ".tunnel"
    }

    private func preparedManager() async throws -> NETunnelProviderManager {
        if let manager { return manager }

        let existing: [NETunnelProviderManager]
        do {
            existing = try await NETunnelProviderManager.loadAllFromPreferences()
        } catch {
            throw LocalTunnelError.system(error.localizedDescription)
        }

        let matching = existing.first { manager in
            let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol
            return configuration?.providerBundleIdentifier == providerBundleIdentifier
        }

        let manager = matching ?? NETunnelProviderManager()
        try await save(manager)
        self.manager = manager
        observeStatus(of: manager)
        return manager
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol)
            ?? NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = providerBundleIdentifier
        configuration.serverAddress = LocalTunnel.peerAddress

        manager.protocolConfiguration = configuration
        manager.localizedDescription = "Roam Control"
        manager.isEnabled = true

        do {
            try await manager.saveToPreferences()
            // NetworkExtension requires a freshly saved configuration to be read
            // back before its connection will start.
            try await manager.loadFromPreferences()
        } catch {
            let failure = permissionDenied(error)
                ? LocalTunnelError.notPermitted
                : LocalTunnelError.system(error.localizedDescription)
            status = .failed(failure.localizedDescription)
            throw failure
        }
    }

    private func permissionDenied(_ error: any Error) -> Bool {
        (error as NSError).domain == NEVPNErrorDomain
            && (error as NSError).code == NEVPNError.configurationReadWriteFailed.rawValue
    }

    // MARK: - Status

    private func observeStatus(of manager: NETunnelProviderManager) {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStatus()
            }
        }

        refreshStatus()
    }

    private func refreshStatus() {
        guard let manager else { return }
        status = Self.status(for: manager.connection.status)
    }

    private static func status(for status: NEVPNStatus) -> LocalTunnelStatus {
        switch status {
        case .invalid: .notConfigured
        case .disconnected: .disconnected
        case .connecting, .reasserting: .connecting
        case .connected: .connected
        case .disconnecting: .disconnected
        @unknown default: .disconnected
        }
    }

    private func waitUntilConnected(_ connection: NEVPNConnection) async throws {
        let deadline = ContinuousClock.now.advanced(by: Self.connectionTimeout)
        var hasLeftIdle = false

        while ContinuousClock.now < deadline {
            switch connection.status {
            case .connected:
                status = .connected
                return
            case .connecting, .reasserting:
                hasLeftIdle = true
            case .disconnected, .invalid:
                // Idle is also the state right after startVPNTunnel, so this
                // only counts as a failure once the tunnel has actually moved.
                guard hasLeftIdle else { break }
                let failure = LocalTunnelError.system(
                    "The local tunnel stopped as soon as it started. Restart Roam Control and try again."
                )
                status = .failed(failure.localizedDescription)
                throw failure
            default:
                break
            }

            try? await Task.sleep(for: Self.pollInterval)
        }

        status = .failed(LocalTunnelError.timedOut.localizedDescription)
        throw LocalTunnelError.timedOut
    }
}

/// Confirms a discovered port answers through the tunnel. Bonjour can hand back
/// a stale announcement.
@MainActor
final class LocalTunnelReachabilityProbe {
    private nonisolated static let defaultTimeout: Duration = .milliseconds(900)

    private let queue = DispatchQueue(
        label: "com.clover.roamcontrol.tunnel-probe",
        qos: .userInitiated
    )
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    func canReach(
        port: UInt16,
        timeout: Duration = LocalTunnelReachabilityProbe.defaultTimeout
    ) async -> Bool {
        cancel()

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation

            let connection = NWConnection(
                host: NWEndpoint.Host(LocalTunnel.peerAddress),
                port: endpointPort,
                using: .tcp
            )
            self.connection = connection

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Task { @MainActor in self?.finish(reachable: true) }
                case .failed, .cancelled:
                    Task { @MainActor in self?.finish(reachable: false) }
                case .setup, .waiting, .preparing:
                    break
                @unknown default:
                    break
                }
            }

            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(reachable: false)
            }

            connection.start(queue: queue)
        }
    }

    func cancel() {
        finish(reachable: false)
    }

    private func finish(reachable: Bool) {
        guard let continuation else { return }
        self.continuation = nil

        timeoutTask?.cancel()
        timeoutTask = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        continuation.resume(returning: reachable)
    }
}
