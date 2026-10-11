#import "ColorMatching.h"

CGColorRef IntentionCopyMatchedColor(CGColorRef color, CGColorSpaceRef space) {
    // Core Graphics default rendering policy has value zero.
    return CGColorCreateCopyByMatchingToColorSpace(space, 0, color, NULL);
}
