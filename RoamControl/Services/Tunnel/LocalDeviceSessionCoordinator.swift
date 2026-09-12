import Foundation
import Network
import Observation

enum DeviceSessionPhase: Equatable {
    case idle
    case startingTunnel
    case discovering
    case connecting
    case active(LocationTarget)
    case stopping
    case failed(String)
}

enum MobileDataGuidance: Equatable {
    case connectionHelp
    case turnOff
    case turnBackOn
}

enum ActiveLocationUpdateResult: Equatable {
    case unavailable
    case updated
    case failed
}

/// Sequences the tunnel, the browser and the session runner, and turns what they
/// report into the phase the interface renders. It owns no networking itself.
@MainActor
@Observable
final class LocalDeviceSessionCoordinator {
    private struct PendingSession {
        let pairingRecord: Data
        let target: LocationTarget
    }

    private static let minimumRestorationDisplayDuration: TimeInterval = 1.2
    private static let discoveryTimeout: Duration = .seconds(30)
    private static let connectionHelpDelay: Duration = .seconds(5)
    private static let probeRetryDelay: Duration = .milliseconds(650)
    private static let maximumProbeAttempts = 3

    private(set) var phase: DeviceSessionPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            onPhaseChange?(phase)
        }
    }
    private(set) var mobileDataGuidance: MobileDataGuidance?

    var onPhaseChange: ((DeviceSessionPhase) -> Void)?

    private let tunnel: LocalTunnelController
    private let browser = RemotePairingBrowser()
    private let probe = LocalTunnelReachabilityProbe()
    private let runner = LocationSessionRunner()
    private let wifi = WiFiAvailability()

    private var pendingSession: PendingSession?
    private var startupTask: Task<Void, Never>?
    private var discoveryTimeoutTask: Task<Void, Never>?
    private var connectionHelpTask: Task<Void, Never>?
    private var mobileDataDiscoveryLoop: Task<Void, Never>?
    private var probeRetryTask: Task<Void, Never>?

    private var probeAttempts = 0
    private var isVerifyingReachability = false
    private var hasRestartedTunnelThisAttempt = false
    private var isMobileDataStartupMode = false
    private var cancellationRequested = false
    private var pendingFailureMessage: String?
    private var restorationDisplayStart: Date?

    init(tunnel: LocalTunnelController) {
        self.tunnel = tunnel
        runner.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    var isBusy: Bool {
        switch phase {
        case .startingTunnel, .discovering, .connecting, .stopping: true
        case .idle, .active, .failed: false
        }
    }

    /// `true` once a stop the iPhone never confirmed has left the simulated
    /// location possibly still in place. The recovery record has to survive it.
    private(set) var hasUnconfirmedSimulation = false

    /// Used to keep a preference change from cutting a live session off.
    var needsTunnel: Bool {
        switch phase {
        case .idle, .failed: false
        case .startingTunnel, .discovering, .connecting, .active, .stopping: true
        }
    }

    // MARK: - Starting

    func start(pairingRecord: Data, target: LocationTarget) {
        guard !runner.isRunning, !isBusy else { return }

#if targetEnvironment(simulator)
        phase = .failed("A real iPhone is required to start a location session.")
#else
        cancellationRequested = false
        pendingFailureMessage = nil
        restorationDisplayStart = nil
        mobileDataGuidance = nil
        hasRestartedTunnelThisAttempt = false
        isMobileDataStartupMode = false
        pendingSession = PendingSession(pairingRecord: pairingRecord, target: target)

        phase = .startingTunnel
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.tunnel.start()
            } catch {
                self.fail(error.localizedDescription)
                return
            }

            guard !Task.isCancelled, self.pendingSession != nil else { return }
            await self.routeStartupForCurrentNetwork()
        }
