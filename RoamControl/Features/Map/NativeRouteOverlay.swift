import MapKit
import SwiftUI

/// Attaches the native navigation vector overlay to SwiftUI's existing map.
struct NativeRouteOverlay: UIViewRepresentable {
    let route: MKRoute?
    @Binding var renderedRoute: MKRoute?

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
        context.coordinator.route = route
        context.coordinator.didRender = { route in
            if renderedRoute !== route { renderedRoute = route }
        }
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
    final class Coordinator {
        weak var anchor: AnchorView?
        var route: MKRoute?
        var didRender: ((MKRoute?) -> Void)?
        private var session: RCNativeRouteSession?
        private var refreshPending = false
        private var stopped = false
        private weak var attemptedMap: MKMapView?
        private var attemptedRoute: MKRoute?

        func scheduleRefresh() {
            guard !stopped, !refreshPending else { return }
            refreshPending = true
            // Wait for SwiftUI to attach its sibling map, and publish state outside
            // updateUIView. No display link or per-frame raster invalidation.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.refreshPending = false
                self.refresh()
            }
        }

        private func refresh() {
            guard anchor?.window != nil, let route, let map = findMapView() else {
                session?.invalidate()
                session = nil
                attemptedMap = nil
                attemptedRoute = nil
                didRender?(nil)
                return
            }
            if attemptedMap !== map || attemptedRoute !== route {
                session?.invalidate()
                session = nil
                attemptedMap = map
                attemptedRoute = route
                session = RCNativeRouteSession(mapView: map, route: route)
            }
            didRender?(session?.route)
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
            stopped = true
            didRender = nil
            session?.invalidate()
            session = nil
        }
    }
}
