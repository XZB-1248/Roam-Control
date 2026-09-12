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

typedef RCCartographicConfiguration (*RCConfigurationFactory)(id, SEL, MKMapConfiguration *);
static RCConfigurationFactory originalConfigurationFactory;

static RCCartographicConfiguration RCGlobeConfiguration(
    id receiver, SEL selector, MKMapConfiguration *configuration
) {
    RCCartographicConfiguration result = originalConfigurationFactory(receiver, selector, configuration);
    if ([configuration isKindOfClass:MKStandardMapConfiguration.class]) {
        // Same projection value used by ForceGlobeProjectionForStandardMap in
        // -[MKMapView _updateCartographicConfigurationOnInit:]. Leave terrain,
        // emphasis and every other field under MapKit's control.
        result.projection = 1;
    }
    return result;
}

BOOL RCInstallStandardMapGlobeSupport(void) {
    static dispatch_once_t onceToken;
    static BOOL installed = NO;
    dispatch_once(&onceToken, ^{
        SEL selector = NSSelectorFromString(@"_cartographicConfigurationForMapConfiguration:");
        Method method = class_getClassMethod(MKMapConfiguration.class, selector);
        if (!method) {
            os_log_error(OS_LOG_DEFAULT, "Standard map globe unavailable: configuration factory missing");
            return;
        }

        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        if (signature.numberOfArguments != 3
            || strcmp(signature.methodReturnType, @encode(RCCartographicConfiguration)) != 0
            || strcmp([signature getArgumentTypeAtIndex:2], @encode(id)) != 0) {
            os_log_error(OS_LOG_DEFAULT, "Standard map globe unavailable: configuration ABI changed");
            return;
        }

        originalConfigurationFactory = (RCConfigurationFactory)method_getImplementation(method);
        method_setImplementation(method, (IMP)RCGlobeConfiguration);
        installed = YES;
    });
    return installed;
}
