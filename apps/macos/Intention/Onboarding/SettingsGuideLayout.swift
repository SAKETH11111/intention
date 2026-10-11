import CoreGraphics

/// The permission list a `SettingsGuide` is helping with.
enum GuidedList: Sendable {
    /// Asked for during setup, before Intention can read System Settings, so
    /// the guide can only say what to look for.
    case accessibility
    /// Asked for after setup. By then Intention usually holds Accessibility and
    /// can find its own line, so the guide rings it when it can be sure of
    /// the page and the line. On that page with the line in doubt it shows
    /// the note, and on a page it cannot name it shows nothing.
    case screenRecording
}

/// What the guide shows and where, worked out from frames alone so it can
/// be tested without System Settings. Panel frames are in AppKit screen
/// coordinates; the drawing inside a panel is measured from the panel's top
/// left, as SwiftUI draws it.
enum SettingsGuideLayout {
    enum Mark: Equatable {
        case none
        /// A note under the list saying what Intention's line looks like.
        /// Claims no line.
        case list
        /// A ring on Intention's switch, read from System Settings itself.
        /// AppKit screen coordinates.
        case row(toggle: CGRect)
    }

    // MARK: Which page and which copy

    /// The release's bundle identifier.
    static let releaseIdentifier = "co.intention.mac"

    /// The names System Settings may list this copy of Intention under: its
    /// bundle's file name, its display name and its bundle name. Nil for
    /// any copy but the release. Every copy's bundle is Intention.app, so a
    /// development copy can be listed under the release's name, and the
    /// list gives a line a name and no bundle identity Intention reads. Such a
    /// copy could ring the release's switch, so it reads nothing and shows
    /// nothing.
    static func ownNames(bundleIdentifier: String?, candidates: [String?]) -> [String]? {
        guard bundleIdentifier == releaseIdentifier else { return nil }
        let names = Array(Set(candidates.compactMap { $0 }.filter { !$0.isEmpty }))
        return names.isEmpty ? nil : names
    }

    // MARK: Which reading

    /// A reading of Intention's line kept between reads: the window's frame
    /// when the read began, which stood still while it ran, and when it
    /// began.
    struct Observation: Equatable {
        var reading: SettingsListReading
        var window: CGRect
        var at: ContinuousClock.Instant
        /// Whether the read before found the same thing, a line at the same
        /// place in the window included. A read taken while the list
        /// scrolls or the page changes mixes two moments, and two reads in
        /// a row agree only once the page holds still.
        var repeated: Bool
    }

    /// A reading is drawn for this long after its read began. Reads come
    /// about every 0.15 seconds; one that has not been followed by then
    /// may describe a list that has since scrolled.
    static let freshFor = Duration.seconds(1)

    /// What to keep after an accepted read. `reading` is nil off the
    /// Screen Recording page or when the read failed.
    static func observe(_ reading: SettingsListReading?, window: CGRect, at: ContinuousClock.Instant,
                        after previous: Observation?) -> Observation? {
        guard let reading else { return nil }
        let repeated = previous.map { inWindow($0.reading, $0.window) == inWindow(reading, window) } ?? false
        return Observation(reading: reading, window: window, at: at, repeated: repeated)
    }

    /// A row's frames measured from the window's origin, so a window that
    /// moved between two reads still compares equal.
    private static func inWindow(_ reading: SettingsListReading, _ window: CGRect) -> SettingsListReading {
        guard case let .row(toggle, label) = reading else { return reading }
        return .row(toggle: toggle.offsetBy(dx: -window.minX, dy: -window.minY),
                    label: label.offsetBy(dx: -window.minX, dy: -window.minY))
    }

    /// Chooses the mark for the latest observation of System Settings.
    ///
    /// `observation` is nil when Intention cannot read System Settings, which
    /// is always so at the first Accessibility request, or when the window
    /// is not on a page the guide recognizes. Without a fresh one, the
    /// Accessibility request still gets its note: setup opened that page a
    /// moment ago and Intention cannot read any page yet. A Screen Recording
    /// visit gets nothing, because the person may have moved to another
    /// permission's list, where "Turn on Intention" would be wrong.
    ///
    /// `window` is where the window is now. Nothing is drawn from a single
    /// read: a page that is changing can show one page's title over
    /// another's list for a moment, and a list that is scrolling pairs
    /// frames from different moments, so a reading counts only once the
    /// read after it finds the same thing. The ring also needs a window the
    /// same size as when it was read; a window that only moved carries the
    /// line with it, so the ring follows a drag at once. The note says
    /// "Turn on Intention", so it shows only when the reads found Intention's
    /// line switched off and the ring cannot be drawn on it: the line is
    /// out of view, there are two, or the window has changed size. A read
    /// cut short does not know the switch's state, and gets nothing.
    static func mark(for list: GuidedList, observation: Observation?, window: CGRect, now: ContinuousClock.Instant,
                     mainDisplayHeight: CGFloat) -> Mark {
        guard let observation, now - observation.at <= freshFor else { return list == .accessibility ? .list : .none }
        guard observation.repeated else { return .none }
        switch observation.reading {
        case let .row(toggle, _):
            guard observation.window.size == window.size else { return .list }
            let moved = toggle.offsetBy(dx: window.minX - observation.window.minX, dy: window.minY - observation.window.minY)
            return .row(toggle: SettingsList.appKitFrame(moved, mainDisplayHeight: mainDisplayHeight))
        case .alreadyOn, .unreadable, .notListed, .incomplete:
            return .none
        case .scrolledAway, .ambiguous:
            // Both found a line named Intention switched off.
            return .list
        }
    }

