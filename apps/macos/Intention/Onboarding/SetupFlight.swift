import AppKit

/// Where the setup window's sun lands as setup ends: the foot mark's dot,
/// given by the app, which owns the mark.
struct SetupLanding {
    /// The foot mark's dot, its square in screen coordinates.
    var frame: CGRect
    /// The mark's sun, its bloom included, which the flying sun
    /// shrinks to so the two are the same disc when it lands.
    var side: CGFloat
    /// The mark's own window level. The flight flies at it, ordered in
    /// front of the mark's windows, so nothing of the mark draws over the
    /// sun as it lands, and a Dock that slides up still covers both.
    var level: NSWindow.Level
    /// Whether the mark cuts its bloom 2 points past the disc, as it does on
    /// every desktop; the flying sun takes the same cut on its way down.
    var cutsBloom: Bool
    /// Whether the mark is the moon now. The sun then settles into the
    /// resting dot by itself, so a sun is never seen turning into a moon.
    var isMoon: Bool
    /// The resting dot's solid ink on this desktop, and its radius with its
    /// hairline (`OwnHandMark.restEdge`) included.
    var restColor: NSColor
    var restRadius: CGFloat
    /// Hides the mark's resting dot at the given media time, when the
    /// falling sun first reaches it, so the dot never shows under the sun's
    /// soft lower edge. Asked as the flight starts, so the hide is timed by
    /// Core Animation and not by a wake on the main thread.
    var cover: @MainActor (CFTimeInterval) -> Void = { _ in }
    /// Shows the mark's sun under the landed one, swells it once and
    /// settles it to rest, with no recording.
    var arrive: @MainActor () -> Void
    /// Shows the resting dot again once the sun has settled into it by
    /// itself, under the moon.
    var uncover: @MainActor () -> Void = {}
}

/// The setup window's sun flying down into the foot mark as the window
/// closes: the same disc, lifted out of the window into a panel of
/// its own above the mark that takes no click, 1.1 s down to the mark,
/// shrinking to the mark's own sun. It then holds while the mark's sun
/// comes up under it, whatever that sun's own arrival does, and fades out
/// over it, so the hand-off shows one disc throughout.
@MainActor
final class SetupFlight {
    private var panel: NSPanel?
    /// Counts flights, so one superseded by a newer flight stops and never
    /// calls the mark.
    private var flights = 0
    /// Told as a flight lands and as the moon's settle begins, for the
    /// checks, which start another flight at exact steps.
    var stepped: @MainActor (Step) -> Void = { _ in }

    enum Step { case landed, settling }

    /// The flight's length after the sun lifts out: 50 ms, then 1.1 s down.
    static let lift: Double = 0.05
    static let duration: Double = 1.1
    /// How long the landed sun holds over the mark's while that one comes
    /// up, and how long it then takes to fade out over it.
    static let hold: Double = 0.24
    static let fade: Double = 0.12
    /// One frame at 60 Hz.
    static let frame: Double = 1.0 / 60
    /// The painting is its disc and a bloom around it: the disc is 230 of
    /// the art's 385 pixels, as in the mark's own painting.
    static let bloom: CGFloat = 385.0 / 230.0
    /// The scale the sun draws in to as it settles into the dot by itself.
    static let rest: CGFloat = 0.72

