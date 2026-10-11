#import <AppKit/AppKit.h>
#import <objc/runtime.h>

@interface GuardEarlyPanel : NSPanel
@end
@implementation GuardEarlyPanel
+ (void)load {
    fprintf(stderr, "IntentionRenderGuardEarlyProbe testing executable +load (intentionional trap)\n");
    fprintf(stderr, "PANEL_NEVER_ORDERED\n");
    id panel = class_createInstance(self, 0);
    [panel orderFrontRegardless];
}
- (void)orderFrontRegardless {
    fprintf(stderr, "ORIGINAL_ORDERING_IMPLEMENTATION_REACHED\n");
    _Exit(91);
}
@end
int main(void) { return 92; }
