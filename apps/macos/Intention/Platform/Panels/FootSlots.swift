import AppKit

/// The three places the foot dot can rest, drawn while the person drags it:
/// a paper slot at the bottom centre, above the Dock, and one at the middle
/// of each side edge, each flat paper with a half-point edge at a control's
/// strength and the one float, radius 10, lying along its edge. The slot
/// the dot would snap to takes a one-point edge in full ink and shows the
/// resting dot inside it, faint, where the dot will land. No scrim: the
/// slots read over any desktop on their own, and the person keeps seeing
/// what they work on. Each slot's middle is where the dot rests, which is
/// far enough from its floor (`SunDotView.envelope`) that a slot never
/// reaches into a Dock that stays shown.
///
/// The slots arrive in 280 ms, each fading in as it slides 8 points in from
/// its own edge, and leave in a 160 ms fade as the dot settles. Under Reduce
/// Motion they only fade. The view draws and nothing else: it takes no
/// mouse event and reads nothing from any app.
@MainActor
final class FootSlotsView: NSView {
    /// A slot lying along the bottom edge; a side slot is the same turned.
    nonisolated static let long: CGFloat = 64
    nonisolated static let short: CGFloat = 40
    nonisolated static let radius: CGFloat = 10
    /// How far a slot slides in from its edge as it arrives.
    nonisolated static let rise: CGFloat = 8

    /// Each slot's centre, where the dot rests in it, in the view's
    /// coordinates.
    var centres: [FootSlot: CGPoint] = [:] {
        didSet { if centres != oldValue { layoutSlots() } }
    }
    /// The slot the dot would snap to now, if it is on this display.
    var target: FootSlot? {
        didSet { if target != oldValue { markTarget() } }
    }
    /// Reduce Motion, read at each change; the renders set their own.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var slots: [FootSlot: Slot] = [:]

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for slot in FootSlot.allCases {
            let drawn = Slot(slot)
            layer?.addSublayer(drawn.root)
            slots[slot] = drawn
        }
        paint()
        // Slots stay off until `arrive`, so a view made for a drag that never
        // starts shows nothing.
        slots.values.forEach { $0.root.opacity = 0 }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func updateLayer() {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        slots.values.forEach { $0.setScale(scale) }
    }

    /// Whether any slot is on its way in or out, for the checks.
    var isAnimating: Bool { slots.values.contains { !($0.root.animationKeys() ?? []).isEmpty } }

    /// The slots come in from their edges.
    func arrive() {
        let still = reducesMotion()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (slot, drawn) in slots {
            drawn.root.removeAllAnimations()
            drawn.root.opacity = 1
            drawn.root.transform = CATransform3DIdentity
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = still ? 0.2 : 0.28
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            drawn.root.add(fade, forKey: "arrive")
            guard !still else { continue }
            let slide = CABasicAnimation(keyPath: "transform.translation")
            slide.fromValue = NSValue(size: Self.inward(slot, by: -Self.rise))
            slide.toValue = NSValue(size: .zero)
            slide.duration = 0.28
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            drawn.root.add(slide, forKey: "slide")
        }
        CATransaction.commit()
    }

    /// The slots fade away, then `done` runs on the main actor.
    func leave(_ done: @escaping @MainActor @Sendable () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(Self.completion(done))
        for drawn in slots.values {
            let from = drawn.root.presentation()?.opacity ?? drawn.root.opacity
            drawn.root.removeAllAnimations()
            drawn.root.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = 0
            fade.duration = 0.16
            drawn.root.add(fade, forKey: "leave")
        }
        CATransaction.commit()
    }

