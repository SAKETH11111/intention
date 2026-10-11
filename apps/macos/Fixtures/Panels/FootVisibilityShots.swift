import AppKit
import Metal
import QuartzCore

// Draws the foot dot over the desktops it must stay findable on, for judging
// its visibility: a light desk and a night-blue desk as the foot shots have
// them, a near-black desk, and a busy photograph, by day (the sun, Light)
// and by night (the moon, Dark), each with a Dock below it. Every state the
// dot shows at the foot: at rest, opened into its hint, held in the hand,
// beside a slot while dragged, and listening. Each tile is the bottom centre
// of a 1440 by 900 point desk, drawn off screen through `cacheDisplay` in a
// window never ordered front, by a process that never activates, at twice
// its points. Only the app's own views are drawn: `SunDotView`, `FootSlip`
// through it, and `FootSlotsView`. The photograph is the file given; the
// script passes a free Unsplash photo of river rocks.
//
// With `--frames` it draws instead every frame, 60 a second, of the dot
// settling from the sun or the moon into rest, and of setup's moon handing
// over to the mark (its settled ink disc going as the mark is uncovered),
// with and without Reduce Motion, on the light and night-blue desks, through
// Core Animation's own renderer with no window at all.
//
// Usage: FootVisibilityShots <directory> <photo.png> [--frames]
@main
struct FootVisibilityShots: GuardedRender {
    static let tile = CGSize(width: 320, height: 180)
    /// The Dock's top, and the dot resting `FootMark.aboveDock` above it.
    static let dockTop: CGFloat = 64

    enum Desk: String, CaseIterable {
        case light, navy, black, photo
    }

    enum State: String, CaseIterable {
        case rest, hint, held, slot, listening
    }

