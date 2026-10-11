import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit

// What the dot matrix and the reply timing run share: Accessibility reads,
// the guard that a window of theirs is the focused one, captures that hold
// only a window they opened and Intention's own panels, and a new window in the
// person's own Chrome Beta, made, recognised and closed by its own id, with
// a Gmail draft in it discarded through Gmail's own control. Each runner
// subclasses it and adds what it does in the window.
@MainActor
class OwnedWindows {
    var intention: NSRunningApplication?

    // MARK: Accessibility reads

    func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil }
    func str(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }
    func elem(_ e: AXUIElement, _ name: String) -> AXUIElement? { guard let v = attr(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }; return (v as! AXUIElement) }
    func elems(_ e: AXUIElement, _ name: String) -> [AXUIElement] { (attr(e, name) as? [AXUIElement]) ?? [] }
    /// The element's children, or nil when Accessibility did not answer:
    /// the app stopped answering, the element has gone, or the read was
    /// refused. An element with no children answers with none.
    func children(_ e: AXUIElement) -> [AXUIElement]? {
        var v: CFTypeRef?
        switch AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) {
        case .success: return (v as? [AXUIElement]) ?? []
        case .noValue, .attributeUnsupported: return []
        default: return nil
        }
    }
    /// Whether the element carries an address, as an email's links do and
    /// Gmail's own controls do not: nil when Accessibility did not answer,
    /// which is kept apart from an element with none.
    func linksOut(_ e: AXUIElement) -> Bool? {
        var v: CFTypeRef?
        switch AXUIElementCopyAttributeValue(e, kAXURLAttribute as CFString, &v) {
        case .success: return !((v as? URL)?.absoluteString ?? "").isEmpty
        case .noValue, .attributeUnsupported: return false
        default: return nil
        }
    }
    /// The tree walks the runners share (`TreeSearch.swift`), reading
    /// Accessibility: a link leads out when it carries an address, and a
    /// dialog is one by role or by a group's subrole.
    lazy var tree = TreeReader<AXUIElement>(
        children: { [unowned self] in children($0) },
        role: { [unowned self] in str($0, kAXRoleAttribute) },
        description: { [unowned self] in str($0, kAXDescriptionAttribute) },
        title: { [unowned self] in str($0, kAXTitleAttribute) },
        linksOut: { [unowned self] in linksOut($0) },
        isDialog: { [unowned self] e, role in
            if role == "AXSheet" || role == "AXDialog" || role == "AXPopover" { return true }
            guard role == "AXGroup", let subrole = str(e, kAXSubroleAttribute) else { return false }
            return subrole == "AXDialog" || subrole == "AXApplicationDialog" || subrole == "AXSystemDialog"
        })
    func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }
    func focusedWindow(_ pid: pid_t) -> AXUIElement? { elem(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) }
    func focusedElement(_ pid: pid_t) -> AXUIElement? { elem(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute) }
    /// The window server's ids of the on-screen windows of `pid`, with their
    /// bounds; nil when the window server does not answer.
    func serverWindows(of pid: pid_t) -> [(id: CGWindowID, bounds: CGRect)]? {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return infos.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let b = info[kCGWindowBounds as String] as? [String: NSNumber],
                  let bounds = CGRect(dictionaryRepresentation: b as CFDictionary),
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            return (number, bounds)
        }
    }
    /// The window server's id for an Accessibility window of `pid`: the
    /// on-screen window of that process with the same frame.
    func windowID(_ window: AXUIElement, pid: pid_t) -> CGWindowID? {
        guard let f = frame(window), let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in infos {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let b = info[kCGWindowBounds as String] as? [String: NSNumber],
                  let bounds = CGRect(dictionaryRepresentation: b as CFDictionary),
                  abs(bounds.minX - f.minX) <= 1, abs(bounds.minY - f.minY) <= 1, abs(bounds.width - f.width) <= 1, abs(bounds.height - f.height) <= 1,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            return number
        }
        return nil
    }
    /// The element whose description is `description` or starts with it,
    /// under `root`, breadth first; Gmail's discard control carries its
    /// shortcut after its name. Nil when there is none or the tree could
    /// not be read whole; `lookup` tells those apart.
    func element(described description: String, under root: AXUIElement, role: String? = nil) -> AXUIElement? {
        lookup(described: description, under: root, role: role).node
    }
    /// Whether the element described so is under `root`, is not, or could
    /// not be told: the page did not answer, or has more elements than
    /// one read covers.
    func lookup(described description: String, under root: AXUIElement, role: String? = nil) -> TreeLookup<AXUIElement> {
        guard str(root, kAXRoleAttribute) != nil else { return .unknown("the window did not answer") }
        return tree.element(described: description, role: role, under: root)
    }

    // MARK: Guards

    func frontmost(_ pid: pid_t) -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
    func guardWindow(_ pid: pid_t, _ window: AXUIElement) -> Bool {
        frontmost(pid) && focusedWindow(pid).map { CFEqual($0, window) } == true
    }
    func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

    func appleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { fputs("AppleScript: \(error)\n", stderr) }
        return result?.stringValue
    }

    // MARK: Captures of owned windows only

    var shareable: SCShareableContent?
    /// One image of the window `wid` of `pid`, cropped to `rect` in screen
    /// points, with Intention's own panels whose titles start with one of
    /// `panels` (its dot's, by default) composited in when `withDot`, and
    /// nothing else of the screen.
    func capture(window wid: CGWindowID, pid: pid_t, rect: CGRect, withDot: Bool, panels: [String] = ["dot "]) async -> (CGImage, CGFloat)? {
        // The window list is fetched again whenever the window asked for is
        // not in it, as each case's new window is not, and for the dot's
        // panels, which come and go.
        func find() -> SCWindow? { shareable?.windows.first { $0.windowID == wid && $0.owningApplication?.processID == pid } }
        if find() == nil || withDot { shareable = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        guard let content = shareable, let target = find(),
              let display = content.displays.first(where: { $0.frame.intersects(rect) }) else { return nil }
        var windows = [target]
        if withDot, let intention { windows += content.windows.filter { $0.owningApplication?.processID == intention.processIdentifier && $0.title.map { title in panels.contains { title.hasPrefix($0) } } == true } }
        let filter = SCContentFilter(display: display, including: windows)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        let crop = rect.intersection(display.frame)
        config.sourceRect = crop.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int(crop.width * scale)
        config.height = Int(crop.height * scale)
        config.captureResolution = .best
        config.ignoreShadowsDisplay = true
        config.showsCursor = false
        guard config.width > 0, config.height > 0, let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return (image, scale)
    }
    func save(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    // MARK: A window of the person's Chrome Beta

    /// The window made in the person's own Chrome Beta, by the
    /// id Chrome's scripting gives it, and whether a draft was discarded.
    var chromeBetaWindowID: String?
    var chromeBetaWindow: AXUIElement?
    /// The window server's id of the window made, the only one
    /// captures may hold.
    var chromeBetaServerWindow: CGWindowID?
    var chromeBetaNote = ""

    /// Opens a new window of the person's own Chrome Beta at `url` and
    /// returns it once it is the focused window, `settle` seconds later.
    /// Nil, with `chromeBetaNote` saying why, when anything is not as
    /// expected; a window made by then is closed.
    func openChromeBetaWindow(url: String, settle: Double) async -> (pid: pid_t, window: AXUIElement)? {
        // A new window of the person's own browser, found by the ids
        // Chrome's scripting gives its windows before and after.
        guard let beta = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome.beta").first else { return nil }
        // The window the matrix makes gets a rectangle no other window of
        // Chrome Beta has, so it is known by that rectangle alone: the
        // script confirms that exactly its window has those bounds, and
        // exactly one Accessibility window has that frame. Anything else
        // closes the made window and clicks nothing.
        let existing = (appleScript("tell application \"Google Chrome Beta\" to get bounds of every window") ?? "")
        var rect: CGRect?
        for step in 0..<20 {
            let candidate = CGRect(x: 120 + step * 7, y: 120, width: 980 - step * 3, height: 740)
            let bounds = "\(Int(candidate.minX)), \(Int(candidate.minY)), \(Int(candidate.maxX)), \(Int(candidate.maxY))"
            if !existing.contains(bounds) { rect = candidate; break }
        }
        guard let rect else { return nil }
        // The Accessibility and window server windows that exist before the
        // window is made are never the made one, whatever their frames;
        // both lists must answer before anything is made.
        var listValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(beta.processIdentifier), kAXWindowsAttribute as CFString, &listValue) == .success,
              let before = listValue as? [AXUIElement], let serverBefore = serverWindows(of: beta.processIdentifier) else {
            chromeBetaNote = "Chrome Beta's windows could not be listed; no window was made"
            return nil
        }
        let serverBeforeIDs = Set(serverBefore.map(\.id))
        let boundsText = "{\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.maxX)), \(Int(rect.maxY))}"
        // The made window's id comes back first, so it can be closed
        // whatever the rest of the answer says.
        guard let answer = appleScript("""
        tell application "Google Chrome Beta"
            set w to make new window
            set madeID to id of w as string
            try
                set URL of active tab of w to "\(url)"
                set bounds of w to \(boundsText)
                activate
                set matching to id of every window whose bounds is \(boundsText)
                set AppleScript's text item delimiters to ","
                return madeID & "|" & (matching as string)
            on error message
                return madeID & "|error " & message
            end try
        end tell
        """) else { return nil }
        let parts = answer.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, Int(parts[0]) != nil else { return nil }
        let id = String(parts[0])
        chromeBetaWindowID = id
        func closeMade(_ why: String) {
            chromeBetaNote = why + "; nothing was clicked, and the made window was closed"
            _ = appleScript("tell application \"Google Chrome Beta\" to close (first window whose id is \(id))")
            let remaining = (appleScript("tell application \"Google Chrome Beta\" to get id of every window") ?? "")
            if remaining.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(id) { chromeBetaNote += ", but it is still open" }
            chromeBetaWindowID = nil
        }
        guard parts[1] == parts[0] else { closeMade("the made window's bounds were not its alone (\(parts[1]))"); return nil }
        func same(_ f: CGRect) -> Bool { abs(f.minX - rect.minX) <= 1 && abs(f.minY - rect.minY) <= 1 && abs(f.width - rect.width) <= 1 && abs(f.height - rect.height) <= 1 }
        for _ in 0..<60 {
            let windows = elems(AXUIElementCreateApplication(beta.processIdentifier), kAXWindowsAttribute)
                .filter { candidate in frame(candidate).map(same) == true && !before.contains { CFEqual($0, candidate) } }
            // The window server must also show exactly one new window with
            // the made bounds; captures hold that one and no other.
            let serverNew = (serverWindows(of: beta.processIdentifier) ?? []).filter { !serverBeforeIDs.contains($0.id) && same($0.bounds) }
            if windows.count == 1, let made = windows.first, serverNew.count == 1, frontmost(beta.processIdentifier),
               let w = focusedWindow(beta.processIdentifier), CFEqual(w, made) {
                chromeBetaWindow = made
                chromeBetaServerWindow = serverNew[0].id
                await sleep(settle)
                return (beta.processIdentifier, made)
            }
            await sleep(0.25)
        }
        closeMade("Chrome Beta did not focus the one new window with the made bounds")
        return nil
    }

    /// Presses Gmail's own "Discard draft" control in the made window, only
    /// while that window is the focused one, and says what happened.
    func discardDraft() async -> String {
        // The discard control is looked for only in the made window, and
        // only while that window is the focused one.
        guard let beta = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome.beta").first,
              let w = chromeBetaWindow, guardWindow(beta.processIdentifier, w) else {
            return "the made window was no longer the focused one; the draft, if any, was left"
        }
        guard let discard = element(described: "Discard draft", under: w) else { return "no Discard draft control found; the draft, if any, was left" }
        guard AXUIElementPerformAction(discard, kAXPressAction as CFString) == .success else { return "Gmail's discard control did not take the press" }
        await sleep(1.5)
        return "draft discarded through Gmail's control"
    }

    /// Closes the made window by its id, never another, and forgets it
    /// once Chrome's own list of windows no longer has it. False, with the
    /// window still remembered, when it is still open afterwards, a sheet
    /// over it included, or when Chrome would not list its windows in
    /// three tries, so a window is never taken for closed on a failed
    /// read.
    func closeMadeWindow() async -> Bool {
        guard let id = chromeBetaWindowID else { return true }
        _ = appleScript("tell application \"Google Chrome Beta\" to close (first window whose id is \(id))")
        await sleep(0.8)
        var listed: String?
        for attempt in 0..<3 {
            if attempt > 0 { await sleep(0.5) }
            listed = appleScript("tell application \"Google Chrome Beta\" to get id of every window")
            if listed != nil { break }
        }
        guard let listed else { return false }
        let remaining = listed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !remaining.contains(id) else { return false }
        chromeBetaWindowID = nil
        chromeBetaWindow = nil
        chromeBetaServerWindow = nil
        return true
    }
}
