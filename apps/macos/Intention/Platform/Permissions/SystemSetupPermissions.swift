import AppKit
import AVFoundation

/// The real grants, read from and requested of macOS.
extension SetupPermissions {
    @MainActor
    static func system(accessibility: AccessibilityPermission, clipboard: PasteboardOwner) -> SetupPermissions {
        SetupPermissions(
            isGranted: { permission in
                switch permission {
                case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                case .accessibility: accessibility.refresh()
                }
            },
            request: { permission in
                switch permission {
                case .microphone:
                    // macOS asks once, with Allow in its own alert. After a
                    // refusal only the person can change it, in Settings.
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                    } else {
                        open("Privacy_Microphone")
                    }
                case .accessibility:
                    // The prompt is what puts Intention in the list, switched
                    // off, and macOS answers it with an alert whose button
                    // opens the list. A list opened over that alert would
                    // hide it, so setup opens the list only when no alert
                    // comes up in front; see `PermissionAlert`. Setup
                    // cancels this request when its window closes, and
                    // then nothing is opened.
                    await PermissionAlert.request(accessibility.prompt) {
                        guard !accessibility.refresh() else { return false }
                        open("Privacy_Accessibility")
                        return true
                    }
                }
            }
        )
    }

    /// For the menu bar item's "Allow the clipboard…", offered after a paste replaced the person's clipboard.
    /// macOS lists an app under Paste from Other Apps only once a read has
    /// asked, and only the person can make it Allow there
    /// (NSPasteboard.AccessBehavior). So Intention reads once, and the list
    /// opens after macOS's alert is answered, unless the request was
    /// cancelled meanwhile.
    @MainActor
    static func askToReadClipboard(_ clipboard: PasteboardOwner) async {
        await clipboard.askToRead()
        guard !Task.isCancelled, !clipboard.mayReadOtherApps else { return }
        open("Privacy_Pasteboard")
    }

    /// Opens Privacy & Security at one list. This address has worked from
    /// macOS 13 on; the pane it lands on is a page of its own, so nothing
    /// needs scrolling into view.
    @MainActor
    private static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            FrontHandoff.open(url)
        }
    }
}

/// Opens something in another app and lets that app come to the front.
/// Setup insists on being in front when it opens, and macOS then keeps the
/// app it launches behind setup's window unless setup hands the front over.
@MainActor
enum FrontHandoff {
    static func open(_ url: URL) {
        if let app = NSWorkspace.shared.urlForApplication(toOpen: url), let bundle = Bundle(url: app)?.bundleIdentifier {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundle)
        }
        NSWorkspace.shared.open(url)
    }
}
