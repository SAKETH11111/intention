import AppKit
import Metal
import QuartzCore
import SwiftUI

// The foot dot's placement on a made-up screen, for the renders and the
// drag video: `--placement-stills <directory>` draws the slots and the dot
// at each slot on a light desk by day and a dark desk by night, off screen
// in a process that never activates, and
// `--placement-frames <light|dark> <seconds>` plays a drag to the right, a
// throw to the left and a drag back to the bottom with no window at all,
// writing its frames for scripts/foot-placement-video.sh to encode. Every
// piece is the app's own: the slots view, the sun dot and its slip, placed
// by `FootPlacement` and `FootMark.layout` on a screen the size of the desk,
// and the snap on `FootSpring`. Every word on the desk is made up.
extension FootShots {
    @MainActor
    static func renderPlacement(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scenes: [(String, PlacementDesk.Dock, (PlacementDesk) -> Void)] = [
            ("rest-bottom", .bottom, { _ in }),
            ("drag-middle", .bottom, { $0.hold(at: CGPoint(x: 820, y: 430)) }),
            ("drag-near-right", .bottom, { $0.hold(at: CGPoint(x: 1180, y: 450)) }),
            ("rest-left-hint", .bottom, { $0.rest(at: .left, hint: true) }),
            ("rest-right-hint", .bottom, { $0.rest(at: .right, hint: true) }),
            ("listening-left", .bottom, { $0.rest(at: .left, hint: false); $0.listen() }),
            ("listening-right", .bottom, { $0.rest(at: .right, hint: false); $0.listen() }),
            ("listening-left-hover", .bottom, { $0.rest(at: .left, hint: false); $0.listen(); $0.words("Done", key: "esc", after: "cancels") }),
            ("listening-right-hover", .bottom, { $0.rest(at: .right, hint: false); $0.listen(); $0.words("Done", key: "esc", after: "cancels") }),
            ("dock-left-drag", .left, { $0.hold(at: CGPoint(x: 230, y: 470)) }),
            ("dock-left-rest-left", .left, { $0.rest(at: .left, hint: true) }),
            // A dictation's notice outside an email: the foot's own slip
            // says it, since no caret dot stands in a plain field.
            ("notice-bottom", .bottom, { $0.words("Pasted it, which replaced what you'd copied") }),
            ("notice-right", .bottom, { $0.rest(at: .right, hint: false); $0.words("Pasted it, which replaced what you'd copied") }),
        ]
        for look in [Look(sky: .sun, dark: false), Look(sky: .moon, dark: true)] {
            for (name, dock, apply) in scenes {
                let desk = PlacementDesk(look: look, dock: dock)
                desk.still = true
                apply(desk)
                try savePlacement(desk, to: directory.appendingPathComponent("placement-\(name)-\(look.dark ? "dark" : "light").png"))
            }
        }
    }

    /// Draws the desk off screen: in a window that is never ordered front,
    /// in a process that never activates, through `cacheDisplay` at twice
    /// its points, so nothing reaches the window server's screen.
    @MainActor
    private static func savePlacement(_ desk: PlacementDesk, to file: URL) throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: PlacementDesk.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = desk
        desk.layoutSubtreeIfNeeded()
        desk.displayIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(PlacementDesk.size.width * 2), pixelsHigh: Int(PlacementDesk.size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
        rep.size = PlacementDesk.size
        desk.cacheDisplay(in: desk.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: file)
        window.contentView = nil
    }

