import CoreLocation
import Foundation

/// Translates between the datum MapKit reports and the WGS-84 the device's
/// location simulation expects.
///
/// Mainland China is surveyed in GCJ-02, which offsets WGS-84 by around 600 m in
/// a direction that varies with position: south-east at 22.8°N, north-east
/// further north. Assuming a constant direction sends corrections the wrong way.
///
/// The offset has no published formula. The polynomials below are its
/// long-established reconstruction on the Krasovsky 1940 ellipsoid.
enum MapCoordinateDatum {
    static func wgs84(from mapCoordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isOffset(mapCoordinate) else { return mapCoordinate }

        // No closed-form inverse exists, so converge on it: each pass corrects
        // by however far the current guess lands from the target once offset.
        var estimate = mapCoordinate
        for _ in 0..<inverseRefinementPasses {
            let offset = offsetting(estimate)
            estimate.latitude += mapCoordinate.latitude - offset.latitude
            estimate.longitude += mapCoordinate.longitude - offset.longitude
        }
        return estimate
    }

    /// The conventional bounding box for mainland China. It over-reaches: Hong
    /// Kong, Macau, Taiwan, Seoul, Bangkok and Hanoi all sit inside it but are
    /// surveyed in WGS-84.
    static func isOffset(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.longitude >= 72.004
            && coordinate.longitude <= 137.8347
            && coordinate.latitude >= 0.8293
            && coordinate.latitude <= 55.8271
    }

    // MARK: - The offset

    private static let inverseRefinementPasses = 4
    private static let semiMajorAxis = 6_378_245.0
    private static let eccentricitySquared = 0.006_693_421_622_965_943

    private static func offsetting(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let x = coordinate.longitude - 105.0
        let y = coordinate.latitude - 35.0

        let latitudeRadians = coordinate.latitude / 180.0 * .pi
        let sinLatitude = sin(latitudeRadians)
        let magic = 1 - eccentricitySquared * sinLatitude * sinLatitude
        let magicRoot = magic.squareRoot()

        let latitudeShift = (latitudePolynomial(x, y) * 180.0)
            / ((semiMajorAxis * (1 - eccentricitySquared)) / (magic * magicRoot) * .pi)
        let longitudeShift = (longitudePolynomial(x, y) * 180.0)
            / (semiMajorAxis / magicRoot * cos(latitudeRadians) * .pi)

        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + latitudeShift,
            longitude: coordinate.longitude + longitudeShift
        )
    }

    private static func latitudePolynomial(_ x: Double, _ y: Double) -> Double {
        var value = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * abs(x).squareRoot()
        value += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        value += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        value += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return value
    }

    private static func longitudePolynomial(_ x: Double, _ y: Double) -> Double {
        var value = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * abs(x).squareRoot()
        value += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        value += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        value += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return value
    }
}
