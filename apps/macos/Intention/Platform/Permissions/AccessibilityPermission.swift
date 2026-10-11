import AppKit
import ApplicationServices

/// Whether Intention may use Accessibility, which it needs to find the caret
/// in the focused field.
@MainActor
@Observable
final class AccessibilityPermission {
    private(set) var isGranted = AXIsProcessTrusted()
    /// Called when a grant is withdrawn while Intention is running.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onLoss: (() -> Void)?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        // The system posts this when any app's Accessibility grant changes.
        // The trust database updates slightly later, so recheck after a delay.
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main,
            using: Self.notificationHandler(for: self))
    }

    nonisolated static func notificationHandler(for permission: AccessibilityPermission) -> @Sendable (Notification) -> Void {
        { [weak permission] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak permission] in
                permission?.refresh()
            }
        }
    }

    /// Rereads the grant. Call before an operation that needs it.
    @discardableResult
    func refresh() -> Bool {
        let granted = AXIsProcessTrusted()
        let lost = isGranted && !granted
        if granted != isGranted {
            isGranted = granted
            onChange?()
        }
        if lost { onLoss?() }
        return granted
    }

    /// Shows the system prompt that links to Privacy & Security.
    func prompt() {
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6 treats as shared mutable state.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isGranted = AXIsProcessTrustedWithOptions(options)
    }

    /// Asks macOS for the grant and sees the person to the Accessibility
    /// list: by macOS's own alert when it comes up in front, whose button
    /// opens the list, and otherwise by opening the list. A list opened
    /// over the alert would hide it; see `PermissionAlert`.
    func request() {
        Task {
            await PermissionAlert.request(prompt) {
                guard !self.refresh() else { return false }
                self.openSystemSettings()
                return true
            }
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
