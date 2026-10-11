import AppKit
import ApplicationServices
import AVFoundation
import ScreenCaptureKit

/// A recorded tour of real apps for visual evidence of the resting dot.
///
/// It records the main display in real time while typing synthetic text into
/// ordinary writing surfaces. Every key is guarded: the screen must be
/// unlocked, the scene's app frontmost, and the focused element one of that
/// app's text controls. Any guard failure ends the tour; nothing is retried
/// into another app. The tour never presses Return outside its own TextEdit
/// document, never submits, and never types into this machine's other apps.
/// It measures nothing: the recording is for a person to inspect.
@MainActor
enum CaretTour {
    enum Failure: Error, CustomStringConvertible {
        case locked, frontmost(String), focus(String), launch(String), recorder(String)
        var description: String {
            switch self {
            case .locked: "desktop locked"
            case let .frontmost(app): "expected \(app) frontmost"
            case let .focus(app): "no text control focused in \(app)"
            case let .launch(app): "could not open \(app)"
            case let .recorder(reason): "recorder: \(reason)"
            }
        }
    }

    struct Scene: Codable {
        let title: String
        var start: Double
        var end: Double = 0
        var outcome = "ran"
    }

    /// Closes Chrome windows whose page is a tour page under `evidence`,
    /// left by earlier tours. Other windows are untouched.
    static func cleanup(evidence: URL) -> Int32 {
        let prefix = evidence.absoluteString
        var error: NSDictionary?
        let result = NSAppleScript(source: """
        tell application "Google Chrome"
            set closed to 0
            repeat with w in (every window)
                try
                    set u to URL of active tab of w
                    if u starts with "\(prefix)" and u ends with "/tour-fields.html" and (count of tabs of w) is 1 then
                        close w
                        set closed to closed + 1
                    end if
                end try
            end repeat
            return closed
        end tell
        """)?.executeAndReturnError(&error)
        print("closed \(result?.int32Value ?? -1) tour windows")
        // Report what remains: tab counts and whether each tab is a tour page.
        let remaining = NSAppleScript(source: """
        tell application "Google Chrome"
            set report to ""
            repeat with w in (every window)
                set tourTabs to 0
                repeat with t in (every tab of w)
                    try
                        if (URL of t) starts with "\(prefix)" then set tourTabs to tourTabs + 1
                    end try
                end repeat
                set report to report & "window tabs=" & (count of tabs of w) & " tourTabs=" & tourTabs & linefeed
            end repeat
            return report
        end tell
        """)?.executeAndReturnError(nil)
        print(remaining?.stringValue ?? "no report")
        fflush(stdout)
        return error == nil ? 0 : 1
    }

    /// Records the frontmost app's focused text control's geometry answers,
    /// attribute names and ancestor roles; lengths only, never text. It
    /// reads nothing else and sends no input.
    @MainActor
    static func probeFocused(output: URL, focus: Bool = false) -> Int32 {
        let tour = Tour(output: output, caption: nil, clock: .now)
        if focus {
            guard tour.focusOnlyTextControl() else { print("no single settable text control to focus"); return 1 }
            Thread.sleep(forTimeInterval: 0.8)
        }
        return tour.probeFrontmost() ? 0 : 1
    }

    @MainActor
    static func probePanel(output: URL) async -> Int32 {
        NSApp.setActivationPolicy(.accessory)
        return await Tour(output: output, caption: nil, clock: .now).probePanel() ? 0 : 1
    }

