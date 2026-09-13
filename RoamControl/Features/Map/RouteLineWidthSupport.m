#import "RouteLineWidthSupport.h"
#import <objc/runtime.h>
#import <stdatomic.h>
#import <math.h>

@interface RCRouteLineWidthState : NSObject {
@public
    _Atomic(double) zoomScale;
}
@property (nonatomic, strong) MKPolyline *polyline;
@end
@implementation RCRouteLineWidthState
@end

static char routeLineWidthKey;
static char mapLineWidthKey;
static void (*originalApplyStroke)(MKOverlayPathRenderer *, SEL, CGContextRef, MKZoomScale);
static void (*originalSetMapView)(MKOverlayRenderer *, SEL, MKMapView *);
static SEL zoomScaleSelector;

static BOOL RCRendererMatchesRoute(MKOverlayRenderer *renderer, RCRouteLineWidthState *state) {
    if (!state || ![renderer isKindOfClass:MKPolylineRenderer.class]) return NO;
    MKPolyline *candidate = ((MKPolylineRenderer *)renderer).polyline;
    MKPolyline *route = state.polyline;
    return candidate.pointCount == route.pointCount
        && memcmp(candidate.points, route.points, route.pointCount * sizeof(MKMapPoint)) == 0;
}

static void RCSetRouteMapView(MKOverlayRenderer *renderer, SEL selector, MKMapView *mapView) {
    RCRouteLineWidthState *state = objc_getAssociatedObject(mapView, &mapLineWidthKey);
    if (RCRendererMatchesRoute(renderer, state)) {
        // SwiftUI replaces renderers during camera updates. Attach the shared
        // scale before the first tile is drawn, not one display-link tick later.
        objc_setAssociatedObject(renderer, &routeLineWidthKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    originalSetMapView(renderer, selector, mapView);
}

static void RCApplyRouteStroke(
    MKOverlayPathRenderer *renderer, SEL selector, CGContextRef context, MKZoomScale tileScale
) {
    originalApplyStroke(renderer, selector, context, tileScale);
    RCRouteLineWidthState *state = objc_getAssociatedObject(renderer, &routeLineWidthKey);
    if (!state) return;

    double scale = atomic_load_explicit(&state->zoomScale, memory_order_relaxed);
    if (isfinite(scale) && scale > 0 && renderer.lineWidth > 0) {
        // Raster tiles use discrete zoom levels and otherwise scale their cached
        // stroke during a pinch. Use the live points-to-map-points scale instead.
        // Unlike tileScale, this scale already excludes the display pixel density.
        CGContextSetLineWidth(context, renderer.lineWidth / scale);
    }
}

static BOOL RCInstallRouteLineWidthSupport(void) {
    static dispatch_once_t onceToken;
    static BOOL installed;
    dispatch_once(&onceToken, ^{
        zoomScaleSelector = NSSelectorFromString(@"_zoomScale");
        Method zoomMethod = class_getInstanceMethod(MKMapView.class, zoomScaleSelector);
        Method strokeMethod = class_getInstanceMethod(
            MKOverlayPathRenderer.class, @selector(applyStrokePropertiesToContext:atZoomScale:)
        );
        Method mapMethod = class_getInstanceMethod(MKOverlayRenderer.class, NSSelectorFromString(@"_setMapView:"));
        if (!zoomMethod || !strokeMethod || !mapMethod) return;

        NSMethodSignature *zoomSignature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(zoomMethod)];
        NSMethodSignature *strokeSignature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(strokeMethod)];
        NSMethodSignature *mapSignature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(mapMethod)];
        if (zoomSignature.numberOfArguments != 2
            || strcmp(zoomSignature.methodReturnType, @encode(MKZoomScale)) != 0
            || strokeSignature.numberOfArguments != 4
            || strcmp(strokeSignature.methodReturnType, @encode(void)) != 0
            || strcmp([strokeSignature getArgumentTypeAtIndex:2], @encode(CGContextRef)) != 0
            || strcmp([strokeSignature getArgumentTypeAtIndex:3], @encode(MKZoomScale)) != 0
            || mapSignature.numberOfArguments != 3
            || strcmp(mapSignature.methodReturnType, @encode(void)) != 0
            || strcmp([mapSignature getArgumentTypeAtIndex:2], @encode(id)) != 0) return;

        originalApplyStroke = (void *)method_getImplementation(strokeMethod);
        originalSetMapView = (void *)method_getImplementation(mapMethod);
        method_setImplementation(strokeMethod, (IMP)RCApplyRouteStroke);
        method_setImplementation(mapMethod, (IMP)RCSetRouteMapView);
        installed = YES;
    });
    return installed;
}

BOOL RCRefreshRouteLineWidth(MKMapView *mapView, MKPolyline *polyline) {
    if (!RCInstallRouteLineWidthSupport()) return NO;
    double scale = ((MKZoomScale (*)(id, SEL))[mapView methodForSelector:zoomScaleSelector])(mapView, zoomScaleSelector);
    if (!isfinite(scale) || scale <= 0) return NO;

    RCRouteLineWidthState *state = objc_getAssociatedObject(mapView, &mapLineWidthKey);
    BOOL changed = NO;
    if (!state || state.polyline != polyline) {
        state = [RCRouteLineWidthState new];
        state.polyline = polyline;
        atomic_init(&state->zoomScale, scale);
        objc_setAssociatedObject(mapView, &mapLineWidthKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        changed = YES;
    } else {
        double previous = atomic_load_explicit(&state->zoomScale, memory_order_relaxed);
        // Ignore subpixel changes, pan-only updates and settled cameras.
        if (fabs(scale / previous - 1) >= 0.0025) {
            atomic_store_explicit(&state->zoomScale, scale, memory_order_relaxed);
            changed = YES;
        }
    }
    for (id<MKOverlay> overlay in mapView.overlays) {
        MKOverlayRenderer *renderer = [mapView rendererForOverlay:overlay];
        BOOL attached = objc_getAssociatedObject(renderer, &routeLineWidthKey) != state;
        if (attached) {
            if (!RCRendererMatchesRoute(renderer, state)) continue;
            objc_setAssociatedObject(renderer, &routeLineWidthKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (changed || attached) [renderer setNeedsDisplay];
    }
    return changed;
}

void RCClearRouteLineWidth(MKMapView *mapView) {
    objc_setAssociatedObject(mapView, &mapLineWidthKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Existing renderers may still draw fading tiles. Their state is released
    // with them; retain the last width without scheduling any further redraws.
}
