#import <MapKit/MapKit.h>

NS_ASSUME_NONNULL_BEGIN

// Main-thread updates; MapKit can consume the stored scale on its render threads.
BOOL RCRefreshRouteLineWidth(MKMapView *mapView, MKPolyline *polyline);
void RCClearRouteLineWidth(MKMapView *mapView);

NS_ASSUME_NONNULL_END