    /// A Core Animation completion that runs `done` on the main actor:
    /// Core Animation may call it on another thread, so it hops to the main
    /// queue there and runs at once on the main thread.
    nonisolated static func completion(_ done: @escaping @MainActor @Sendable () -> Void) -> @Sendable () -> Void {
        {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
                return
            }
            MainActor.assumeIsolated { done() }
        }
    }

    /// Shows every slot at once with nothing moving, for the renders.
    func showStill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slots.values.forEach {
            $0.root.removeAllAnimations()
            $0.root.opacity = 1
        }
        CATransaction.commit()
    }

    /// The offset `distance` points toward the screen's inside from `slot`'s
    /// edge.
    private static func inward(_ slot: FootSlot, by distance: CGFloat) -> CGSize {
        switch slot {
        case .bottom: CGSize(width: 0, height: distance)
        case .left: CGSize(width: distance, height: 0)
        case .right: CGSize(width: -distance, height: 0)
        }
    }

    private func layoutSlots() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (slot, drawn) in slots {
            guard let centre = centres[slot] else {
                drawn.root.isHidden = true
                continue
            }
            drawn.root.isHidden = false
            drawn.root.position = centre
        }
        CATransaction.commit()
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    private func paint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slots.values.forEach { $0.paint(dark: isDark, target: $0.slot == target) }
        CATransaction.commit()
    }

    /// The target's edge firms and its resting dot shows, in 120 ms.
    private func markTarget() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(reducesMotion() ? 0 : 0.12)
        slots.values.forEach { $0.paint(dark: isDark, target: $0.slot == target) }
        CATransaction.commit()
    }

    /// One slot's layers: two shadows, the paper with its edge, the top light
    /// by day, and the faint dot that shows where the foot dot will land.
    private final class Slot {
        let slot: FootSlot
        let root = CALayer()
        private let near = CALayer()
        private let far = CALayer()
        private let paper = CAShapeLayer()
        private let light = CAShapeLayer()
        private let ghost = CAShapeLayer()

        init(_ slot: FootSlot) {
            self.slot = slot
            let size = slot == .bottom ? CGSize(width: FootSlotsView.long, height: FootSlotsView.short)
                : CGSize(width: FootSlotsView.short, height: FootSlotsView.long)
            let box = CGRect(origin: .zero, size: size)
            let r = FootSlotsView.radius
            root.bounds = box
            for shadow in [far, near] {
                shadow.frame = box
                shadow.shadowOpacity = 1
                root.addSublayer(shadow)
            }
            // CSS's 0 2px 2px -1px and 0 12px 24px -12px: the offset down, the
            // blur halved for Core Animation's radius, the spread as an inset.
            near.shadowOffset = CGSize(width: 0, height: -2)
            near.shadowRadius = 1
            near.shadowPath = CGPath(roundedRect: box.insetBy(dx: 1, dy: 1), cornerWidth: r - 1, cornerHeight: r - 1, transform: nil)
            far.shadowOffset = CGSize(width: 0, height: -12)
            far.shadowRadius = 12
            let farBox = box.insetBy(dx: min(12, box.width / 2 - 2), dy: min(12, box.height / 2 - 2))
            far.shadowPath = CGPath(roundedRect: farBox, cornerWidth: min(r, farBox.height / 2), cornerHeight: min(r, farBox.height / 2), transform: nil)
            paper.frame = box
            // Inset by half the widest edge, so the one-point target edge
            // stays inside the slot's box.
            paper.path = CGPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerWidth: r - 0.5, cornerHeight: r - 0.5, transform: nil)
            paper.lineWidth = 0.5
            root.addSublayer(paper)
            // A one-point light along the inside of the top edge, inside the
            // widest edge so it never breaks it.
            light.frame = box
            light.path = CGPath(roundedRect: box.insetBy(dx: 1.5, dy: 1.5), cornerWidth: r - 1.5, cornerHeight: r - 1.5, transform: nil)
            light.fillColor = nil
            light.lineWidth = 1
            let topOnly = CALayer()
            topOnly.frame = CGRect(x: 0, y: box.height - 4, width: box.width, height: 4)
            topOnly.backgroundColor = NSColor.black.cgColor
            light.mask = topOnly
            root.addSublayer(light)
            let shape = OwnHandMark.dot(diameter: SunDotView.restWidth)
            ghost.bounds = CGRect(origin: .zero, size: shape.size)
            ghost.path = shape.path
            ghost.position = CGPoint(x: box.midX, y: box.midY)
            ghost.opacity = 0
            root.addSublayer(ghost)
        }

        func setScale(_ scale: CGFloat) {
            [root, near, far, paper, light, ghost].forEach { $0.contentsScale = scale }
        }

        /// The day or night material, and whether this is the slot the dot
        /// would land in.
        func paint(dark: Bool, target: Bool) {
            let ink = NSColor(srgbRed: 0x20 / 255.0, green: 0x2A / 255.0, blue: 0x2E / 255.0, alpha: 1)
            let paperInk = NSColor(srgbRed: 0xEE / 255.0, green: 0xEF / 255.0, blue: 0xE9 / 255.0, alpha: 1)
            if dark {
                paper.fillColor = NSColor(srgbRed: 0x1E / 255.0, green: 0x2E / 255.0, blue: 0x5C / 255.0, alpha: 1).cgColor
                paper.strokeColor = paperInk.withAlphaComponent(target ? 1 : 0.5).cgColor
                near.shadowColor = NSColor.black.withAlphaComponent(0.4).cgColor
                far.shadowColor = NSColor(srgbRed: 2 / 255.0, green: 8 / 255.0, blue: 30 / 255.0, alpha: 0.8).cgColor
                light.strokeColor = nil
                ghost.fillColor = paperInk.withAlphaComponent(0.34).cgColor
            } else {
                paper.fillColor = NSColor(srgbRed: 0xF9 / 255.0, green: 0xFA / 255.0, blue: 0xF7 / 255.0, alpha: 1).cgColor
                paper.strokeColor = ink.withAlphaComponent(target ? 1 : 0.46).cgColor
                near.shadowColor = ink.withAlphaComponent(0.08).cgColor
                far.shadowColor = ink.withAlphaComponent(0.35).cgColor
                light.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
                ghost.fillColor = ink.withAlphaComponent(0.24).cgColor
            }
            paper.lineWidth = target ? 1 : 0.5
            ghost.opacity = target ? 1 : 0
        }
    }
}

