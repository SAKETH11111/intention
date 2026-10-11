import AppKit
import Carbon

/// Owns only the system shortcut. Dictation decides whether a press can paste.
@MainActor
final class PasteShortcut {
    var onPaste: () -> Void = {}
    /// The key that types V under Command in the current layout, as the
    /// paste route's Command-V finds it, so the shortcut the menu shows is
    /// the one that works in Dvorak and other layouts too.
    var currentKey: () -> UInt32 = { UInt32(KeyEvents.pasteKeyCode()) }
    nonisolated static let signature: OSType = 0x496E7450 // IntP
    nonisolated static let identifier: UInt32 = 1
    nonisolated(unsafe) private var hotKey: EventHotKeyRef?
    nonisolated(unsafe) private var handler: EventHandlerRef?
    nonisolated(unsafe) private var layoutObserver: NSObjectProtocol?
    private var keyCode: UInt32?

    @discardableResult
    func start() -> Bool {
        if hotKey != nil { return true }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), Self.eventHandler, 1, &event,
                                            Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else {
            AppLog.event("pasteShortcut.unavailable")
            return false
        }
        guard register(currentKey()) else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            AppLog.event("pasteShortcut.unavailable")
            return false
        }
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { @Sendable [weak self] _ in self?.layoutChanged() }
        return true
    }

    private func register(_ code: UInt32) -> Bool {
        let id = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        guard RegisterEventHotKey(code, UInt32(controlKey | optionKey | cmdKey), id,
                                  GetApplicationEventTarget(), 0, &hotKey) == noErr else { return false }
        keyCode = code
        return true
    }

    /// Moves the shortcut to V's key in the layout just chosen. Called by
    /// the notification center; reaches the main actor itself.
    nonisolated func layoutChanged() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { follow() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.follow() }
        }
    }

    private func follow() {
        let code = currentKey()
        guard let hotKey, code != keyCode else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
        keyCode = nil
        if !register(code) { AppLog.event("pasteShortcut.unavailable") }
    }

    deinit {
        if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Carbon can call from outside the main actor. Keep this C callback
    /// nonisolated and cross to the actor before running the app's action.
    nonisolated static let eventHandler: EventHandlerUPP = { _, event, context in
        guard let event, let context,
              GetEventClass(event) == OSType(kEventClassKeyboard),
              GetEventKind(event) == UInt32(kEventHotKeyPressed) else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard status == noErr, id.signature == signature, id.id == identifier else { return OSStatus(eventNotHandledErr) }
        Unmanaged<PasteShortcut>.fromOpaque(context).takeUnretainedValue().pressed()
        return noErr
    }

    nonisolated private func pressed() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { onPaste() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.onPaste() }
        }
    }
}
