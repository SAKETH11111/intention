import AppKit
@testable import Onboarding
import Testing

/// Setup's sun flying into the foot mark, on a layer that is never shown.
@MainActor
@Suite
struct SetupFlightTests {
    private static let side: CGFloat = 16 * SetupFlight.bloom

    private func landing(moon: Bool = false, events: Events? = nil, arrive: @escaping @MainActor () -> Void = {}) -> SetupLanding {
        SetupLanding(frame: CGRect(x: 100, y: 20, width: Self.side, height: Self.side), side: Self.side, level: .normal,
                     cutsBloom: true, isMoon: moon, restColor: .black, restRadius: 8.25,
                     cover: { _ in events?.list.append("cover") },
                     arrive: { events?.list.append("arrive"); arrive() },
                     uncover: { events?.list.append("uncover") })
    }

    @MainActor
    private final class Events {
        var list: [String] = []
    }

    @Test func theDotGoesAsTheFallingSunsEdgeFirstReachesIt() {
        // Straight down from 200 points above: the visible edge, 10 from the
        // centre at the landed size, meets a 6.5 dot before the landing.
        let reach = SetupFlight.reach(from: CGPoint(x: 0, y: 200), to: .zero, startScale: 1, edge: 10, dot: 6.5)
        #expect(reach > 0.8 && reach < 1)
        let y = 200 * (1 - SetupFlight.ease((0.55, 0.085, 0.68, 0.53), reach))
        #expect(abs(y - 16.5) < 1.5)
        // A flight that starts on the dot reaches it at once.
        #expect(SetupFlight.reach(from: .zero, to: .zero, startScale: 1, edge: 10, dot: 6.5) == 0)
        // The curve's ends.
        #expect(abs(SetupFlight.ease((0.455, 0.03, 0.515, 0.955), 0)) < 0.001)
        #expect(abs(SetupFlight.ease((0.455, 0.03, 0.515, 0.955), 1) - 1) < 0.001)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test(.timeLimit(.minutes(1))) func theSunLandsAsTheMarksOwnAndFadesOnlyOnceTheMarkHasItsSun() async {
        let host = CALayer()
        var atArrival: (opacity: Float, side: CGFloat, at: ContinuousClock.Instant)?
        var atDone: (opacity: Float?, at: ContinuousClock.Instant)?
        let events = Events()
        let flight = SetupFlight()
        flight.fly(NSImage(size: CGSize(width: 10, height: 10)), from: CGRect(x: 0, y: 200, width: 92, height: 92),
                   to: landing(events: events) {
                       atArrival = (host.sublayers?.first?.opacity ?? -1, host.sublayers?.first?.bounds.width ?? 0, .now)
                   },
                   on: host, scale: 2) { atDone = (nil, .now) }
        // Drawn at the mark's own size and centred on the mark's dot, so the
        // two suns are one disc when it lands.
        let disc = host.sublayers?.first
        #expect(disc?.bounds.width == Self.side)
        #expect(disc?.position == CGPoint(x: 100 + Self.side / 2, y: 20 + Self.side / 2))
        #expect(disc?.sublayers?.first?.mask != nil)
        #expect(await eventually { atDone != nil })
        // It held over the mark's sun for the hold and faded for the fade
        // before it went, timed in the flight's own callbacks; by then its
        // own opacity had gone to nothing.
        if let atArrival, let atDone {
            #expect(atDone.at - atArrival.at >= .milliseconds(Int((SetupFlight.hold + SetupFlight.fade) * 1000)))
        }
        #expect(disc?.opacity == 0)
        // The mark's sun came up while the flying one still covered it, whole.
        #expect(atArrival?.opacity == 1)
        #expect(atArrival?.side == Self.side)
        // The resting dot went before the sun landed over it.
        #expect(events.list == ["cover", "arrive"])
        #expect(host.sublayers?.isEmpty ?? true)
    }

