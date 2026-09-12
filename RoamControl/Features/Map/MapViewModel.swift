import MapKit
import Observation
import SwiftUI

@MainActor
@Observable
final class MapViewModel: NSObject, MKLocalSearchCompleterDelegate {
    var searchQuery = ""
    var searchSuggestions: [MapSearchSuggestion] = []
    var selectedLocation: LocationTarget?
    var isSearching = false
    var isFindingRealLocation = false
    var errorMessage: String?
    var cameraPosition: MapCameraPosition

    @ObservationIgnored
    private let searchCompleter = MKLocalSearchCompleter()
    @ObservationIgnored
    private let locationManager = CLLocationManager()
    @ObservationIgnored
    private var recenterOnNextRealLocation = false
    @ObservationIgnored
    private var locationRequestStartedAt: Date?
    @ObservationIgnored
    private var locationTimeout: Task<Void, Never>?
    @ObservationIgnored
    private var shouldReportLocationErrors = false
    @ObservationIgnored
    private var lastRealLocation: CLLocation?
    @ObservationIgnored
    private var isRealLocationCacheTrusted = true
    @ObservationIgnored
    private var requiresFreshRealLocation = false

    /// Applied to every camera change, so motion is decided in one place instead
    /// of at each call site. The view keeps it in step with Reduce Motion.
    @ObservationIgnored
    var cameraAnimation: Animation? = .easeInOut(duration: 0.3)

    /// The map view's size, and how much of its top and bottom are hidden
    /// behind the controls floating over it. The view reports geometry; fitting
    /// works out what to do with it.
    @ObservationIgnored
    var viewSize: CGSize = .zero
    @ObservationIgnored
    var obscuredInsets = ObscuredInsets()

    struct ObscuredInsets: Equatable {
        var top: CGFloat = 0
        var bottom: CGFloat = 0
    }

    @ObservationIgnored
    private var pendingFit: MKMapRect?
    @ObservationIgnored
    private var pendingFitExpiry: Task<Void, Never>?

    override init() {
        cameraPosition = .automatic
        super.init()
        searchCompleter.delegate = self
        searchCompleter.resultTypes = [.address, .pointOfInterest, .query]
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var isShowingSuggestions: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !searchSuggestions.isEmpty
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        errorMessage = nil

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        switch coordinateInput(from: trimmedQuery) {
        case .coordinate, .invalid:
            searchSuggestions = []
            searchCompleter.queryFragment = ""
            return
        case .notCoordinates:
            break
        }

        guard trimmedQuery.count >= 2 else {
            searchSuggestions = []
            searchCompleter.queryFragment = ""
            return
        }

        searchCompleter.queryFragment = trimmedQuery
    }

    func selectDroppedPin(at coordinate: CLLocationCoordinate2D) async {
        await selectCoordinate(
            coordinate,
            fallbackName: "Dropped Pin",
            fallbackDescription: "Selected from the map",
            recenter: false
        )
    }

    func search() async {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        switch coordinateInput(from: trimmedQuery) {
        case .coordinate(let coordinate):
            isSearching = true
            errorMessage = nil
            resetSearchField()
            await selectCoordinate(
                coordinate,
                fallbackName: "Entered Location",
                fallbackDescription: "Entered using coordinates",
                recenter: true
            )
            isSearching = false
            return
        case .invalid:
            searchSuggestions = []
            errorMessage = "Enter latitude from −90 to 90 and longitude from −180 to 180."
            return
        case .notCoordinates:
            break
        }

        await performSearch(for: trimmedQuery)
    }

    func selectSuggestion(_ suggestion: MapSearchSuggestion) async {
        searchQuery = suggestion.title
        searchSuggestions = []

        let query = [suggestion.title, suggestion.subtitle]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        await performSearch(for: query)
    }

    func show(_ target: LocationTarget) {
        selectedLocation = target
        resetSearchField()
        errorMessage = nil
        center(on: target)
    }

    func center(on target: LocationTarget) {
        move(to: .region(
            MKCoordinateRegion(
                center: target.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
            )
        ))
    }

    func move(to position: MapCameraPosition) {
        withAnimation(cameraAnimation) { cameraPosition = position }
    }

    func show(_ route: MKRoute) {
        let routeRect = route.polyline.boundingMapRect
        guard !routeRect.isNull, !routeRect.isEmpty else { return }

        // The card covering the map is still the shorter one at this point; it
        // grows as the route appears. Hold the rect briefly so the fit can be
        // redone once that height is known, and no longer, or a card resizing
        // mid-walk would pull the camera back.
        pendingFit = routeRect
        pendingFitExpiry?.cancel()
        pendingFitExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.pendingFit = nil
        }

