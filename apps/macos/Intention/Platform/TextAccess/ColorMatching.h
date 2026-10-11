#import <CoreGraphics/CoreGraphics.h>

/// Preserve the source profile's default conversion policy.
CGColorRef _Nullable IntentionCopyMatchedColor(CGColorRef _Nonnull color,
                                               CGColorSpaceRef _Nonnull space) CF_RETURNS_RETAINED;
