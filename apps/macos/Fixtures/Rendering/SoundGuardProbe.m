#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <stdlib.h>

#ifdef INTENTION_SOUND_ONLY
extern void IntentionSilentTestGuardRequire(void);
#define RequireGuard IntentionSilentTestGuardRequire
#else
extern void IntentionRenderGuardRequire(void);
#define RequireGuard IntentionRenderGuardRequire
#endif
// No audio is loaded. If swizzling misses this subclass, fail safely.
@interface IntentionSilentProbeSound : NSSound
@end
@implementation IntentionSilentProbeSound
- (BOOL)play { fprintf(stderr, "ORIGINAL_SOUND_IMPLEMENTATION_REACHED\n"); _Exit(91); }
- (BOOL)resume { fprintf(stderr, "ORIGINAL_SOUND_IMPLEMENTATION_REACHED\n"); _Exit(91); }
@end
@interface IntentionSilentProbeResponder : NSResponder
@end
@implementation IntentionSilentProbeResponder
- (void)noResponderFor:(SEL)selector {
    fprintf(stderr, "ORIGINAL_SOUND_IMPLEMENTATION_REACHED\n");
    _Exit(91);
}
@end
int main(int argc, const char **argv) {
    @autoreleasepool {
#ifndef INTENTION_SOUND_FALLBACK_PROBE
        RequireGuard();
#endif
        if (argc != 2) return 2;
#ifndef INTENTION_SOUND_FALLBACK_PROBE
        if (strcmp(getenv("INTENTION_SILENT") ?: "", "1")) return 2;
#endif
        fprintf(stderr, "IntentionRenderSoundProbe testing %s (must remain silent)\n", argv[1]);
        if (!strcmp(argv[1], "play") || !strcmp(argv[1], "resume")) {
            NSSound *sound = class_createInstance([IntentionSilentProbeSound class], 0);
            BOOL played = !strcmp(argv[1], "play") ? [sound play] : [sound resume];
            if (played) return 3;
        } else if (!strcmp(argv[1], "unhandled-key")) {
            NSResponder *responder = class_createInstance([IntentionSilentProbeResponder class], 0);
            [responder noResponderFor:@selector(keyDown:)];
        } else if (!strcmp(argv[1], "beep")) NSBeep();
        else if (!strcmp(argv[1], "system")) AudioServicesPlaySystemSound(0);
        else if (!strcmp(argv[1], "alert")) AudioServicesPlayAlertSound(0);
        else if (!strcmp(argv[1], "system-completion") || !strcmp(argv[1], "alert-completion")) {
            __block BOOL completed = NO;
            if (!strcmp(argv[1], "system-completion")) AudioServicesPlaySystemSoundWithCompletion(0, ^{ completed = YES; });
            else AudioServicesPlayAlertSoundWithCompletion(0, ^{ completed = YES; });
            if (!completed) return 4;
        } else if (!strcmp(argv[1], "event-post")) CGEventPost(kCGHIDEventTap, NULL);
        else if (!strcmp(argv[1], "event-pid")) CGEventPostToPid(getpid(), NULL);
        else return 5;
        return 0;
    }
}