    /// Flies `image` from `start`, the sun's frame on screen, to `landing`,
    /// in a panel of its own. Its clock starts as the sun lifts out of the
    /// window.
    func fly(_ image: NSImage, from start: CGRect, to landing: SetupLanding) {
        panel?.orderOut(nil)
        let area = start.union(landing.frame.insetBy(dx: -landing.side, dy: -landing.side)).insetBy(dx: -24, dy: -24).integral
        let panel = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = landing.level
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: area.size))
        view.wantsLayer = true
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        let scale = NSScreen.screens.first { $0.frame.intersects(area) }?.backingScaleFactor ?? 2
        var local = landing
        local.frame = landing.frame.offsetBy(dx: -area.minX, dy: -area.minY)
        // In front of the mark's windows at their level again before each
        // step at the mark, should the mark have ordered itself in since.
        local.cover = { time in panel.orderFrontRegardless(); landing.cover(time) }
        local.arrive = { panel.orderFrontRegardless(); landing.arrive() }
        fly(image, from: start.offsetBy(dx: -area.minX, dy: -area.minY), to: local, on: view.layer, scale: scale) { [weak self] in
            guard self?.panel === panel else { return }
            panel.orderOut(nil)
            self?.panel = nil
        }
    }

    /// Flies `image` on `host`, from `start` to `landing`, both in the
    /// host's coordinates, and calls `done` once the sun has gone. The
    /// panel's flight, and a fixture's, which records it in a window of its
    /// own.
    func fly(_ image: NSImage, from start: CGRect, to landing: SetupLanding, on host: CALayer?, scale: CGFloat,
             done: @escaping @MainActor () -> Void = {}) {
        // The disc is drawn at the mark's size and scaled up to the
        // window's: its paint, and the resting dot for the settle under the moon.
        let side = landing.side
        let inner = side / Self.bloom
        let disc = CALayer()
        let paint = CALayer()
        paint.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        paint.contentsGravity = .resizeAspect
        paint.contentsScale = scale
        // The resting dot's solid ink in its circle, the mark's
        // own dot once the disc has drawn in. Its hairline is the mark's,
        // fading in round it as the mark is uncovered.
        let ink = Self.restShape(radius: landing.restRadius - OwnHandMark.restEdge, color: landing.restColor, in: side)
        let from = CGPoint(x: start.midX, y: start.midY)
        let to = CGPoint(x: landing.frame.midX, y: landing.frame.midY)
        // The bloom is cut as the mark cuts it, drawn in over the flight,
        // so it is gone by the time the sun lands.
        let cut = CAGradientLayer()
        let edges = [0, (inner / 2) / (side / 2), (inner / 2 + 2) / (side / 2)] as [NSNumber]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        paint.frame = disc.bounds
        ink.frame = disc.bounds
        disc.addSublayer(paint)
        disc.addSublayer(ink)
        if landing.cutsBloom {
            cut.type = .radial
            cut.frame = disc.bounds
            cut.startPoint = CGPoint(x: 0.5, y: 0.5)
            cut.endPoint = CGPoint(x: 1, y: 1)
            cut.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            cut.locations = edges
            paint.mask = cut
        }
        disc.position = to
        host?.addSublayer(disc)
        CATransaction.commit()

        // It leaves 50 ms after lifting out: across in GSAP's power2.inOut,
        // down in power2.in, so it falls into the mark.
        let begin = CACurrentMediaTime() + Self.lift
        func move(_ layer: CALayer, _ key: String, _ from: Any, _ to: Any, _ timing: CAMediaTimingFunction) {
            let move = CABasicAnimation(keyPath: key)
            move.fromValue = from
            move.toValue = to
            move.duration = Self.duration
            move.beginTime = begin
            move.fillMode = .backwards
            move.timingFunction = timing
            layer.add(move, forKey: key)
        }
        let inOut = CAMediaTimingFunction(controlPoints: 0.455, 0.03, 0.515, 0.955)
        move(disc, "position.x", from.x, to.x, inOut)
        move(disc, "position.y", from.y, to.y, CAMediaTimingFunction(controlPoints: 0.55, 0.085, 0.68, 0.53))
        move(disc, "transform.scale", start.width / side, 1, inOut)
        if landing.cutsBloom { move(cut, "locations", [0, 1, 1] as [NSNumber], edges, inOut) }
        // Its visible edge: the cut 2 points past the disc, or else the
        // bloom's own edge.
        let edge = landing.cutsBloom ? inner / 2 + 2 : side / 2
        let reach = Self.reach(from: from, to: to, startScale: start.width / side, edge: edge, dot: landing.restRadius)
        flights += 1
        let flight = flights

        Task { @MainActor [weak self] in
            // Whether this is still the flight in the air; one a newer
            // flight superseded takes its sun away and stops. One whose
            // owner has gone still lands.
            @MainActor func current() -> Bool {
                guard self.map({ $0.flights == flight }) ?? true else {
                    disc.removeFromSuperlayer()
                    return false
                }
                return true
            }
            // The resting dot goes the frame before the sun's visible edge
            // first reaches it, and the sun lands over the empty place.
            guard current() else { return }
            landing.cover(begin + reach * Self.duration - Self.frame)
            try? await Task.sleep(for: .milliseconds(Int((Self.lift + Self.duration) * 1000)))
            guard current() else { return }
            self?.stepped(.landed)
            if landing.isMoon {
                Self.settle(disc, paint: paint, ink: ink)
                self?.stepped(.settling)
                try? await Task.sleep(for: .milliseconds(280))
                guard current() else { return }
                landing.uncover()
            } else {
                // Landed: the mark's sun comes up under this one, the same
                // size, and this one fades out over it.
                landing.arrive()
                try? await Task.sleep(for: .milliseconds(Int(Self.hold * 1000)))
                guard current() else { return }
                Self.fadeOut(disc)
                try? await Task.sleep(for: .milliseconds(Int(Self.fade * 1000) + 20))
                guard current() else { return }
            }
            disc.removeFromSuperlayer()
            done()
        }
    }

    /// How far through the flight, from 0 to 1, the falling sun's visible
    /// edge (`edge` from its centre at its landed size) first reaches the
    /// resting dot of radius `dot` at `to`, on the flight's own curves; 1
    /// when it reaches it only as it lands.
    static func reach(from: CGPoint, to: CGPoint, startScale: CGFloat, edge: CGFloat, dot: CGFloat) -> Double {
        let across = (0.455, 0.03, 0.515, 0.955), down = (0.55, 0.085, 0.68, 0.53)
        for step in 0...200 {
            let t = Double(step) / 200
            let x = from.x + (to.x - from.x) * ease(across, t)
            let y = from.y + (to.y - from.y) * ease(down, t)
            let scale = startScale + (1 - startScale) * ease(across, t)
            if hypot(x - to.x, y - to.y) <= edge * scale + dot { return t }
        }
        return 1
    }

    /// A cubic Bézier timing curve with control points `c` at time `t`, as
    /// Core Animation evaluates it.
    static func ease(_ c: (Double, Double, Double, Double), _ t: Double) -> Double {
        func bezier(_ p1: Double, _ p2: Double, _ s: Double) -> Double {
            3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s
        }
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if bezier(c.0, c.2, mid) < t { low = mid } else { high = mid }
        }
        return bezier(c.1, c.3, (low + high) / 2)
    }

    /// The landed sun fading out over the mark's, the same disc under it.
    private static func fadeOut(_ disc: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.opacity = 0
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.fade
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        disc.add(fade, forKey: "fade")
    }

    /// A part of the resting dot, `radius` once the disc has drawn in to
    /// rest, centred in the disc and hidden until the settle. The outline's
    /// path runs down the page, as the asset's does, and the disc's y runs
    /// up, so it is turned over.
    private static func restShape(radius: CGFloat, color: NSColor, in side: CGFloat) -> CAShapeLayer {
        let shape = OwnHandMark.dot(diameter: 2 * radius / rest)
        var centred = CGAffineTransform(translationX: (side - shape.size.width) / 2, y: (side + shape.size.height) / 2).scaledBy(x: 1, y: -1)
        let layer = CAShapeLayer()
        layer.path = shape.path.copy(using: &centred)
        layer.fillColor = color.cgColor
        layer.opacity = 0
        return layer
    }

    /// The flying sun settling into the resting dot by itself, as the foot
    /// mark's own settle does: it draws in to 72% over 260 ms, and over the
    /// last 110 ms its paint fades under the dot's own solid ink.
    private static func settle(_ disc: CALayer, paint: CALayer, ink: CALayer) {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.transform = CATransform3DMakeScale(rest, rest, 1)
        paint.opacity = 0
        ink.opacity = 1
        CATransaction.commit()
        guard !still else { return }
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = rest
        shrink.duration = 0.26
        shrink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        disc.add(shrink, forKey: "settle")
        for (layer, values) in [(paint, [1, 1, 0]), (ink, [0, 0, 1])] {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = values
            fade.keyTimes = [0, 0.15 / 0.26, 1] as [NSNumber]
            fade.duration = 0.26
            layer.add(fade, forKey: "settle")
        }
    }
}