    /// Whether a finished read may be used. It must belong to the visit
    /// that asked for it, since one that started before the guide stopped
    /// and started again describes an earlier page. And the window must
    /// stand where it stood when the read began: frames read while it was
    /// being dragged mix two positions, so the ring would land off the
    /// switch. A dropped read leaves the previous one in place until it is
    /// no longer fresh.
    static func accepts(visit: Int, currentVisit: Int, windowBefore: CGRect, windowAfter: CGRect?) -> Bool {
        visit == currentVisit && windowAfter == windowBefore
    }

    // MARK: The note under the list

    static let listSize = CGSize(width: 340, height: 104 + shadowRoom)
    /// Where the note's drawn switch, and the arrow above it, sit from the
    /// note's right edge. Matches `SettingsGuideView`.
    static let listArrowInset: CGFloat = 38

    /// Just under the Settings window, or inside its bottom edge when the
    /// window reaches the foot of the screen. Its right edge sits 10 points
    /// inside the window's, so the arrow rises under the middle of the
    /// switches' column: on macOS 27.2 a switch is 36 points wide and ends
    /// 30 points inside the window's right edge.
    static func listPanel(window: CGRect, screen: CGRect) -> CGRect {
        var frame = CGRect(origin: CGPoint(x: window.maxX - listSize.width - 10, y: window.minY - listSize.height - 4),
                           size: listSize)
        if frame.minY < screen.minY + 8 { frame.origin.y = window.minY + 14 }
        frame.origin.x = min(max(frame.minX, screen.minX + 8), screen.maxX - listSize.width - 8)
        return frame
    }

    // MARK: The ring on Intention's line

    struct Row: Equatable {
        /// The panel, in AppKit screen coordinates.
        var panel: CGRect
        /// Inside the panel, from its top left.
        var ring: CGRect
        var callout: CGRect
        var arrowFrom: CGPoint
        var arrowTo: CGPoint
    }

    static let calloutSize = CGSize(width: 222, height: 60)
    /// Room around the drawing for the halo and the callout's shadow.
    private static let margin: CGFloat = 16
    /// More room under the drawing, where the float falls: by night it
    /// drops 16 and blurs 32, about 20 points past the note's foot, and a
    /// panel any shorter cuts it off in a hard line.
    static let shadowRoom: CGFloat = 16

    /// A ring around the switch and a callout joined to it by an arrow. The
    /// callout stands just outside the window's right edge, level with the
    /// line, where it covers nothing in the list. When the screen ends
    /// there it sits inside the window under the line, or over it near the
    /// window's foot, covering other lines but never Intention's.
    static func row(toggle: CGRect, window: CGRect, screen: CGRect) -> Row {
        let ring = toggle.insetBy(dx: -7, dy: -6)
        let size = calloutSize
        var callout: CGRect
        var from: CGPoint
        var to: CGPoint
        let right = CGRect(x: max(window.maxX + 20, ring.maxX + 44), y: ring.midY - size.height / 2,
                           width: size.width, height: size.height)
        if right.maxX <= screen.maxX - 8 {
            callout = right
            callout.origin.y = min(max(callout.minY, screen.minY + 8), screen.maxY - size.height - 8)
            from = CGPoint(x: callout.minX - 6, y: min(max(ring.midY, callout.minY + 14), callout.maxY - 14))
            to = CGPoint(x: ring.maxX + 6, y: ring.midY)
        } else {
            let x = min(max(ring.maxX + 12 - size.width, screen.minX + 8), screen.maxX - size.width - 8)
            let below = CGRect(x: x, y: ring.minY - 36 - size.height, width: size.width, height: size.height)
            if below.minY >= max(window.minY, screen.minY) + 8 {
                callout = below
                from = CGPoint(x: ring.midX, y: callout.maxY + 6)
                to = CGPoint(x: ring.midX, y: ring.minY - 6)
            } else {
                callout = CGRect(x: x, y: ring.maxY + 36, width: size.width, height: size.height)
                from = CGPoint(x: ring.midX, y: callout.minY - 6)
                to = CGPoint(x: ring.midX, y: ring.maxY + 6)
            }
        }
        var panel = ring.union(callout).insetBy(dx: -margin, dy: -margin).integral
        // AppKit's y grows upward, so the panel grows down from its foot
        // and everything in it keeps its place from the top left.
        panel.origin.y -= shadowRoom
        panel.size.height += shadowRoom
        func local(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX - panel.minX, y: panel.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        func local(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x - panel.minX, y: panel.maxY - point.y)
        }
        return Row(panel: panel, ring: local(ring), callout: local(callout), arrowFrom: local(from), arrowTo: local(to))
    }
}
