#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <execinfo.h>
#import <pthread.h>
#import <dlfcn.h>

// This library is linked only by render/test scripts. Its +load installs
// before executable +load methods and Swift stored-property initialization.
static BOOL installed;
static BOOL renderGuardEnabled;
static Class windowBase, applicationBase, runningApplicationBase, soundBase, responderBase;
static pthread_mutex_t registryLock = PTHREAD_MUTEX_INITIALIZER;
struct GuardedMethod { Method method; IMP replacement; struct GuardedMethod *next; };
static struct GuardedMethod *guardedMethods;
static void fail(id object, SEL selector) __attribute__((noreturn));
static void fail(id object, SEL selector) {
    fprintf(stderr, "OffscreenRenderGuard fatal: %s %s attempted screen presentation; caller stack follows\n",
            class_getName(object_getClass(object)), sel_getName(selector));
    void *stack[64];
    int count = backtrace(stack, 64);
    backtrace_symbols_fd(stack, count, STDERR_FILENO);
    fflush(stderr);
    abort();
}

static BOOL descendsFrom(Class cls, Class base) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        if (current == base) return YES;
    }
    return NO;
}

// Replace each class's own implementation, so NSPanel and loaded subclasses
// cannot bypass the guard by overriding an ordering selector without super.
static void replace(Class cls, const char *name) {
    SEL selector = sel_registerName(name);
    unsigned count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned i = 0; i < count; ++i) {
        Method method = methods[i];
        if (method_getName(method) != selector) continue;
        IMP original = method_getImplementation(method);
        // Do not hold this lock across ObjC runtime calls. Concurrent scans
        // may install two wrappers; both trap before their captured originals.
        pthread_mutex_lock(&registryLock);
        BOOL alreadyGuarded = NO;
        for (struct GuardedMethod *entry = guardedMethods; entry; entry = entry->next) {
            if (entry->method == method && entry->replacement == original) { alreadyGuarded = YES; break; }
        }
        pthread_mutex_unlock(&registryLock);
        if (alreadyGuarded) continue;
        IMP replacement;
        if (strcmp(name, "play") == 0 || strcmp(name, "resume") == 0) {
            replacement = imp_implementationWithBlock(^BOOL(id object) { return NO; });
        } else if (strcmp(name, "noResponderFor:") == 0) {
            // AppKit can call NSBeep internally without a dyld binding that
            // interposition can replace. Stop unhandled-key beeps at source.
            replacement = imp_implementationWithBlock(^(id object, SEL eventSelector) {});
        } else if (strcmp(name, "beep") == 0) {
            replacement = imp_implementationWithBlock(^(id object) {});
        } else if (strcmp(name, "orderWindow:relativeTo:") == 0) {
            replacement = imp_implementationWithBlock(^(id object, NSWindowOrderingMode mode, NSInteger relative) {
                if (mode != NSWindowOut) fail(object, selector);
                ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))original)(object, selector, mode, relative);
            });
        } else if (strcmp(name, "setIsVisible:") == 0) {
            replacement = imp_implementationWithBlock(^(id object, BOOL visible) {
                if (visible) fail(object, selector);
                ((void (*)(id, SEL, BOOL))original)(object, selector, visible);
            });
        } else if (strcmp(name, "setActivationPolicy:") == 0) {
            replacement = imp_implementationWithBlock(^BOOL(id object, NSApplicationActivationPolicy policy) {
                if (policy != NSApplicationActivationPolicyProhibited) fail(object, selector);
                return ((BOOL (*)(id, SEL, NSApplicationActivationPolicy))original)(object, selector, policy);
            });
        } else {
            // The replacement never returns or examines the extra arguments.
            replacement = (IMP)fail;
        }
        method_setImplementation(method, replacement);
        pthread_mutex_lock(&registryLock);
        struct GuardedMethod *entry = calloc(1, sizeof(*entry));
        if (!entry) abort();
        entry->method = method;
        entry->replacement = replacement;
        entry->next = guardedMethods;
        guardedMethods = entry;
        pthread_mutex_unlock(&registryLock);
    }
    free(methods);
}