    /// Plays the drag demo with no window at all and writes its frames, 60 a
    /// second for `seconds`, as raw BGRA at `scale` times the desk's points to
    /// standard output, for ffmpeg. `CARenderer` draws the desk's own layer
    /// tree into a Metal texture at each frame's time, so Core Animation
    /// evaluates the real springs and fades; nothing reaches the window
    /// server and the process never activates.
    @MainActor
    static func renderPlacementFrames(dark: Bool, seconds: Double, scale: CGFloat) -> Bool {
        let desk = PlacementDesk(look: Look(sky: dark ? .moon : .sun, dark: dark), dock: .bottom)
        desk.layoutSubtreeIfNeeded()
        desk.layoutSubtreeIfNeeded()
        // With no window AppKit leaves each subview's layer out of the desk's
        // tree, so they are hung in it here, under the desk's own pointer,
        // and their frames follow the views' on every frame.
        let views = desk.subviews
        func hang() {
            for view in views {
                guard let layer = view.layer else { continue }
                layer.frame = view.frame
                view.layout()
            }
        }
        for view in views {
            if let layer = view.layer { desk.layer?.insertSublayer(layer, below: desk.pointerLayer) }
            // No window tells the views their backing scale, so they take the
            // default of 2, which their images are drawn at.
            view.viewDidChangeBackingProperties()
        }
        guard let root = desk.layer, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return false }
        let width = Int(PlacementDesk.size.width * scale), height = Int(PlacementDesk.size.height * scale)
        let described = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        described.usage = [.renderTarget, .shaderRead]
        described.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: described) else { return false }
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])
        // The desk's layers at `scale`, drawn into the texture's pixels.
        let holder = CALayer()
        holder.frame = CGRect(x: 0, y: 0, width: width, height: height)
        holder.addSublayer(root)
        root.anchorPoint = .zero
        root.position = .zero
        root.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        renderer.layer = holder
        renderer.bounds = holder.frame
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let out = FileHandle.standardOutput
        desk.play()
        let start = CACurrentMediaTime()
        for frame in 0..<Int(seconds * 60) {
            let due = start + Double(frame) / 60
            while CACurrentMediaTime() < due { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hang()
            CATransaction.commit()
            CATransaction.flush()
            renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            guard let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return false }
            blit.synchronize(resource: texture)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            out.write(Data(bytes))
        }
        return true
    }

    /// A made-up screen: a desktop, the menu bar, a notes window with its
    /// caret, a Dock at the bottom or the left, and the foot dot with its
    /// slots exactly where the app places them on a screen this size.
    @MainActor
    final class PlacementDesk: NSView {
        enum Dock { case bottom, left }

        static let size = CGSize(width: 1280, height: 800)
        static let menuBar: CGFloat = 24
        static let dockDepth: CGFloat = 64

        let screen: FootMark.Screen
        let dock: FootDock
        let mark = SunDotView(frame: CGRect(x: 0, y: 0, width: SunDotView.side, height: SunDotView.side))
        let slots = FootSlotsView(frame: CGRect(origin: .zero, size: PlacementDesk.size))
        private let pointer = CAShapeLayer()
        /// The drawn pointer's layer, which the off-screen frames keep on top.
        var pointerLayer: CALayer { pointer }
        private let look: Look
        /// Renders show end states with nothing moving.
        var still = false {
            didSet {
                mark.reducesMotion = { [still] in still }
                slots.reducesMotion = { [still] in still }
            }
        }
        /// The dot's centre now, in the desk's coordinates.
        private var dot: CGPoint = .zero
        private var slot = FootSlot.bottom

        init(look: Look, dock: Dock) {
            self.look = look
            let frame = CGRect(origin: .zero, size: Self.size)
            var usable = CGRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height - Self.menuBar)
            switch dock {
            case .bottom: usable = CGRect(x: 0, y: Self.dockDepth, width: usable.width, height: usable.height - Self.dockDepth)
            case .left: usable = CGRect(x: Self.dockDepth, y: 0, width: usable.width - Self.dockDepth, height: usable.height)
            }
            screen = FootMark.Screen(id: 1, frame: frame, usable: usable, key: "desk")
            self.dock = FootPlacement.dock(on: screen, systemEdge: nil)
            super.init(frame: frame)
            appearance = NSAppearance(named: look.dark ? .darkAqua : .aqua)
            wantsLayer = true
            drawDesktop(dock: dock)
            slots.centres = FootPlacement.slotCentres(on: screen, dock: self.dock)
            addSubview(slots)
            mark.sky = look.sky
            addSubview(mark)
            drawPointer()
            place(at: FootPlacement.dotCentre(for: .bottom, on: screen, dock: self.dock))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override var isFlipped: Bool { false }

        private func place(at point: CGPoint) {
            dot = point
            mark.frame.origin = CGPoint(x: point.x - SunDotView.side / 2, y: point.y - SunDotView.side / 2)
        }

        /// The dot held at `point` with the slots shown and the one it would
        /// land in marked, the pointer on it.
        func hold(at point: CGPoint) {
            place(at: point)
            mark.lifted = true
            slots.showStill()
            slots.target = FootPlacement.snap(release: point, velocity: .zero, screens: [(screen: screen, dock: dock)], from: 1)?.slot
            showPointer(at: CGPoint(x: point.x + 2, y: point.y - 2))
        }

        /// The dot resting in `slot`, with the pointer on it and its hint when
        /// asked.
        func rest(at slot: FootSlot, hint: Bool) {
            self.slot = slot
            let centre = FootPlacement.dotCentre(for: slot, on: screen, dock: dock)
            place(at: centre)
            if hint {
                showPointer(at: CGPoint(x: centre.x + 2, y: centre.y - 2))
                words("Dictate", key: "fn")
            }
        }

        func listen() { mark.phase = .listening }

        /// The dot opens into its slip, toward the screen's middle at a side,
        /// as `FootMark` opens it at the slot the dot rests in.
        func words(_ text: String?, key: String? = nil, after: String? = nil) {
            mark.opening = switch slot {
            case .bottom: .centre
            case .left: .rightward
            case .right: .leftward
            }
            mark.slip = text.map { FootSlip(text: $0, key: key, after: after) }
        }

        // MARK: The drag demo

        private var timer: Timer?
        private var started = CACurrentMediaTime()
        private var steps: [(at: Double, run: (PlacementDesk) -> Void)] = []
        /// The pointer's path while it is moved, and the dot's spring after a
        /// release.
        private var path: (from: CGPoint, to: CGPoint, start: Double, duration: Double, dragging: Bool)?
        private var spring: (FootSpring, start: Double)?
        private var grab = CGVector.zero

        /// Rest, the hint, a drag to the right slot; a press and a throw to
        /// the left; a throw back to the bottom. About nine seconds.
        func play() {
            let bottom = FootPlacement.dotCentre(for: .bottom, on: screen, dock: dock)
            let right = FootPlacement.dotCentre(for: .right, on: screen, dock: dock)
            let left = FootPlacement.dotCentre(for: .left, on: screen, dock: dock)
            steps = [
                (0.3, { $0.showPointer(at: CGPoint(x: 900, y: 300)); $0.move(to: CGPoint(x: bottom.x + 2, y: bottom.y - 2), over: 0.45) }),
                (0.8, { $0.words("Dictate", key: "fn") }),
                (1.5, { $0.press() }),
                (1.6, { $0.beginDrag() }),
                (1.6, { $0.move(to: CGPoint(x: right.x - 70, y: right.y + 30), over: 1.1, dragging: true) }),
                (2.9, { $0.release(velocity: CGVector(dx: 300, dy: -120)) }),
                (3.5, { $0.settle(at: .right) }),
                (4.4, { $0.words(nil); $0.move(to: CGPoint(x: right.x - 120, y: right.y - 60), over: 0.3) }),
                (4.9, { $0.move(to: CGPoint(x: right.x + 2, y: right.y - 2), over: 0.3) }),
                (5.3, { $0.press() }),
                (5.4, { $0.beginDrag() }),
                (5.4, { $0.move(to: CGPoint(x: 520, y: 470), over: 0.7, dragging: true) }),
                (6.1, { $0.release(velocity: CGVector(dx: -1900, dy: -60)) }),
                (6.7, { $0.settle(at: .left) }),
                (7.3, { $0.press() }),
                (7.4, { $0.beginDrag() }),
                (7.4, { $0.move(to: CGPoint(x: bottom.x - 40, y: bottom.y + 90), over: 0.9, dragging: true) }),
                (8.4, { $0.release(velocity: CGVector(dx: 80, dy: -1800)) }),
                (9.0, { $0.settle(at: .bottom) }),
                (9.4, { $0.words(nil); $0.move(to: CGPoint(x: 900, y: 300), over: 0.5) }),
            ]
            started = CACurrentMediaTime()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in
                MainActor.assumeIsolated { self.tick() }
            }
        }

        private func tick() {
            let t = CACurrentMediaTime() - started
            while let first = steps.first, first.at <= t {
                steps.removeFirst()
                first.run(self)
            }
            if let path {
                let p = min(1, (t - path.start) / path.duration)
                // Eased in and out, as a hand moves.
                let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
                let at = CGPoint(x: path.from.x + (path.to.x - path.from.x) * e, y: path.from.y + (path.to.y - path.from.y) * e)
                setPointer(at)
                if path.dragging {
                    let held = CGPoint(x: at.x - grab.dx, y: at.y - grab.dy)
                    place(at: held)
                    slots.target = FootPlacement.snap(release: held, velocity: .zero, screens: [(screen: screen, dock: dock)], from: 1)?.slot
                }
                if p >= 1 { self.path = nil }
            }
            if let (spring, start) = spring {
                let s = t - start
                place(at: spring.position(at: s))
                if spring.settled(at: s) {
                    place(at: spring.to)
                    self.spring = nil
                    mark.lifted = false
                }
            }
        }

        private func move(to point: CGPoint, over duration: Double, dragging: Bool = false) {
            path = (pointer.position, point, CACurrentMediaTime() - started, duration, dragging)
        }

        private func press() {
            pointer.fillColor = NSColor(white: 0.3, alpha: 1).cgColor
            pointer.transform = CATransform3DMakeScale(0.9, 0.9, 1)
        }

        /// Taken where the dot is drawn, at the open slip's end, as `FootMark`
        /// takes it: the slip closes at once and the dot stays under the hand.
        private func beginDrag() {
            let shown = mark.convert(mark.shownDotCentre, to: self)
            grab = CGVector(dx: pointer.position.x - shown.x, dy: pointer.position.y - shown.y)
            mark.closeSlipAtOnce()
            place(at: shown)
            mark.lifted = true
            slots.target = nil
            slots.arrive()
        }

        /// Let go: the pointer lifts, the slots fade and the dot springs into
        /// the slot it was thrown toward.
        private func release(velocity: CGVector) {
            path = nil
            pointer.fillColor = NSColor.black.cgColor
            pointer.transform = CATransform3DIdentity
            let landing = FootPlacement.snap(release: dot, velocity: velocity, screens: [(screen: screen, dock: dock)], from: 1)?.slot ?? .bottom
            slot = landing
            slots.target = nil
            slots.leave {}
            let end = FootPlacement.dotCentre(for: landing, on: screen, dock: dock)
            if still {
                place(at: end)
                mark.lifted = false
            } else {
                // As `FootMark.settle` throws it: no faster than its fastest
                // throw, and swinging no nearer the edge than its bound.
                let speed = hypot(velocity.dx, velocity.dy)
                let scale = speed > FootMark.fastestThrow ? FootMark.fastestThrow / speed : 1
                let thrown = CGVector(dx: velocity.dx * scale, dy: velocity.dy * scale)
                spring = (FootSpring.bounded(from: dot, to: end, velocity: thrown, outward: FootMark.outward(of: landing)), CACurrentMediaTime() - started)
            }
            // The pointer stays where it was let go, as a hand does; the dot
            // keeps its ink until it lands.
        }

        /// The pointer comes onto the dot where it landed and its hint shows.
        private func settle(at slot: FootSlot) {
            let centre = FootPlacement.dotCentre(for: slot, on: screen, dock: dock)
            move(to: CGPoint(x: centre.x + 2, y: centre.y - 2), over: 0.3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { self.words("Dictate", key: "fn") }
        }

        // MARK: Drawing

        private func showPointer(at point: CGPoint) {
            pointer.isHidden = false
            setPointer(point)
        }

        private func setPointer(_ point: CGPoint) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pointer.position = point
            CATransaction.commit()
        }

        private func drawPointer() {
            let arrow = CGMutablePath()
            for (index, point) in [(0, 0), (0, -16), (4.2, -12.2), (7.2, -18.4), (9.8, -17.2), (6.9, -11.2), (12, -11.2)].enumerated() {
                let at = CGPoint(x: point.0, y: point.1)
                if index == 0 { arrow.move(to: at) } else { arrow.addLine(to: at) }
            }
            arrow.closeSubpath()
            pointer.path = arrow
            pointer.fillColor = NSColor.black.cgColor
            pointer.strokeColor = NSColor.white.cgColor
            pointer.lineWidth = 1.2
            pointer.isHidden = true
            pointer.zPosition = 10
            layer?.addSublayer(pointer)
        }

        private func drawDesktop(dock: Dock) {
            let desktop = CAGradientLayer()
            desktop.frame = bounds
            desktop.colors = look.dark ? [Self.rgb(0x1B2850), Self.rgb(0x111A36)] : [Self.rgb(0xF2EFE6), Self.rgb(0xE4E0D3)]
            layer?.addSublayer(desktop)
            let bar = CALayer()
            bar.frame = CGRect(x: 0, y: Self.size.height - Self.menuBar, width: Self.size.width, height: Self.menuBar)
            bar.backgroundColor = look.dark ? NSColor(white: 0.08, alpha: 0.5).cgColor : NSColor(white: 1, alpha: 0.55).cgColor
            layer?.addSublayer(bar)
            let ink = look.dark ? NSColor(white: 0.9, alpha: 1) : NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
            for (index, word) in ["Notes", "File", "Edit", "View"].enumerated() {
                let text = Self.text(word, ink: ink, size: 13, bold: index == 0)
                text.frame = CGRect(x: 40 + CGFloat(index) * 58, y: Self.size.height - Self.menuBar + 4, width: 60, height: 18)
                layer?.addSublayer(text)
            }
            let sheet = CALayer()
            sheet.frame = CGRect(x: 300, y: 250, width: 640, height: 380)
            sheet.backgroundColor = look.dark ? Self.rgb(0x1E1E1E) : .white
            sheet.cornerRadius = 12
            sheet.shadowOpacity = 0.18
            sheet.shadowRadius = 14
            sheet.shadowOffset = CGSize(width: 0, height: -6)
            layer?.addSublayer(sheet)
            for (index, line) in ["Offsite", "Twelve of us, two days.", "Agenda: Q3 deck, roadmap, team dinner", "Book the train for Friday"].enumerated() {
                let text = Self.text(line, ink: ink, size: index == 0 ? 19 : 14, bold: index == 0)
                text.frame = CGRect(x: 32, y: 380 - 52 - CGFloat(index) * 26, width: 560, height: 22)
                sheet.addSublayer(text)
            }
            let caret = CALayer()
            caret.frame = CGRect(x: 32 + 170, y: 380 - 52 - 3 * 26 + 2, width: 1.5, height: 17)
            caret.backgroundColor = ink.cgColor
            sheet.addSublayer(caret)
            let dockLayer = CALayer()
            let tiles = 9
            let length = CGFloat(tiles) * 46 + 14
            dockLayer.frame = switch dock {
            case .bottom: CGRect(x: (Self.size.width - length) / 2, y: 6, width: length, height: Self.dockDepth - 12)
            case .left: CGRect(x: 6, y: (Self.size.height - Self.menuBar - length) / 2, width: Self.dockDepth - 12, height: length)
            }
            dockLayer.cornerRadius = 16
            dockLayer.backgroundColor = look.dark ? NSColor(white: 0.12, alpha: 0.6).cgColor : NSColor(white: 1, alpha: 0.6).cgColor
            dockLayer.borderWidth = 0.5
            dockLayer.borderColor = NSColor(white: look.dark ? 1 : 0, alpha: 0.14).cgColor
            layer?.addSublayer(dockLayer)
            for (index, colour) in [0x3B82F6, 0xF59E0B, 0x10B981, 0xEF4444, 0x8B5CF6, 0x6B7280, 0x0EA5E9, 0xF97316, 0x14B8A6].enumerated() {
                let tile = CALayer()
                let along = 7 + CGFloat(index) * 46
                tile.frame = dock == .bottom ? CGRect(x: along + 3, y: 6, width: 40, height: 40) : CGRect(x: 6, y: along + 3, width: 40, height: 40)
                tile.cornerRadius = 9
                tile.backgroundColor = Self.rgb(colour)
                dockLayer.addSublayer(tile)
            }
        }

        private static func rgb(_ hex: Int) -> CGColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1).cgColor
        }

        private static func text(_ string: String, ink: NSColor, size: CGFloat, bold: Bool) -> CATextLayer {
            let text = CATextLayer()
            text.string = string
            text.font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
            text.fontSize = size
            text.foregroundColor = ink.cgColor
            text.contentsScale = 2
            return text
        }
    }
}
