#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <dlfcn.h>

extern void IntentionRenderGuardRequire(void);
#import <objc/runtime.h>

// If the guard ever calls through, stop before AppKit can display anything.
// This also makes absence of the guard a safe, failing subprocess test.
static void original(void) {
    fprintf(stderr, "ORIGINAL_ORDERING_IMPLEMENTATION_REACHED\n");
    _Exit(91);
}
static BOOL orderedOut, hidden, policyForwarded;
@interface GuardProbePanel : NSPanel
@end
@implementation GuardProbePanel
- (void)orderFront:(id)sender { original(); }
- (void)orderBack:(id)sender { original(); }
- (void)orderFrontRegardless { original(); }
- (void)makeKeyAndOrderFront:(id)sender { original(); }
- (void)orderWindow:(NSWindowOrderingMode)mode relativeTo:(NSInteger)relative {
    if (mode != NSWindowOut || relative != 73) original();
    orderedOut = YES;
}
- (void)setIsVisible:(BOOL)visible {
    if (visible) original();
    hidden = YES;
}
- (void)makeKeyWindow { original(); }
- (void)makeMainWindow { original(); }
- (void)miniaturize:(id)sender { original(); }
- (void)deminiaturize:(id)sender { original(); }
- (void)toggleFullScreen:(id)sender { original(); }
- (void)beginSheet:(NSWindow *)sheet completionHandler:(void (^)(NSModalResponse))completion { original(); }
- (void)beginCriticalSheet:(NSWindow *)sheet completionHandler:(void (^)(NSModalResponse))completion { original(); }
- (void)addChildWindow:(NSWindow *)window ordered:(NSWindowOrderingMode)mode { original(); }
- (void)addTabbedWindow:(NSWindow *)window ordered:(NSWindowOrderingMode)mode { original(); }
@end
@interface GuardProbeApplication : NSApplication
@end
@implementation GuardProbeApplication
- (void)unhide:(id)sender { original(); }
- (void)unhideWithoutActivation { original(); }
- (void)arrangeInFront:(id)sender { original(); }
- (void)unhideAllApplications:(id)sender { original(); }
- (void)activate { original(); }
- (void)activateIgnoringOtherApps:(BOOL)flag { original(); }
- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)policy {
    if (policy != NSApplicationActivationPolicyProhibited) original();
    policyForwarded = YES;
    return YES;
}
@end

@interface GuardProbeRunningApplication : NSRunningApplication
@end
@implementation GuardProbeRunningApplication
- (BOOL)activateWithOptions:(NSApplicationActivationOptions)options { original(); return NO; }
- (BOOL)activateFromApplication:(NSRunningApplication *)app options:(NSApplicationActivationOptions)options { original(); return NO; }
- (BOOL)unhide { original(); return NO; }
@end
static id rawAllocate(Class cls, SEL selector) { return class_createInstance(cls, 0); }
static void lateOriginal(id object, SEL selector) { original(); }

int main(int argc, const char **argv) {
    fprintf(stderr, "IntentionRenderGuardProbe testing %s (intentionional trap)\n", argc > 1 ? argv[1] : "missing selector");
    fflush(stderr);
    @autoreleasepool {
        IntentionRenderGuardRequire();
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        const char *name = argc > 1 ? argv[1] : "orderFrontRegardless";
        if (strcmp(name, "order-out") == 0 || strcmp(name, "hide") == 0) {
            id panel = class_createInstance([GuardProbePanel class], 0);
            if (strcmp(name, "order-out") == 0) {
                [panel orderWindow:NSWindowOut relativeTo:73];
                if (!orderedOut) return 95;
            } else {
                [panel setIsVisible:NO];
                if (!hidden) return 95;
            }
            puts("ALLOWED_IMPLEMENTATION_REACHED");
            return 0;
        }
        if (strcmp(name, "prohibited-policy") == 0 || strcmp(name, "regular-policy") == 0) {
            id application = class_createInstance([GuardProbeApplication class], 0);
            [application setActivationPolicy:strcmp(name, "prohibited-policy") == 0
                ? NSApplicationActivationPolicyProhibited : NSApplicationActivationPolicyRegular];
            if (!policyForwarded) return 95;
            puts("ALLOWED_IMPLEMENTATION_REACHED");
            return 0;
        }
        if (strcmp(name, "loaded-subclass") == 0) {
            if (argc < 3 || !dlopen(argv[2], RTLD_NOW | RTLD_LOCAL)) _Exit(94);
        } else if (strncmp(name, "late-", 5) == 0) {
            Class late = objc_allocateClassPair([NSPanel class], "GuardLatePanel", 0);
            class_addMethod(late, @selector(orderFrontRegardless), (IMP)lateOriginal, "v@:");
            if (strcmp(name, "late-allocator") == 0) {
                class_addMethod(object_getClass(late), @selector(alloc), (IMP)rawAllocate, "@@:");
            }
            objc_registerClassPair(late);
            if (strcmp(name, "late-inherited") == 0) {
                late = objc_allocateClassPair(late, "GuardLateChildPanel", 0);
                objc_registerClassPair(late);
            }
            if (strcmp(name, "late-allocator") == 0) {
                id raw = [late alloc];
                fprintf(stderr, "PANEL_NEVER_ORDERED\n");
                [raw orderFrontRegardless];
            }
            NSPanel *panel = [[late alloc] initWithContentRect:NSMakeRect(0, 0, 32, 32)
                styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            fprintf(stderr, "PANEL_NEVER_ORDERED\n");
            [panel orderFrontRegardless];
        } else if (strcmp(name, "activateWithOptions:") == 0 ||
                   strcmp(name, "activateFromApplication:options:") == 0 || strcmp(name, "unhide") == 0) {
            id running = class_createInstance([GuardProbeRunningApplication class], 0);
            ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(running, sel_registerName(name), nil, 0);
        } else if (strncmp(name, "activate", 8) == 0 || strncmp(name, "unhide", 6) == 0 ||
                   strcmp(name, "arrangeInFront:") == 0) {
            object_setClass(app, [GuardProbeApplication class]);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(app, sel_registerName(name), YES);
        } else {
            GuardProbePanel *panel = [[GuardProbePanel alloc] initWithContentRect:NSMakeRect(0, 0, 32, 32)
                styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            if (panel.visible) _Exit(92);
            fprintf(stderr, "PANEL_NEVER_ORDERED\n");
            if (strcmp(name, "orderWindow:relativeTo:") == 0) {
                [panel orderWindow:NSWindowAbove relativeTo:0];
            } else if (strcmp(name, "setIsVisible:") == 0) {
                [panel setIsVisible:YES];
            } else {
                ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(panel, sel_registerName(name), nil, NSWindowAbove);
            }
        }
        return 93;
    }
}
