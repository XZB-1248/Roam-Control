import MapKit
import SwiftUI

/// Keeps only the walking route's raster stroke at its screen-space width.
/// Camera changes wake a short-lived display link, including during touch tracking.
struct RouteLineWidthUpdater: UIViewRepresentable {
    let polyline: MKPolyline?
    let camera: MapCamera?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        context.coordinator.anchor = view
        view.didAttach = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleRefresh()
        }
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        // The continuous camera value makes SwiftUI deliver in-gesture updates.
        context.coordinator.setPolyline(polyline)
        context.coordinator.scheduleRefresh()
    }

    static func dismantleUIView(_ uiView: AnchorView, coordinator: Coordinator) {
        uiView.didAttach = nil
        coordinator.stop()
    }

    final class AnchorView: UIView {
        var didAttach: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            didAttach?()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var anchor: AnchorView?
        private weak var mapView: MKMapView?
        private var polyline: MKPolyline?
        private var displayLink: CADisplayLink?
        private var remainingFrames = 0

        func setPolyline(_ polyline: MKPolyline?) {
            guard self.polyline !== polyline else { return }
            self.polyline = polyline
            if polyline == nil { stop() }
        }

        func scheduleRefresh() {
            guard polyline != nil, anchor?.window != nil else {
                displayLink?.isPaused = true
                return
            }
            // Give SwiftUI time to attach/replace its overlay renderer.
            remainingFrames = 6
            if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(refresh))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            displayLink?.isPaused = false
        }

        @objc private func refresh() {
            guard let polyline, anchor?.window != nil else { stop(); return }
            remainingFrames -= 1
            defer {
                if remainingFrames <= 0 { displayLink?.isPaused = true }
            }
            if mapView?.window !== anchor?.window || mapView == nil {
                if let mapView { RCClearRouteLineWidth(mapView) }
                mapView = findMapView()
            }
            guard let mapView else { return }

            if RCRefreshRouteLineWidth(mapView, polyline) { remainingFrames = 6 }
        }

        private func findMapView() -> MKMapView? {
            func descendant(of view: UIView) -> MKMapView? {
                if let map = view as? MKMapView { return map }
                for child in view.subviews {
                    if let map = descendant(of: child) { return map }
                }
                return nil
            }
            var ancestor = anchor?.superview
            while let view = ancestor {
                if let map = descendant(of: view) { return map }
                ancestor = view.superview
            }
            return nil
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            if let mapView { RCClearRouteLineWidth(mapView) }
        }
    }
}
