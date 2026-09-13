#import "NativeRouteSupport.h"
#import <objc/runtime.h>
#import <os/log.h>

// Protocol declarations preserve ARC's ownership rules for private initializers.
// Classes are resolved at runtime; there is no private framework link dependency.
@protocol RCRouteInternals <NSObject>
- (id)_geoComposedRoute;
- (id)vk_mapLayer;
- (void)_addVectorOverlay:(id)overlay;
- (void)_removeVectorOverlay:(id)overlay;
- (id)routeContext;
- (void)setRouteContext:(id)context;
- (instancetype)initWithComposedRoute:(id)route traffic:(id)traffic;
- (instancetype)initWithComposedRoute:(id)route useType:(unsigned char)useType;
- (void)setSelected:(BOOL)selected;
@end

static BOOL RCHasSignature(Class cls, SEL selector, char result, const char *arguments) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) { return NO; }
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    size_t count = strlen(arguments);
    // These interfaces have single-code encodings. In particular, an object (@)
    // and a block (@?) must not pass the same ABI check.
    if (signature.numberOfArguments != count + 2
        || signature.methodReturnType[0] != result || signature.methodReturnType[1] != '\0') {
        return NO;
    }
    for (NSUInteger index = 0; index < count; index++) {
        const char *actual = [signature getArgumentTypeAtIndex:index + 2];
        if (actual[0] != arguments[index] || actual[1] != '\0') { return NO; }
    }
    return YES;
}

@implementation RCNativeRouteSession {
    __weak MKMapView *_mapView;
    id<RCRouteInternals> _layer;
    id _overlay;
    id _context;
    id _previousContext;
}

- (instancetype)initWithMapView:(MKMapView *)mapView route:(MKRoute *)route {
    self = [super init];
    if (!self) { return nil; }
    Class overlayClass = NSClassFromString(@"VKPolylineOverlay");
    Class contextClass = NSClassFromString(@"VKRouteContext");
    if (!RCHasSignature(mapView.class, @selector(vk_mapLayer), '@', "")
        || !RCHasSignature(mapView.class, @selector(_addVectorOverlay:), 'v', "@")
        || !RCHasSignature(mapView.class, @selector(_removeVectorOverlay:), 'v', "@")
        || !RCHasSignature(route.class, @selector(_geoComposedRoute), '@', "")
        || !RCHasSignature(overlayClass, @selector(initWithComposedRoute:traffic:), '@', "@@")
        || !RCHasSignature(overlayClass, @selector(setSelected:), 'v', @encode(BOOL))
        || !RCHasSignature(contextClass, @selector(initWithComposedRoute:useType:), '@', "@C")) {
        os_log_error(OS_LOG_DEFAULT, "Native route unavailable: private API missing or incompatible");
        return nil;
    }

    id<RCRouteInternals> layer = [(id<RCRouteInternals>)mapView vk_mapLayer];
    if (!RCHasSignature([layer class], @selector(routeContext), '@', "")
        || !RCHasSignature([layer class], @selector(setRouteContext:), 'v', "@")) {
        os_log_error(OS_LOG_DEFAULT, "Native route unavailable: map layer API missing or incompatible");
        return nil;
    }
    id composedRoute = [(id<RCRouteInternals>)route _geoComposedRoute];
    if (!composedRoute) { return nil; }
    id<RCRouteInternals> overlay = [(id<RCRouteInternals>)[overlayClass alloc]
        initWithComposedRoute:composedRoute traffic:nil];
    // Use type 0 displays the route without starting a navigation session.
    id context = [(id<RCRouteInternals>)[contextClass alloc]
        initWithComposedRoute:composedRoute useType:0];
    if (!overlay || !context) { return nil; }

    _mapView = mapView;
    _route = route;
    _layer = layer;
    _overlay = overlay;
    _context = context;
    _previousContext = [layer routeContext];
    [overlay setSelected:YES];
    [(id<RCRouteInternals>)mapView _addVectorOverlay:overlay];
    // The navigation render layer needs a matching context even for a preview.
    [layer setRouteContext:context];
    return self;
}

- (void)invalidate {
    if (!_overlay) { return; }
    [(id<RCRouteInternals>)_mapView _removeVectorOverlay:_overlay];
    // Do not overwrite a context installed by another map client after ours.
    if ([_layer routeContext] == _context) {
        [_layer setRouteContext:_previousContext];
    }
    _overlay = nil;
    _context = nil;
    _previousContext = nil;
    _layer = nil;
}

- (void)dealloc {
    [self invalidate];
}
@end
