import Foundation
import ServiceManagement

/// Whether macOS opens Intention at login, through the app's own login item.
/// The person can also turn it off in System Settings > General > Login
/// Items, so the status is reread rather than remembered.
@MainActor
@Observable
final class LoginItem {
    enum State: Equatable {
        case on
        /// Registered, but the person must allow it in Login Items.
        case needsApproval
        case off
    }

    private(set) var state: State = .off
    /// The last registration error, shown in Settings until the next change.
    private(set) var failure: String?

    init() { refresh() }

    func refresh() {
        state = switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    /// Whether this copy of Intention is installed in /Applications or
    /// ~/Applications. A copy run from the disk image, Downloads or a
    /// translocated path can move or disappear, which would leave a login item
    /// that opens nothing.
    static func isStable(bundle: URL = Bundle.main.bundleURL,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = bundle.standardizedFileURL.resolvingSymlinksInPath().path
        return [URL(fileURLWithPath: "/Applications"), home.appending(path: "Applications")].contains {
            path.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/")
        }
    }

    /// Registers or unregisters at once. The caller decides whether this
    /// copy is one to register; see `isStable`.
    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            failure = nil
        } catch {
            AppLog.event("Login item change failed")
            failure = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
