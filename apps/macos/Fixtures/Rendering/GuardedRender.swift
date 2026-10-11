import AppKit
import SwiftUI

@_silgen_name("IntentionRenderGuardRequire")
private func requireRenderGuard()

@MainActor
enum OffscreenRenderGuard {
    static func requireInstalled() { requireRenderGuard() }

    static func prepare() {
        requireRenderGuard()
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSApplication.shared.activationPolicy() == .prohibited else {
            fatalError("OffscreenRenderGuard could not prohibit activation")
        }
    }
}

/// Render workers supply a body, never an unguarded process entry point.
@MainActor
protocol GuardedRender {
    static func render() throws
}

extension GuardedRender {
    static func main() throws {
        OffscreenRenderGuard.prepare()
        if CommandLine.arguments.contains("--render-dry-run") {
            // Exercise the two supported drawing paths without screen capture.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
            window.contentView = view
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                fatalError("OffscreenRenderGuard dry render failed")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard ImageRenderer(content: Color.red.frame(width: 32, height: 32)).cgImage != nil,
                  !window.isVisible, !NSApp.isActive else {
                fatalError("OffscreenRenderGuard dry render failed")
            }
            print("OffscreenRenderGuard dry render passed")
            return
        }
        try render()
    }
}
