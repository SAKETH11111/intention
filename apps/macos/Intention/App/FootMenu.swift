import AppKit

/// The foot dot's own menu, opened by a right click or a Control-click on
/// it, or by VoiceOver's Show Menu on its button: what Wispr Flow's pill
/// offers, in Intention's words. Hide for 1 hour, Settings, the microphone,
/// History, and Paste last dictation with its shortcut. A native menu, as
/// the menu bar's is, so keyboard and VoiceOver work it like any other, and
/// opening it from the foot's non-activating window leaves focus and the
/// caret in the field below, where Paste last dictation puts its text. It
/// holds no rules: what each item does is the app's (`Actions`), and which
/// microphones it lists, in what words and which is chosen, is the shared
/// `MicrophoneMenu`'s, as Settings shows them.
@MainActor
enum FootMenu {
    /// What the items do.
    struct Actions {
        var hide: @MainActor () -> Void
        var settings: @MainActor () -> Void
        var microphone: @MainActor (MicrophonePreference) -> Void
        var history: @MainActor () -> Void
        var pasteLast: @MainActor () -> Void
    }

    /// The shortcut for Paste last dictation, shown beside it: Control,
    /// Option and Command with V. Wispr Flow's own is Control-Command-V, and
    /// people who try Intention often keep Flow, so that one would clash;
    /// Option-Shift-Command-V is Paste and Match Style in most apps;
    /// Control-Option alone is VoiceOver's modifier; Gmail's shortcuts are
    /// single keys and Command-Shift chords; macOS's Control-Option-Command
    /// shortcuts are digits and punctuation, not letters.
    static let pasteKey = "v"
    static let pasteModifiers: NSEvent.ModifierFlags = [.control, .option, .command]

    static func make(microphones: [MicrophoneMenu.Row], canPasteLast: Bool, actions: Actions) -> NSMenu {
        let menu = NSMenu(title: "Intention")
        menu.autoenablesItems = false
        menu.addItem(item("Hide for 1 hour", actions.hide))
        menu.addItem(item("Settings…", actions.settings))
        menu.addItem(.separator())
        let microphone = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let list = NSMenu(title: "Microphone")
        list.autoenablesItems = false
        for (index, row) in microphones.enumerated() {
            // The built-in microphone and the system default, then each
            // device, as Settings lists them. Names only: Settings says
            // "Recommended" on the row's second line, which an item lacks.
            if index == 2 { list.addItem(.separator()) }
            let title = row.title.replacingOccurrences(of: " (recommended)", with: "")
            let choice = item(title) { actions.microphone(row.preference) }
            choice.state = row.isChosen ? .on : .off
            list.addItem(choice)
        }
        microphone.submenu = list
        menu.addItem(microphone)
        menu.addItem(.separator())
        menu.addItem(item("History", actions.history))
        let paste = item("Paste last dictation", actions.pasteLast)
        paste.keyEquivalent = pasteKey
        paste.keyEquivalentModifierMask = pasteModifiers
        paste.isEnabled = canPasteLast
        menu.addItem(paste)
        return menu
    }

    private static func item(_ title: String, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.chosen(_:)), keyEquivalent: "")
        item.target = action
        // The menu item holds its target weakly; this keeps it alive.
        item.representedObject = action
        return item
    }
}

/// One item's action. AppKit calls it on the main thread as the menu
/// closes; it still reaches the main actor itself, as the rule for
/// framework callbacks asks.
final class MenuAction: NSObject, Sendable {
    private let run: @MainActor @Sendable () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        nonisolated(unsafe) let run = run
        self.run = { run() }
    }

    /// Not named `perform(_:)`, which `#selector` would take for NSObject's
    /// own `performSelector:`.
    @objc nonisolated func chosen(_ sender: Any?) {
        let run = run
        guard Thread.isMainThread else {
            DispatchQueue.main.async { MainActor.assumeIsolated { run() } }
            return
        }
        MainActor.assumeIsolated { run() }
    }
}
