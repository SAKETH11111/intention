import ApplicationServices
import Foundation

/// Finds Intention's line in System Settings' front window through
/// Accessibility, so `SettingsGuide` can ring its switch. It needs the
/// Accessibility grant and answers nil without it, which is always so while
/// that grant is the one being asked for.
///
/// It reads as little as the job allows. Every read starts with the
/// window's title, and the list is walked only when that title is one the
/// guide asked for. The walk reads roles, frames and switch values, and a
/// switch's own title. A label's text is read only when the label sits on
/// a line with a switch, as the apps' names do in a permission list, and it
/// is compared with Intention's name there and then. Nothing is kept or logged.
///
/// An element that fails to answer may be a second line named Intention, so
/// any such failure makes the reading `.incomplete` rather than leaving the
/// element out. Only an attribute the element says it lacks is skipped, and
/// an element Accessibility says is not there when it sits inside the
/// sidebar, which System Settings names. An
/// incomplete reading knows neither where Intention's line is nor whether its
/// switch is on, so the guide shows nothing for it.
final class SettingsListReader: Sendable {
    /// One read at a time: a read already running makes the next tick skip.
    private let executor = AccessibilityExecutor(capacity: 1)

    /// The walk starts no element after this many or this long. A settings
    /// page is a few hundred elements, and an answer that comes late has
    /// already been overtaken by the next tick. An element already started
    /// can take longer: each of its messages may wait out Accessibility's
    /// one-second timeout, and the first that does ends the walk.
    private static let elementLimit = 3000
    private static let timeLimit = Duration.milliseconds(500)

