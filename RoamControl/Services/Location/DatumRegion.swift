import CoreLocation
import Foundation

/// The area whose map data carries the GCJ-02 offset: Natural Earth's 1:10m
/// boundaries for China, Hong Kong, Macau and Taiwan.
///
/// The received wisdom that the offset stops at the mainland border is wrong for
/// what MapKit actually reports — a location set in Hong Kong lands 600 m
/// south-east without the conversion. Hong Kong was measured; Macau and Taiwan
/// are included because they are served from the same map data, not because
/// anyone has tried them. Settings can override the decision either way.
enum DatumRegion {
    static func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard let rings = loaded else { return false }
        if let cached = cache.value(for: coordinate) { return cached }

        let isInside = rings.contains(coordinate)
        cache.store(isInside, for: coordinate)
        return isInside
    }

    private static let loaded = Rings(
        resource: "ChinaDatumRegion",
        extension: "bin"
    )

    private static let cache = LastAnswer()
}

/// A single remembered answer. The largest ring runs to twelve thousand points,
/// and views ask about the same coordinate on every redraw.
private final class LastAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var key: CLLocationCoordinate2D?
    private var answer = false

    func value(for coordinate: CLLocationCoordinate2D) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard let key, key.latitude == coordinate.latitude, key.longitude == coordinate.longitude
        else { return nil }
        return answer
    }

    func store(_ value: Bool, for coordinate: CLLocationCoordinate2D) {
        lock.lock()
        defer { lock.unlock() }
        key = coordinate
        answer = value
    }
}

/// A packed set of polygon rings: a global bounding box, per-ring bounding
/// boxes, then every vertex as a pair of `Float32`.
private struct Rings {
    private struct Ring {
        let minLongitude, minLatitude, maxLongitude, maxLatitude: Float
        let offset, count: Int
    }

    private let rings: [Ring]
    private let points: [Float]
    private let minLongitude, minLatitude, maxLongitude, maxLatitude: Float

    init?(resource: String, extension fileExtension: String) {
        guard
            let url = Bundle.main.url(forResource: resource, withExtension: fileExtension),
            let data = try? Data(contentsOf: url),
            data.count > 24,
            data.prefix(4).elementsEqual("RCGO".utf8)
        else { return nil }

        var cursor = 6
        let ringCount = Int(data.value(UInt16.self, at: &cursor))
        minLongitude = data.value(Float.self, at: &cursor)
        minLatitude = data.value(Float.self, at: &cursor)
        maxLongitude = data.value(Float.self, at: &cursor)
        maxLatitude = data.value(Float.self, at: &cursor)

        var rings: [Ring] = []
        rings.reserveCapacity(ringCount)
        for _ in 0..<ringCount {
            rings.append(Ring(
                minLongitude: data.value(Float.self, at: &cursor),
                minLatitude: data.value(Float.self, at: &cursor),
                maxLongitude: data.value(Float.self, at: &cursor),
                maxLatitude: data.value(Float.self, at: &cursor),
                offset: Int(data.value(UInt32.self, at: &cursor)),
                count: Int(data.value(UInt32.self, at: &cursor))
            ))
        }
        self.rings = rings

        let remaining = (data.count - cursor) / MemoryLayout<Float>.size
        var points = [Float](repeating: 0, count: remaining)
        for index in 0..<remaining {
            points[index] = data.value(Float.self, at: &cursor)
        }
        self.points = points
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let x = Float(coordinate.longitude)
        let y = Float(coordinate.latitude)
        guard x >= minLongitude, x <= maxLongitude, y >= minLatitude, y <= maxLatitude else {
            return false
        }

        // Crossings are counted across every ring rather than per ring, so a
        // point inside a hole crosses twice and correctly reads as outside.
        var isInside = false
        for ring in rings {
            guard x >= ring.minLongitude, x <= ring.maxLongitude,
                  y >= ring.minLatitude, y <= ring.maxLatitude
            else { continue }

            var j = ring.count - 1
            for i in 0..<ring.count {
                let xi = points[2 * (ring.offset + i)]
                let yi = points[2 * (ring.offset + i) + 1]
                let xj = points[2 * (ring.offset + j)]
                let yj = points[2 * (ring.offset + j) + 1]

                if (yi > y) != (yj > y),
                   x < (xj - xi) * (y - yi) / (yj - yi) + xi {
                    isInside.toggle()
                }
                j = i
            }
        }
        if isInside { return true }

        // The coastline is drawn at 1:10m, so reclaimed land reads as sea —
        // Hong Kong's Central sits 64 m outside it. Coastal water belongs to the
        // same offset map data anyway, so a margin is closer to the truth there.
        // It also reaches across land borders, where it is wrong, but nobody
        // sets a location within a kilometre of one.
        return isWithinMargin(x: x, y: y)
    }

    private func isWithinMargin(x: Float, y: Float) -> Bool {
        let latitudeMargin = Self.marginMetres / 111_320
        let cosLatitude = cos(y * .pi / 180)
        let longitudeMargin = cosLatitude > 0.01 ? latitudeMargin / cosLatitude : latitudeMargin

        guard x >= minLongitude - longitudeMargin, x <= maxLongitude + longitudeMargin,
              y >= minLatitude - latitudeMargin, y <= maxLatitude + latitudeMargin
        else { return false }

        let limit = Self.marginMetres * Self.marginMetres
        for ring in rings {
            guard x >= ring.minLongitude - longitudeMargin,
                  x <= ring.maxLongitude + longitudeMargin,
                  y >= ring.minLatitude - latitudeMargin,
                  y <= ring.maxLatitude + latitudeMargin
            else { continue }

            var j = ring.count - 1
            for i in 0..<ring.count {
                let squared = Self.squaredDistance(
                    x: x, y: y, cosLatitude: cosLatitude,
                    x1: points[2 * (ring.offset + j)], y1: points[2 * (ring.offset + j) + 1],
                    x2: points[2 * (ring.offset + i)], y2: points[2 * (ring.offset + i) + 1]
                )
                if squared <= limit { return true }
                j = i
            }
        }
        return false
    }

    private static let marginMetres: Float = 1_000

    private static func squaredDistance(
        x: Float, y: Float, cosLatitude: Float,
        x1: Float, y1: Float, x2: Float, y2: Float
    ) -> Float {
        let px = (x - x1) * cosLatitude * 111_320
        let py = (y - y1) * 111_320
        let dx = (x2 - x1) * cosLatitude * 111_320
        let dy = (y2 - y1) * 111_320

        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? max(0, min(1, (px * dx + py * dy) / lengthSquared)) : 0
        let ox = px - t * dx
        let oy = py - t * dy
        return ox * ox + oy * oy
    }
}

private extension Data {
    func value<T>(_ type: T.Type, at cursor: inout Int) -> T {
        let size = MemoryLayout<T>.size
        let value = withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: type) }
        cursor += size
        return value
    }
}
