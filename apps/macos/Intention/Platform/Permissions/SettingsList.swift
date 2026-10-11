import CoreGraphics
import Foundation

/// What `SettingsListReader` keeps of one element in System Settings'
/// window: a switch, or a label that reads as Intention's name. The other
/// apps' names beside the switches are compared with Intention's name where
/// they are read and dropped, so none of them reaches here.
///
/// Frames are in the window server's coordinates, measured from the top
/// left of the main display, as Accessibility reports them.
struct SettingsNode: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A text label that reads as Intention's name.
        case intentionLabel
        /// A switch or checkbox. `isOn` is nil when its value could not be
        /// read; `isIntention` when its own title or description is Intention's
        /// name.
        case toggle(isOn: Bool?, isIntention: Bool)
    }

    var kind: Kind
    var frame: CGRect
    /// The part of the window the element can be seen through: the window
    /// cut down by every scroll area around the element.
    var clip: CGRect
}

/// What System Settings' front window says about Intention's line in a
/// permission list.
enum SettingsListReading: Equatable, Sendable {
    /// Exactly one line carries Intention's name, its switch is off and in
    /// view. Frames in window server coordinates.
    case row(toggle: CGRect, label: CGRect)
    /// Intention's one line is in the list but scrolled out of view.
    case scrolledAway
    /// Every line named Intention on this page is already switched on.
    case alreadyOn
    /// More than one line carries Intention's name and at least one is off,
    /// for example a development copy beside an installed one. The icons
    /// tell them apart and Accessibility does not, so no line can be
    /// singled out.
    case ambiguous
    /// No switch on this page belongs to a line named Intention.
    case notListed
    /// A switch on a line named Intention did not report whether it is on.
    /// Unknown is never drawn as off: pressing a switch that is already on
    /// would withdraw the grant.
    case unreadable
    /// The read stopped at its element or time limit before the page was
    /// read whole, so Intention's line may be there unread.
    case incomplete
}

enum SettingsList {
    /// Finds Intention's switch among the nodes read from one window.
    ///
    /// A switch is Intention's when its own title says so, or when it is the
    /// nearest switch to the right of a label reading Intention on the same
    /// line. Lines are matched by geometry rather than by the element tree,
    /// because System Settings has built these lists from different
    /// elements in different macOS versions and the drawn line is the one
    /// thing they share.
    static func locate(_ nodes: [SettingsNode]) -> SettingsListReading {
        let toggles = nodes.indices.filter { nodes[$0].kind != .intentionLabel }
        var mine: [Int: CGRect] = [:]
        for index in toggles {
            if case .toggle(_, true) = nodes[index].kind { mine[index] = nodes[index].frame }
        }
        for label in nodes where label.kind == .intentionLabel {
            let sameLine = toggles.filter { onSameLine(label.frame, nodes[$0].frame) }
            if let nearest = sameLine.min(by: { nodes[$0].frame.minX < nodes[$1].frame.minX }) {
                mine[nearest] = label.frame
            }
        }
        func state(_ index: Int) -> Bool? {
            if case let .toggle(isOn, _) = nodes[index].kind { isOn } else { nil }
        }
        guard let only = mine.first else { return .notListed }
        if mine.keys.contains(where: { state($0) == nil }) { return .unreadable }
        if mine.keys.allSatisfy({ state($0) == true }) { return .alreadyOn }
        guard mine.count == 1 else { return .ambiguous }
        let toggle = nodes[only.key]
        let seen = toggle.frame.intersection(toggle.clip)
        guard !seen.isNull, seen.height >= toggle.frame.height * 0.6, seen.width >= toggle.frame.width * 0.6 else {
            return .scrolledAway
        }
        return .row(toggle: toggle.frame, label: only.value)
    }

    /// Whether a label sits on the same line as a switch, to its left. Only
    /// such labels have their text read: on a permission list they are the
    /// apps' names, and every other label on the page is left unread.
    static func isBesideSwitch(_ label: CGRect, toggles: [CGRect]) -> Bool {
        toggles.contains { onSameLine(label, $0) }
    }

    private static func onSameLine(_ label: CGRect, _ toggle: CGRect) -> Bool {
        let reach = max(toggle.height, label.height) * 0.75
        return abs(toggle.midY - label.midY) <= reach && toggle.minX >= label.maxX - 2
    }

    /// Whether a label in the list is Intention's name. System Settings shows
    /// an app under its bundle's file name or its display name, and the
    /// check ignores case and surrounding spaces only: "Intention Dev" is not
    /// "Intention".
    static func isIntention(_ text: String, names: [String]) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && names.contains { text.caseInsensitiveCompare($0) == .orderedSame }
    }

    /// Converts a frame measured from the top left of the main display, as
    /// the window server and Accessibility report them, to AppKit's screen
    /// coordinates, which are measured from its bottom left.
    static func appKitFrame(_ frame: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: mainDisplayHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
