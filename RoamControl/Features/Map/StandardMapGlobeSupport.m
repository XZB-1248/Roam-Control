#import "StandardMapGlobeSupport.h"
#import <MapKit/MapKit.h>
#import <objc/runtime.h>
#import <os/log.h>

// MapKit's cartographic configuration, verified on iOS 27. Keep the complete ABI, including
// its trailing BOOL and padding; do not send this struct through performSelector.
typedef struct {
    long long mapType;
    long long mapDisplayStyle;
    long long projection;
    long long terrainMode;
    long long mapkitUsage;
    long long mapkitClientMode;
    bool isCarDisplay;
} RCCartographicConfiguration;

_Static_assert(sizeof(RCCartographicConfiguration) == 56, "Unexpected MapKit configuration layout");

typedef void (*RCConfigurationSetter)(MKMapView *, SEL, RCCartographicConfiguration, BOOL, BOOL);
static RCConfigurationSetter originalConfigurationSetter;

static void RCSetGlobeConfiguration(
    MKMapView *mapView, SEL selector, RCCartographicConfiguration configuration,
    BOOL onInit, BOOL animated
) {
    if (configuration.mapType == 0) {
        configuration.projection = 1;
        // SwiftUI route overlays can cause _updateCartographicConfigurationOnInit:
        // to downgrade terrain AFTER the configuration factory has returned.
        // Flat terrain (0) plus globe projection produces planar tiles on the
        // sphere and misaligned map labels. Apply the compatible pair at the
        // final setter, including when overlays are added or removed.
        if (configuration.terrainMode == 0) {
            configuration.terrainMode = 1;
        }
    }
    originalConfigurationSetter(mapView, selector, configuration, onInit, animated);
}

BOOL RCInstallStandardMapGlobeSupport(void) {
    static dispatch_once_t onceToken;
    static BOOL installed = NO;
    dispatch_once(&onceToken, ^{
        SEL selector = NSSelectorFromString(@"_setCartographicConfiguration:onInit:animated:");
        Method method = class_getInstanceMethod(MKMapView.class, selector);
        if (!method) {
            os_log_error(OS_LOG_DEFAULT, "Standard map globe unavailable: configuration setter missing");
            return;
        }

        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        if (signature.numberOfArguments != 5
            || strcmp(signature.methodReturnType, @encode(void)) != 0
            || strcmp([signature getArgumentTypeAtIndex:2], @encode(RCCartographicConfiguration)) != 0
            || strcmp([signature getArgumentTypeAtIndex:3], @encode(BOOL)) != 0
            || strcmp([signature getArgumentTypeAtIndex:4], @encode(BOOL)) != 0) {
            os_log_error(OS_LOG_DEFAULT, "Standard map globe unavailable: configuration ABI changed");
            return;
        }

        originalConfigurationSetter = (RCConfigurationSetter)method_getImplementation(method);
        method_setImplementation(method, (IMP)RCSetGlobeConfiguration);
        installed = YES;
    });
    return installed;
}
