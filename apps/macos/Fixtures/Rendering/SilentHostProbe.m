#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <stdlib.h>

extern void IntentionSilentTestGuardRequire(void);
static BOOL ordered, activated, policySet;

// Safe stand-ins for host startup: the originals record calls without ever
// entering AppKit's window or activation implementations.
@interface IntentionHostProbePanel : NSPanel
@end
@implementation IntentionHostProbePanel
- (void)orderFrontRegardless { ordered = YES; }
@end
@interface IntentionHostProbeApplication : NSApplication
@end
@implementation IntentionHostProbeApplication
- (void)activate { activated = YES; }
- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)policy { policySet = YES; return YES; }
@end
@interface IntentionHostProbeSound : NSSound
@end
@implementation IntentionHostProbeSound
- (BOOL)play { _Exit(91); }
@end

@interface IntentionHostBootstrapProbe : NSObject
@end
@implementation IntentionHostBootstrapProbe
+ (void)load {
    IntentionSilentTestGuardRequire();
    if (NSApp != nil || strcmp(getenv("INTENTION_SILENT") ?: "", "1")) _Exit(92);
    [class_createInstance([IntentionHostProbePanel class], 0) orderFrontRegardless];
    id app = class_createInstance([IntentionHostProbeApplication class], 0);
    [app activate];
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    if (!ordered || !activated || !policySet) _Exit(93);
    if ([class_createInstance([IntentionHostProbeSound class], 0) play]) _Exit(94);
    NSBeep();
    AudioServicesPlaySystemSound(0);
}
@end

int main(void) {
    puts("PASS silent host startup permits window/activation methods and suppresses sound");
    return 0;
}
