import AppKit
import Carbon
@testable import Dictation
import Testing

@MainActor
struct PasteShortcutTests {
    /// Calls the actual Carbon entry point without registering a system key.
    nonisolated private static func fire(_ shortcut: PasteShortcut, id: UInt32 = 1) -> OSStatus {
        var event: EventRef?
        let created = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
                                  EventAttributes(kEventAttributeNone), &event)
        guard created == noErr, let event else { return created }
        defer { ReleaseEvent(event) }
        var hotKey = EventHotKeyID(signature: 0x496E7450, id: id)
        let set = SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    MemoryLayout<EventHotKeyID>.size, &hotKey)
        guard set == noErr else { return set }
        return PasteShortcut.eventHandler(nil, event, Unmanaged.passUnretained(shortcut).toOpaque())
    }

    @Test func theHandlerRunsImmediatelyOnMainAndHopsFromABackgroundQueue() async {
        let shortcut = PasteShortcut()
        var presses = 0
        shortcut.onPaste = {
            MainActor.assertIsolated()
            #expect(Thread.isMainThread)
            presses += 1
        }
        #expect(Self.fire(shortcut) == noErr)
        #expect(presses == 1)
        let status = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                #expect(!Thread.isMainThread)
                continuation.resume(returning: Self.fire(shortcut))
            }
        }
        #expect(status == noErr)
        #expect(await AppearanceCallbackTests.eventually { presses == 2 })
    }

    @Test func anotherHotKeyIsNotConsumed() {
        let shortcut = PasteShortcut()
        var presses = 0
        shortcut.onPaste = { presses += 1 }
        #expect(Self.fire(shortcut, id: 2) == OSStatus(eventNotHandledErr))
        #expect(presses == 0)
    }

    @Test func aLayoutChangeReadsTheKeyOnMainFromABackgroundQueue() async {
        let shortcut = PasteShortcut()
        var reads = 0
        shortcut.currentKey = {
            MainActor.assertIsolated()
            #expect(Thread.isMainThread)
            reads += 1
            return UInt32(kVK_ANSI_V)
        }
        shortcut.layoutChanged()
        #expect(reads == 1)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                shortcut.layoutChanged()
                continuation.resume()
            }
        }
        #expect(await AppearanceCallbackTests.eventually { reads == 2 })
    }
}
