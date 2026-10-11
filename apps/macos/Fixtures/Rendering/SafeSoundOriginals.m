// Safe original symbols for the sound interception probes. A broken guard
// reaches these sentinels, never the machine's audio hardware.
#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <stdio.h>
#import <stdlib.h>
static void missed(void) {
    fprintf(stderr, "ORIGINAL_SOUND_IMPLEMENTATION_REACHED\n");
    _Exit(91);
}
static void safeEventPost(CGEventTapLocation tap, CGEventRef event) { missed(); }
static void safeEventPostToPid(pid_t pid, CGEventRef event) { missed(); }
static void safeNSBeep(void) { missed(); }
static void safeAudioServicesPlaySystemSound(SystemSoundID sound) { missed(); }
static void safeAudioServicesPlayAlertSound(SystemSoundID sound) { missed(); }
static void safeAudioServicesPlaySystemSoundWithCompletion(SystemSoundID sound, void (^completion)(void)) { missed(); }
static void safeAudioServicesPlayAlertSoundWithCompletion(SystemSoundID sound, void (^completion)(void)) { missed(); }

#define INTERPOSE(replacementFunction, originalFunction) \
    __attribute__((used, section("__DATA,__interpose"))) static const struct { \
        const void *replacement; const void *original; \
    } interpose_##originalFunction = { (const void *)replacementFunction, (const void *)originalFunction }
INTERPOSE(safeNSBeep, NSBeep);
INTERPOSE(safeAudioServicesPlaySystemSound, AudioServicesPlaySystemSound);
INTERPOSE(safeAudioServicesPlayAlertSound, AudioServicesPlayAlertSound);
INTERPOSE(safeAudioServicesPlaySystemSoundWithCompletion, AudioServicesPlaySystemSoundWithCompletion);
INTERPOSE(safeAudioServicesPlayAlertSoundWithCompletion, AudioServicesPlayAlertSoundWithCompletion);
INTERPOSE(safeEventPost, CGEventPost);
INTERPOSE(safeEventPostToPid, CGEventPostToPid);
