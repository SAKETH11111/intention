#import <AppKit/AppKit.h>
#import <objc/runtime.h>

// Loading this fixture cannot present a window, even if the guard fails.
@interface GuardLoadedPanel : NSPanel
@end
@implementation GuardLoadedPanel
+ (id)alloc { return class_createInstance(self, 0); }
+ (void)load {
    fprintf(stderr, "PANEL_NEVER_ORDERED\n");
    [[self alloc] orderFrontRegardless];
}
- (void)orderFrontRegardless {
    fprintf(stderr, "ORIGINAL_ORDERING_IMPLEMENTATION_REACHED\n");
    _Exit(91);
}
@end
