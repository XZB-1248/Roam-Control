import BackgroundTasks
import Foundation

/// Why iOS refused a background task. `BGTaskScheduler` distinguishes a handful
/// of conditions with different remedies, so reporting them as one "iOS could
/// not schedule this" leaves the user with nothing to act on.
enum SchedulerFailureReason {
    case unavailable
    case tooManyPendingRequests
    case notPermitted
    case immediateRunIneligible
    case unknown

    static func classify(_ error: any Error) -> Self {
        let error = error as NSError
        guard error.domain == BGTaskScheduler.errorDomain else { return .unknown }

        switch BGTaskScheduler.Error.Code(rawValue: error.code) {
        case .unavailable: return .unavailable
        case .tooManyPendingTaskRequests: return .tooManyPendingRequests
        case .notPermitted: return .notPermitted
        case .immediateRunIneligible: return .immediateRunIneligible
        default: return .unknown
        }
    }

    /// Cycling the tunnel cannot help when iOS itself is withholding the task.
    var isRecoverable: Bool {
        switch self {
        case .tooManyPendingRequests, .immediateRunIneligible, .unknown: true
        case .unavailable, .notPermitted: false
        }
    }

    var guidance: String {
        switch self {
        case .unavailable:
            "iOS background processing is unavailable. Check Background App Refresh for Roam Control in Settings, then try again."
        case .tooManyPendingRequests:
            "iOS has too many pending background tasks. Let the others finish, then try again."
        case .notPermitted:
            "iOS did not permit the background task Roam Control needs."
        case .immediateRunIneligible:
            "iOS could not start the task immediately under current conditions. Keep Roam Control open and try again shortly."
        case .unknown:
            "iOS could not schedule the background task Roam Control needs. Try again shortly."
        }
    }
}
