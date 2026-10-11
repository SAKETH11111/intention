import AudioToolbox
import Foundation

/// Set before app code runs by test scripts and the render guard. Read the
/// process environment directly so the guard and Swift share one switch.
enum ProcessSafety {
    static var isSilent: Bool {
        guard let value = getenv("INTENTION_SILENT") else { return false }
        return strcmp(value, "1") == 0
    }

    /// Real fixture input is a separately requested check, never a render.
    static var allowsCheckInput: Bool {
        !isSilent && (CommandLine.arguments.contains("--allow-input-posting")
            || ProcessInfo.processInfo.environment["INTENTION_ALLOW_CHECK_INPUT"] == "1")
    }
}

enum SoundOutput {
    @discardableResult
    static func perform(_ output: () -> Void) -> Bool {
        guard !ProcessSafety.isSilent else { return false }
        output()
        return true
    }

    static func playSystemSound(_ sound: SystemSoundID) {
        perform { AudioServicesPlaySystemSound(sound) }
    }
}
