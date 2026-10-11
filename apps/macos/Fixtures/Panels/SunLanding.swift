import AppKit

// The entry point of the small bundle scripts/sun-landing-video.sh builds:
// setup's sun landing in the foot mark, as setup ends, on three made-up
// desks at once: the sun on a dark and on a light desktop, and the moon on
// a dark one. Each desk holds the real foot mark's sun (`FootMark.mark`,
// driven by `FootMark.receiveSun`) and `SetupFlight`'s flying sun above it,
// as its panel flies above the mark's windows. `--sun-landing <seconds>`
// plays three landings in a window behind the desktop picture, drawn and
// animated like any window yet never seen, for the script to record by its
// title, then quits.
@main
struct SunLanding: GuardedRender {
    /// The window's title, which `RecordWindow` finds it by.
    static let title = "Intention sun landing"

    @MainActor
    static func render() {
        let app = NSApplication.shared
        let arguments = CommandLine.arguments
        SetupStyle.registerFonts()
        guard let index = arguments.firstIndex(of: "--sun-landing"), arguments.indices.contains(index + 1),
              let seconds = Double(arguments[index + 1]) else { exit(2) }
        app.setActivationPolicy(.prohibited)
        let desks = [Desk(dark: true, moon: false), Desk(dark: false, moon: false), Desk(dark: true, moon: true)]
        let size = CGSize(width: Desk.size.width * CGFloat(desks.count), height: Desk.size.height)
        let row = NSView(frame: CGRect(origin: .zero, size: size))
        for (index, desk) in desks.enumerated() {
            desk.frame.origin = CGPoint(x: CGFloat(index) * Desk.size.width, y: 0)
            row.addSubview(desk)
        }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = title
        window.contentView = row
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.ignoresMouseEvents = true
        if let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) {
            window.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2))
        }
        window.orderFrontRegardless()
        // A landing every 2.5 s, the first after a second, so the recording
        // has the resting dot before each.
        for round in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(round) * 2.5) {
                MainActor.assumeIsolated { desks.forEach { $0.land() } }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
        withExtendedLifetime(window) { app.run() }
    }

    /// A made-up desk: a flat desktop, the foot mark's dot near its foot,
    /// and the sun coming down to it from the upper left.
    @MainActor
    final class Desk: NSView {
        static let size = CGSize(width: 220, height: 220)
        /// The foot dot's centre, and the window's sun as it lifts out.
        static let dot = CGPoint(x: 110, y: 40)
        static let sun = CGRect(x: 20, y: 120, width: 80, height: 80)

        private let foot: FootMark
        private let flight = SetupFlight()
        private let moon: Bool

        init(dark: Bool, moon: Bool) {
            self.moon = moon
            let screen = FootMark.Screen(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                         usable: CGRect(x: 0, y: 80, width: 1440, height: 795))
            foot = FootMark(desktop: .init(screens: { [screen] }, pointer: { CGPoint(x: 700, y: 400) }, showsWindow: false))
            super.init(frame: CGRect(origin: .zero, size: Self.size))
            wantsLayer = true
            appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            layer?.backgroundColor = dark ? NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1).cgColor
                : NSColor(srgbRed: 0.86, green: 0.89, blue: 0.93, alpha: 1).cgColor
            foot.mark.reducesMotion = { false }
            foot.sky = moon ? .moon : .sun
            foot.enabled = true
            // The real mark's sun, on this desk in place of its own window.
            let mark = foot.mark
            addSubview(mark)
            mark.frame = CGRect(x: Self.dot.x - SunDotView.side / 2, y: Self.dot.y - SunDotView.side / 2,
                                width: SunDotView.side, height: SunDotView.side)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        /// The mark's own windows sit just under the Dock and the flight
        /// flies above them, so here the flying sun is the top layer.
        func land() {
            let side = SunDotView.disc * SunDotView.bloom
            let landing = SetupLanding(frame: CGRect(x: Self.dot.x - side / 2, y: Self.dot.y - side / 2, width: side, height: side),
                                       side: side, level: .normal, cutsBloom: true, isMoon: moon, restColor: foot.mark.restInk,
                                       restRadius: SunDotView.restWidth / 2 + OwnHandMark.restEdge, cover: { [foot] time in foot.coverForSun(at: time) },
                                       arrive: { [foot] in foot.receiveSun() }, uncover: { [foot] in foot.uncover() })
            let top = CALayer()
            top.frame = bounds
            top.zPosition = 10
            layer?.addSublayer(top)
            flight.fly(SetupStyle.image("SetupSun", "webp"), from: Self.sun, to: landing, on: top, scale: 2) { top.removeFromSuperlayer() }
        }
    }
}
