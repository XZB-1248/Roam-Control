#import <MapKit/MapKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Main-thread ownership of one native navigation overlay and its route context.
NS_SWIFT_UI_ACTOR
@interface RCNativeRouteSession : NSObject
@property (nonatomic, strong, readonly) MKRoute *route;
- (nullable instancetype)initWithMapView:(MKMapView *)mapView route:(MKRoute *)route;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
/// Safe to call repeatedly. Removes only this session's overlay/context.
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
