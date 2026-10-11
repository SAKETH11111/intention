import Carbon.HIToolbox
import CoreGraphics

/// The only key Intention sends to another app: Command-V for the paste route.
/// Return, Enter, Command-Z and every other key that could send, submit or
/// edit are never posted.
///
/// Events go to one process, never to whichever app happens to be in front,
/// and come from a private event source, so keys the person is holding do
/// not combine with them.
enum KeyEvents {
    enum Key {
        /// Command-V. The key code comes from `pasteKeyCode()`.
        case paste(CGKeyCode)
    }

    static func post(_ key: Key, to pid: pid_t) -> Bool {
        // Normal app insertion remains available. Test and render processes
        // cannot post, even if a fixture check flag was accidentally supplied.
        guard !ProcessSafety.isSilent else { return false }
        #if DEBUG
        if CommandLine.arguments.contains("--insertion-checks"), !ProcessSafety.allowsCheckInput { return false }
        #endif
        let (code, flags): (CGKeyCode, CGEventFlags) = switch key {
        case let .paste(code): (code, .maskCommand)
        }
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    /// The key that types "v" while Command is held in the current layout, so
    /// the paste shortcut also works in Dvorak and other layouts, including
    /// those that switch to QWERTY under Command. Falls back to the ANSI V
    /// position. Text Input Sources must be read on the main thread.
    @MainActor
    static func pasteKeyCode() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let command = UInt32((cmdKey >> 8) & 0xFF)
        return data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return fallback }
            for code in 0..<UInt16(128) {
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), command, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys, 4, &length, &characters)
                if status == noErr, length == 1, characters[0] == UniChar(UInt8(ascii: "v")) { return CGKeyCode(code) }
            }
            return fallback
        }
    }
}
