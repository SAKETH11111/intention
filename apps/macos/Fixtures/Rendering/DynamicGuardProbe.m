#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static id rawAllocate(Class cls, SEL selector) { return class_createInstance(cls, 0); }
static void original(id object, SEL selector) {
    fprintf(stderr, "ORIGINAL_ORDERING_IMPLEMENTATION_REACHED\n");
    _Exit(91);
}
int main(int argc, const char **argv) {
    fprintf(stderr, "IntentionRenderGuardDynamicProbe testing dynamic allocation (intentionional trap)\n");
    fflush(stderr);
    if (argc != 2) return 2;
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) return 3;
    void (*requireGuard)(void) = dlsym(library, "IntentionRenderGuardRequire");
    if (!requireGuard) return 4;
    requireGuard();
    Class cls = objc_allocateClassPair([NSPanel class], "GuardDynamicallyLoadedPanel", 0);
    class_addMethod(object_getClass(cls), @selector(alloc), (IMP)rawAllocate, "@@:");
    class_addMethod(cls, @selector(orderFrontRegardless), (IMP)original, "v@:");
    objc_registerClassPair(cls);
    fprintf(stderr, "PANEL_NEVER_ORDERED\n");
    [[cls alloc] orderFrontRegardless];
    return 5;
}
