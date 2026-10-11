#if OFFSCREEN_RENDER
import AppKit

/// `--foot-menu-snapshot <directory> --onboarding-fixture` opens the foot
/// dot's menu, and then its Microphone list, by day and by night, captures
/// each of Intention's own menu windows to a PNG and quits. The menu is the
/// app's own (`AppModel.footMenu`), listing the made-up microphones Settings
/// renders show (`SettingsSnapshot.inputs`), never this Mac's. A native menu
/// is drawn only on screen, so this runs only inside a screen window the
/// coordinator grants. It captures only windows owned by this process, and
/// logs, without stopping, whether Intention became the active app.
@MainActor
enum FootMenuSnapshot {
    static func renderIfRequested(arguments: [String], model: AppModel) {
        OffscreenRenderGuard.requireInstalled()
        if let index = arguments.firstIndex(of: "--foot-menu-mock"), arguments.indices.contains(index + 1) {
            exit(drawMocks(model: model, to: URL(fileURLWithPath: arguments[index + 1])) ? 0 : 1)
        }
        guard let index = arguments.firstIndex(of: "--foot-menu-snapshot"), arguments.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A borderless window that is never ordered front, for the menu's
        // place on screen: the middle of the main display's lower third.
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = NSWindow(contentRect: CGRect(x: screen.midX - 10, y: screen.minY + screen.height / 3, width: 20, height: 20),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        anchor.contentView = view
        var shots: [(String, NSAppearance.Name, Bool)] = []
        for (name, appearance) in [("day", NSAppearance.Name.aqua), ("night", .darkAqua)] {
            shots.append(("menu-\(name)", appearance, false))
            shots.append(("microphone-\(name)", appearance, true))
        }
        var failed = false
        for (name, appearance, submenu) in shots {
            NSApp.appearance = NSAppearance(named: appearance)
            let full = model.footMenu()
            let menu = submenu ? (full.item(withTitle: "Microphone")?.submenu ?? full) : full
            if submenu { full.item(withTitle: "Microphone")?.submenu = nil }
            let file = directory.appendingPathComponent("\(name).png")
            let shot = Shot(menu: menu)
            // The menu tracks in its own run loop mode; the timer runs in it.
            let timer = Timer(timeInterval: 0.6, repeats: false) { _ in
                MainActor.assumeIsolated {
                    shot.captured = capture(to: file)
                    FileHandle.standardError.write(Data("\(name): app active \(NSApp.isActive)\n".utf8))
                    shot.menu.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            menu.popUp(positioning: nil, at: CGPoint(x: 10, y: 10), in: view)
            if !shot.captured {
                FileHandle.standardError.write(Data("check failed: \(name) not captured\n".utf8))
                failed = true
            }
        }
        exit(failed ? 1 : 0)
    }

    /// `--foot-menu-mock <directory> --onboarding-fixture` draws, off screen
    /// and with no window, a stand-in for the menu and its Microphone list
    /// beside it, by day and by night: the items' titles, order, separators,
    /// checks, greyed state and shortcut are read from the app's own menu,
    /// and only the drawing imitates macOS's, which styles the real one.
    private static func drawMocks(model: AppModel, to directory: URL) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, dark) in [("day", false), ("night", true)] {
            let menu = model.footMenu()
            let list = menu.item(withTitle: "Microphone")?.submenu ?? NSMenu()
            let main = mock(menu, dark: dark), side = mock(list, dark: dark)
            let size = CGSize(width: main.width + side.width + 40, height: max(main.height, side.height) + 40)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return false }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            (dark ? NSColor(srgbRed: 0.08, green: 0.12, blue: 0.25, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.92, blue: 0.88, alpha: 1)).setFill()
            CGRect(origin: .zero, size: size).fill()
            main.draw(CGPoint(x: 12, y: size.height - 12 - main.height))
            // The Microphone list opens beside its row, as macOS opens it.
            let row = main.top(of: "Microphone")
            side.draw(CGPoint(x: 12 + main.width + 4, y: size.height - 12 - row - side.height + 26))
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:]),
                  (try? png.write(to: directory.appendingPathComponent("menu-mock-\(name).png"))) != nil else { return false }
        }
        return true
    }

    /// A menu's items laid out as macOS lays a menu out: 22 point rows,
    /// 11 point separators, a check column, the shortcut at the right and a
    /// chevron for a submenu, on its light or dark panel.
    private struct Mock {
        let menu: NSMenu
        let dark: Bool
        let width: CGFloat = 270
        var height: CGFloat { menu.items.reduce(10) { $0 + ($1.isSeparatorItem ? 11 : 22) } }

        func top(of title: String) -> CGFloat {
            var y: CGFloat = 5
            for item in menu.items {
                if item.title == title { return y }
                y += item.isSeparatorItem ? 11 : 22
            }
            return 0
        }

        func draw(_ origin: CGPoint) {
            let box = CGRect(origin: origin, size: CGSize(width: width, height: height))
            let panel = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
            (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
            panel.fill()
            NSColor(white: dark ? 1 : 0, alpha: 0.18).setStroke()
            panel.lineWidth = 0.5
            panel.stroke()
            let ink = dark ? NSColor.white : NSColor.black
            let font = NSFont.menuFont(ofSize: 13)
            var y = box.maxY - 5
            for item in menu.items {
                if item.isSeparatorItem {
                    y -= 11
                    NSColor(white: dark ? 1 : 0, alpha: 0.12).setFill()
                    CGRect(x: box.minX + 10, y: y + 5, width: width - 20, height: 1).fill()
                    continue
                }
                y -= 22
                let colour = item.isEnabled ? ink : ink.withAlphaComponent(0.3)
                let text: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
                if item.state == .on { ("✓" as NSString).draw(at: CGPoint(x: box.minX + 8, y: y + 3), withAttributes: text) }
                (item.title as NSString).draw(at: CGPoint(x: box.minX + 24, y: y + 3), withAttributes: text)
                var trailing = ""
                if item.submenu != nil { trailing = "›" }
                if !item.keyEquivalent.isEmpty {
                    let mask = item.keyEquivalentModifierMask
                    trailing = (mask.contains(.control) ? "⌃" : "") + (mask.contains(.option) ? "⌥" : "") + (mask.contains(.shift) ? "⇧" : "")
                        + (mask.contains(.command) ? "⌘" : "") + item.keyEquivalent.uppercased()
                }
                let side = NSAttributedString(string: trailing, attributes: [.font: font, .foregroundColor: colour.withAlphaComponent(item.isEnabled ? 0.5 : 0.3)])
                side.draw(at: CGPoint(x: box.maxX - 12 - side.size().width, y: y + 3))
            }
        }
    }

    private static func mock(_ menu: NSMenu, dark: Bool) -> Mock { Mock(menu: menu, dark: dark) }

    /// One open menu and whether it was captured, handed to the timer that
    /// captures and closes it; only ever touched on the main thread.
    private final class Shot: @unchecked Sendable {
        let menu: NSMenu
        var captured = false
        init(menu: NSMenu) { self.menu = menu }
    }

    /// The topmost on-screen window of this process above normal windows,
    /// the menu, as the window server draws it.
    private static func capture(to file: URL) -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
              let menu = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }),
              let number = menu[kCGWindowNumber as String] as? UInt32,
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, number, [.boundsIgnoreFraming, .bestResolution]),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: file)) != nil
    }
}
#endif
