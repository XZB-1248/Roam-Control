import CoreLocation
import Observation

/// Reports the position Core Location currently gives the app. It does not ask
/// for permission: the map already does, and a diagnostics screen is the wrong
/// place for a prompt.
@MainActor
@Observable
final class ReportedLocationObserver: NSObject {
    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var isAuthorized = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        isAuthorized = Self.isAuthorized(manager.authorizationStatus)
    }

    func start() {
        guard isAuthorized else { return }
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }
}

extension ReportedLocationObserver: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            isAuthorized = Self.isAuthorized(status)
            if isAuthorized { start() }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        let coordinate = location.coordinate
        MainActor.assumeIsolated {
            self.coordinate = coordinate
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}