#endif
    }

    /// On mobile data, Bonjour only reaches the tunnel once cellular is briefly
    /// out of the way.
    private func routeStartupForCurrentNetwork() async {
        guard pendingSession != nil else { return }

        if await wifi.isAvailable() {
            beginDiscovery(showConnectionHelpIfUnavailable: true)
        } else {
            isMobileDataStartupMode = true
            enterMobileDataGuidance()
        }
    }

    // MARK: - Discovery

    private func beginDiscovery(
        reportTimeout: Bool = true,
        showConnectionHelpIfUnavailable: Bool = false
    ) {
        guard let pendingSession else { return }

        stopDiscovery()
        phase = .discovering

        browser.start(matching: pendingSession.pairingRecord) { [weak self] event in
            self?.handle(event)
        }

        if showConnectionHelpIfUnavailable {
            connectionHelpTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.connectionHelpDelay)
                guard !Task.isCancelled, let self, self.isAwaitingDiscovery else { return }
                self.mobileDataGuidance = .connectionHelp
            }
        }

        if reportTimeout {
            discoveryTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.discoveryTimeout)
                guard !Task.isCancelled, let self, self.phase == .discovering else { return }
                self.fail(self.browser.hasSeenUnmatchedService
                    ? "Roam Control found an outdated device announcement. Turn the local tunnel off and on in Settings, then try again."
                    : "Roam Control could not find this iPhone through the local tunnel. Check that it is connected and try again."
                )
            }
        }
    }

    private var isAwaitingDiscovery: Bool {
        pendingSession != nil && phase == .discovering && !runner.isRunning
    }

    private func handle(_ event: RemotePairingBrowser.Event) {
        switch event {
        case .matched(let service):
            // A refreshed TXT record re-announces a service already being
            // checked; restarting the probe would read it as unreachable.
            guard isAwaitingDiscovery, !isVerifyingReachability, probeRetryTask == nil else { return }
            verifyReachability(of: service)
        case .unmatched:
            break
        case .unavailable:
            fail("Local Network access is required to find this iPhone.")
        }
    }

    private func stopDiscovery() {
        browser.stop()
        probe.cancel()
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil
        connectionHelpTask?.cancel()
        connectionHelpTask = nil
        probeRetryTask?.cancel()
        probeRetryTask = nil
        probeAttempts = 0
        isVerifyingReachability = false
    }

    // MARK: - Reachability

    private func verifyReachability(of service: RemotePairingService) {
        probeAttempts += 1
        isVerifyingReachability = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            let isReachable = await self.probe.canReach(port: service.port)
            self.isVerifyingReachability = false
            guard self.isAwaitingDiscovery else { return }

            if isReachable {
                self.probeAttempts = 0
                self.beginSession(with: service)
            } else {
                self.handleUnreachableService(service)
            }
        }
    }

    private func handleUnreachableService(_ service: RemotePairingService) {
        if isMobileDataStartupMode {
            probeAttempts = 0
            return
        }

        if !hasRestartedTunnelThisAttempt {
            probeAttempts = 0
            restartTunnelAndRetryDiscovery()
            return
        }

        guard probeAttempts < Self.maximumProbeAttempts else {
            probeAttempts = 0
            mobileDataGuidance = .connectionHelp
            return
        }

        probeRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.probeRetryDelay)
            guard !Task.isCancelled, let self else { return }
            self.probeRetryTask = nil
            self.verifyReachability(of: service)
        }
    }

    /// Cycling the tunnel fixes most "found it but cannot reach it" cases.
    private func restartTunnelAndRetryDiscovery() {
        guard pendingSession != nil else { return }

        hasRestartedTunnelThisAttempt = true
        stopDiscovery()
        phase = .startingTunnel

        startupTask?.cancel()
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.tunnel.restart()
            } catch {
                self.fail(error.localizedDescription)
                return
            }

            guard !Task.isCancelled, self.pendingSession != nil else { return }
            self.beginDiscovery(showConnectionHelpIfUnavailable: true)
        }
    }

    // MARK: - Session

    private func beginSession(with service: RemotePairingService) {
        guard let pendingSession else { return }

        stopDiscovery()
        mobileDataGuidance = nil
        mobileDataDiscoveryLoop?.cancel()
        mobileDataDiscoveryLoop = nil
        phase = .connecting

        runner.start(
            pairingRecord: pendingSession.pairingRecord,
            service: service,
            target: pendingSession.target,
            subtitle: "Connecting to \(pendingSession.target.name)…"
        )
    }

    private func handle(_ event: LocationSessionRunner.Event) {
        switch event {
        case .schedulerUnavailable:
            fail("iOS could not prepare the location session. Close Roam Control, reopen it, and try again.")

        case .submissionRejected(let reason):
            // Cycling the tunnel cannot make iOS hand back a task it withheld.
            guard reason.isRecoverable else {
                fail(reason.guidance)
                return
            }
            recoverFromConnectionSetback()

        case .active:
            guard !cancellationRequested, let target = pendingSession?.target else { return }
            mobileDataDiscoveryLoop?.cancel()
            mobileDataDiscoveryLoop = nil
            phase = .active(target)
            if mobileDataGuidance == .turnOff {
                mobileDataGuidance = .turnBackOn
            }
            runner.describe(subtitle: "Location active at \(target.name)")

        case .expired:
            cancellationRequested = true
            pendingFailureMessage = nil
            mobileDataGuidance = nil
            phase = .stopping

        case .finished(let outcome):
            handleSessionFinished(outcome)
        }
    }

    private func handleSessionFinished(_ outcome: LocationSessionRunner.Outcome) {
        if outcome.isSuccessful {
            hasUnconfirmedSimulation = false
        }

        if let pendingFailureMessage {
            self.pendingFailureMessage = nil
            finishSession(with: .failed(pendingFailureMessage))
            return
        }

        if cancellationRequested {
            cancellationRequested = false
            clearPendingSession()
            tunnel.stopUnlessKeptRunning()

            // The engine confirms clearing the simulated location before it
            // returns, so a failure here means the iPhone is still simulating.
            guard case .failure(let message) = outcome else {
                completeRestoration()
                return
            }
            restorationDisplayStart = nil
            hasUnconfirmedSimulation = true
            phase = .failed(Self.presentable(message))
            return
        }

        switch outcome {
        case .success, .cancelled:
            finishSession(with: .idle)

        case .failure(let message):
            guard isRecoverableConnectionFailure(message) else {
                finishSession(with: .failed(Self.presentable(message)))
                return
            }
            recoverFromConnectionSetback()
        }
    }

    private func recoverFromConnectionSetback() {
        guard pendingSession != nil else { return }

        if isMobileDataStartupMode {
            enterMobileDataGuidance()
        } else if hasRestartedTunnelThisAttempt {
            phase = .discovering
            mobileDataGuidance = .connectionHelp
        } else {
            restartTunnelAndRetryDiscovery()
        }
    }

    private func isRecoverableConnectionFailure(_ message: String) -> Bool {
        // Matched against the native engine's own wording, which still names
        // LocalDevVPN. `presentable(_:)` rewrites it for display.
        message.localizedCaseInsensitiveContains("through LocalDevVPN")
            || message.localizedCaseInsensitiveContains("make the iPhone connection available")
            || message.localizedCaseInsensitiveContains("open the secure device tunnel")
    }

    private static func presentable(_ nativeMessage: String) -> String {
        nativeMessage.replacingOccurrences(
            of: "LocalDevVPN",
            with: "the local tunnel",
            options: .caseInsensitive
        )
    }

    // MARK: - Updating and stopping

    @discardableResult
    func updateLocation(_ target: LocationTarget) -> ActiveLocationUpdateResult {
        guard case .active = phase, let pendingSession else { return .unavailable }
        guard runner.updateLocation(target) else {
            fail("Roam Control could not update the active location.")
            return .failed
        }

        self.pendingSession = PendingSession(
            pairingRecord: pendingSession.pairingRecord,
            target: target
        )
        phase = .active(target)
        runner.describe(subtitle: "Location active at \(target.name)")
        return .updated
    }

    func stop() {
        mobileDataGuidance = nil

        switch phase {
        case .idle:
            return
        case .startingTunnel, .discovering:
            cancellationRequested = true
            startupTask?.cancel()
            stopDiscovery()
            clearPendingSession()
            tunnel.stopUnlessKeptRunning()
            phase = .idle
        case .connecting, .active:
            cancellationRequested = true
            if case .active = phase {
                restorationDisplayStart = .now
                runner.describe(subtitle: "Restoring real location…")
            }
            phase = .stopping

            guard runner.cancel() else {
                // Nothing was running yet, so no `.finished` is coming.
                cancellationRequested = false
                clearPendingSession()
                tunnel.stopUnlessKeptRunning()
                phase = .idle
                return
            }
        case .stopping:
            break
        case .failed:
            clearPendingSession()
            phase = .idle
        }
    }

    func reset() {
        stop()
        if !runner.isRunning {
            clearPendingSession()
            phase = .idle
        }
    }

    func appDidBecomeActive() {
        guard mobileDataGuidance == .turnOff else { return }
        startMobileDataDiscoveryLoop()
    }

    private func fail(_ message: String) {
        mobileDataGuidance = nil
        startupTask?.cancel()
        stopDiscovery()

        if runner.isRunning {
            // Let the worker unwind first; the message is reported when it ends.
            pendingFailureMessage = message
            runner.cancel()
            return
        }

        runner.cancel()
        clearPendingSession()
        tunnel.stopUnlessKeptRunning()
        phase = .failed(message)
    }

    private func finishSession(with finalPhase: DeviceSessionPhase) {
        mobileDataGuidance = nil
        clearPendingSession()
        tunnel.stopUnlessKeptRunning()
        phase = finalPhase
    }

    private func completeRestoration() {
        let elapsed = restorationDisplayStart.map { Date.now.timeIntervalSince($0) } ?? .infinity
        restorationDisplayStart = nil
        let remaining = max(0, Self.minimumRestorationDisplayDuration - elapsed)

        guard remaining > 0 else {
            phase = .idle
            return
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, !self.runner.isRunning, self.phase == .stopping else { return }
            self.phase = .idle
        }
    }

    private func clearPendingSession() {
        startupTask?.cancel()
        startupTask = nil
        mobileDataDiscoveryLoop?.cancel()
        mobileDataDiscoveryLoop = nil
        stopDiscovery()
        pendingSession = nil
        hasRestartedTunnelThisAttempt = false
        isMobileDataStartupMode = false
    }

    // MARK: - Mobile data guidance

    func dismissMobileDataGuidance() {
        mobileDataGuidance = nil
    }

    func useMobileDataGuidance() {
        guard mobileDataGuidance == .connectionHelp, pendingSession != nil else { return }
        isMobileDataStartupMode = true
        enterMobileDataGuidance()
    }

    func confirmMobileDataIsOff() {
        guard mobileDataGuidance == .turnOff, pendingSession != nil else { return }
        mobileDataDiscoveryLoop?.cancel()
        mobileDataDiscoveryLoop = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self else { return }
            self.startMobileDataDiscoveryLoop()
        }
    }

    func retryConnection() {
        guard mobileDataGuidance == .connectionHelp, pendingSession != nil else { return }
        mobileDataGuidance = nil
        beginDiscovery(showConnectionHelpIfUnavailable: true)
    }

    func restartTunnel() {
        guard pendingSession != nil else { return }
        mobileDataGuidance = nil
        restartTunnelAndRetryDiscovery()
    }

    private func enterMobileDataGuidance() {
        guard pendingSession != nil, !runner.isRunning else { return }
        stopDiscovery()
        phase = .discovering
        mobileDataGuidance = .turnOff
        startMobileDataDiscoveryLoop()
    }

    /// The announcement can take a few seconds to appear on the tunnel.
    private func startMobileDataDiscoveryLoop() {
        guard
            isMobileDataStartupMode,
            mobileDataGuidance == .turnOff,
            pendingSession != nil,
            !runner.isRunning
        else { return }

        mobileDataDiscoveryLoop?.cancel()
        mobileDataDiscoveryLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard
                    let self,
                    self.isMobileDataStartupMode,
                    self.mobileDataGuidance == .turnOff,
                    self.pendingSession != nil,
                    !self.runner.isRunning
                else { return }

                self.beginDiscovery(reportTimeout: false)
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}

@MainActor
private final class WiFiAvailability {
    private static let firstReportTimeout: Duration = .milliseconds(600)
    private static let pollInterval: Duration = .milliseconds(50)

    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var isSatisfied = false
    private var hasReported = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isSatisfied = isSatisfied
                self?.hasReported = true
            }
        }
        monitor.start(queue: DispatchQueue(
            label: "com.clover.roamcontrol.wifi-path",
            qos: .utility
        ))
    }

    /// Reading before the monitor's first report would mistake a cold start for
    /// an iPhone with no Wi-Fi.
    func isAvailable() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: Self.firstReportTimeout)
        while !hasReported, ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.pollInterval)
        }
        return isSatisfied
    }
}