    @MainActor
    static func render() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, let photo = NSImage(contentsOfFile: arguments[2])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            FileHandle.standardError.write(Data("usage: FootVisibilityShots <directory> <photo>\n".utf8))
            exit(2)
        }
        SetupStyle.registerFonts()
        let directory = URL(fileURLWithPath: arguments[1])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if arguments.contains("--frames") {
            exit(renderFrames(to: directory, photo: photo) ? 0 : 1)
        }
        for night in [false, true] {
            for desk in Desk.allCases {
                for state in State.allCases {
                    let view = Tile(desk: desk, night: night, state: state, photo: photo)
                    let name = "visible-\(state.rawValue)-\(desk.rawValue)-\(night ? "night" : "day").png"
                    do {
                        try save(view, to: directory.appendingPathComponent(name))
                    } catch {
                        FileHandle.standardError.write(Data("failed \(name)\n".utf8))
                        exit(1)
                    }
                }
            }
        }
        exit(0)
    }

    @MainActor
    static func save(_ view: NSView, to file: URL) throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: tile), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(tile.width * 2), pixelsHigh: Int(tile.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
        rep.size = tile
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: file)
        window.contentView = nil
    }

    /// The settle and the moon's handoff, every frame at 60 a second, as
    /// PNGs named `<sequence>-<desk>-<day|night>-<frame>.png`.
    @MainActor
    static func renderFrames(to directory: URL, photo: CGImage) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return false }
        let scale: CGFloat = 2
        let width = Int(tile.width * scale), height = Int(tile.height * scale)
        let described = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        described.usage = [.renderTarget, .shaderRead]
        described.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: described) else { return false }
        for desk in [Desk.light, .navy] {
            for night in [false, true] {
                // The settle: listening for a third of a second, then rest,
                // through 400 ms after the change.
                let settle = Tile(desk: desk, night: night, state: .rest, photo: photo)
                settle.mark.reducesMotion = { false }
                settle.mark.phase = .listening
                guard frames(of: settle, texture: texture, queue: queue, scale: scale, count: 45, at: 20,
                             change: { $0.mark.phase = .resting },
                             named: { directory.appendingPathComponent("settle-\(desk.rawValue)-\(night ? "night" : "day")-\(String(format: "%02d", $0)).png") }) else { return false }
                guard night else { continue }
                // The moon at its loudest: the voice held at full level, so the
                // disc swells to 24 points with its hairline.
                let loud = Tile(desk: desk, night: night, state: .rest, photo: photo)
                loud.mark.reducesMotion = { false }
                loud.mark.phase = .listening
                guard frames(of: loud, texture: texture, queue: queue, scale: scale, count: 40, at: 6,
                             change: { $0.mark.level = 1 }, each: { frame, view in if frame > 6 { view.mark.level = frame % 3 == 0 ? 0.2 : 1 } },
                             named: { directory.appendingPathComponent("swell-\(desk.rawValue)-night-\(String(format: "%02d", $0)).png") }) else { return false }
                // Setup's moon handoff: its settled ink disc over the covered
                // mark, gone as the mark is uncovered and the hairline comes,
                // as `SetupFlight` and `FootMark.uncover` do at 280 ms.
                for still in [false, true] {
                    let handoff = Tile(desk: desk, night: night, state: .rest, photo: photo)
                    handoff.mark.reducesMotion = { still }
                    let disc = CAShapeLayer()
                    let inner = SunDotView.disc * 0.72
                    let centre = CGPoint(x: handoff.mark.frame.midX, y: handoff.mark.frame.midY)
                    disc.path = CGPath(ellipseIn: CGRect(x: centre.x - inner / 2, y: centre.y - inner / 2, width: inner, height: inner), transform: nil)
                    disc.fillColor = handoff.mark.restInk.cgColor
                    disc.zPosition = 5
                    handoff.layer?.addSublayer(disc)
                    handoff.mark.layer?.opacity = 0
                    guard frames(of: handoff, texture: texture, queue: queue, scale: scale, count: 30, at: 4,
                                 change: { view in
                                     disc.removeFromSuperlayer()
                                     view.mark.layer?.opacity = 1
                                     view.mark.fadeEdgeIn()
                                 },
                                 named: { directory.appendingPathComponent("handoff\(still ? "-still" : "")-\(desk.rawValue)-night-\(String(format: "%02d", $0)).png") }) else { return false }
                }
            }
        }
        return true
    }

    /// Draws `view` with no window, frame by frame at 60 a second, running
    /// `change` at frame `at`, and saves each frame.
    @MainActor
    private static func frames(of view: Tile, texture: MTLTexture, queue: MTLCommandQueue, scale: CGFloat, count: Int, at: Int,
                               change: (Tile) -> Void, each: (Int, Tile) -> Void = { _, _ in }, named: (Int) -> URL) -> Bool {
        view.layoutSubtreeIfNeeded()
        // With no window AppKit leaves each subview's layer out of the tile's
        // tree, so they are hung in it here, with their backing scale set.
        for sub in view.subviews {
            guard let layer = sub.layer else { continue }
            layer.frame = sub.frame
            view.layer?.addSublayer(layer)
            sub.viewDidChangeBackingProperties()
            sub.layout()
        }
        guard let root = view.layer else { return false }
        let holder = CALayer()
        holder.frame = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        holder.addSublayer(root)
        root.anchorPoint = .zero
        root.position = .zero
        root.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])
        renderer.layer = holder
        renderer.bounds = holder.frame
        let start = CACurrentMediaTime() + 0.05
        for frame in 0..<count {
            let due = start + Double(frame) / 60
            while CACurrentMediaTime() < due { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002)) }
            if frame == at {
                CATransaction.begin()
                change(view)
                CATransaction.commit()
            }
            each(frame, view)
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
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let image = CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: texture.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intention: .defaultIntention),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
            do { try png.write(to: named(frame)) } catch { return false }
        }
        return true
    }

    /// One tile: the desk, the Dock, and the dot in `state`.
    @MainActor
    final class Tile: NSView {
        let mark = SunDotView(frame: CGRect(x: 0, y: 0, width: SunDotView.side, height: SunDotView.side))

        init(desk: Desk, night: Bool, state: State, photo: CGImage) {
            super.init(frame: CGRect(origin: .zero, size: FootVisibilityShots.tile))
            appearance = NSAppearance(named: night ? .darkAqua : .aqua)
            wantsLayer = true
            let size = FootVisibilityShots.tile
            let ground = CALayer()
            ground.frame = bounds
            switch desk {
            case .light:
                let gradient = CAGradientLayer()
                gradient.colors = [Self.rgb(0xF1EEE4), Self.rgb(0xE6E2D6)]
                gradient.frame = bounds
                ground.addSublayer(gradient)
            case .navy:
                let gradient = CAGradientLayer()
                gradient.colors = [Self.rgb(0x1B2850), Self.rgb(0x111A36)]
                gradient.frame = bounds
                ground.addSublayer(gradient)
            case .black:
                // A near-black desktop with a faint woven pattern, as on
                // the screenshot that asked for this.
                ground.backgroundColor = Self.rgb(0x141414)
                let weave = CAReplicatorLayer()
                weave.frame = bounds
                let thread = CALayer()
                thread.frame = CGRect(x: 0, y: 0, width: size.width, height: 1)
                thread.backgroundColor = Self.rgb(0x1C1C1C)
                weave.addSublayer(thread)
                weave.instanceCount = Int(size.height / 3)
                weave.instanceTransform = CATransform3DMakeTranslation(0, 3, 0)
                ground.addSublayer(weave)
            case .photo:
                // The bottom centre of the photo laid over a 1440 by 900
                // desk, as a desktop picture fills the screen: scaled to
                // cover it, centred, its overflow cropped evenly.
                let width = CGFloat(photo.width), height = CGFloat(photo.height)
                let scale = min(width / 1440, height / 900)
                let margin = CGPoint(x: (width - 1440 * scale) / 2, y: (height - 900 * scale) / 2)
                let crop = CGRect(x: margin.x + (1440 - size.width) / 2 * scale, y: height - margin.y - size.height * scale,
                                  width: size.width * scale, height: size.height * scale)
                ground.contents = photo.cropping(to: crop.integral)
                ground.contentsGravity = .resize
            }
            layer?.addSublayer(ground)
            let dock = CALayer()
            dock.frame = CGRect(x: 10, y: 6, width: size.width - 20, height: FootVisibilityShots.dockTop - 12)
            dock.cornerRadius = 16
            dock.backgroundColor = night ? NSColor(white: 0.12, alpha: 0.6).cgColor : NSColor(white: 1, alpha: 0.55).cgColor
            dock.borderWidth = 0.5
            dock.borderColor = NSColor(white: night ? 1 : 0, alpha: 0.14).cgColor
            layer?.addSublayer(dock)
            for (index, colour) in [0x3B82F6, 0xF59E0B, 0x10B981, 0xEF4444, 0x8B5CF6, 0x6B7280].enumerated() {
                let icon = CALayer()
                icon.frame = CGRect(x: 7 + CGFloat(index) * 50, y: 6, width: 40, height: 40)
                icon.cornerRadius = 9
                icon.backgroundColor = Self.rgb(colour)
                dock.addSublayer(icon)
            }
            let centre = CGPoint(x: size.width / 2, y: FootVisibilityShots.dockTop + FootMark.aboveDock)
            if state == .slot {
                let slots = FootSlotsView(frame: bounds)
                slots.reducesMotion = { true }
                slots.centres = [.bottom: centre]
                slots.target = .bottom
                slots.showStill()
                addSubview(slots)
            }
            mark.sky = night ? .moon : .sun
            mark.reducesMotion = { true }
            let at = state == .slot ? CGPoint(x: centre.x + 44, y: centre.y + 34) : centre
            mark.frame.origin = CGPoint(x: at.x - SunDotView.side / 2, y: at.y - SunDotView.side / 2)
            addSubview(mark)
            switch state {
            case .rest: break
            case .hint: mark.slip = FootSlip(text: "Dictate", key: "fn")
            case .held, .slot: mark.lifted = true
            case .listening: mark.phase = .listening
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override var isFlipped: Bool { false }

        private static func rgb(_ hex: Int) -> CGColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1).cgColor
        }
    }
}