    /// For the frontmost app: whether its accessibility tree appears after
    /// each client request Intention can make. Records roles and counts only,
    /// and restores AXEnhancedUserInterface to its earlier value.
    @MainActor
    static func axBootstrapProbe(output: URL) -> Int32 {
        guard let front = NSWorkspace.shared.frontmostApplication else { return 1 }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        func census(_ label: String) -> String {
            var focusedRole = "none"
            if let focused = attr(app, kAXFocusedUIElementAttribute) { focusedRole = attr(focused as! AXUIElement, kAXRoleAttribute) as? String ?? "?" }
            var queue: [AXUIElement] = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            var visited = 0, text = 0, web = 0
            while !queue.isEmpty, visited < 6000 {
                let node = queue.removeFirst()
                visited += 1
                let role = attr(node, kAXRoleAttribute) as? String ?? ""
                if [kAXTextFieldRole, kAXTextAreaRole].contains(role) { text += 1 }
                if role == "AXWebArea" { web += 1 }
                queue += (attr(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            }
            return "\(label): elements=\(visited) textControls=\(text) webAreas=\(web) focusedRole=\(focusedRole)"
        }
        var lines = ["app=\(front.bundleIdentifier ?? "?")",
                     "AXManualAccessibility=\(String(describing: attr(app, "AXManualAccessibility"))) AXEnhancedUserInterface=\(String(describing: attr(app, "AXEnhancedUserInterface")))",
                     census("before")]
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 1.5)
        lines.append("set AXManualAccessibility -> \(manual.rawValue)")
        lines.append(census("after manual"))
        let earlier = attr(app, "AXEnhancedUserInterface") as? Bool ?? false
        let enhanced = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 1.5)
        lines.append("set AXEnhancedUserInterface -> \(enhanced.rawValue)")
        lines.append(census("after enhanced"))
        if !earlier { _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        // Chrome takes the request on its window rather than the app.
        if let window = attr(app, kAXFocusedWindowAttribute) {
            let windowElement = window as! AXUIElement
            let windowEarlier = attr(windowElement, "AXEnhancedUserInterface") as? Bool ?? false
            let onWindow = AXUIElementSetAttributeValue(windowElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            let manualWindow = AXUIElementSetAttributeValue(windowElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 3)
            lines.append("window AXEnhancedUserInterface -> \(onWindow.rawValue), AXManualAccessibility -> \(manualWindow.rawValue)")
            lines.append(census("after window requests, 3 s"))
            if !windowEarlier { _ = AXUIElementSetAttributeValue(windowElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        }
        var roles: [String] = []
        var queue: [(AXUIElement, Int)] = ((attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).map { ($0, 0) }
        while !queue.isEmpty, roles.count < 60 {
            let (node, depth) = queue.removeFirst()
            roles.append(String(repeating: "  ", count: depth) + (attr(node, kAXRoleAttribute) as? String ?? "?") + "/" + (attr(node, kAXSubroleAttribute) as? String ?? "-"))
            queue = ((attr(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []).map { ($0, depth + 1) } + queue
        }
        lines.append("tree:\n" + roles.joined(separator: "\n"))
        try? (lines.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("ax-bootstrap.txt"), atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
        return 0
    }

    /// For the frontmost app: whether hit-testing and querying its window's
    /// innermost elements makes its accessibility tree appear. Records roles
    /// and counts only; changes no setting.
    @MainActor
    static func axWakeProbe(output: URL) -> Int32 {
        guard let front = NSWorkspace.shared.frontmostApplication else { return 1 }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        func census(_ label: String) -> String {
            var queue: [AXUIElement] = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            var visited = 0, text = 0, web = 0
            while !queue.isEmpty, visited < 6000 {
                let node = queue.removeFirst()
                visited += 1
                let role = attr(node, kAXRoleAttribute) as? String ?? ""
                if [kAXTextFieldRole, kAXTextAreaRole].contains(role) { text += 1 }
                if role == "AXWebArea" { web += 1 }
                queue += (attr(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            }
            let focused = attr(app, kAXFocusedUIElementAttribute).map { attr($0 as! AXUIElement, kAXRoleAttribute) as? String ?? "?" } ?? "none"
            return "\(label): elements=\(visited) textControls=\(text) webAreas=\(web) focusedRole=\(focused)"
        }
        var lines = ["app=\(front.bundleIdentifier ?? "?")", census("before")]
        guard let window = attr(app, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else { print("no window"); return 1 }
        var origin = CGPoint.zero, size = CGSize.zero
        if let v = attr(window, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &origin) }
        if let v = attr(window, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
        // Query every element's attribute names, focus and parameterized names.
        var queue: [AXUIElement] = [window]
        while !queue.isEmpty {
            let node = queue.removeFirst()
            var names: CFArray?
            AXUIElementCopyAttributeNames(node, &names)
            AXUIElementCopyParameterizedAttributeNames(node, &names)
            _ = attr(node, kAXFocusedUIElementAttribute)
            _ = attr(node, "AXSelectedTextMarkerRange")
            queue += (attr(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        Thread.sleep(forTimeInterval: 1)
        lines.append(census("after attribute queries"))
        // Hit-test a grid of points inside the window, including the
        // composer near the bottom.
        var hits: [String: Int] = [:]
        for fy in stride(from: 0.2, through: 0.95, by: 0.15) {
            for fx in stride(from: 0.2, through: 0.8, by: 0.2) {
                var element: AXUIElement?
                let code = AXUIElementCopyElementAtPosition(app, Float(origin.x + size.width * fx), Float(origin.y + size.height * fy), &element)
                let role = element.flatMap { attr($0, kAXRoleAttribute) as? String } ?? "err\(code.rawValue)"
                hits[role, default: 0] += 1
            }
        }
        lines.append("hit roles: \(hits.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: " "))")
        Thread.sleep(forTimeInterval: 2)
        lines.append(census("after hit tests, 2 s"))
        try? (lines.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("ax-wake.txt"), atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
        return 0
    }

    /// Presses Continue on Spotlight's first-run notice, which the person
    /// approved: only a button titled Continue, in a Spotlight panel whose
    /// text is that notice. Nothing else is pressed or typed.
    @MainActor
    static func acceptSpotlightNotice() async -> Int32 {
        guard ProcessSafety.allowsCheckInput else { return 1 }
        func panelPID() -> pid_t? {
            guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
            return windows.first { ["Spotlight", "Siri"].contains($0[kCGWindowOwnerName as String] as? String ?? "")
                && (($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) >= 20 }
                .flatMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value }
        }
        func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        if panelPID() == nil {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 49, keyDown: down)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(900))
        }
        guard let pid = panelPID() else { print("no Spotlight panel"); return 1 }
        var queue = [AXUIElementCreateApplication(pid)], texts: [String] = [], buttons: [AXUIElement] = [], visited = 0
        while !queue.isEmpty, visited < 3000 {
            let node = queue.removeFirst()
            visited += 1
            let role = attr(node, kAXRoleAttribute) as? String
            for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let text = attr(node, key) as? String, !text.isEmpty { texts.append(text) }
            }
            if role == kAXButtonRole, (attr(node, kAXTitleAttribute) as? String) == "Continue" || (attr(node, kAXDescriptionAttribute) as? String) == "Continue" {
                buttons.append(node)
            }
            queue += (attr(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        let notice = texts.contains { $0.contains("Spotlight sends your search requests and approximate location to Apple") }
        guard notice, buttons.count == 1 else {
            print("notice=\(notice) continueButtons=\(buttons.count); nothing pressed")
            for text in texts where text.localizedCaseInsensitiveContains("spotlight") || text.localizedCaseInsensitiveContains("apple") {
                print("text: \(text.prefix(160).debugDescription)")
            }
            return notice ? 1 : 3
        }
        let result = AXUIElementPerformAction(buttons[0], kAXPressAction as CFString)
        print("pressed Continue: \(result.rawValue)")
        return result == .success ? 0 : 1
    }

    /// Records one scene in an app that exposes no accessible text, such
    /// as Codex: clicks its composer at `point`, types synthetic words,
    /// moves with the arrow keys and deletes exactly what it typed. Return
    /// is never pressed. Every event requires the app frontmost; the click
    /// also requires `point` inside the app's own frontmost window.
    static func runOpaque(output: URL, bundle: String, point: CGPoint, idle: Double? = nil) async -> Int32 {
        NSApp.setActivationPolicy(.accessory)
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            print("BLOCKED opaque scene: Accessibility and Screen Recording are required")
            return 2
        }
        let caption = Caption()
        let recorder: Recorder
        do { recorder = try await Recorder(url: output.appendingPathComponent("tour.mov")) } catch {
            print("BLOCKED opaque scene: \(error)")
            return 2
        }
        let tour = Tour(output: output, caption: caption, clock: recorder.clock)
        var status: Int32 = 0
        do { try await tour.playOpaque(bundle: bundle, point: point, idle: idle) } catch {
            print("STOPPED opaque scene: \(error)")
            if !tour.scenes.isEmpty { tour.scenes[tour.scenes.count - 1].outcome = "stopped: \(error)" }
            status = 1
        }
        caption.show("End of scene")
        try? await Task.sleep(for: .seconds(1))
        do { try await recorder.finish() } catch { print("FAIL recording: \(error)"); status = 1 }
        try? JSONEncoder().encode(tour.scenes).write(to: output.appendingPathComponent("scenes.json"))
        print("Scene video: \(output.appendingPathComponent("tour.mov").path)")
        return status
    }

    static func run(output: URL) async -> Int32 {
        NSApp.setActivationPolicy(.accessory)
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            print("BLOCKED tour: Accessibility and Screen Recording are required")
            return 2
        }
        let caption = Caption()
        let recorder: Recorder
        do { recorder = try await Recorder(url: output.appendingPathComponent("tour.mov")) } catch {
            print("BLOCKED tour: \(error)")
            return 2
        }
        let tour = Tour(output: output, caption: caption, clock: recorder.clock)
        var status: Int32 = 0
        do { try await tour.play() } catch {
            print("STOPPED tour: \(error)")
            tour.scenes[tour.scenes.count - 1].outcome = "stopped: \(error)"
            status = 1
        }
        caption.show("End of tour")
        try? await Task.sleep(for: .seconds(1))
        do { try await recorder.finish() } catch { print("FAIL tour recording: \(error)"); status = 1 }
        let data = try? JSONEncoder().encode(tour.scenes)
        try? data?.write(to: output.appendingPathComponent("scenes.json"))
        print("Tour video: \(output.appendingPathComponent("tour.mov").path)")
        return status
    }
}

/// A caption above the apps. It never takes focus or mouse events.
@MainActor
private final class Caption {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init() {
        let screen = NSScreen.screens[0].frame
        panel = NSPanel(contentRect: CGRect(x: screen.midX - 330, y: screen.minY + 84, width: 660, height: 30),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.backgroundColor = NSColor(white: 0.1, alpha: 0.82)
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 8, y: 6, width: 644, height: 18)
        panel.contentView?.addSubview(label)
    }

    func show(_ text: String) {
        label.stringValue = text
        panel.orderFrontRegardless()
    }
}

/// Real-time display recording, including the caption and every app window.
private final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let stream: SCStream
    private let queue = DispatchQueue(label: "tour.recorder")
    private var started = false
    private var frames = 0
    let clock = ContinuousClock.now

    @MainActor
    init(url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
            throw CaretTour.Failure.recorder("no main display")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = Int(filter.pointPixelScale)
        let width = display.width * scale / 2 * 2, height = display.height * scale / 2 * 2
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = false
        config.queueDepth = 6
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 8],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaretTour.Failure.recorder("writer input") }
        writer.add(input)
        guard writer.startWriting() else { throw CaretTour.Failure.recorder(writer.error?.localizedDescription ?? "start") }
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            writer.startSession(atSourceTime: sample.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData, input.append(sample) { frames += 1 }
    }

    func finish() async throws {
        try await stream.stopCapture()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed, frames > 0 else {
            throw CaretTour.Failure.recorder(writer.error?.localizedDescription ?? "no frames")
        }
        print("Recorded \(frames) frames")
    }
}

@MainActor
private final class Tour {
    let output: URL
    let caption: Caption?
    let clock: ContinuousClock.Instant
    var scenes: [CaretTour.Scene] = []
    private var app = ""
    private var bundle = ""
    /// The scene's field is in another process's floating panel, such as
    /// Spotlight, which holds keyboard focus while another app is in front.
    private var panelScene = false

    init(output: URL, caption: Caption?, clock: ContinuousClock.Instant) {
        self.output = output
        self.caption = caption
        self.clock = clock
    }

    private var now: Double {
        let c = (ContinuousClock.now - clock).components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    /// `--only <text>` limits the tour to scenes whose title contains it.
    private let only: String? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--only"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }()

    private func scene(_ title: String, app: String, bundle: String, panel: Bool = false, _ body: () async throws -> Void) async throws {
        if let only, !title.contains(only) { return }
        panelScene = panel
        if !scenes.isEmpty { scenes[scenes.count - 1].end = now }
        scenes.append(.init(title: title, start: now))
        self.app = app
        self.bundle = bundle
        caption?.show("\(scenes.count). \(title)")
        try await body()
        scenes[scenes.count - 1].end = now
    }

    // MARK: Guards

    private func frontmostIsScene() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle
    }

    private func focusedTextControl() -> Bool {
        var value: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let element = value as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundle else { return false }
        guard panelScene || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role as? String ?? "")
    }

    private func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Geometry answers of the focused control, for diagnosis. Lengths and
    /// rectangles only; never its text.
    private func probe(_ name: String) {
        guard focusedTextControl(), let element = focusedElement() else { return }
        func attr(_ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        func rect(_ value: CFTypeRef?) -> String {
            var r = CGRect.zero
            guard let value, CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgRect, &r) else { return "nil" }
            return NSStringFromRect(r)
        }
        func bounds(_ location: Int, _ length: Int) -> String {
            var range = CFRange(location: location, length: length)
            var result: CFTypeRef?
            guard location >= 0, let argument = AXValueCreate(.cfRange, &range),
                  AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, argument, &result) == .success else { return "error" }
            return rect(result)
        }
        var selection = CFRange()
        if let value = attr(kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cfRange, &selection) }
        var position = CGPoint.zero, size = CGSize.zero
        if let value = attr(kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &position) }
        if let value = attr(kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
        var lines = ["scene=\(name) role=\(attr(kAXRoleAttribute) as? String ?? "?") subrole=\(attr(kAXSubroleAttribute) as? String ?? "-")",
                     "frame=\(NSStringFromRect(CGRect(origin: position, size: size))) selection=\(selection.location),\(selection.length) characters=\(String(describing: (attr(kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue))",
                     "collapsed=\(bounds(selection.location, 0)) after=\(bounds(selection.location, 1)) before=\(bounds(selection.location - 1, 1)) first=\(bounds(0, 1))"]
        if let marker = attr("AXSelectedTextMarkerRange") {
            var result: CFTypeRef?
            _ = AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString, marker, &result)
            lines.append("marker=\(rect(result))")
        }
        for key in [kAXValueAttribute, kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute] {
            var settable = DarwinBoolean(false)
            let code = AXUIElementIsAttributeSettable(element, key as CFString, &settable)
            lines.append("settable \(key)=\(settable.boolValue) code=\(code.rawValue)")
        }
        var windowValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue)
        var current: AXUIElement? = element
        for depth in 0..<40 {
            guard let node = current else { lines.append("ancestor \(depth) missing parent"); break }
            var role: CFTypeRef?, subrole: CFTypeRef?, parent: CFTypeRef?
            let roleCode = AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
            let subroleCode = AXUIElementCopyAttributeValue(node, kAXSubroleAttribute as CFString, &subrole)
            let subroleType = subrole.map { CFGetTypeID($0) == CFStringGetTypeID() ? "string" : "type\(CFGetTypeID($0))" } ?? "none"
            lines.append("ancestor \(depth) role=\(role as? String ?? "?")(\(roleCode.rawValue)) subrole=\(subrole as? String ?? "-")(\(subroleCode.rawValue),\(subroleType))")
            if let windowValue, CFEqual(node, windowValue) { lines.append("ancestor \(depth) is window"); break }
            let parentCode = AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent)
            if parentCode != .success { lines.append("ancestor \(depth) parent error \(parentCode.rawValue)") }
            current = parent.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        var names: CFArray?
        AXUIElementCopyParameterizedAttributeNames(element, &names)
        lines.append("parameterized=\(((names as? [String]) ?? []).joined(separator: ","))")
        AXUIElementCopyAttributeNames(element, &names)
        lines.append("attributes=\(((names as? [String]) ?? []).joined(separator: ","))")
        let url = output.appendingPathComponent("probe-\(name).txt")
        try? (((try? String(contentsOf: url, encoding: .utf8)) ?? "") + lines.joined(separator: "\n") + "\n\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Focuses the front window's only settable text control, without
    /// typing, so its caret geometry can be probed.
    func focusOnlyTextControl() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        guard let window = attr(AXUIElementCreateApplication(front.processIdentifier), kAXFocusedWindowAttribute) else { return false }
        var queue = [window as! AXUIElement], visited = 0, controls: [AXUIElement] = []
        while !queue.isEmpty, visited < 4000 {
            let node = queue.removeFirst()
            visited += 1
            if [kAXTextFieldRole, kAXTextAreaRole].contains(attr(node, kAXRoleAttribute) as? String ?? "") {
                var settable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &settable)
                if settable.boolValue, (attr(node, kAXSubroleAttribute) as? String) != kAXSecureTextFieldSubrole { controls.append(node) }
            }
            queue += (attr(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        guard controls.count == 1 else { return false }
        return AXUIElementSetAttributeValue(controls[0], kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    func probeFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier else { return false }
        bundle = id
        app = front.localizedName ?? id
        guard focusedTextControl() else {
            func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
            }
            var lines = ["frontmost=\(id) focused element is not a text control of that app"]
            if let focused = focusedElement() {
                lines.append("focused role=\(attr(focused, kAXRoleAttribute) as? String ?? "?") subrole=\(attr(focused, kAXSubroleAttribute) as? String ?? "-")")
            }
            // Text controls in the front window: roles, subroles and frames.
            let appElement = AXUIElementCreateApplication(front.processIdentifier)
            if let window = attr(appElement, kAXFocusedWindowAttribute) {
                var queue = [window as! AXUIElement], visited = 0
                while !queue.isEmpty, visited < 4000 {
                    let node = queue.removeFirst()
                    visited += 1
                    let role = attr(node, kAXRoleAttribute) as? String ?? ""
                    if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) || (attr(node, "AXEditableAncestor") != nil && role != "AXStaticText" && attr(node, kAXChildrenAttribute).map { ($0 as? [AXUIElement])?.isEmpty == false } == true && lines.count < 30 && role == "AXGroup") {
                        var position = CGPoint.zero, size = CGSize.zero
                        if let value = attr(node, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &position) }
                        if let value = attr(node, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
                        var settable = DarwinBoolean(false)
                        AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &settable)
                        lines.append("control role=\(role) subrole=\(attr(node, kAXSubroleAttribute) as? String ?? "-") frame=\(NSStringFromRect(CGRect(origin: position, size: size))) valueSettable=\(settable.boolValue) focused=\((attr(node, kAXFocusedAttribute) as? NSNumber)?.boolValue ?? false)")
                    }
                    queue += (attr(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []
                }
                lines.append("visited \(visited) elements")
            }
            try? (lines.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("probe-focused.txt"), atomically: true, encoding: .utf8)
            return false
        }
        probe("focused")
        return true
    }

    /// Opens Spotlight, records its empty field's geometry answers and the
    /// owner's window list (levels and frames, no titles), and closes it.
    /// Nothing is typed.
    func probePanel() async -> Bool {
        bundle = "com.apple.campo"
        app = "Spotlight"
        panelScene = true
        do {
            try await key(49, flags: .maskCommand, requireText: false)
            try await awaitFocus()
        } catch { return false }
        try? await pause(0.6)
        probe("panel-empty")
        var lines: [String] = []
        if let focused = focusedElement() {
            var pid: pid_t = 0
            AXUIElementGetPid(focused, &pid)
            var window: CFTypeRef?, position: CFTypeRef?, size: CFTypeRef?
            AXUIElementCopyAttributeValue(focused, kAXWindowAttribute as CFString, &window)
            if let window {
                AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &position)
                AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &size)
                var origin = CGPoint.zero, extent = CGSize.zero
                if let position { AXValueGetValue(position as! AXValue, .cgPoint, &origin) }
                if let size { AXValueGetValue(size as! AXValue, .cgSize, &extent) }
                lines.append("ax window frame=\(NSStringFromRect(CGRect(origin: origin, size: extent)))")
            }
            let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
            for info in windows where (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid {
                let bounds = (info[kCGWindowBounds as String] as? [String: NSNumber]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
                lines.append("cg window layer=\((info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1) alpha=\((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1) bounds=\(NSStringFromRect(bounds))")
            }
        }
        let url = output.appendingPathComponent("probe-panel-empty.txt")
        try? (((try? String(contentsOf: url, encoding: .utf8)) ?? "") + lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try? await key(53, requireText: false)
        return true
    }

    /// Tab to the next field, confirming focus actually moved.
    private func nextField() async throws {
        let before = focusedElement()
        for _ in 0..<3 {
            try await key(48, requireText: false)
            try await pause(0.3)
            if let now = focusedElement(), before.map({ !CFEqual($0, now) }) ?? true, focusedTextControl() { return }
        }
        throw CaretTour.Failure.focus(app)
    }

    /// A left click at `point` (global points, top-left origin), only when
    /// the scene's app is frontmost and its own window is the topmost one
    /// there.
    private func click(_ point: CGPoint) throws {
        guard ProcessSafety.allowsCheckInput else { throw CaretTour.Failure.focus(app) }
        guard unlocked() else { throw CaretTour.Failure.locked }
        guard frontmostIsScene(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { throw CaretTour.Failure.frontmost(app) }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let topmost = windows.first {
            (($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 1) == 0
                && (($0[kCGWindowBounds as String] as? [String: NSNumber]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }?.contains(point) ?? false)
        }
        guard (topmost?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { throw CaretTour.Failure.focus(app) }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    func playOpaque(bundle: String, point: CGPoint, idle: Double? = nil) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { throw CaretTour.Failure.launch(bundle) }
        let name = FileManager.default.displayName(atPath: url.path)
        try await scene("\(name) composer (no accessible text)", app: name, bundle: bundle) {
            try await open([], with: url.path)
            try await pause(0.8)
            try click(point)
            // Idle: the click only, then watching the caret blink.
            if let idle {
                try await pause(idle)
                return
            }
            try await pause(1.5)
            try await type("hello dot tour", requireText: false)
            try await pause(1.5)
            try await key(123, times: 4, requireText: false)
            try await key(124, times: 4, requireText: false)
            try await pause(0.8)
            try await key(51, times: 14, pace: 0.12, requireText: false)
            try await pause(1.5)
        }
    }

    private func unlocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session != nil && (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue != true
    }

    private func post(_ code: CGKeyCode, text: String? = nil, flags: CGEventFlags = [], requireText: Bool, allowAnyFrontmost: Bool = false) throws {
        guard ProcessSafety.allowsCheckInput else { throw CaretTour.Failure.focus(app) }
        for down in [true, false] {
            guard unlocked() else { throw CaretTour.Failure.locked }
            guard allowAnyFrontmost || panelScene || frontmostIsScene() else { throw CaretTour.Failure.frontmost(app) }
            if requireText, !focusedTextControl() { throw CaretTour.Failure.focus(app) }
            guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: code, keyDown: down) else { return }
            event.flags = flags
            if let text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.post(tap: .cghidEventTap)
        }
    }

    private func type(_ text: String, pace: Double = 0.09, requireText: Bool = true) async throws {
        for character in text {
            try post(0, text: String(character), requireText: requireText)
            try await Task.sleep(for: .seconds(pace))
        }
    }

    private func key(_ code: CGKeyCode, times: Int = 1, flags: CGEventFlags = [], pace: Double = 0.14, requireText: Bool = true) async throws {
        for _ in 0..<times {
            try post(code, flags: flags, requireText: requireText)
            try await Task.sleep(for: .seconds(pace))
        }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
        guard unlocked() else { throw CaretTour.Failure.locked }
    }

    /// Waits for the scene's app to be frontmost with a text control focused.
    private func awaitFocus(_ seconds: Double = 6) async throws {
        let until = now + seconds
        while now < until {
            if unlocked(), panelScene || frontmostIsScene(), focusedTextControl() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CaretTour.Failure.focus(app)
    }

    private func awaitFrontmost(_ seconds: Double = 8) async throws {
        let until = now + seconds
        while now < until {
            if frontmostIsScene() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CaretTour.Failure.frontmost(app)
    }

    private func open(_ urls: [URL], with appPath: String) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            if urls.isEmpty {
                _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: config)
            } else {
                _ = try await NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: appPath), configuration: config)
            }
        } catch { throw CaretTour.Failure.launch(app) }
        try await awaitFrontmost()
    }

    private func appleScript(_ source: String) throws {
        var error: NSDictionary?
        guard NSAppleScript(source: source)?.executeAndReturnError(&error) != nil, error == nil else {
            throw CaretTour.Failure.launch(app)
        }
    }

    // MARK: Scenes

    func play() async throws {
        try await dismissSpotlight()
        let page = output.appendingPathComponent("tour-fields.html")
        try Self.page.write(to: page, atomically: true, encoding: .utf8)
        let note = output.appendingPathComponent("Tour note.txt")
        try "A synthetic note for the Intention caret tour.\n".write(to: note, atomically: true, encoding: .utf8)
        let arrows: (Int) async throws -> Void = { count in
            try await self.key(123, times: count)
            try await self.key(124, times: count)
        }

        try await scene("TextEdit: typing, new lines, arrows and deletion", app: "TextEdit", bundle: "com.apple.TextEdit") {
            try await open([note], with: "/System/Applications/TextEdit.app")
            try await awaitFocus()
            try await key(125, flags: .maskCommand)
            try await pause(0.8)
            try await type("The dot rides on the caret as I type.")
            probe("textedit")
            try await key(36)
            try await key(36)
            try await pause(0.6)
            try await type("New lines, wrapping and deleting keep it in place, even across a long sentence that runs on.")
            try await pause(0.6)
            try await arrows(6)
            try await key(126)
            try await key(125)
            try await key(51, times: 12, pace: 0.08)
            try await pause(1)
            try await key(13, flags: .maskCommand, requireText: false)
            try await pause(0.8)
        }

        try await scene("Chrome page: search box, message box, rich composer", app: "Google Chrome", bundle: "com.google.Chrome") {
            try appleScript("""
            tell application "Google Chrome"
                set w to make new window
                set URL of active tab of w to "\(page.absoluteString)"
            end tell
            """)
            // An accessory process's Apple Event cannot activate Chrome;
            // LaunchServices can.
            try await open([], with: "/Applications/Google Chrome.app")
            do { try await awaitFocus(4) } catch {
                // Autofocus applies on load; a page loaded behind another
                // window reloads once in front.
                try await key(15, flags: .maskCommand, requireText: false)
                try await awaitFocus(6)
            }
            try await pause(1.2)
            try await type("synthetic search words")
            probe("chrome-input")
            try await arrows(5)
            try await key(51, times: 6, pace: 0.08)
            try await pause(0.6)
            try await nextField()
            try await pause(1.2)
            try await type("A message box that wraps onto a second line when the words keep coming.")
            try await pause(0.6)
            try await key(51, times: 10, pace: 0.08)
            try await nextField()
            try await pause(1.2)
            try await type("Rich composer text")
            try await arrows(4)
            try await key(51, times: 18, pace: 0.06)
            try await pause(1.2)
        }

        try await scene("Chrome address bar", app: "Google Chrome", bundle: "com.google.Chrome") {
            try await open([], with: "/Applications/Google Chrome.app")
            try await key(37, flags: .maskCommand, requireText: false)
            try await awaitFocus()
            try await pause(0.8)
            try await type("intention caret tour")
            probe("chrome-omnibox")
            try await arrows(4)
            try await key(51, times: 17, pace: 0.07)
            try await pause(0.8)
            try await key(53, times: 2, requireText: false)
            try? appleScript("""
            tell application "Google Chrome"
                repeat with w in (every window)
                    try
                        if (URL of active tab of w) is "\(page.absoluteString)" then close w
                    end try
                end repeat
            end tell
            """)
            try await pause(0.5)
        }

        try await scene("Safari page fields and address bar", app: "Safari", bundle: "com.apple.Safari") {
            try await open([page], with: "/Applications/Safari.app")
            try await awaitFocus(8)
            try await pause(1.2)
            try await type("safari search words")
            probe("safari-input")
            try await arrows(4)
            try await key(51, times: 5, pace: 0.08)
            try await nextField()
            try await pause(1)
            try await type("Typing in Safari's message box.")
            try await key(51, times: 8, pace: 0.08)
            try await key(37, flags: .maskCommand, requireText: false)
            try await awaitFocus()
            try await pause(0.8)
            try await type("intention caret")
            probe("safari-address")
            try await key(51, times: 12, pace: 0.07)
            try await key(53, times: 2, requireText: false)
            try await pause(0.4)
            try await key(13, flags: .maskCommand, requireText: false)
            try await pause(0.5)
        }

        try await scene("Finder search field", app: "Finder", bundle: "com.apple.finder") {
            try await open([output], with: "/System/Library/CoreServices/Finder.app")
            try await pause(0.8)
            try await key(3, flags: .maskCommand, requireText: false)
            try await awaitFocus()
            try await pause(0.8)
            try await type("tour")
            probe("finder-search")
            try await arrows(3)
            try await key(51, times: 4, pace: 0.1)
            try await pause(0.6)
            try await key(53, requireText: false)
            try await key(13, flags: .maskCommand, requireText: false)
            try await pause(0.5)
        }

        try await scene("Dictionary search field", app: "Dictionary", bundle: "com.apple.Dictionary") {
            try await open([], with: "/System/Applications/Dictionary.app")
            try await awaitFocus()
            try await pause(0.8)
            try await type("caret")
            probe("dictionary-search")
            try await arrows(3)
            try await key(51, times: 5, pace: 0.1)
            try await pause(0.8)
            try await key(12, flags: .maskCommand, requireText: false)
            try await pause(0.5)
        }

        try await scene("Spotlight search", app: "Spotlight", bundle: "com.apple.campo", panel: true) {
            try await key(49, flags: .maskCommand, requireText: false)
            try await awaitFocus()
            try await pause(0.8)
            try await type("caret dot tour")
            probe("spotlight")
            try await arrows(4)
            try await key(51, times: 14, pace: 0.08)
            try await pause(0.8)
            try await key(53, requireText: false)
            try await pause(0.6)
        }
    }

    /// A Spotlight panel left open (this machine shows its first-run
    /// privacy screen; macOS 27 hosts the panel in the Siri process) covers
    /// the tour. Command-Space closes it without answering; if it stays, the
    /// tour stops rather than pressing anything else.
    func dismissSpotlight() async throws {
        func panelVisible() -> Bool {
            guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
            return windows.contains { ["Spotlight", "Siri"].contains($0[kCGWindowOwnerName as String] as? String ?? "")
                && (($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) >= 20 }
        }
        guard panelVisible() else { return }
        app = "Spotlight panel"
        try post(49, flags: .maskCommand, requireText: false, allowAnyFrontmost: true)
        try await pause(0.8)
        if panelVisible() { throw CaretTour.Failure.focus(app) }
    }

    private static let page = """
    <!doctype html><html><head><meta charset="utf-8"><title>Intention caret tour</title><style>
    body{font:16px -apple-system,Helvetica,sans-serif;margin:36px;background:#fafafa;color:#222}
    label{display:block;margin:18px 0 6px;color:#555;font-size:13px}
    input,textarea,.composer{width:520px;font:16px -apple-system,Helvetica,sans-serif;padding:10px 12px;border:1px solid #bbb;border-radius:8px;background:#fff}
    textarea{height:64px;resize:none}
    .composer{min-height:44px;outline:none}
    .composer:empty::before{content:attr(data-placeholder);color:#999;pointer-events:none}
    </style></head><body>
    <h2>Synthetic fields</h2>
    <label>Search</label><input autofocus placeholder="Search" autocomplete="off">
    <label>Message</label><textarea placeholder="Write a message"></textarea>
    <label>Composer</label><div class="composer" contenteditable="true" role="textbox" data-placeholder="Ask anything"></div>
    </body></html>
    """
}
