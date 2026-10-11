import AppKit
import QuartzCore

/// Synthetic foot slips, drawn by cacheDisplay without ordering a window.
@main
struct FnSlipShots: GuardedRender {
    @MainActor static func render() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        SetupStyle.registerFonts()
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let before = CommandLine.arguments.contains("--before")
        let messages = [
            ("failed", "Can't hear fn, quit and reopen Intention"),
            ("secure", "Secure input is blocking fn"),
            ("accessibility", "Allow Accessibility to use fn"),
            ("short", "Hold fn to dictate")
        ]
        for dark in [false, true] {
            for (name, message) in messages {
                let size = CGSize(width: 720, height: 180)
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let desk = NSView(frame: CGRect(origin: .zero, size: size))
                desk.wantsLayer = true
                desk.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.08, green: 0.1, blue: 0.16, alpha: 1) : NSColor(srgbRed: 0.92, green: 0.93, blue: 0.91, alpha: 1)).cgColor
                let mark = SunDotView(frame: CGRect(x: 40, y: 50, width: 640, height: 80))
                mark.reducesMotion = { true }
                mark.increasesContrast = { false }
                mark.sky = dark ? .moon : .sun
                desk.addSubview(mark)
                window.contentView = desk
                mark.slip = before ? nil : FootSlip(text: message)
                desk.layoutSubtreeIfNeeded()
                desk.displayIfNeeded()
                func finish(_ layer: CALayer) {
                    layer.removeAllAnimations()
                    layer.sublayers?.forEach(finish)
                }
                if let layer = desk.layer { finish(layer) }
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 360,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
                bitmap.size = size
                desk.cacheDisplay(in: desk.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: directory.appendingPathComponent("foot-\(name)-\(dark ? "night" : "day").png"))
                precondition(!window.isVisible && !app.isActive)
                window.contentView = nil
            }
        }
    }
}