        fit(routeRect)
    }

    /// Redoes the most recent fit against a newly measured covered area.
    func refitForObscuredArea() {
        guard let pendingFit else { return }
        fit(pendingFit)
    }

    private func fit(_ routeRect: MKMapRect) {
        let horizontalPadding = max(routeRect.size.width * 0.24, 1_200)
        let verticalPadding = max(routeRect.size.height * 0.30, 1_200)
        let padded = routeRect.insetBy(dx: -horizontalPadding, dy: -verticalPadding)

        guard viewSize.width > 0, viewSize.height > 0 else {
            move(to: .rect(padded))
            return
        }

        let top = min(0.4, obscuredInsets.top / viewSize.height)
        let bottom = min(0.5, obscuredInsets.bottom / viewSize.height)
        let visible = max(0.25, 1 - top - bottom)

        // A rect is fitted by whichever of its dimensions binds first, and a
        // walking route is usually wide, so growing the height alone does
        // nothing. Give the rect the view's own aspect ratio and it is fitted
        // exactly, leaving the route the share of the height it was given.
        var height = padded.size.height / visible
        var width = padded.size.width
        let aspect = viewSize.width / viewSize.height
        if width / height < aspect {
            width = height * aspect
        } else {
            height = width / aspect
        }

        // Put the route's centre where the middle of the uncovered band falls.
        let centre = 0.5 + (top - bottom) / 2
        move(to: .rect(MKMapRect(
            origin: MKMapPoint(x: padded.midX - width / 2, y: padded.midY - height * centre),
            size: MKMapSize(width: width, height: height)
        )))
    }

    func prepareCurrentLocation(recenter: Bool = false) {
        requestCurrentLocation(
            recenter: recenter,
            reportErrors: false,
            requireFreshLocation: false
        )
    }

    func refreshRealLocationAfterSession() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            self?.refreshRealLocationAfterRestoration()
        }
    }

    /// Keeps the cached position current for the next recentre. The map itself
    /// stays where the user left it.
    func refreshRealLocationAfterRestoration() {
        requestCurrentLocation(
            recenter: false,
            reportErrors: false,
            requireFreshLocation: true
        )
    }

    func showCurrentLocation() {
        if let cachedLocation = cachedRealLocation() {
            // The cache answers instantly but can hold a simulated position: a
            // session's location lingers for a few seconds after it ends, long
            // enough to be captured as the real one. Correct the map once a
            // genuinely current fix arrives.
            center(on: cachedLocation)
            errorMessage = nil
            requestCurrentLocation(
                recenter: true,
                reportErrors: false,
                requireFreshLocation: true
            )
            return
        }

        requestCurrentLocation(
            recenter: true,
            reportErrors: true,
            requireFreshLocation: !isRealLocationCacheTrusted
        )
    }

    func invalidateRealLocationCache() {
        lastRealLocation = nil
        isRealLocationCacheTrusted = false
    }

    private func performSearch(for query: String) async {

        isSearching = true
        errorMessage = nil
        searchSuggestions = []
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else {
                errorMessage = "No matching place found."
                return
            }

            let coordinate = item.location.coordinate
            let target = LocationTarget(
                name: item.name ?? searchQuery,
                subtitle: placeDescription(for: item),
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )

            selectedLocation = target
            move(to: .region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
                )
            ))
            resetSearchField()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Search is unavailable right now."
        }
    }

    private func selectCoordinate(
        _ coordinate: CLLocationCoordinate2D,
        fallbackName: String,
        fallbackDescription: String,
        recenter: Bool
    ) async {
        errorMessage = nil
        let pendingTarget = LocationTarget(
            name: fallbackName,
            subtitle: "Finding nearby address…",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        selectedLocation = pendingTarget

        if recenter {
            move(to: .region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
                )
            ))
        }

        guard let request = MKReverseGeocodingRequest(
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        ) else {
            selectedLocation = LocationTarget(
                name: fallbackName,
                subtitle: fallbackDescription,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            return
        }

        do {
            let items = try await request.mapItems
            guard selectedLocation?.id == pendingTarget.id, let item = items.first else { return }

            selectedLocation = LocationTarget(
                name: item.name ?? fallbackName,
                subtitle: placeDescription(for: item),
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        } catch {
            guard selectedLocation?.id == pendingTarget.id else { return }
            selectedLocation = LocationTarget(
                name: fallbackName,
                subtitle: fallbackDescription,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
    }

    private func coordinateInput(from query: String) -> CoordinateInput {
        let trimmed = query.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "()[]"))
        )
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .notCoordinates }

        let latitudeText = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let longitudeText = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let latitude = Double(latitudeText),
            let longitude = Double(longitudeText)
        else { return .notCoordinates }

        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            return .invalid
        }

        return .coordinate(
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        )
    }

    func clearSearch() {
        resetSearchField()
        errorMessage = nil
    }

    func clearSelectedLocation() {
        selectedLocation = nil
        errorMessage = nil
    }

    private func resetSearchField() {
        searchQuery = ""
        searchSuggestions = []
        searchCompleter.queryFragment = ""
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let suggestions = completer.results.prefix(6).map {
            MapSearchSuggestion(title: $0.title, subtitle: $0.subtitle)
        }

        Task { @MainActor [weak self] in
            self?.searchSuggestions = suggestions
        }
    }

    nonisolated func completer(
        _ completer: MKLocalSearchCompleter,
        didFailWithError error: any Error
    ) {
        Task { @MainActor [weak self] in
            self?.searchSuggestions = []
        }
    }

    private func placeDescription(for item: MKMapItem) -> String {
        let invisibleCharacters = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}")
        )
        let candidates = [
            item.address?.shortAddress,
            item.addressRepresentations?.cityWithContext,
            item.address?.fullAddress
        ]

        for candidate in candidates {
            let detail = candidate?.trimmingCharacters(in: invisibleCharacters) ?? ""
            if !detail.isEmpty {
                return detail
            }
        }
        return "Location details unavailable"
    }

    private func requestCurrentLocation(
        recenter: Bool,
        reportErrors: Bool,
        requireFreshLocation: Bool
    ) {
        shouldReportLocationErrors = reportErrors
        requiresFreshRealLocation = requireFreshLocation
        switch locationManager.authorizationStatus {
        case .notDetermined:
            recenterOnNextRealLocation = recenter
            isFindingRealLocation = recenter
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            recenterOnNextRealLocation = recenter
            isFindingRealLocation = recenter
            locationRequestStartedAt = Date()
            locationManager.startUpdatingLocation()
            locationTimeout?.cancel()
            locationTimeout = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }

                guard let self, self.locationRequestStartedAt != nil else { return }
                // A simulated-location session can take a little longer than a
                // normal location request to hand control back to Core Location.
                // Do not turn a delayed, fresh callback into an error after the
                // session itself has already ended.
                self.isFindingRealLocation = false
                self.errorMessage = nil

                do {
                    try await Task.sleep(for: .seconds(45))
                } catch {
                    return
                }

                guard self.locationRequestStartedAt != nil else { return }
                self.locationManager.stopUpdatingLocation()
                self.locationRequestStartedAt = nil
                self.recenterOnNextRealLocation = false
                self.requiresFreshRealLocation = false
            }
        case .denied, .restricted:
            isFindingRealLocation = false
            if recenter && shouldReportLocationErrors {
                errorMessage = "Allow Location access in Settings to show your real position."
            }
        @unknown default:
            break
        }
    }

    private func receiveLocations(_ locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        if requiresFreshRealLocation,
           let locationRequestStartedAt,
           location.timestamp < locationRequestStartedAt.addingTimeInterval(-0.5) {
            return
        }

        lastRealLocation = location
        isRealLocationCacheTrusted = true
        requiresFreshRealLocation = false
        locationManager.stopUpdatingLocation()
        locationTimeout?.cancel()
        locationTimeout = nil
        self.locationRequestStartedAt = nil
        isFindingRealLocation = false

        guard recenterOnNextRealLocation else { return }
        recenterOnNextRealLocation = false
        errorMessage = nil
        center(on: location)
    }

    private func center(on location: CLLocation) {
        move(to: .region(
            MKCoordinateRegion(
                center: MapCoordinateDatum.mapCoordinate(from: location.coordinate),
                span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)
            )
        ))
    }

    private func cachedRealLocation() -> CLLocation? {
        guard isRealLocationCacheTrusted else { return nil }

        let candidates = [lastRealLocation, locationManager.location]
            .compactMap { $0 }
            .filter {
                $0.horizontalAccuracy >= 0
                    && $0.horizontalAccuracy <= 1_000
                    && Date().timeIntervalSince($0.timestamp) <= 300
            }

        return candidates.max { $0.timestamp < $1.timestamp }
    }
}