static const char *windowSelectors[] = {
    "orderFront:", "orderBack:", "orderFrontRegardless", "makeKeyAndOrderFront:",
    "orderWindow:relativeTo:", "setIsVisible:", "makeKeyWindow", "makeMainWindow",
    "miniaturize:", "deminiaturize:", "toggleFullScreen:", "setOrderedIndex:",
    "beginSheet:completionHandler:", "beginCriticalSheet:completionHandler:",
    "addChildWindow:ordered:", "addTabbedWindow:ordered:", "selectNextTab:", "selectPreviousTab:",
    "moveTabToNewWindow:", "mergeAllWindows:", "toggleTabOverview:", NULL
};
static const char *applicationSelectors[] = {
    "activate", "activateIgnoringOtherApps:", "setActivationPolicy:",
    "unhide:", "unhideWithoutActivation", "arrangeInFront:", "unhideAllApplications:",
    "runModalForWindow:", "beginModalSessionForWindow:",
    "runModalForWindow:relativeToWindow:", "beginModalSessionForWindow:relativeToWindow:",
    "beginSheet:modalForWindow:modalDelegate:didEndSelector:contextInfo:",
    "orderFrontStandardAboutPanel:", "orderFrontStandardAboutPanelWithOptions:",
    "orderFrontCharacterPalette:", NULL
};

static const char *runningApplicationSelectors[] = {
    "activateWithOptions:", "activateFromApplication:options:", "unhide", NULL
};

static void guardClass(Class cls) {
    if (!soundBase) return; // Startup registrations precede the initial scan.
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        const char **names;
        if (descendsFrom(current, responderBase)) replace(current, "noResponderFor:");
        if (descendsFrom(current, soundBase)) {
            replace(current, "play");
            replace(current, "resume");
            replace(object_getClass(current), "beep");
            continue;
        }
        if (!renderGuardEnabled) break;
        if (descendsFrom(current, windowBase)) names = windowSelectors;
        else if (descendsFrom(current, applicationBase)) names = applicationSelectors;
        else if (descendsFrom(current, runningApplicationBase)) names = runningApplicationSelectors;
        else break;
        // Recheck methods, rather than caching classes: categories can replace
        // an already guarded method. The method registry avoids wrapper stacks.
        for (; *names; ++names) replace(current, *names);
    }
}

// Registration is independent of +alloc: a legitimate custom allocator can
// use class_createInstance without passing through NSWindow's allocator.
static void guardedRegisterClassPair(Class cls) {
    guardClass(cls);
    objc_registerClassPair(cls);
}
static id guardedCreateInstance(Class cls, size_t extraBytes) {
    guardClass(cls);
    return class_createInstance(cls, extraBytes);
}
static id guardedConstructInstance(Class cls, void *bytes) {
    guardClass(cls);
    return objc_constructInstance(cls, bytes);
}
static id guardedAllocateObject(Class cls, NSUInteger extraBytes, NSZone *zone) {
    guardClass(cls);
    return NSAllocateObject(cls, extraBytes, zone);
}

static void guardAllClasses(void) {
    unsigned count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned i = 0; i < count; ++i) guardClass(classes[i]);
    free(classes);
}
static void *guardedDlopen(const char *path, int mode) {
    void *handle = dlopen(path, mode);
    // Refresh categories on existing classes before returning to the caller.
    // Constructors are covered by the allocation and construction hooks too.
    if (installed && handle) guardAllClasses();
    return handle;
}

// C entry points cover AppKit's unhandled-key beep and missed direct calls.
// Input is forbidden even in sound-only test hosts: posting can beep in a
// different app, outside this process's sound interception.
static void silentBeep(void) {}
static void silentSystemSound(SystemSoundID sound) {}
static void silentSystemSoundWithCompletion(SystemSoundID sound, void (^completion)(void)) {
    if (completion) completion();
}
static void forbiddenEventPost(CGEventTapLocation tap, CGEventRef event) {
    fprintf(stderr, "Intention guard refused CGEventPost in a test or render process\n");
    abort();
}
static void forbiddenEventPostToPid(pid_t pid, CGEventRef event) {
    fprintf(stderr, "Intention guard refused CGEventPostToPid in a test or render process\n");
    abort();
}

// dyld only interposes calls from other images, so the guard is a render-only
// dylib. Its calls below reach the originals and cannot recurse into itself.
#define INTERPOSE(replacementFunction, originalFunction) \
    __attribute__((used, section("__DATA,__interpose"))) static const struct { \
        const void *replacement; const void *original; \
    } interpose_##originalFunction = { (const void *)replacementFunction, (const void *)originalFunction }
