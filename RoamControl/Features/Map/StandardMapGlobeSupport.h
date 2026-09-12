#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs the process-local Standard map projection adjustment once, before
/// creating any map views. Returns NO when the private interface is unsupported.
FOUNDATION_EXPORT BOOL RCInstallStandardMapGlobeSupport(void);

NS_ASSUME_NONNULL_END
