import AppKit

/// A window that takes Command-W and the editing keys itself: Intention lives
/// in the menu bar, so no menu of its own is shown to hold them. Intention's
/// main window and the Report a problem prompt are both one.
final class KeyWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let shift = event.modifierFlags.contains(.shift)
        let action: Selector? = switch key {
        case "w" where !shift: #selector(NSWindow.performClose(_:))
        case "x" where !shift: #selector(NSText.cut(_:))
        case "c" where !shift: #selector(NSText.copy(_:))
        case "v" where !shift: #selector(NSText.paste(_:))
        case "a" where !shift: #selector(NSText.selectAll(_:))
        case "z": shift ? Selector(("redo:")) : Selector(("undo:"))
        default: nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}
