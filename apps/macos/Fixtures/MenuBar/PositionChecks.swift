import AppKit
import SwiftUI
import ObjectiveC

@MainActor private var statusItems: [NSStatusItem] = []
extension NSStatusBar {
    @objc nonisolated func measuredItem(withLength length: CGFloat) -> NSStatusItem {
        nonisolated(unsafe) let item = measuredItem(withLength: length)
        MainActor.assumeIsolated { statusItems.append(item) }
        return item
    }
}

/// Capture only owned button pixels and geometry. Never enumerate other
/// apps' windows or capture the menu bar, Dock or any screen region.
@main struct PositionChecks: App {
    @NSApplicationDelegateAdaptor(PositionDelegate.self) var delegate
    init() {
        let defaults = UserDefaults.standard
        if CommandLine.arguments.contains("--fresh") { defaults.removeObject(forKey: MenuBarPosition.preferredPositionKey) }
        if CommandLine.arguments.contains("--saved") { defaults.set(250, forKey: MenuBarPosition.preferredPositionKey) }
        defaults.synchronize()
        print("position_before=\(defaults.object(forKey: MenuBarPosition.preferredPositionKey) as Any)")
        if CommandLine.arguments.contains("--seed") { MenuBarPosition.seedIfNeeded() }
        defaults.synchronize()
        method_exchangeImplementations(
            class_getInstanceMethod(NSStatusBar.self, #selector(NSStatusBar.statusItem(withLength:)))!,
            class_getInstanceMethod(NSStatusBar.self, #selector(NSStatusBar.measuredItem(withLength:)))!)
    }
    var body: some Scene {
        MenuBarExtra { Button("Synthetic History") {} } label: { Image(nsImage: OwnHandMark.menuBarImage()) }
    }
}
@MainActor final class PositionDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard let item = statusItems.first, let button = item.button, let window = button.window,
                  let screen = window.screen else { print("FAIL missing owned status window"); exit(1) }
            let reference = NSStatusBar.system.statusItem(withLength: 28)
            reference.button?.title = "F"
            try? await Task.sleep(for: .milliseconds(700))
            print("os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
            print("autosave_name=\(item.autosaveName ?? "nil")")
            print("screen=\(screen.frame) notch_top=\(screen.safeAreaInsets.top) right_area=\(screen.auxiliaryTopRightArea as Any)")
            print("owned_item_frame=\(window.frame) owned_reference_frame=\(reference.button?.window?.frame as Any)")
            print("position_readback=\(UserDefaults.standard.object(forKey: MenuBarPosition.preferredPositionKey) as Any)")
            guard item.autosaveName == MenuBarPosition.autosaveName else { print("FAIL SwiftUI status identity changed"); exit(1) }
            if let index = CommandLine.arguments.firstIndex(of: "--picture"), index + 1 < CommandLine.arguments.count,
               let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
                button.cacheDisplay(in: button.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                }
            }
            print("inactive=\(!NSApp.isActive)")
            NSStatusBar.system.removeStatusItem(reference)
            exit(NSApp.isActive ? 1 : 0)
        }
    }
}