/// The borderless window that holds one display's slots while the foot dot
/// is dragged, the size of that display, just under the foot's own window,
/// taking no mouse event, never key, on every Space and over full-screen
/// apps as the foot is.
@MainActor
final class FootSlotsWindow: NSPanel {
    let slots = FootSlotsView(frame: .zero)

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
        level = FootWindow.footLevel
        #if DEBUG
        title = "foot slots"
        #endif
        contentView = slots
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Covers `screen` with its slots at `centres`, in AppKit screen
    /// coordinates.
    func cover(_ frame: CGRect, centres: [FootSlot: CGPoint]) {
        if self.frame != frame { setFrame(frame, display: false) }
        slots.frame = CGRect(origin: .zero, size: frame.size)
        slots.centres = centres.mapValues { CGPoint(x: $0.x - frame.minX, y: $0.y - frame.minY) }
    }
}

/// The spring the foot dot settles into its slot on: the design's spring
/// for what the hand touches, response 0.26 s and damping 0.72, as SwiftUI
/// defines them, started with the speed the person let go at. Pure, so the
/// checks can sample it.
struct FootSpring {
    nonisolated static let response = 0.26
    nonisolated static let damping = 0.72
    /// The farthest the dot may swing past its slot toward the slot's edge:
    /// resting `SunDotView.envelope` from that edge and still held, so the
    /// whole drawn dot, its hairline included, at `SunDotView.liftScale`,
    /// keeps its own edge 8 points clear of the screen's edge or the Dock.
    /// The dot is a circle 16 points across with its hairline:
    /// 26 - 8 - 16 / 2 × 1.3 = 7.6.
    nonisolated static var overshoot: CGFloat {
        SunDotView.envelope - 8 - (SunDotView.restWidth + 2 * SunDotView.restEdge) / 2 * SunDotView.liftScale
    }

    let from: CGPoint
    let to: CGPoint
    let velocity: CGVector
    /// Where a spring that would have swung past its bound was stopped: the
    /// time, the point on the bound, and the speed along the edge kept, from
    /// which a fresh spring takes it home.
    private var stop: (time: Double, at: CGPoint, velocity: CGVector)?
    /// The way to the slot's edge and how far past `to` the dot may go that
    /// way, enforced at every position asked for, between samples too.
    private var bound: (unit: CGVector, limit: CGFloat)?

    init(from: CGPoint, to: CGPoint, velocity: CGVector) {
        self.from = from
        self.to = to
        self.velocity = velocity
    }

    /// A spring from `from` to `to` thrown at `velocity` that swings at most
    /// `limit` past `to` toward `outward`, the slot's edge. The throw's speed
    /// toward the edge is cut only as far as that needs; where even none
    /// would carry the dot past, as from far away, the dot is held at the
    /// bound and springs home from there.
    static func bounded(from: CGPoint, to: CGPoint, velocity: CGVector, outward: CGVector, limit: CGFloat = overshoot) -> FootSpring {
        let length = hypot(outward.dx, outward.dy)
        guard length > 0 else { return FootSpring(from: from, to: to, velocity: velocity) }
        let unit = CGVector(dx: outward.dx / length, dy: outward.dy / length)
        let along = velocity.dx * unit.dx + velocity.dy * unit.dy
        let across = CGVector(dx: velocity.dx - along * unit.dx, dy: velocity.dy - along * unit.dy)
        func spring(_ speed: CGFloat) -> FootSpring {
            FootSpring(from: from, to: to, velocity: CGVector(dx: across.dx + speed * unit.dx, dy: across.dy + speed * unit.dy))
        }
        func past(_ spring: FootSpring, at t: Double) -> CGFloat {
            let here = spring.position(at: t)
            return (here.x - to.x) * unit.dx + (here.y - to.y) * unit.dy
        }
        let samples = stride(from: 0.0, through: FootGlide.longest, by: 1.0 / 480)
        func farthest(_ spring: FootSpring) -> CGFloat { samples.map { past(spring, at: $0) }.max() ?? 0 }
        var chosen: FootSpring
        if farthest(spring(along)) <= limit {
            chosen = spring(along)
        } else if along > 0, farthest(spring(0)) <= limit {
            var low: CGFloat = 0, high = along
            for _ in 0..<20 {
                let middle = (low + high) / 2
                if farthest(spring(middle)) <= limit { low = middle } else { high = middle }
            }
            chosen = spring(low)
        } else {
            chosen = spring(min(along, 0))
            let held = chosen
            if let after = samples.first(where: { past(held, at: $0) > limit }) {
                // The crossing itself, between the last sample inside the
                // bound and the first past it.
                var inside = max(0, after - 1.0 / 480), outside = after
                for _ in 0..<40 {
                    let middle = (inside + outside) / 2
                    if past(held, at: middle) > limit { outside = middle } else { inside = middle }
                }
                let reached = held.position(at: inside)
                let over = max(0, past(held, at: inside) - limit)
                chosen.stop = (inside, CGPoint(x: reached.x - over * unit.dx, y: reached.y - over * unit.dy), .zero)
            }
        }
        // The samples may straddle a peak by a hair; no position goes past.
        chosen.bound = (unit, limit)
        return chosen
    }