INTERPOSE(silentBeep, NSBeep);
INTERPOSE(silentSystemSound, AudioServicesPlaySystemSound);
INTERPOSE(silentSystemSound, AudioServicesPlayAlertSound);
INTERPOSE(silentSystemSoundWithCompletion, AudioServicesPlaySystemSoundWithCompletion);
INTERPOSE(silentSystemSoundWithCompletion, AudioServicesPlayAlertSoundWithCompletion);
INTERPOSE(forbiddenEventPost, CGEventPost);
INTERPOSE(forbiddenEventPostToPid, CGEventPostToPid);
INTERPOSE(guardedRegisterClassPair, objc_registerClassPair);
INTERPOSE(guardedCreateInstance, class_createInstance);
INTERPOSE(guardedConstructInstance, objc_constructInstance);
INTERPOSE(guardedAllocateObject, NSAllocateObject);
INTERPOSE(guardedDlopen, dlopen);

// Also cover subclasses realized or registered after process startup, before
// their first instance can run an initializer that orders itself.
static void guardAllocation(Class cls) {
    Class meta = object_getClass(cls);
    for (const char **name = (const char *[]){"alloc", "allocWithZone:", NULL}; *name; ++name) {
        SEL selector = sel_registerName(*name);
        Method method = class_getInstanceMethod(meta, selector);
        if (!method) continue;
        IMP original = method_getImplementation(method);
        IMP replacement;
        if (strcmp(*name, "alloc") == 0) {
            replacement = imp_implementationWithBlock(^id(Class allocated) {
                guardClass(allocated);
                return ((id (*)(Class, SEL))original)(allocated, selector);
            });
        } else {
            replacement = imp_implementationWithBlock(^id(Class allocated, NSZone *zone) {
                guardClass(allocated);
                return ((id (*)(Class, SEL, NSZone *))original)(allocated, selector, zone);
            });
        }
        // Add to this metaclass; never mutate NSObject's inherited allocator.
        class_replaceMethod(meta, selector, replacement, method_getTypeEncoding(method));
    }
}

static void install(void) {
    // This happens before executable +load methods and Swift globals.
    setenv("INTENTION_SILENT", "1", 1);
#ifndef INTENTION_SOUND_ONLY
    // Silence and XCTest never imply permission to change window behavior.
    // Render launchers opt in before dyld runs this dependency's +load.
    renderGuardEnabled = strcmp(getenv("INTENTION_RENDER_GUARD") ?: "", "1") == 0;
#endif
    @autoreleasepool {
        soundBase = [NSSound class];
        responderBase = [NSResponder class];
        windowBase = [NSWindow class];
        applicationBase = [NSApplication class];
        runningApplicationBase = [NSRunningApplication class];
        guardAllClasses();
        guardAllocation([NSSound class]);
        guardAllocation([NSResponder class]);
        if (renderGuardEnabled) {
            guardAllocation([NSWindow class]);
            guardAllocation([NSPanel class]);
            guardAllocation([NSApplication class]);
            guardAllocation([NSRunningApplication class]);
        }
        installed = YES;
        if (renderGuardEnabled) {
            NSApplication *app = [NSApplication sharedApplication];
            [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
            if (app.activationPolicy != NSApplicationActivationPolicyProhibited) abort();
        }
    }
}

// A required link symbol prevents a render entry point from being built
// without the bootstrap above or without explicit render startup mode.
void IntentionSilentTestGuardRequire(void) {
    if (!installed) abort();
}
#ifndef INTENTION_SOUND_ONLY
void IntentionRenderGuardRequire(void) {
    IntentionSilentTestGuardRequire();
    if (!renderGuardEnabled) {
        fprintf(stderr, "OffscreenRenderGuard requires INTENTION_RENDER_GUARD=1 before process startup\n");
        abort();
    }
}
#endif

// A dependency's +load runs before the executable's +load methods and Swift
// initializers. A C constructor alone is too late for Objective-C +load code.
@interface OffscreenRenderBootstrap : NSObject
@end
@implementation OffscreenRenderBootstrap
+ (void)load { install(); }
@end
