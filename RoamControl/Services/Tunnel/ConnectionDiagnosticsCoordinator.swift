import Foundation
import Observation

enum ConnectionCheckState: Equatable {
    case notRun
    case running
    case passed(String)
    case failed(String)
}

/// A read-only health check. It never starts, changes or stops a location
/// session, but does bring the tunnel up for the duration: without one the check
/// would always fail for the wrong reason.
@MainActor
@Observable
final class ConnectionDiagnosticsCoordinator {
    private static let discoveryTimeout: Duration = .seconds(10)

    private(set) var state: ConnectionCheckState = .notRun
    private(set) var lastChecked: Date?

    private let tunnel: LocalTunnelController
    private let browser = RemotePairingBrowser()
    private let probe = LocalTunnelReachabilityProbe()
    private var checkTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isVerifyingReachability = false

    init(tunnel: LocalTunnelController) {
        self.tunnel = tunnel
    }

    func run(pairingRecord: Data?, sessionPhase: DeviceSessionPhase) {
        cancel(resetState: false)

        guard let pairingRecord else {
            finish(.failed("This iPhone is not paired. Open Pairing & Connection and pair it first."))
            return
        }

        switch sessionPhase {
        case .active:
            finish(.passed("The secure location session is active and responding."))
            return
        case .startingTunnel, .discovering, .connecting, .stopping:
            finish(.failed("Roam Control is already changing the connection. Let it finish, then run the check again."))
            return
        case .idle, .failed:
            break
        }

#if targetEnvironment(simulator)
        finish(.failed("Tunnel reachability can only be checked on a physical iPhone."))
#else
        state = .running
        checkTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.tunnel.start()
            } catch {
                self.finish(.failed(error.localizedDescription))
                return
            }

            guard !Task.isCancelled, self.state == .running else { return }
            self.search(matching: pairingRecord)
        }
#endif
    }

    func cancel() {
        cancel(resetState: true)
    }

    private func search(matching pairingRecord: Data) {
        browser.start(matching: pairingRecord) { [weak self] event in
            guard let self, self.state == .running else { return }

            switch event {
            case .matched(let service):
                // A refreshed TXT record re-announces a service already being
                // checked; restarting the probe would read it as unreachable.
                guard !self.isVerifyingReachability else { return }
                self.verifyReachability(of: service)
            case .unmatched:
                break
            case .unavailable:
                self.finish(.failed("Local Network access is unavailable. Allow it in iPhone Settings, then try again."))
            }
        }

        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.discoveryTimeout)
            guard !Task.isCancelled, let self, self.state == .running else { return }

            self.finish(.failed(self.browser.hasSeenUnmatchedService
                ? "The tunnel is up, but the device announcement does not match the paired iPhone. Turn the tunnel off and on in Settings, then try again."
                : "This iPhone was not reachable through the local tunnel. On mobile data, switch data off briefly and run the check again."
            ))
        }
    }

    /// An announcement only proves the iPhone is talking. Connecting to the port
    /// it named is what proves the tunnel carries traffic to it.
    private func verifyReachability(of service: RemotePairingService) {
        isVerifyingReachability = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            let isReachable = await self.probe.canReach(port: service.port)
            self.isVerifyingReachability = false
            guard self.state == .running else { return }

            self.finish(isReachable
                ? .passed("This iPhone's pairing service answered through the local tunnel. The secure session itself is verified when you start a location session.")
                : .failed("The announcement matches, but this iPhone's pairing service did not answer through the local tunnel. Turn the tunnel off and on in Settings, then try again.")
            )
        }
    }

    private func cancel(resetState: Bool) {
        checkTask?.cancel()
        checkTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        probe.cancel()
        isVerifyingReachability = false
        browser.stop()

        if resetState, state == .running {
            state = .notRun
        }
    }

    private func finish(_ newState: ConnectionCheckState) {
        cancel(resetState: false)
        tunnel.stopUnlessKeptRunning()
        state = newState
        lastChecked = Date()
    }
}
