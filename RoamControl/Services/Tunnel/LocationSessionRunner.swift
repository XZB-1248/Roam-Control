import BackgroundTasks
import Foundation
import RoamPairingFFI

/// Runs one location session: the native worker and the background task that
/// keeps it alive. A session lasts exactly as long as the task, so the two are
/// started and torn down together.
@MainActor
final class LocationSessionRunner {
    enum Outcome: Sendable, Equatable {
        case success
        case failure(String)
    }

    enum Event {
        /// Not retryable without relaunching the app.
        case schedulerUnavailable
        /// Worth retrying once the connection has been cycled.
        case submissionRejected
        case active
        case expired
        case finished(Outcome)
    }

    var onEvent: ((Event) -> Void)?

    private(set) var isRunning = false

    private var session: OpaquePointer?
    private var runIdentifier: UUID?
    private var submittedTaskIdentifier: String?
    private var backgroundTask: BGContinuedProcessingTask?
    private var progressTask: Task<Void, Never>?
    private var hasFinishedBackgroundTask = true
    private var pending: (pairingRecord: Data, service: RemotePairingService, target: LocationTarget)?

    private static var taskIdentifierPrefix: String {
        BackgroundTaskIdentifier.prefix(for: "location")
    }

    // MARK: - Lifecycle

    func start(
        pairingRecord: Data,
        service: RemotePairingService,
        target: LocationTarget,
        subtitle: String
    ) {
        guard !isRunning else { return }

        pending = (pairingRecord, service, target)

        let identifier = "\(Self.taskIdentifierPrefix).\(UUID().uuidString)"
        let wasRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            MainActor.assumeIsolated {
                guard let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.runNativeSession(hostedBy: task)
            }
        }

        guard wasRegistered else {
            pending = nil
            onEvent?(.schedulerUnavailable)
            return
        }

        submittedTaskIdentifier = identifier
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Roam Control",
            subtitle: subtitle
        )
        request.strategy = .fail

        Task { [weak self] in
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } catch {
                guard let self else { return }
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                self.submittedTaskIdentifier = nil
                self.pending = nil
                self.onEvent?(.submissionRejected)
            }
        }
    }

    @discardableResult
    func updateLocation(_ target: LocationTarget) -> Bool {
        guard isRunning, let session else { return false }
        return rc_location_session_update(session, target.latitude, target.longitude) == 0
    }

    func describe(subtitle: String) {
        backgroundTask?.updateTitle("Roam Control", subtitle: subtitle)
    }

    /// Returns `true` when a live worker was asked to wind down and the caller
    /// should wait for `.finished`; `false` when nothing was running yet.
    @discardableResult
    func cancel() -> Bool {
        if let session {
            rc_location_session_cancel(session)
            return true
        }

        if let submittedTaskIdentifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: submittedTaskIdentifier)
            self.submittedTaskIdentifier = nil
        }
        pending = nil
        return false
    }

    // MARK: - Native worker

    private func runNativeSession(hostedBy task: BGContinuedProcessingTask) {
        guard let pending, !isRunning else {
            task.setTaskCompleted(success: false)
            return
        }
        guard let session = rc_location_session_create() else {
            task.setTaskCompleted(success: false)
            onEvent?(.finished(.failure("Roam Control could not start its location engine.")))
            return
        }

        backgroundTask = task
        hasFinishedBackgroundTask = false
        task.progress.totalUnitCount = 5_760
        task.progress.completedUnitCount = 1
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.handleExpiration()
            }
        }
        startProgressTicking(for: task)

        let runIdentifier = UUID()
        self.runIdentifier = runIdentifier
        self.session = session
        isRunning = true

        let sessionBits = UInt(bitPattern: session)
        let contextBits = UInt(bitPattern: Unmanaged.passRetained(self).toOpaque())
        let (pairingRecord, service, target) = pending

        DispatchQueue.global(qos: .userInitiated).async {
            guard
                let session = OpaquePointer(bitPattern: sessionBits),
                let context = UnsafeMutableRawPointer(bitPattern: contextBits)
            else { return }

            var result = RCLocationResult()
            let returnCode = pairingRecord.withUnsafeBytes { recordBytes in
                guard let recordBaseAddress = recordBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return Int32(-1)
                }

                return LocalTunnel.peerAddress.withCString { peerAddress in
                    service.identifier.withCString { serviceIdentifier in
                        service.authTag.withCString { authTag in
                            rc_location_session_run(
                                session,
                                recordBaseAddress,
                                pairingRecord.count,
                                peerAddress,
                                service.port,
                                serviceIdentifier,
                                authTag,
                                target.latitude,
                                target.longitude,
                                locationStartedCallback,
                                context,
                                &result
                            )
                        }
                    }
                }
            }

            let outcome = Outcome(result: result, returnCode: returnCode)
            rc_location_result_destroy(&result)

            DispatchQueue.main.async {
                if let session = OpaquePointer(bitPattern: sessionBits) {
                    rc_location_session_destroy(session)
                }
                let runner = Unmanaged<LocationSessionRunner>
                    .fromOpaque(context)
                    .takeRetainedValue()
                runner.nativeSessionFinished(outcome, runIdentifier: runIdentifier)
            }
        }
    }

    fileprivate func nativeSessionStarted() {
        guard isRunning else { return }
        onEvent?(.active)
    }

    private func nativeSessionFinished(_ outcome: Outcome, runIdentifier: UUID) {
        guard self.runIdentifier == runIdentifier else { return }

        self.runIdentifier = nil
        session = nil
        isRunning = false
        pending = nil

        finishBackgroundTask(success: outcome == .success)
        onEvent?(.finished(outcome))
    }

    private func handleExpiration() {
        cancel()
        finishBackgroundTask(success: true)
        onEvent?(.expired)
    }

    // MARK: - Background task

    private func startProgressTicking(for task: BGContinuedProcessingTask) {
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard
                    !Task.isCancelled,
                    let self,
                    self.backgroundTask === task,
                    !self.hasFinishedBackgroundTask
                else { return }

                task.progress.completedUnitCount = min(
                    task.progress.completedUnitCount + 1,
                    task.progress.totalUnitCount - 1
                )
            }
        }
    }

    private func finishBackgroundTask(success: Bool) {
        guard !hasFinishedBackgroundTask else { return }
        hasFinishedBackgroundTask = true

        progressTask?.cancel()
        progressTask = nil
        backgroundTask?.setTaskCompleted(success: success)
        backgroundTask = nil
        submittedTaskIdentifier = nil
    }
}

private extension LocationSessionRunner.Outcome {
    init(result: RCLocationResult, returnCode: Int32) {
        guard returnCode != 0 else {
            self = .success
            return
        }

        let message = result.error_message.map { String(cString: $0) } ?? ""
        self = .failure(
            message.isEmpty ? "The iPhone could not start the location session." : message
        )
    }
}

private let locationStartedCallback: RCLocationStartedCallback = { context in
    guard let context else { return }
    let contextBits = UInt(bitPattern: context)

    DispatchQueue.main.async {
        guard let context = UnsafeMutableRawPointer(bitPattern: contextBits) else { return }
        Unmanaged<LocationSessionRunner>
            .fromOpaque(context)
            .takeUnretainedValue()
            .nativeSessionStarted()
    }
}