private enum CoordinateInput {
    case notCoordinates
    case invalid
    case coordinate(CLLocationCoordinate2D)
}

extension MapViewModel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                requestCurrentLocation(
                    recenter: recenterOnNextRealLocation,
                    reportErrors: shouldReportLocationErrors,
                    requireFreshLocation: requiresFreshRealLocation
                )
            case .denied, .restricted:
                isFindingRealLocation = false
                if recenterOnNextRealLocation {
                    recenterOnNextRealLocation = false
                    if shouldReportLocationErrors {
                        errorMessage = "Allow Location access in Settings to show your real position."
                    }
                }
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        MainActor.assumeIsolated {
            receiveLocations(locations)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            let locationError = error as NSError
            if locationError.domain == kCLErrorDomain,
               locationError.code == CLError.Code.locationUnknown.rawValue {
                return
            }

            locationManager.stopUpdatingLocation()
            locationTimeout?.cancel()
            locationTimeout = nil
            locationRequestStartedAt = nil
            isFindingRealLocation = false
            if recenterOnNextRealLocation {
                recenterOnNextRealLocation = false
                if shouldReportLocationErrors {
                    errorMessage = "Your real location is not available yet."
                }
            }
        }
    }
}

struct MapSearchSuggestion: Identifiable, Sendable {
    let title: String
    let subtitle: String

    var id: String {
        "\(title)|\(subtitle)"
    }
}