    /// Where the dot is `t` seconds after letting go.
    func position(at t: Double) -> CGPoint {
        let free: CGPoint
        if let stop, t >= stop.time {
            free = FootSpring(from: stop.at, to: to, velocity: stop.velocity).position(at: t - stop.time)
        } else {
            free = CGPoint(x: to.x + Self.offset(Double(from.x - to.x), Double(velocity.dx), t),
                           y: to.y + Self.offset(Double(from.y - to.y), Double(velocity.dy), t))
        }
        guard let bound else { return free }
        let past = (free.x - to.x) * bound.unit.dx + (free.y - to.y) * bound.unit.dy
        guard past > bound.limit else { return free }
        let over = past - bound.limit
        return CGPoint(x: free.x - over * bound.unit.dx, y: free.y - over * bound.unit.dy)
    }

    /// Whether the dot has come to rest, within a third of a point, by `t`.
    func settled(at t: Double) -> Bool {
        let here = position(at: t), soon = position(at: t + 1.0 / 120)
        return hypot(here.x - to.x, here.y - to.y) < 0.35 && hypot(soon.x - here.x, soon.y - here.y) < 0.05
    }

    /// The underdamped spring's displacement from rest, from `x0` with speed
    /// `v0`.
    private static func offset(_ x0: Double, _ v0: Double, _ t: Double) -> CGFloat {
        let omega = 2 * Double.pi / response
        let decay = damping * omega
        let omegaD = omega * (1 - damping * damping).squareRoot()
        let value = exp(-decay * t) * (x0 * cos(omegaD * t) + (v0 + decay * x0) / omegaD * sin(omegaD * t))
        return CGFloat(value)
    }
}

/// Steps a `FootSpring` on the display's refresh until it settles, moving
/// the foot's window each frame, then runs `done`. The display link calls in
/// on the main run loop; `step` still reaches the main actor itself, as the
/// rule for framework callbacks asks.
@MainActor
final class FootGlide: NSObject {
    private var link: CADisplayLink?
    private var spring: FootSpring?
    private var started: CFTimeInterval = 0
    private var apply: (CGPoint) -> Void = { _ in }
    private var done: () -> Void = {}

    var isRunning: Bool { link != nil }

    func start(_ spring: FootSpring, on view: NSView, apply: @escaping (CGPoint) -> Void, done: @escaping () -> Void) {
        stop()
        self.spring = spring
        self.apply = apply
        self.done = done
        started = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        // AppKit stops a view's display link once the view is off every
        // display, so the spring's end is also kept by the clock: a glide
        // that has not settled by `longest` lands where it was going.
        generation &+= 1
        let started = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.longest))
            guard let self, self.generation == started, self.isRunning else { return }
            self.finish()
        }
    }

    /// The longest a glide runs; the spring settles well before.
    nonisolated static let longest = 1.5
    /// Changes with each glide, so an older glide's clock ends nothing.
    private var generation = 0

    /// Puts the dot at the spring's end and runs `done`.
    private func finish() {
        guard let spring else { return }
        apply(spring.to)
        let done = done
        stop()
        done()
    }

    /// Ends the glide where it is, without running `done`.
    func stop() {
        link?.invalidate()
        link = nil
        spring = nil
    }

    @objc nonisolated private func step(_ link: CADisplayLink) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.advance() } }
            return
        }
        MainActor.assumeIsolated { advance() }
    }

    private func advance() {
        guard let spring else { return }
        let t = CACurrentMediaTime() - started
        if spring.settled(at: t) || t > Self.longest {
            finish()
        } else {
            apply(spring.position(at: t))
        }
    }
}
