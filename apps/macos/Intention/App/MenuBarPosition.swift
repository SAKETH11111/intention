import Foundation

/// MenuBarExtra names its sole status item "Item-0". Keep it the first and
/// only status scene: changing that identity loses AppKit's saved position.
/// This preference is undocumented, so the native fixture checks the name
/// and geometry as well as the saved value on the OS where it runs.
enum MenuBarPosition {
    static let autosaveName = "Item-0"
    static let preferredPositionKey = "NSStatusItem Preferred Position \(autosaveName)"

    /// Run before SwiftUI builds the status scene. AppKit treats zero as
    /// an unset position on the tested OS; one places it at the right end.
    /// A saved position, including zero, belongs to the person and survives.
    static func seedIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: preferredPositionKey) == nil else { return }
        defaults.set(1, forKey: preferredPositionKey)
        // AppKit can read the preference outside UserDefaults' process cache.
        defaults.synchronize()
    }
}
