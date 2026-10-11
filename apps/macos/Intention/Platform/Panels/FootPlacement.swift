import AppKit

/// Where the foot dot rests on a display: the bottom centre, above the
/// Dock, or the middle of the left or right edge. Settings names them.
enum FootSlot: String, CaseIterable, Sendable {
    case bottom, left, right

    var title: String {
        switch self {
        case .bottom: "Bottom"
        case .left: "Left"
        case .right: "Right"
        }
    }
}

/// The Dock as far as placing the foot goes: the edge it is on, and whether
/// it hides there, when it may slide over a slot on that edge.
struct FootDock: Equatable, Sendable {
    var edge: FootSlot
    var hides: Bool
}

/// Where a dot let go lands: a display and its slot.
struct FootSnap: Equatable {
    var display: CGDirectDisplayID
    var slot: FootSlot
}

/// Places the foot on made-up or real displays, in AppKit coordinates.
enum FootPlacement {
    /// The Dock on `screen`, from the room its usable area leaves at each
    /// edge but the menu bar's: more than `FootMark.margin` stays shown,
    /// a few points is the strip macOS keeps for a hidden Dock. With no
    /// room at any edge, as in a full-screen space or on a display the Dock
    /// is not on, it is taken as hiding at `systemEdge`, or the bottom.
    nonisolated static func dock(on screen: FootMark.Screen, systemEdge: FootSlot?) -> FootDock {
        let insets: [(edge: FootSlot, amount: CGFloat)] = [
            (.bottom, screen.usable.minY - screen.frame.minY),
            (.left, screen.usable.minX - screen.frame.minX),
            (.right, screen.frame.maxX - screen.usable.maxX)
        ]
        guard let largest = insets.max(by: { $0.amount < $1.amount }), largest.amount > 0 else {
            return FootDock(edge: systemEdge ?? .bottom, hides: true)
        }
        return FootDock(edge: largest.edge, hides: largest.amount <= FootMark.margin)
    }

    /// The edge the Dock is set to in its own settings, or nil.
    nonisolated static func systemDockEdge() -> FootSlot? {
        let application = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(application)
        guard let orientation = CFPreferencesCopyAppValue("orientation" as CFString, application) as? String else { return nil }
        return FootSlot(rawValue: orientation)
    }

    /// The dot's centre in `slot`: `FootMark.aboveDock` beside a Dock that
    /// stays shown on that edge, otherwise `FootMark.aboveEdge` in from the
    /// usable area's edge; the bottom centre or the middle of a side.
    nonisolated static func dotCentre(for slot: FootSlot, on screen: FootMark.Screen, dock: FootDock) -> CGPoint {
        let usable = screen.usable
        let offset = !dock.hides && dock.edge == slot ? FootMark.aboveDock : FootMark.aboveEdge
        switch slot {
        case .bottom: return CGPoint(x: usable.midX.rounded(), y: usable.minY + offset)
        case .left: return CGPoint(x: usable.minX + offset, y: usable.midY.rounded())
        case .right: return CGPoint(x: usable.maxX - offset, y: usable.midY.rounded())
        }
    }

    /// The focused-field rule at `slot`: a field that crosses the slot's
    /// band, `FootMark.column` either side of the dot along its edge, must
    /// end `FootMark.clearance` plus `margin` in from that edge.
    nonisolated static func isClear(of field: CGRect?, slot: FootSlot, on screen: FootMark.Screen, dock: FootDock) -> Bool {
        guard let field, field.intersects(screen.frame) else { return true }
        let centre = dotCentre(for: slot, on: screen, dock: dock)
        switch slot {
        case .bottom:
            guard field.minX < centre.x + FootMark.column, field.maxX > centre.x - FootMark.column else { return true }
            return field.minY - FootMark.margin - screen.usable.minY >= FootMark.clearance
        case .left:
            guard field.minY < centre.y + FootMark.column, field.maxY > centre.y - FootMark.column else { return true }
            return field.minX - FootMark.margin - screen.usable.minX >= FootMark.clearance
        case .right:
            guard field.minY < centre.y + FootMark.column, field.maxY > centre.y - FootMark.column else { return true }
            return screen.usable.maxX - field.maxX - FootMark.margin >= FootMark.clearance
        }
    }

    /// Whether a Dock hiding on `slot`'s edge may have slid over it: the
    /// pointer is on that display within `FootMark.dockReveal` of the edge.
    nonisolated static func dockMayCover(slot: FootSlot, on screen: FootMark.Screen, dock: FootDock, pointer: CGPoint) -> Bool {
        guard dock.hides, dock.edge == slot, screen.frame.contains(pointer) else { return false }
        let distance: CGFloat
        switch slot {
        case .bottom: distance = pointer.y - screen.frame.minY
        case .left: distance = pointer.x - screen.frame.minX
        case .right: distance = screen.frame.maxX - pointer.x
        }
        return distance < FootMark.dockReveal
    }

    nonisolated static func slotCentres(on screen: FootMark.Screen, dock: FootDock) -> [FootSlot: CGPoint] {
        Dictionary(uniqueKeysWithValues: FootSlot.allCases.map { ($0, dotCentre(for: $0, on: screen, dock: dock)) })
    }

    /// Where a dot let go at `release`, moving at `velocity` in points a
    /// second, lands: on the display under the release, which a throw never
    /// changes, in the slot nearest where the throw would carry it.
    nonisolated static func snap(release: CGPoint, velocity: CGVector,
                                 screens: [(screen: FootMark.Screen, dock: FootDock)], from current: CGDirectDisplayID) -> FootSnap? {
        guard let first = screens.first else { return nil }
        // Project 120 milliseconds of the release's velocity, so a short
        // flick can choose a slot without dragging all the way to its edge.
        let flickSeconds: CGFloat = 0.12
        let projected = clamp(CGPoint(x: release.x + velocity.dx * flickSeconds, y: release.y + velocity.dy * flickSeconds),
                              to: screens.map { $0.screen.frame })
        let chosen = screens.first { $0.screen.frame.contains(release) }
            ?? screens.first { $0.screen.frame.contains(projected) }
            ?? screens.first { $0.screen.id == current }
            ?? first
        let slot = FootSlot.allCases.min {
            distanceSquared(dotCentre(for: $0, on: chosen.screen, dock: chosen.dock), projected)
                < distanceSquared(dotCentre(for: $1, on: chosen.screen, dock: chosen.dock), projected)
        } ?? .bottom
        return FootSnap(display: chosen.screen.id, slot: slot)
    }

    /// What a display's choice is kept under: its UUID, which survives a
    /// reboot and a reconnection, unlike its id.
    nonisolated static func displayKey(for id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "id-\(id)" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Clamp to the actual frames, since a bounding rectangle can include
    /// empty space between displays. Keep the upper edges just inside a
    /// frame so `contains` can still find the display of a clamped point.
    nonisolated private static func clamp(_ point: CGPoint, to frames: [CGRect]) -> CGPoint {
        if frames.contains(where: { $0.contains(point) }) { return point }
        return frames.map { frame in
            CGPoint(x: min(max(point.x, frame.minX), frame.maxX.nextDown),
                    y: min(max(point.y, frame.minY), frame.maxY.nextDown))
        }.min { distanceSquared($0, point) < distanceSquared($1, point) } ?? point
    }

    nonisolated private static func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }
}