    /// Reads the front window of the System Settings process `pid` and
    /// calls `done` on the main actor with Intention's line, or nil when the
    /// window's title is not in `pages` or Intention cannot read the window.
    /// Returns false, without reading, while the previous read is still
    /// running.
    @discardableResult
    func read(pid: pid_t, pages: Set<String>, names: [String],
              done: @escaping @MainActor @Sendable (SettingsListReading?) -> Void) -> Bool {
        executor.submit { expired in
            let reading = expired ? nil : Self.read(pid: pid, pages: pages, names: names)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(reading) } }
        }
    }

    private static func read(pid: pid_t, pages: Set<String>, names: [String]) -> SettingsListReading? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXElement.application(pid)
        guard let window = (try? app.element(kAXFocusedWindowAttribute).get()) ?? (try? app.element(kAXMainWindowAttribute).get()) else {
            return nil
        }
        return reading(of: window, pages: pages, names: names)
    }

    /// Intention's line in `window`, or nil when its title is not in `pages`.
    /// The title is read again after the walk: the person can change page
    /// while the list is being walked, and what was read may then be the
    /// new page's list, where Microphone's line for Intention would pass for
    /// Screen Recording's.
    static func reading(of window: AXElement, pages: Set<String>, names: [String]) -> SettingsListReading? {
        func isOnPage() -> Bool {
            (try? window.string(kAXTitleAttribute).get()).map(pages.contains) ?? false
        }
        guard isOnPage() else { return nil }
        let reading = (try? walk(window, names: names)) ?? .incomplete
        return isOnPage() ? reading : nil
    }

    /// The identifier System Settings gives its sidebar, read on macOS
    /// 27.2. The sidebar and a page's list of apps are built from the same
    /// kinds of element, so this name is what tells them apart. On a
    /// version that names it otherwise nothing is passed over, and a
    /// sidebar cell that is not there cuts the read short.
    private static let sidebar = "com.apple.settings.sidebar.collectionView"

    /// Thrown when an element fails to answer, or the walk runs out of time
    /// or elements.
    private struct Unread: Error {}

    private static func walk(_ window: AXElement, names: [String]) throws -> SettingsListReading {
        guard let windowFrame = try? window.frame().get() else { throw Unread() }
        let deadline = ContinuousClock.now + timeLimit
        var toggles: [SettingsNode] = []
        var labels: [(element: AXElement, frame: CGRect, clip: CGRect)] = []
        // Each element carries whether it sits inside the sidebar.
        var queue = [(element: window, clip: windowFrame, inSidebar: false)]
        var next = 0
        while next < queue.count {
            guard next < elementLimit, ContinuousClock.now < deadline else { throw Unread() }
            let (element, clip, inSidebar) = queue[next]
            next += 1
            let shape: [Result<CFTypeRef, AXFailure>]
            switch element.values([kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
                                   kAXIdentifierAttribute]) {
            case let .success(values):
                shape = values
            case let .failure(failure) where failure.code == .invalidUIElement:
                // Listed by its parent and not there when asked, as a few of
                // the sidebar's cells are in System Settings on macOS 27.2.
                // That is passed over only inside the element System
                // Settings itself names as its sidebar. Anywhere else it may
                // be a line that was replaced while the read ran, with the
                // line now in its place unread.
                guard inSidebar else { throw Unread() }
                continue
            case .failure:
                throw Unread()
            }
            let role = try present(shape[0]) as? String
            let frame = try frame(position: present(shape[1]), size: present(shape[2]))
            switch role {
            case kAXStaticTextRole:
                // Kept unread until the switches are known. A label without
                // a frame cannot sit on a line.
                if let frame { labels.append((element, frame, clip)) }
                continue
            case kAXCheckBoxRole, "AXSwitch":
                // A switch that cannot be placed could be a second line
                // named Intention.
                guard let frame else { throw Unread() }
                let isOn = try present(element.int(kAXValueAttribute)).map { $0 != 0 }
                // The switch's own title, where a list names its switches. Its
                // description is not asked for: on macOS 27.2 every switch
                // on these pages answers that read with a general failure,
                // which would cut every read short, and the names are in
                // the labels beside the switches.
                let isIntention = try present(element.string(kAXTitleAttribute)).map { SettingsList.isIntention($0, names: names) } ?? false
                toggles.append(SettingsNode(kind: .toggle(isOn: isOn, isIntention: isIntention), frame: frame, clip: clip))
                continue
            default:
                break
            }
            // A row scrolled out of view is still walked, so the guide can
            // tell "out of view" from "not listed"; the clip records how
            // much of the window it would show through.
            let inner = role == kAXScrollAreaRole ? frame.map { clip.intersection($0) } ?? clip : clip
            // Only an identifier that was read and is the sidebar's counts;
            // one that fails to answer leaves the element outside it.
            let inside = inSidebar || (try? shape[4].get()) as? String == Self.sidebar
            guard let children = try present(shape[3]) else { continue }
            guard CFGetTypeID(children) == CFArrayGetTypeID() else { throw Unread() }
            for child in children as! [AnyObject] {
                guard CFGetTypeID(child) == AXUIElementGetTypeID() else { throw Unread() }
                queue.append((AXElement(ref: child as! AXUIElement), inner, inside))
            }
        }
        let switchFrames = toggles.map(\.frame)
        var nodes = toggles
        for label in labels where SettingsList.isBesideSwitch(label.frame, toggles: switchFrames) {
            guard ContinuousClock.now < deadline else { throw Unread() }
            if let text = try present(label.element.string(kAXValueAttribute)), SettingsList.isIntention(text, names: names) {
                nodes.append(SettingsNode(kind: .intentionLabel, frame: label.frame, clip: label.clip))
            }
        }
        return SettingsList.locate(nodes)
    }

    /// An attribute's value, or nil when the element says it lacks it. Any
    /// other error, a timeout included, throws.
    private static func present<Value>(_ result: Result<Value, AXFailure>) throws -> Value? {
        switch result {
        case let .success(value): return value
        case let .failure(failure) where failure.code == .attributeUnsupported || failure.code == .noValue: return nil
        case .failure: throw Unread()
        }
    }

    /// Nil when the element lacks a position or size; throws when either
    /// is not a point or size.
    private static func frame(position: CFTypeRef?, size: CFTypeRef?) throws -> CGRect? {
        guard let position, let size else { return nil }
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { throw Unread() }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else {
            throw Unread()
        }
        return CGRect(origin: origin, size: extent)
    }
}