    @Test(.timeLimit(.minutes(1))) func underTheMoonTheSunSettlesByItselfAndTheMarkIsNeverAsked() async {
        let host = CALayer()
        var asked = false
        var done = false
        let events = Events()
        var settled: (scale: CGFloat, inks: [(fill: CGColor?, side: CGFloat, opacity: Float)])?
        let flight = SetupFlight()
        flight.stepped = { step in
            guard step == .settling, let disc = host.sublayers?.first else { return }
            let shapes = (disc.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
            settled = (disc.transform.m11, shapes.map { ($0.fillColor, $0.path?.boundingBox.width ?? 0, $0.opacity) })
        }
        flight.fly(NSImage(size: CGSize(width: 10, height: 10)), from: CGRect(x: 0, y: 200, width: 92, height: 92),
                   to: landing(moon: true, events: events) { asked = true }, on: host, scale: 2) { done = true }
        #expect(await eventually { done })
        #expect(!asked)
        // It settles into the mark's own dot: its solid ink in the Own Hand
        // outline, at the dot's size once drawn in, with no hairline of its
        // own, since the mark's fades in round it as it is uncovered.
        #expect(settled?.scale == SetupFlight.rest)
        let inks = settled?.inks ?? []
        #expect(inks.map(\.fill) == [NSColor.black.cgColor])
        #expect(inks.first?.opacity == 1)
        let dot = OwnHandMark.dot(diameter: 2 * (8.25 - OwnHandMark.restEdge)).path.boundingBox.width
        #expect(abs((inks.first?.side ?? 0) * SetupFlight.rest - dot) < 0.001)
        // Hidden as the sun reached it, the dot shows again once the sun has
        // settled into it.
        #expect(events.list == ["cover", "uncover"])
        #expect(host.sublayers?.isEmpty ?? true)
    }

    @Test(.timeLimit(.minutes(1))) func aSecondFlightStopsTheFirstBeforeItReachesTheMark() async {
        let first = CALayer(), second = CALayer()
        let firstEvents = Events(), secondEvents = Events()
        var done = false
        let flight = SetupFlight()
        let image = NSImage(size: CGSize(width: 10, height: 10))
        flight.fly(image, from: CGRect(x: 0, y: 200, width: 92, height: 92), to: landing(events: firstEvents), on: first, scale: 2)
        flight.fly(image, from: CGRect(x: 0, y: 200, width: 92, height: 92), to: landing(events: secondEvents), on: second, scale: 2) {
            done = true
        }
        #expect(await eventually { done })
        #expect(firstEvents.list.isEmpty)
        #expect(first.sublayers?.isEmpty ?? true)
        #expect(secondEvents.list == ["cover", "arrive"])
    }

    @Test(.timeLimit(.minutes(1))) func aMoonFlightSupersededDuringItsSettleNeverShowsTheDot() async {
        let first = CALayer(), second = CALayer()
        let firstEvents = Events(), secondEvents = Events()
        var firstDone = false, secondDone = false
        var inSettle: (disc: Bool, events: [String])?
        let flight = SetupFlight()
        let image = NSImage(size: CGSize(width: 10, height: 10))
        // The second starts the moment the first begins to settle into the
        // dot, and only that once.
        flight.stepped = { step in
            guard step == .settling, inSettle == nil else { return }
            inSettle = (first.sublayers?.isEmpty == false, firstEvents.list)
            flight.fly(image, from: CGRect(x: 0, y: 200, width: 92, height: 92), to: landing(moon: true, events: secondEvents),
                       on: second, scale: 2) { secondDone = true }
        }
        flight.fly(image, from: CGRect(x: 0, y: 200, width: 92, height: 92), to: landing(moon: true, events: firstEvents),
                   on: first, scale: 2) { firstDone = true }
        #expect(await eventually { secondDone })
        // It was settling, its disc there and the dot still hidden, when the
        // second started; it never showed the dot or finished.
        #expect(inSettle?.disc == true)
        #expect(inSettle?.events == ["cover"])
        #expect(firstEvents.list == ["cover"])
        #expect(!firstDone)
        #expect(first.sublayers?.isEmpty ?? true)
        #expect(secondEvents.list == ["cover", "uncover"])
    }

}
