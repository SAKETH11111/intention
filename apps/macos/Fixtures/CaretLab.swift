import AppKit
import ApplicationServices
import ScreenCaptureKit
import ImageIO

// Independent integration oracle. It imports no Intention source. Bright green
// painted carets and grayscale glyphs distinguish the stem; an isolated round
// component above it locates the actual rendered dot in the same frame.
@main
@MainActor
enum CaretLab {
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--video-self-test" {
            Task {
                do {
                    try await CaretFixtureVideo.selfCheck(at: URL(fileURLWithPath: CommandLine.arguments[2]))
                    print("PASS generated-pixel video: capture-denial gate, 4 encoded samples, original timestamps; not live evidence")
                    exit(0)
                } catch { print("FAIL video encoder self-check: \(error)"); exit(1) }
            }
            RunLoop.main.run()
            return
        }
        if CommandLine.arguments.contains("--oracle-self-test") {
            let passed = CaretPixelOracle.selfCheck()
            print(passed ? "PASS independent pixel oracle: gray/light/dark, missing dot with nearby glyph, offset, large gap, ambiguous caret, Retina" : "FAIL independent pixel oracle")
            exit(passed ? 0 : 1)
        }
        if CommandLine.arguments.count == 3, ["--probe-focused", "--focus-and-probe"].contains(CommandLine.arguments[1]) {
            _ = NSApplication.shared
            exit(CaretTour.probeFocused(output: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
                                        focus: CommandLine.arguments[1] == "--focus-and-probe"))
        }
        if CommandLine.arguments.count == 7, CommandLine.arguments[1] == "--region-screenshot" {
            // Saves one screenshot of a screen region, for diagnosing what a
            // detector saw. Coordinates are top-left global points.
            let values = CommandLine.arguments[2...5].compactMap(Double.init)
            let path = CommandLine.arguments[6]
            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard values.count == 4, let display = content.displays.first else { exit(2) }
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    let scale = CGFloat(filter.pointPixelScale)
                    config.sourceRect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
                    config.width = Int(values[2] * scale)
                    config.height = Int(values[3] * scale)
                    config.showsCursor = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { exit(2) }
                    CGImageDestinationAddImage(destination, image, nil)
                    exit(CGImageDestinationFinalize(destination) ? 0 : 1)
                } catch { print(error); exit(1) }
            }
            RunLoop.main.run()
            return
        }
        if [6, 7].contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--opaque-scene",
           let x = Double(CommandLine.arguments[4]), let y = Double(CommandLine.arguments[5]) {
            _ = NSApplication.shared
            let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let bundle = CommandLine.arguments[3]
            let idle = CommandLine.arguments.count == 7 ? Double(CommandLine.arguments[6]) : nil
            Task { exit(await CaretTour.runOpaque(output: output, bundle: bundle, point: CGPoint(x: x, y: y), idle: idle)) }
            NSApp.run()
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--ax-wake-probe" {
            _ = NSApplication.shared
            exit(CaretTour.axWakeProbe(output: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)))
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--ax-bootstrap-probe" {
            _ = NSApplication.shared
            exit(CaretTour.axBootstrapProbe(output: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)))
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--probe-panel" {
            _ = NSApplication.shared
            let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            Task { exit(await CaretTour.probePanel(output: output)) }
            NSApp.run()
            return
        }
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--accept-spotlight-notice" {
            _ = NSApplication.shared
            Task { exit(await CaretTour.acceptSpotlightNotice()) }
            NSApp.run()
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--tour-cleanup" {
            exit(CaretTour.cleanup(evidence: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)))
        }
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--tour" {
            _ = NSApplication.shared
            Task {
                let status = await CaretTour.run(output: URL(fileURLWithPath: CommandLine.arguments[2]))
                exit(status)
            }
            NSApp.run()
            return
        }
        if CommandLine.arguments.contains("--permissions") {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.regular)
            let delegate = PermissionDelegate()
            NSApp.delegate = delegate
            NSApp.run()
            withExtendedLifetime(delegate) {}
            return
        }
        guard CommandLine.arguments.count == 4, CommandLine.arguments[3] != "all" else {
            print("Run one named fixture per process: caret-lab <app> <output> <case>. Use ./dev mac-caret-check for the matrix.")
            exit(2)
        }
        guard Bundle.main.bundleIdentifier == "company.intention.caret-lab",
              NSRunningApplication.current.bundleIdentifier == "company.intention.caret-lab" else {
            print("BLOCKED caret lab: launch the built Intention Caret Lab.app executable with its bundle intact")
            exit(2)
        }
        NSApplication.shared.setActivationPolicy(.regular)
        let delegate = LabDelegate()
        NSApp.delegate = delegate
        NSApp.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class PermissionDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            if CommandLine.arguments.contains("--request-permissions") {
                let fixture = NSWindow(contentRect: CGRect(x: 200, y: 250, width: 480, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
                fixture.title = "Intention Caret Lab permission setup"
                fixture.isReleasedWhenClosed = false
                window = fixture
                fixture.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                try? await Task.sleep(for: .milliseconds(300))
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                _ = CGRequestScreenCaptureAccess()
                // Enumerate permission-protected metadata only. No pixels are
                // requested by setup, and no foreign titles are retained.
                _ = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                try? await Task.sleep(for: .seconds(2))
            }
            print("bundle=\(Bundle.main.bundleIdentifier ?? "none") runningBundle=\(NSRunningApplication.current.bundleIdentifier ?? "none") accessibility=\(AXIsProcessTrusted()) screenRecording=\(CGPreflightScreenCaptureAccess())")
            exit(0)
        }
    }
}

@MainActor
private final class LabDelegate: NSObject, NSApplicationDelegate {
    private let lab = Lab()
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await lab.run() }
    }
}

private struct Case: Codable {
    let name: String
    let engine: String
    let dark: Bool
    let tall: Bool
    let secure: Bool
    let visual: Bool
}

private struct FrameResult: Codable {
    let phase: String
    let time: Double
    let caretVisible: Bool
    let dotVisible: Bool
    let horizontalError: Double?
    let gap: Double?
    let caretTop: Double?
    var caretCenterX: Double? = nil
    var dotCenterX: Double? = nil
    let image: String?
}

private struct Result: Codable {
    let scenario: Case
    var verdict = "blocked"
    var reason = "not run"
    var frames: [FrameResult] = []
    var deliveredKeys = 0
    var expectedKeys = 0
    var focusCleared: Bool?
    var video: String?
    var videoSampleTimes: [Double] = []
}

@MainActor
private final class Lab {
    private let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    private let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
    private let token = "Intention caret lab " + UUID().uuidString
    private var window: NSWindow!
    private var editor: NSTextView!
    private var input: NSTextField?
    private var candidate: NSRunningApplication?
    private var fixturePID: pid_t = 0
    private var fixtureID: CGWindowID = 0
    private var fixtureTitle = ""
    private var fixtureFrame = CGRect.zero
    private var crop = CGRect.zero
    private var expectedField = CGRect.zero
    private var field: AXUIElement?
    private var fixtureAXWindow: AXUIElement?
    private var chromeWindow: String?
    private var chromeTab: String?
    private var chromeURL: String?
    private var chromeFixtureTitle: String?
    private var terminalProfile: String?
    private var native = true
    /// A floating non-activating panel keyed while another app is in front,
    /// as launchers such as Spotlight are.
    private var panelMode = false
    private var terminal = false
    private var terminalWindow: String?
    private var electronApp: NSRunningApplication?
    private var gateFailure = "none"
    private var started = 0.0
    private var captureContent: SCShareableContent?
    private var results: [Result] = []
    private var savedPhases = Set<String>()
    private var video: CaretFixtureVideo?
    private let clock = { ProcessInfo.processInfo.systemUptime }

    private enum Failure: Error {
        case focusLost, permissions, fixture, capture, appLaunch, receipts, cadence, chromeAXWindow, chromeTitle, chromeField, chromeWindow, chromeGeometry
    }

    /// LaunchServices does not preserve the invoking shell's working directory.
    /// Resolve only these fixture resources under the signed build-time root.
    private func fixtureResource(_ relative: String, directory: Bool = false) throws -> URL {
        let allowed = ["apps/macos/.build/caret-lab/composers/editors.js",
                       "apps/macos/.build/caret-lab/Intention Electron Fixture.app",
                       "apps/macos/Fixtures/CaretTerminalFixture.py"]
        guard allowed.contains(relative),
              let path = Bundle.main.object(forInfoDictionaryKey: "IntentionFixtureRepositoryRoot") as? String,
              path.hasPrefix("/") else { throw Failure.fixture }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path == path,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/macos/Fixtures/CaretLab.swift").path)
        else { throw Failure.fixture }
        let resource = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard resource.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: resource.path, isDirectory: &isDirectory),
              isDirectory.boolValue == directory, FileManager.default.isReadableFile(atPath: resource.path)
        else { throw Failure.fixture }
        return resource
    }

    private func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func rect(_ element: AXUIElement) -> CGRect? {
        guard let position = attr(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attr(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private func axWindow() -> AXUIElement? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID,
              let value = attr(AXUIElementCreateApplication(fixturePID), kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// A single gate owns all input and capture. No screenshot, keystroke or
    /// image write can proceed after an unrelated app/window takes focus.
    /// Finder comes forward, then the non-activating panel takes keyboard
    /// focus without activating this process, as a launcher does.
    private func keyPanelOverAnotherApp() async throws {
        guard ProcessSafety.allowsCheckInput else { throw Failure.focusLost }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), configuration: config)
        for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.finder" {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { throw Failure.focusLost }
        // A non-activating panel takes the keyboard when clicked, as people
        // key launcher panels. Click the centre of the owned field, only when
        // the topmost window there (other than the candidate's click-through
        // dot surface) is this panel.
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        guard let input else { throw Failure.fixture }
        let target = screenRect(window.convertToScreen(input.frame))
        let point = CGPoint(x: target.midX, y: target.midY)
        for _ in 0..<5 {
            guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { throw Failure.capture }
            let topmost = windows.first { info in
                guard let bounds = info[kCGWindowBounds as String] as? [String: NSNumber],
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point) else { return false }
                let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                // System overlays above floating level (the Dock's and menu
                // bar's full-screen surfaces) pass clicks through here.
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
                return owner != candidate?.processIdentifier && layer <= Int(CGWindowLevelForKey(.floatingWindow))
                    && ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
            }
            guard (topmost?[kCGWindowNumber as String] as? NSNumber)?.uint32Value == UInt32(window.windowNumber) else { throw Failure.focusLost }
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(30))
            }
            try await Task.sleep(for: .milliseconds(150))
            (window.firstResponder as? NSTextView)?.insertionPointColor = .green
            if validPanel() { return }
        }
        throw Failure.focusLost
    }

    /// For the panel: another app is frontmost, the panel is key, and the
    /// system-wide keyboard focus is this process's focused field.
    private func validPanel() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != fixturePID else { gateFailure = "panel: fixture became frontmost"; return false }
        guard window.isKeyWindow, window.isVisible, window.title == fixtureTitle, UInt32(window.windowNumber) == fixtureID,
              screenRect(window.frame) == fixtureFrame else { gateFailure = "panel key window"; return false }
        guard (window.firstResponder as? NSTextView)?.delegate === input else { gateFailure = "panel focused control"; return false }
        guard let focused = attr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { gateFailure = "panel system focus"; return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused as! AXUIElement, &pid) == .success, pid == fixturePID else { gateFailure = "panel system focus owner"; return false }
        return true
    }

    private func valid() -> Bool {
        if panelMode { return validPanel() }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID else { gateFailure = "frontmost process"; return false }
        if native {
            guard NSApp.keyWindow === window else { gateFailure = "native key window"; return false }
            guard window.isVisible && window.title == fixtureTitle && UInt32(window.windowNumber) == fixtureID && screenRect(window.frame) == fixtureFrame else { gateFailure = "native window geometry"; return false }
            guard input != nil ? (window.firstResponder as? NSTextView)?.delegate === input : window.firstResponder === editor else { gateFailure = "native focused control"; return false }
            return true
        }
        guard let focused = axWindow(), let fixtureAXWindow, CFEqual(focused, fixtureAXWindow),
              attr(focused, kAXTitleAttribute) as? String == fixtureTitle,
              rect(focused) == fixtureFrame else { gateFailure = "owned AX window"; return false }
        guard let field, let current = attr(AXUIElementCreateApplication(fixturePID), kAXFocusedUIElementAttribute),
              CFGetTypeID(current) == AXUIElementGetTypeID(), CFEqual(current, field),
              let controlWindow = attr(field, kAXWindowAttribute), CFGetTypeID(controlWindow) == AXUIElementGetTypeID(),
              CFEqual(controlWindow, fixtureAXWindow) else { gateFailure = "owned focused control"; return false }
        guard let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow, fixtureID) as? [[String: Any]],
              let info = infos.first,
              (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == fixturePID,
              (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == fixtureID,
              let bounds = info[kCGWindowBounds as String] as? [String: NSNumber],
              CGRect(dictionaryRepresentation: bounds as CFDictionary) == fixtureFrame else { gateFailure = "owned Window Server window"; return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID
    }

    private func screenRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - rect.maxY, width: rect.width, height: rect.height)
    }

    private func prepareNative(_ item: Case) async throws {
        native = true
        panelMode = item.name == "native-panel"
        fixturePID = getpid()
        if panelMode {
            let panel = NSPanel(contentRect: CGRect(x: 180, y: 220, width: 560, height: 260), styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
            panel.level = .floating
            panel.becomesKeyOnlyIfNeeded = false
            panel.hidesOnDeactivate = false
            window = panel
        } else {
            window = NSWindow(contentRect: CGRect(x: 180, y: 220, width: 560, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        }
        window.isReleasedWhenClosed = false
        fixtureTitle = token + " " + item.name
        window.title = fixtureTitle
        let bg = item.dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white
        window.backgroundColor = bg
        editor = NSTextView(frame: CGRect(x: 40, y: 60, width: 440, height: 140))
        editor.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        editor.textColor = item.dark ? .lightGray : .darkGray
        editor.backgroundColor = bg
        editor.insertionPointColor = .green
        editor.isRichText = false
        editor.textContainerInset = NSSize(width: 12, height: 18)
        if item.tall {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = 40
            editor.defaultParagraphStyle = paragraph
        }
        window.contentView?.addSubview(editor)
        if item.secure || ["native-single", "native-search", "native-panel"].contains(item.name) {
            let secure: NSTextField = item.secure ? NSSecureTextField(frame: .zero)
                : item.name == "native-search" ? NSSearchField(frame: .zero) : NSTextField(frame: .zero)
            secure.frame = CGRect(x: 40, y: 70, width: 440, height: 40)
            secure.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
            secure.textColor = .darkGray
            secure.backgroundColor = bg
            window.contentView?.addSubview(secure)
            input = secure
        } else { input = nil }
        if panelMode {
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeFirstResponder(input ?? editor)
        if input != nil { (window.firstResponder as? NSTextView)?.insertionPointColor = .green }
        fixtureID = UInt32(window.windowNumber)
        fixtureFrame = screenRect(window.frame)
        crop = screenRect(window.convertToScreen(CGRect(x: 24, y: 40, width: 476, height: 188)))
        expectedField = screenRect(window.convertToScreen(input?.frame ?? editor.frame))
        if panelMode {
            try await keyPanelOverAnotherApp()
            (window.firstResponder as? NSTextView)?.insertionPointColor = .green
        }
        // Activation after the previous fixture process exits is asynchronous.
        // Wait without recapturing or posting input; never reclaim focus here.
        for _ in 0..<30 {
            if valid() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure.focusLost
    }

    private func appleScript(_ source: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        guard process.terminationStatus == 0 else { throw Failure.fixture }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prepareChrome(_ item: Case) async throws {
        native = false
        let title = token + " " + item.name
        let acceptedTitles = [title, title + " - Google Chrome", title + " — Google Chrome"]
        let page = output.appendingPathComponent(item.name + ".html")
        let kind = item.engine
        let electron = kind.hasPrefix("electron-")
        let composer = kind == "electron-t3-layout"
        let singleLine = ["input", "search"].contains(kind)
        let tag = composer ? "<div id='field' class='composer-tiptap' contenteditable='true' role='textbox'><p><br></p></div><div id='placeholder'>Synthetic composer placeholder</div>" : singleLine ? "<input id='field' type='\(kind == "search" ? "search" : "text")' autocomplete='off'>" : kind == "textarea" ? "<textarea id='field'></textarea>" : "<div id='field' contenteditable='true' role='textbox'></div>"
        var html = """
        <!doctype html><meta charset="utf-8"><title>\(title)</title>
        <style>body{margin:40px;background:\(item.dark ? "#202020" : "#eee");color:#888;font:16px sans-serif}
        #field{display:block;box-sizing:border-box;width:440px;height:\(singleLine ? "52" : "140")px;padding:12px;border:1px solid #888;outline:none;
        background:\(item.dark ? "#202020" : "white");color:#888;caret-color:#00ff00;font:18px/\(item.tall ? "40" : "24")px monospace;white-space:pre-wrap;overflow:auto}
        #field:empty::before{content:'Synthetic placeholder';color:#888;pointer-events:none}
        \(composer ? "#field{position:relative;font:14px/1.625 sans-serif;padding:4px;min-height:78px;max-height:208px;margin:-4px;border:0;background:transparent}#field p{margin:0}#placeholder{position:absolute;top:90px;left:40px;pointer-events:none;font:14px/1.625 sans-serif;color:#888}" : "")
        </style><p>Synthetic caret fixture</p>\(tag)
        <script>const f=document.getElementById('field');f.focus();
        if(f.isContentEditable)getSelection().collapse(f,0);
        let keys=0;const caret=()=>{if(!f.isContentEditable)return f.selectionStart;const s=getSelection();if(!s.rangeCount||!f.contains(s.anchorNode))return 0;const r=document.createRange();r.selectNodeContents(f);r.setEnd(s.anchorNode,s.anchorOffset);return r.toString().length};const receipt=()=>{f.setAttribute('aria-label','Intention fixture keys='+keys+' length='+(f.isContentEditable?f.textContent:f.value).length+' caret='+caret());const p=document.getElementById('placeholder');if(p)p.hidden=f.textContent.length>0};receipt();f.addEventListener('keydown',()=>{keys++;receipt()});f.addEventListener('keyup',receipt);f.addEventListener('input',receipt);document.addEventListener('selectionchange',receipt);
        </script>
        """
        if ["electron-tiptap", "electron-lexical"].contains(kind) {
            let framework = kind == "electron-tiptap" ? "tiptap" : "lexical"
            let bundle = try fixtureResource("apps/macos/.build/caret-lab/composers/editors.js")
            let localBundle = output.appendingPathComponent("editors.js")
            try FileManager.default.copyItem(at: bundle, to: localBundle)
            html = """
            <!doctype html><meta charset="utf-8"><title>\(title)</title>
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'unsafe-inline'">
            <style>
            body{margin:40px;background:\(item.dark ? "#202020" : "#eee");color:#888;font:16px sans-serif}
            #editor-mount{position:relative;width:360px}
            #field{box-sizing:border-box;width:360px;height:140px;padding:8px;outline:none;overflow:auto;
            background:\(item.dark ? "#202020" : "#fff");color:#888;caret-color:#00ff00;white-space:pre-wrap;
            font:16px/\(item.tall ? "40" : "26")px sans-serif;border:1px solid #888}
            #field p{margin:0}
            #field p.is-editor-empty:first-child::before{content:attr(data-placeholder);float:left;height:0;pointer-events:none;color:#888}
            #external-placeholder{position:absolute;top:9px;left:9px;pointer-events:none;font:16px/\(item.tall ? "40" : "26")px sans-serif}
            </style>
            <body data-engine="\(framework)"><p>Synthetic \(framework) composer</p><div id="editor-mount">
            \(framework == "lexical" ? "<div id='external-placeholder' aria-hidden='true'>Synthetic composer placeholder</div>" : "")
            </div><script src="editors.js"></script>
            """
        }
        try html.write(to: page, atomically: true, encoding: .utf8)
        var requestedChromeFrame: CGRect?
        if electron {
            let runtime = try fixtureResource("apps/macos/.build/caret-lab/Intention Electron Fixture.app", directory: true)
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.arguments = ["--fixture-page", page.path, "--fixture-output", output.path, "--fixture-title", title]
            electronApp = try await NSWorkspace.shared.openApplication(at: runtime, configuration: config)
        } else {
        chromeURL = page.absoluteString
        chromeFixtureTitle = title
        guard let screen = NSScreen.screens.first,
              let existing = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { throw Failure.chromeWindow }
        let visible = screenRect(screen.visibleFrame)
        let existingFrames = existing.compactMap { info -> CGRect? in
            guard let bounds = info[kCGWindowBounds as String] as? [String: NSNumber] else { return nil }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
        }
        for index in 0..<20 {
            let proposed = CGRect(x: ceil(visible.minX + 24), y: ceil(visible.minY + 24),
                                  width: floor(min(760, visible.width - 48)) - CGFloat(index * 7),
                                  height: floor(min(560, visible.height - 48)))
            guard proposed.width >= 560, proposed.height >= 360, visible.contains(proposed) else { break }
            if !existingFrames.contains(proposed) { requestedChromeFrame = proposed; break }
        }
        guard let requestedChromeFrame else { throw Failure.chromeWindow }
        let browserIDs = try await appleScript("""
        tell application "Google Chrome"
            set w to make new window
            set bounds of w to {\(Int(requestedChromeFrame.minX)), \(Int(requestedChromeFrame.minY)), \(Int(requestedChromeFrame.maxX)), \(Int(requestedChromeFrame.maxY))}
            set URL of active tab of w to "\(page.absoluteString)"
            activate
            return (id of w as string) & "|" & (id of active tab of w as string)
        end tell
        """).split(separator: "|")
        guard browserIDs.count == 2, browserIDs.allSatisfy({ Int($0) != nil }) else { throw Failure.chromeWindow }
        chromeWindow = String(browserIDs[0])
        chromeTab = String(browserIDs[1])
        }
        // Chrome activation can cross Spaces. Wait for the owned fixture,
        // without sending input or capturing anything during that transition.
        var activated = false
        for _ in 0..<(electron ? 100 : 30) {
            if let chrome = NSWorkspace.shared.frontmostApplication, chrome.bundleIdentifier == (electron ? "company.intention.caret-electron-fixture" : "com.google.Chrome") {
                fixturePID = chrome.processIdentifier
                _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(fixturePID), "AXManualAccessibility" as CFString, kCFBooleanTrue)
                if let focused = axWindow(), let currentTitle = attr(focused, kAXTitleAttribute) as? String, acceptedTitles.contains(currentTitle) {
                    activated = true
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard activated else { print("Web setup denied: electron=\(electron) alive=\(electronApp?.isTerminated == false) frontmost=\(electronApp?.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier)"); throw Failure.chromeAXWindow }
        guard let focused = axWindow() else { throw Failure.chromeAXWindow }
        guard let actualTitle = attr(focused, kAXTitleAttribute) as? String,
              acceptedTitles.contains(actualTitle),
              let frame = rect(focused) else { throw Failure.chromeTitle }
        guard requestedChromeFrame == nil || requestedChromeFrame == frame else { throw Failure.chromeGeometry }
        fixtureTitle = actualTitle
        fixtureFrame = frame
        fixtureAXWindow = focused
        func ownsAXWindow() -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID,
                  let current = axWindow(), CFEqual(current, focused),
                  attr(current, kAXTitleAttribute) as? String == fixtureTitle,
                  rect(current) == frame else { return false }
            return true
        }
        // Chrome's one initial bounds write establishes a unique rectangle.
        // AX must report it exactly and WindowServer must contain exactly one
        // matching PID/layer/rectangle. Never choose the first ambiguous match.
        // Other engines still require the exact nonce WindowServer title.
        var windowDiagnostics: [[String: Any]] = []
        var pinnedWindowID: CGWindowID?
        for attempt in 0..<30 {
            guard ownsAXWindow() else { throw Failure.focusLost }
            guard let infos = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { throw Failure.chromeWindow }
            let sameGeometry = infos.filter {
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == fixturePID &&
                ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 &&
                (($0[kCGWindowBounds as String] as? [String: NSNumber]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }) == frame
            }
            let titleMatches = sameGeometry.filter {
                guard let name = $0[kCGWindowName as String] as? String else { return false }
                return acceptedTitles.contains(name)
            }
            let matchingWindows = requestedChromeFrame != nil ? sameGeometry : titleMatches
            var advertised: CFArray?
            let attributesStatus = AXUIElementCopyAttributeNames(focused, &advertised)
            let attributeNames = advertised as? [String] ?? []
            windowDiagnostics.append(["attempt": attempt, "sameGeometryCount": sameGeometry.count,
                                      "namedGeometryCount": sameGeometry.filter { $0[kCGWindowName as String] is String }.count,
                                      "nonemptyNameCount": sameGeometry.filter { (($0[kCGWindowName as String] as? String)?.isEmpty == false) }.count,
                                      "noncePrefixCount": sameGeometry.filter { ($0[kCGWindowName as String] as? String)?.hasPrefix(token) == true }.count,
                                      "exactTitleCount": titleMatches.count, "ownedAXWindow": ownsAXWindow(),
                                      "explicitUniqueBounds": requestedChromeFrame != nil,
                                      "windowNumberAdvertised": attributeNames.contains("AXWindowNumber"),
                                      "windowIDAdvertised": attributeNames.contains("AXWindowID"),
                                      "attributeNamesStatus": attributesStatus.rawValue])
            let data = try JSONSerialization.data(withJSONObject: windowDiagnostics, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("web-window-acquisition.json"), options: .atomic)
            guard ownsAXWindow(), matchingWindows.count <= 1 else { throw Failure.chromeWindow }
            if let info = matchingWindows.first, let number = info[kCGWindowNumber as String] as? NSNumber {
                pinnedWindowID = number.uint32Value
                break
            }
            guard ownsAXWindow() else { throw Failure.focusLost }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let pinnedWindowID else { throw Failure.chromeWindow }
        fixtureID = pinnedWindowID
        func ownsWindow() -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID,
                  let current = axWindow(), CFEqual(current, focused),
                  attr(current, kAXTitleAttribute) as? String == fixtureTitle,
                  rect(current) == frame,
                  let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, fixtureID) as? [[String: Any]],
                  windows.count == 1, let info = windows.first else { return false }
            // Every value is read out of the window dictionary before it is
            // compared: an autoclosure capturing the dictionary shares a
            // non-sendable value across isolation, which Swift 6.3 rejects.
            let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            let name = info[kCGWindowName as String] as? String
            var bounds: CGRect?
            if let values = info[kCGWindowBounds as String] as? [String: NSNumber] {
                bounds = CGRect(dictionaryRepresentation: values as CFDictionary)
            }
            var titled = requestedChromeFrame != nil
            if let name, acceptedTitles.contains(name) { titled = true }
            guard owner == fixturePID, number == fixtureID, titled, bounds == frame else { return false }
            return true
        }
        if !electron {
            // Chromium documents this request as the switch that enables its
            // Mac accessibility tree. It changes no text or keyboard focus.
            guard ownsWindow() else { throw Failure.focusLost }
            let windowStatus = AXUIElementSetAttributeValue(focused, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            let windowRetained = ownsWindow()
            guard windowRetained else { throw Failure.focusLost }
            let appStatus = AXUIElementSetAttributeValue(AXUIElementCreateApplication(fixturePID), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            let appWindowRetained = ownsWindow()
            let status: [String: Any] = ["windowStatus": windowStatus.rawValue, "appStatus": appStatus.rawValue,
                                       "windowRetainedAfterWindowRequest": windowRetained,
                                       "windowRetainedAfterAppRequest": appWindowRetained]
            let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("web-accessibility-enable.json"), options: .atomic)
            guard appWindowRetained else { throw Failure.focusLost }
            // A refused attribute is not permission to weaken acquisition:
            // the existing exact field/tree guards still decide eligibility.
        }
        func ownedControl(_ control: AXUIElement) -> Bool {
            guard ownsWindow(),
                  attr(control, "AXDOMIdentifier") as? String == "field",
                  [kAXTextFieldRole, kAXTextAreaRole].contains(attr(control, kAXRoleAttribute) as? String ?? ""),
                  attr(control, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
                  let controlWindow = attr(control, kAXWindowAttribute), CFGetTypeID(controlWindow) == AXUIElementGetTypeID(),
                  CFEqual(controlWindow, focused),
                  let box = rect(control), frame.contains(box) else { return false }
            var node = control
            for _ in 0..<40 {
                guard ownsWindow() else { return false }
                if attr(node, kAXRoleAttribute) as? String == "AXWebArea" {
                    let value = attr(node, "AXURL")
                    return ((value as? URL)?.absoluteString ?? (value as? String)) == page.absoluteString
                }
                guard let parent = attr(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID(), !CFEqual(parent, node) else { return false }
                node = parent as! AXUIElement
            }
            return false
        }
        func hasReceipt(_ control: AXUIElement) -> Bool {
            [kAXDescriptionAttribute, kAXTitleAttribute].contains {
                (attr(control, $0) as? String)?.hasPrefix("Intention fixture keys=") == true
            }
        }
        var diagnostics: [[String: Any]] = []
        func diagnose(_ control: AXUIElement?, stage: String, status: AXError? = nil) {
            var row: [String: Any] = ["stage": stage, "ownedWindow": ownsWindow()]
            if let control, ownsWindow() {
                let role = attr(control, kAXRoleAttribute) as? String ?? ""
                row["role"] = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXButtonRole, "AXWebArea"].contains(role) ? role : "other"
                row["descriptionReceipt"] = (attr(control, kAXDescriptionAttribute) as? String)?.hasPrefix("Intention fixture keys=") == true
                row["titleReceipt"] = (attr(control, kAXTitleAttribute) as? String)?.hasPrefix("Intention fixture keys=") == true
                row["expectedDOMID"] = attr(control, "AXDOMIdentifier") as? String == "field"
                row["expectedAXIdentifier"] = attr(control, kAXIdentifierAttribute) as? String == "field"
                if let controlWindow = attr(control, kAXWindowAttribute), CFGetTypeID(controlWindow) == AXUIElementGetTypeID() {
                    row["controlWindowMatches"] = CFEqual(controlWindow, focused)
                } else { row["controlWindowMatches"] = false }
                row["geometryInsideWindow"] = rect(control).map { frame.contains($0) } ?? false
                row["ownedControl"] = ownedControl(control)
            }
            if let status { row["axStatus"] = status.rawValue }
            diagnostics.append(row)
            if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("web-acquisition.json"), options: .atomic)
            }
        }
        field = nil
        var focusAttempted = false
        for attempt in 0..<30 {
            guard ownsWindow() else { throw Failure.focusLost }
            var current: CFTypeRef?
            let focusedStatus = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(fixturePID), kAXFocusedUIElementAttribute as CFString, &current)
            let control = current.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
            if attempt == 0 || attempt == 29 { diagnose(control, stage: attempt == 0 ? "initial" : "last-focused", status: focusedStatus) }
            if let control, ownedControl(control), hasReceipt(control) {
                field = control
                diagnose(control, stage: "acquired")
                break
            }
            // Only initial acquisition may set AXFocused, once, on the
            // unique owned field. Never click, activate or retry this write.
            if !focusAttempted {
                var queue = [focused]
                var visited: [AXUIElement] = []
                var matches: [AXUIElement] = []
                var roles: [String: Int] = [:]
                var domMatches = 0
                var receiptMatches = 0
                var exactDocuments = 0
                var rootChildrenStatus: AXError?
                while !queue.isEmpty, visited.count < 1000 {
                    guard ownsWindow() else { throw Failure.focusLost }
                    let node = queue.removeFirst()
                    if visited.contains(where: { CFEqual($0, node) }) { continue }
                    visited.append(node)
                    let role = attr(node, kAXRoleAttribute) as? String ?? ""
                    let roleCode = [kAXWindowRole, kAXGroupRole, kAXScrollAreaRole, kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXButtonRole, "AXWebArea"].contains(role) ? role : "other"
                    roles[roleCode, default: 0] += 1
                    let domMatchesField = attr(node, "AXDOMIdentifier") as? String == "field"
                    let hasFieldReceipt = hasReceipt(node)
                    if domMatchesField { domMatches += 1 }
                    if hasFieldReceipt { receiptMatches += 1 }
                    if role == "AXWebArea" {
                        let value = attr(node, "AXURL")
                        if ((value as? URL)?.absoluteString ?? (value as? String)) == page.absoluteString { exactDocuments += 1 }
                    }
                    if (attempt == 0 || attempt == 29), (domMatchesField || hasFieldReceipt) {
                        diagnose(node, stage: "discovered-candidate")
                    }
                    if domMatchesField, ownedControl(node), hasFieldReceipt { matches.append(node) }
                    var childrenValue: CFTypeRef?
                    let childrenStatus = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &childrenValue)
                    if CFEqual(node, focused) { rootChildrenStatus = childrenStatus }
                    if let children = childrenValue as? [AXUIElement] { queue.append(contentsOf: children) }
                }
                if attempt == 0 || attempt == 29 {
                    diagnostics.append(["stage": "tree-summary", "attempt": attempt, "visited": visited.count,
                                        "roles": roles, "domMatches": domMatches, "receiptMatches": receiptMatches,
                                        "exactDocumentMatches": exactDocuments, "ownedMatches": matches.count,
                                        "rootChildrenStatus": rootChildrenStatus?.rawValue ?? -1])
                    diagnose(nil, stage: "tree-complete")
                }
                guard queue.isEmpty, matches.count <= 1 else { throw Failure.chromeField }
                if let target = matches.first {
                    guard ownsWindow(), ownedControl(target), hasReceipt(target) else { throw Failure.focusLost }
                    focusAttempted = true
                    let status = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    diagnose(target, stage: "initial-focus", status: status)
                    guard status == .success else { throw Failure.chromeField }
                }
            }
            guard ownsWindow() else { throw Failure.focusLost }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let field, ownedControl(field), let fieldRect = rect(field), frame.contains(fieldRect) else {
            diagnose(nil, stage: "not-acquired")
            throw Failure.chromeField
        }
        crop = fieldRect.insetBy(dx: -16, dy: -32).intersection(frame)
        expectedField = fieldRect
        guard valid() else { throw Failure.focusLost }
    }

    private func prepareTerminal(_ item: Case) async throws {
        native = false
        terminal = true
        let title = token + " " + item.name
        terminalProfile = title
        let fixture = try fixtureResource("apps/macos/Fixtures/CaretTerminalFixture.py")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "/usr/bin/python3 -I " + quote(fixture.path) + " " + quote(output.path)
        let profile: [String: Any] = [
            "name": title, "type": "Window Settings", "ProfileCurrentVersion": 2.01,
            "CommandString": command, "RunCommandAsShell": false,
            "Font": try NSKeyedArchiver.archivedData(withRootObject: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular), requiringSecureCoding: false),
            "BackgroundColor": try NSKeyedArchiver.archivedData(withRootObject: NSColor.white, requiringSecureCoding: false),
            "TextColor": try NSKeyedArchiver.archivedData(withRootObject: NSColor.darkGray, requiringSecureCoding: false),
            "CursorColor": try NSKeyedArchiver.archivedData(withRootObject: NSColor.green, requiringSecureCoding: false),
            "CursorType": 1, "CursorBlink": true, "BlinkCursor": true,
            "columnCount": 44, "rowCount": 14, "WindowTitle": title,
            "ShowActiveProcessInTitle": false, "ShowWorkingDirectoryInTitle": false,
            "ShowShellCommandInTitle": false, "ShowWindowSettingsNameInTitle": false,
            "ShowDimensionsInTitle": false, "shellExitAction": 0,
        ]
        let file = output.appendingPathComponent(title + ".terminal")
        try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0).write(to: file)
        let ownedWindow = try await appleScript("""
        tell application "Terminal"
            open POSIX file "\(file.path)"
            repeat 40 times
                repeat with w in (get windows)
                    if name of current settings of selected tab of w is "\(title)" then
                        set index of w to 1
                        set custom title of selected tab of w to "\(title)"
                        set title displays custom title of selected tab of w to true
                        set title displays device name of current settings of selected tab of w to false
                        set title displays shell path of current settings of selected tab of w to false
                        set title displays window size of current settings of selected tab of w to false
                        set title displays settings name of current settings of selected tab of w to false
                        activate
                        return (id of w) as text
                    end if
                end repeat
                delay 0.1
            end repeat
            return "not-ready"
        end tell
        """)
        guard let ownedID = UInt32(ownedWindow) else { print("Terminal setup denied: owned profile window not ready"); throw Failure.fixture }
        terminalWindow = String(ownedID)
        var setup = "not-frontmost"
        for _ in 0..<40 {
            if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.Terminal" {
                fixturePID = app.processIdentifier
                let focusedWindow = axWindow()
                let titleMatches = focusedWindow.flatMap { attr($0, kAXTitleAttribute) as? String }?.contains(title) == true
                let ready = FileManager.default.fileExists(atPath: output.appendingPathComponent("terminal-receipt.json").path)
                let focusedControl = attr(AXUIElementCreateApplication(fixturePID), kAXFocusedUIElementAttribute)
                setup = "window=\(focusedWindow != nil) title=\(titleMatches) receipt=\(ready) control=\(focusedControl != nil)"
                if let focused = axWindow(), let actual = attr(focused, kAXTitleAttribute) as? String,
                   actual.contains(title), let frame = rect(focused),
                   FileManager.default.fileExists(atPath: output.appendingPathComponent("terminal-receipt.json").path),
                   let value = attr(AXUIElementCreateApplication(fixturePID), kAXFocusedUIElementAttribute),
                   CFGetTypeID(value) == AXUIElementGetTypeID() {
                    let control = value as! AXUIElement
                    setup = "role=\(attr(control, kAXRoleAttribute) as? String ?? "missing") control=\(String(describing: rect(control))) window=\(frame)"
                    if attr(control, kAXRoleAttribute) as? String == kAXTextAreaRole,
                       let rawField = rect(control) {
                        // Independently establish the visible scroll viewport.
                        // The runner does not import production boundary code.
                        var parent: AXUIElement? = control
                        var viewport: CGRect?
                        for _ in 0..<40 {
                            guard let current = parent else { break }
                            if CFEqual(current, focused) { break }
                            if attr(current, kAXRoleAttribute) as? String == kAXScrollAreaRole, let bounds = rect(current) {
                                viewport = viewport.map { $0.intersection(bounds) } ?? bounds
                            }
                            parent = attr(current, kAXParentAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
                        }
                        guard let viewport else { print("Terminal setup denied: missing scroll viewport"); throw Failure.fixture }
                        let fieldRect = rawField.intersection(viewport).intersection(frame)
                        guard !fieldRect.isNull, fieldRect.width >= 4, fieldRect.height >= 8 else { throw Failure.fixture }
                        fixtureTitle = actual; fixtureFrame = frame; fixtureAXWindow = focused; field = control; expectedField = fieldRect
                        let infos = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
                        guard let info = infos?.first(where: { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == fixturePID && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 && (($0[kCGWindowBounds as String] as? [String: NSNumber]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }) == frame }),
                              let number = info[kCGWindowNumber as String] as? NSNumber else { throw Failure.fixture }
                        guard number.uint32Value == ownedID else { print("Terminal setup denied: script/server ID mismatch"); throw Failure.fixture }
                        fixtureID = ownedID
                        crop = fieldRect
                        guard valid() else { throw Failure.focusLost }
                        return
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("Terminal setup denied: \(setup)")
        throw Failure.fixture
    }

    private func launch(_ item: Case) async throws {
        guard valid() else { throw Failure.focusLost }
        // Launching an app takes the keyboard from a panel that never
        // activated its app. No input is sent while waiting; the refocus
        // that follows keys the panel again and gates every key after it.
        let valid = { self.panelMode || self.valid() }
        let ready = output.appendingPathComponent(item.name + "-ready.txt")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = true
        config.arguments = ["--caret-fixture", "--fixture-token", token, "--fixture-pid", String(fixturePID), "--fixture-title", fixtureTitle,
                            "--fixture-window", String(fixtureID), "--fixture-visual", item.visual ? "on" : "off", "--fixture-ready", ready.path]
        candidate = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        for _ in 0..<40 {
            guard valid() else { throw Failure.focusLost }
            guard candidate?.isTerminated == false else { throw Failure.appLaunch }
            if (try? String(contentsOf: ready, encoding: .utf8)) == candidate.map({ String($0.processIdentifier) }) {
                // Obtain immutable window IDs before measuring first focus.
                // The overlay is included even while its alpha is zero.
                captureContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard valid() else { throw Failure.focusLost }
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.appLaunch
    }

    private func send(_ code: CGKeyCode, text: String? = nil) async throws {
        guard ProcessSafety.allowsCheckInput else { throw Failure.focusLost }
        for down in [true, false] {
            guard valid(), let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: code, keyDown: down) else { throw Failure.focusLost }
            event.flags = []
            if let text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(12))
        }
    }

    private func textCount() throws -> Int {
        guard valid() else { throw Failure.focusLost }
        if native { return (input?.stringValue ?? editor.string).utf16.count }
        return try receiptValue("length")
    }

    private func receiptValue(_ key: String) throws -> Int {
        if terminal {
            guard valid(),
                  let data = try? Data(contentsOf: output.appendingPathComponent("terminal-receipt.json")),
                  let receipt = try? JSONDecoder().decode([String: Int].self, from: data),
                  let value = receipt[key] else { throw Failure.receipts }
            return value
        }
        guard valid(), let field else { throw Failure.receipts }
        let receipts = [kAXDescriptionAttribute, kAXTitleAttribute].compactMap { attr(field, $0) as? String }
            .filter { $0.hasPrefix("Intention fixture keys=") }
        guard let receipt = receipts.first, receipts.allSatisfy({ $0 == receipt }),
              let part = receipt.split(separator: " ").first(where: { $0.hasPrefix(key + "=") }),
              let value = Int(part.dropFirst(key.count + 1)) else { throw Failure.receipts }
        return value
    }

    private func selectionPosition() throws -> Int {
        guard valid() else { throw Failure.focusLost }
        if native {
            guard let text = window.firstResponder as? NSTextView else { throw Failure.receipts }
            return text.selectedRange().location
        }
        return try receiptValue("caret")
    }

    private func waitForSelection(_ expected: Int) async throws {
        for _ in 0..<20 {
            if try selectionPosition() == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure.receipts
    }

    private func screenshot() async throws -> (CGImage, CGImage, CGFloat, Double) {
        guard valid() else { throw Failure.focusLost }
        let content: SCShareableContent
        if let captureContent { content = captureContent }
        else { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        guard let target = content.windows.first(where: { $0.windowID == fixtureID && $0.owningApplication?.processID == fixturePID }),
              let display = content.displays.first(where: { $0.frame.contains(crop) }), let candidate else { throw Failure.capture }
        let panels = content.windows.filter { $0.owningApplication?.processID == candidate.processIdentifier && $0.title?.hasPrefix("dot ") == true }
        if !panels.isEmpty { captureContent = content }
        let filter = SCContentFilter(display: display, including: [target] + panels)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.sourceRect = crop.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int(crop.width * scale)
        config.height = Int(crop.height * scale)
        config.captureResolution = .best
        config.ignoreShadowsDisplay = true
        config.showsCursor = false
        config.capturesAudio = false
        guard valid() else { throw Failure.focusLost }
        let requestedAt = clock()
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let capturedAt = clock()
        guard valid(), image.width == config.width, image.height == config.height else { throw Failure.focusLost }
        // Gray-dot subtraction needs a second guarded capture.
        let bareFilter = SCContentFilter(display: display, including: [target])
        guard valid() else { throw Failure.focusLost }
        let background = try await SCScreenshotManager.captureImage(contentFilter: bareFilter, configuration: config)
        guard valid(), background.width == image.width, background.height == image.height else { throw Failure.focusLost }
        let timing = "\(requestedAt),\(capturedAt),\(clock())\n"
        let timingURL = output.appendingPathComponent("capture-timing.csv")
        if !FileManager.default.fileExists(atPath: timingURL.path) { FileManager.default.createFile(atPath: timingURL.path, contents: nil) }
        let timingFile = try FileHandle(forWritingTo: timingURL)
        defer { try? timingFile.close() }
        try timingFile.seekToEnd()
        try timingFile.write(contentsOf: Data(timing.utf8))
        return (image, background, scale, capturedAt)
    }

    private func measure(_ image: CGImage, background: CGImage, scale: CGFloat, phase: String, name: String, capturedAt: Double) throws -> FrameResult {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.capture }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var barePixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let bareContext = CGContext(data: &barePixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.capture }
        bareContext.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height))
        let (stem, dot) = CaretPixelOracle.locate(pixels, width: width, height: height, scale: scale, dark: name.contains("dark"), allowedCaret: expectedField.offsetBy(dx: -crop.minX, dy: -crop.minY), background: barePixels)
        let error = stem.flatMap { s in dot.map { Double(abs(s.midX - $0.midX)) } }
        let gap = stem.flatMap { s in dot.map { Double(s.minY - $0.maxY) } }
        let evidencePhase = savedPhases.contains(phase) && stem != nil && dot != nil ? phase + "-placed" : phase
        let imageName = name + "-" + evidencePhase + ".png"
        var saved: String?
        // Save a bounded evidence image for each phase with a visible stem,
        // including failures. Never select only successful dot frames.
        if stem != nil, !savedPhases.contains(evidencePhase) {
            guard valid(), let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(imageName) as CFURL, "public.png" as CFString, 1, nil) else { throw Failure.focusLost }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw Failure.capture }
            guard valid(), let bareDestination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name + "-" + evidencePhase + "-background.png") as CFURL, "public.png" as CFString, 1, nil) else { throw Failure.focusLost }
            CGImageDestinationAddImage(bareDestination, background, nil)
            guard CGImageDestinationFinalize(bareDestination) else { throw Failure.capture }
            saved = imageName
            savedPhases.insert(evidencePhase)
        }
        return FrameResult(phase: phase, time: capturedAt - started, caretVisible: stem != nil, dotVisible: dot != nil,
                           horizontalError: error, gap: gap, caretTop: stem.map { Double($0.minY) },
                           caretCenterX: stem.map { Double($0.midX) }, dotCenterX: dot.map { Double($0.midX) }, image: saved)
    }

    // Geometry-only diagnostics from the owned synthetic control. This never
    // runs for secure fields and does not print field text.
    private func geometryProbe(_ phase: String) throws {
        guard valid() else { throw Failure.focusLost }
        guard let value = attr(AXUIElementCreateApplication(fixturePID), kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let element = value as! AXUIElement
        func parameter(_ name: String, _ argument: CFTypeRef) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &result) == .success ? result : nil
        }
        func bounds(_ value: CFTypeRef?) -> String {
            var rect = CGRect.zero
            guard let value, CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return "nil" }
            return NSStringFromRect(rect)
        }
        var selection = CFRange()
        if let selected = attr(element, kAXSelectedTextRangeAttribute), CFGetTypeID(selected) == AXValueGetTypeID() {
            AXValueGetValue(selected as! AXValue, .cfRange, &selection)
        }
        var lines = ["uptime=\(clock()) phase=\(phase) selection=\(selection) field=\(String(describing: rect(element)))"]
        for (offset, length) in [(0, 0), (0, 1), (-1, 1)] where selection.location + offset >= 0 {
            var range = CFRange(location: selection.location + offset, length: length)
            if let argument = AXValueCreate(.cfRange, &range) {
                lines.append("range=\(range) bounds=\(bounds(parameter(kAXBoundsForRangeParameterizedAttribute, argument)))")
            }
        }
        if let marker = attr(element, "AXSelectedTextMarkerRange") {
            lines.append("marker=\(bounds(parameter("AXBoundsForTextMarkerRange", marker)))")
        }
        // Lengths only; the synthetic text itself is not recorded.
        let characters = (attr(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
        let valueLength = (attr(element, kAXValueAttribute) as? String)?.utf16.count
        let placeholderLength = (attr(element, kAXPlaceholderValueAttribute) as? String)?.utf16.count
        lines.append("characters=\(String(describing: characters)) valueLength=\(String(describing: valueLength)) placeholderLength=\(String(describing: placeholderLength))")
        // Structure of the control's children: roles, lengths and attribute
        // names, never their text.
        for (index, child) in ((attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(4).enumerated() {
            var childNames: CFArray?
            AXUIElementCopyAttributeNames(child, &childNames)
            let role = attr(child, kAXRoleAttribute) as? String ?? "?"
            let length = (attr(child, kAXValueAttribute) as? String)?.utf16.count
            let grand = (attr(child, kAXChildrenAttribute) as? [AXUIElement])?.count
            let names = ((childNames as? [String]) ?? []).sorted().joined(separator: ",")
            lines.append("child\(index) role=\(role) length=\(String(describing: length)) children=\(String(describing: grand)) frame=\(String(describing: rect(child))) names=\(names.prefix(60))")
            for (gi, grandchild) in ((attr(child, kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(3).enumerated() {
                lines.append("child\(index).\(gi) role=\(attr(grandchild, kAXRoleAttribute) as? String ?? "?") frame=\(String(describing: rect(grandchild))) length=\(String(describing: (attr(grandchild, kAXValueAttribute) as? String)?.utf16.count))")
            }
            for key in ["AXDOMIdentifier", "AXDOMClassList", "AXRoleDescription", "AXSubrole", "AXEnabled", "AXVisited", "AXElementBusy"] {
                if let value = attr(child, key) { lines.append("child\(index) \(key)=\(String(describing: value).prefix(80))") }
            }
            if let marker = attr(element, "AXSelectedTextMarkerRange"), let owner = parameter("AXUIElementForTextMarker", marker) {
                lines.append("markerOwnerIsChild\(index)=\(CFEqual(owner, child))")
            }
        }
        if let start = attr(element, "AXStartTextMarker"),
           let range = parameter("AXTextMarkerRangeForUnorderedTextMarkers", [start, start] as CFArray) {
            lines.append("startMarker=\(bounds(parameter("AXBoundsForTextMarkerRange", range)))")
            if let line = parameter("AXLineTextMarkerRangeForTextMarker", start) {
                lines.append("startLine=\(bounds(parameter("AXBoundsForTextMarkerRange", line)))")
            }
            if let next = parameter("AXNextTextMarkerForTextMarker", start),
               let first = parameter("AXTextMarkerRangeForUnorderedTextMarkers", [start, next] as CFArray) {
                lines.append("firstCharacter=\(bounds(parameter("AXBoundsForTextMarkerRange", first)))")
            }
        }
        for (index, child) in ((attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(2).enumerated() {
            lines.append("child\(index) editableAncestor=\(attr(child, "AXEditableAncestor") != nil)")
        }
        if native, let text = window.firstResponder as? NSTextView {
            var actual = NSRange()
            lines.append("firstRect=\(NSStringFromRect(screenRect(text.firstRect(forCharacterRange: text.selectedRange(), actualRange: &actual))))")
        }
        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        lines.append("attributes=\(String(describing: names))")
        AXUIElementCopyParameterizedAttributeNames(element, &names)
        lines.append("parameters=\(String(describing: names))")
        guard valid() else { throw Failure.focusLost }
        try lines.joined(separator: "\n").write(to: output.appendingPathComponent(phase + "-geometry.txt"), atomically: true, encoding: .utf8)
    }

    private func sample(_ phase: String, result: inout Result) async throws {
        guard candidate?.isTerminated == false else { throw Failure.appLaunch }
        let before = clock()
        let (image, background, scale, capturedAt) = try await screenshot()
        let frame = try measure(image, background: background, scale: scale, phase: phase, name: result.scenario.name, capturedAt: capturedAt)
        guard valid() else { throw Failure.focusLost }
        if video == nil {
            video = try CaretFixtureVideo(url: output.appendingPathComponent("motion.mov"), image: image)
        }
        try video?.append(image, time: capturedAt - started, validate: valid)
        if ProcessInfo.processInfo.environment["INTENTION_CARET_GEOMETRY_TRACE"] == "1" {
            try geometryProbe(String(format: "%04d-%@", result.frames.count, phase))
        }
        let last = result.frames.last
        // Retain the actual observation even if recording exposes slow cadence.
        result.frames.append(frame)
        guard clock() - before < 0.3 else { throw Failure.cadence }
        if let last, last.phase == phase, frame.time - last.time > 0.3 { throw Failure.cadence }
    }

    private func observe(_ phase: String, seconds: Double, result: inout Result) async throws {
        let until = clock() + seconds
        while clock() < until {
            try await sample(phase, result: &result)
            try await Task.sleep(for: .milliseconds(35))
        }
    }

    private func exercise(_ item: Case) async -> Result {
        var result = Result(scenario: item)
        var stage = "fixture activation"
        savedPhases = []
        captureContent = nil
        video = nil
        do {
            if item.engine == "native" { try await prepareNative(item) }
            else if item.engine == "terminal" { try await prepareTerminal(item) }
            else { try await prepareChrome(item) }
            if !item.secure { try geometryProbe("setup") }
            stage = "candidate launch"
            try await launch(item)
            stage = "acquisition setup"
            started = try await refocusReadyFixture()
            try String(started).write(to: output.appendingPathComponent("measurement-uptime.txt"), atomically: true, encoding: .utf8)
            stage = "measurement"
            if item.name.hasPrefix("latency-") {
                try await measureLatency(item, result: &result)
            } else if item.secure {
                // No secure-field screenshots or characters. Window metadata
                // independently verifies the negative visibility requirement.
                try await Task.sleep(for: .seconds(2))
                guard valid() else { throw Failure.focusLost }
                guard candidate?.isTerminated == false else { throw Failure.appLaunch }
                guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { throw Failure.capture }
                let shown = windows.contains { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == candidate?.processIdentifier && ($0[kCGWindowName as String] as? String)?.hasPrefix("dot ") == true && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01 }
                result.verdict = shown ? "fail" : "pass"
                result.reason = shown ? "dot visible in secure field" : "secure field hides dot; no capture or input"
            } else {
                try await observe("cold", seconds: 3, result: &result)
                let count = try textCount()
                let character = item.engine.hasPrefix("electron-") ? "w" : "i"
                for _ in 0..<12 {
                    try await send(0, text: character)
                    result.expectedKeys += 1
                    try await sample("typing", result: &result)
                    try await Task.sleep(for: .milliseconds(35))
                }
                result.deliveredKeys = try textCount() - count
                guard result.deliveredKeys == result.expectedKeys else { throw Failure.receipts }
                try await observe("pause", seconds: 3, result: &result)
                let wrapExpected = !["input", "search"].contains(item.engine) && !(native && input != nil)
                if wrapExpected {
                    for _ in 0..<9 {
                        for _ in 0..<4 { try await send(0, text: character); result.expectedKeys += 1 }
                        try await sample("wrap", result: &result)
                    }
                    result.deliveredKeys = try textCount() - count
                    guard result.deliveredKeys == result.expectedKeys else { throw Failure.receipts }
                }
                for _ in 0..<3 {
                    let before = try selectionPosition()
                    try await send(123)
                    try await waitForSelection(before - 1)
                    try await sample("arrows", result: &result)
                }
                for _ in 0..<3 {
                    let before = try selectionPosition()
                    try await send(124)
                    try await waitForSelection(before + 1)
                    try await sample("arrows-right", result: &result)
                }
                for _ in 0..<result.expectedKeys {
                    try await send(51)
                    try await sample("deletion", result: &result)
                }
                guard try textCount() == count else { throw Failure.receipts }
                try await observe("empty-again", seconds: 3, result: &result)
                let relevant = result.frames.filter { $0.caretVisible }
                let missing = relevant.filter { !$0.dotVisible }
                let misplaced = relevant.filter { ($0.horizontalError ?? 0) > 0.5 || ($0.gap ?? 2) < 1 || ($0.gap ?? 2) > 5 }
                let requiredPhases = ["cold", "typing", "pause", "arrows", "deletion", "empty-again"] + (wrapExpected ? ["wrap"] : [])
                for phase in requiredPhases {
                    guard result.frames.contains(where: { $0.phase == phase && $0.caretVisible }) else { throw Failure.capture }
                }
                if wrapExpected {
                    guard let baseline = result.frames.last(where: { $0.phase == "pause" && $0.caretTop != nil })?.caretTop,
                          result.frames.contains(where: { $0.phase == "wrap" && ($0.caretTop ?? baseline) > baseline + 5 }) else { throw Failure.receipts }
                }
                if relevant.isEmpty { throw Failure.capture }
                result.focusCleared = try await focusAway()
                result.verdict = result.focusCleared == true && missing.isEmpty && misplaced.isEmpty ? "pass" : "fail"
                result.reason = "\(missing.count) visible-caret frames missing dot; \(misplaced.count) outside 0.5 pt centering or 1...5 pt gap; focus cleared \(result.focusCleared == true)"
            }
        } catch {
            result.verdict = "blocked"
            result.reason = String(describing: error)
            if result.reason == "focusLost" { print("Fixture gate denied during \(stage): \(gateFailure)") }
        }
        if let video {
            result.videoSampleTimes = video.times
            do {
                try await video.finish()
                result.video = "motion.mov"
            } catch {
                result.verdict = "blocked"
                result.reason += "; video could not be finalized: \(error)"
            }
        }
        candidate?.terminate()
        for _ in 0..<20 where candidate?.isTerminated == false { try? await Task.sleep(for: .milliseconds(50)) }
        if candidate?.isTerminated == false { candidate?.forceTerminate() }
        candidate = nil
        do {
            if terminal {
                try await cleanupTerminal()
            } else if let electronApp { electronApp.terminate() }
            else if native { window?.close() }
            else { try await cleanupChrome() }
        } catch {
            result.verdict = "blocked"
            result.reason += "; cleanup refused or failed: \(error)"
        }
        return result
    }

    /// Records the fixture at the display's frame rate while typing at a
    /// person's pace and then quickly, moving and deleting, and reports how
    /// long after the caret moves the dot is centred on it again.
    private func measureLatency(_ item: Case, result: inout Result) async throws {
        try await Task.sleep(for: .milliseconds(600))
        guard valid(), let candidate else { throw Failure.focusLost }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let target = content.windows.first(where: { $0.windowID == fixtureID && $0.owningApplication?.processID == fixturePID }),
              let display = content.displays.first(where: { $0.frame.contains(crop) }) else { throw Failure.capture }
        let panels = content.windows.filter { $0.owningApplication?.processID == candidate.processIdentifier && $0.title?.hasPrefix("dot ") == true }
        guard !panels.isEmpty else { throw Failure.capture }
        let recorder = try await CaretLatencyRecorder(
            filter: SCContentFilter(display: display, including: [target] + panels),
            sourceRect: crop.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY),
            allowedCaret: expectedField.offsetBy(dx: -crop.minX, dy: -crop.minY), dark: item.dark)
        var keys: [(name: String, sentAt: Double)] = []
        try await Task.sleep(for: .milliseconds(400))
        // The field's own count shows every key reached it, including any
        // deletion a blink kept from being measured.
        let startCount = try textCount()
        for index in 0..<30 {
            keys.append((index < 20 ? "type" : "type-fast", clock()))
            try await send(0, text: "i")
            result.expectedKeys += 1
            try await Task.sleep(for: .milliseconds(index < 20 ? 110 : 40))
        }
        let typedCount = try textCount()
        for code: CGKeyCode in Array(repeating: 123, count: 8) + Array(repeating: 124, count: 8) {
            keys.append((code == 123 ? "left" : "right", clock()))
            try await send(code)
            try await Task.sleep(for: .milliseconds(110))
        }
        for _ in 0..<30 {
            keys.append(("delete", clock()))
            try await send(51)
            try await Task.sleep(for: .milliseconds(90))
        }
        try await Task.sleep(for: .milliseconds(400))
        guard valid() else { throw Failure.focusLost }
        let endCount = try textCount()
        var delivered = false
        if typedCount - startCount == 30, endCount == startCount { delivered = true }
        let samples = await recorder.stop()
        let analysis = CaretLatencyRecorder.analyse(samples, keys: keys)
        let lags = analysis.compactMap(\.lagMilliseconds).sorted()
        let unmeasured = analysis.filter { $0.caretMovedAt == nil }.count
        // A key goes unmeasured legitimately only when it is a deletion and
        // a blink hid the caret for most of it, as Chrome's does between
        // deletions, and the field's count shows every key arrived. Any
        // other unmeasured key fails the case.
        let hidden = delivered ? analysis.filter { $0.caretMovedAt == nil && $0.caretHidden && $0.key == "delete" }.count : 0
        let stuck = unmeasured - hidden
        let thinKinds = Dictionary(grouping: analysis, by: \.key)
            .filter { _, results in results.filter { $0.caretMovedAt != nil }.count * 3 < results.count }.keys.sorted()
        let neverCaught = analysis.filter { $0.caretMovedAt != nil && $0.dotCaughtUpAt == nil }.count
        let span = (samples.last?.time ?? 0) - (samples.first?.time ?? 0)
        func percentile(_ fraction: Double) -> Double { lags.isEmpty ? -1 : lags[min(lags.count - 1, Int(Double(lags.count - 1) * fraction))] }
        let summary: [String: Any] = [
            "frames": samples.count, "frames_per_second": span > 0 ? Double(samples.count) / span : 0,
            "keys": keys.count, "measured": lags.count, "caret_not_seen_moving": unmeasured, "dot_never_caught_up": neverCaught,
            "keys_delivered": delivered, "deletions_hidden_by_blink": hidden, "other_unmeasured": stuck, "thinly_measured_kinds": thinKinds,
            "lag_ms_median": percentile(0.5), "lag_ms_p90": percentile(0.9), "lag_ms_max": lags.last ?? -1,
            "same_frame": lags.filter { $0 < 1 }.count,
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(analysis).write(to: output.appendingPathComponent("latency-keys.json"))
        try encoder.encode(samples).write(to: output.appendingPathComponent("latency-samples.json"))
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("latency.json"))
        result.deliveredKeys = delivered ? keys.count : 0
        result.focusCleared = true
        let oneFrame = 1000.0 / 60 + 1
        // Every key must be measured or be such a deletion, with at least
        // two thirds of all keys and a third of each kind measured.
        let observed = delivered && stuck == 0 && thinKinds.isEmpty && lags.count * 3 >= keys.count * 2
        result.verdict = neverCaught == 0 && observed && (lags.last ?? .infinity) <= oneFrame ? "pass" : "fail"
        result.reason = (delivered ? "" : "the field's count does not show every key arriving; ")
            + String(format: "%d of %d keys measured; lag median %.1f ms, p90 %.1f ms, max %.1f ms; %d in the same frame; %d never caught up; %d deletions unmeasured while the caret blinked off; %d other keys unmeasured",
                               lags.count, keys.count, percentile(0.5), percentile(0.9), lags.last ?? -1, lags.filter { $0 < 1 }.count, neverCaught, hidden, stuck)
            + (thinKinds.isEmpty ? "" : "; under a third measured: " + thinKinds.joined(separator: ", "))
    }

    /// Cleanup uses saved object identities. Added tabs or changed ownership
    /// are preserved, and an unremoved temporary profile blocks qualification.
    private func cleanupTerminal() async throws {
        guard let terminalProfile else { return }
        var closeOwnedWindow = ""
        if let terminalWindow {
            try Data().write(to: output.appendingPathComponent("terminal-stop"))
            let process = try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: output.appendingPathComponent("terminal-process.json")))
            guard let pid = process["pid"], pid > 1 else { throw Failure.fixture }
            var stopped = false
            for _ in 0..<40 {
                let receipt = try? JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: output.appendingPathComponent("terminal-stopped.json")))
                if receipt?["pid"] == pid, kill(pid, 0) == -1, errno == ESRCH {
                    stopped = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard stopped else {
                try "shutdown-unconfirmed; window and profile preserved".write(to: output.appendingPathComponent("terminal-cleanup.txt"), atomically: true, encoding: .utf8)
                throw Failure.fixture
            }
            closeOwnedWindow = """
            if exists window id \(terminalWindow) then
                set w to window id \(terminalWindow)
                if (count of tabs of w) is not 1 then return "changed-tabs"
                if name of current settings of selected tab of w is not "\(terminalProfile)" then return "changed-profile"
                if custom title of selected tab of w is not "\(terminalProfile)" then return "changed-title"
                close w
            end if
            if exists window id \(terminalWindow) then return "window-remains"
            """
        }
        // An import can succeed before setup obtains a window ID. In that
        // case remove only an unused exact profile; preserve any window.
        let status = try await appleScript("""
        tell application "Terminal"
            \(closeOwnedWindow)
            repeat with w in windows
                repeat with t in tabs of w
                    if name of current settings of t is "\(terminalProfile)" then return "profile-still-in-use"
                end repeat
            end repeat
            if exists settings set "\(terminalProfile)" then delete settings set "\(terminalProfile)"
            if exists settings set "\(terminalProfile)" then return "profile-remains"
            return "removed-owned-window-and-profile"
        end tell
        """)
        try status.write(to: output.appendingPathComponent("terminal-cleanup.txt"), atomically: true, encoding: .utf8)
        guard status == "removed-owned-window-and-profile" else { throw Failure.fixture }
    }

    private func cleanupChrome() async throws {
        guard let chromeWindow, let chromeTab, let chromeURL, let chromeFixtureTitle else { return }
        let status = try await appleScript("""
        tell application "Google Chrome"
            considering case
            if not (exists window id "\(chromeWindow)") then return "already-closed"
            set w to window id "\(chromeWindow)"
            repeat with t in tabs of w
                if (id of t as text) is "\(chromeTab)" then
                    if URL of t is not "\(chromeURL)" then return "changed-url"
                    if title of t is not "\(chromeFixtureTitle)" then return "changed-title"
                    close t
                    return "closed-owned-tab"
                end if
            end repeat
            return "owned-tab-absent"
            end considering
        end tell
        """)
        try status.write(to: output.appendingPathComponent("chrome-cleanup.txt"), atomically: true, encoding: .utf8)
        guard ["already-closed", "closed-owned-tab", "owned-tab-absent"].contains(status) else { throw Failure.fixture }
        let absent = try await chromeFixtureTabs(url: chromeURL, title: chromeFixtureTitle, close: false)
        guard absent == "absent" else { throw Failure.fixture }
    }

    /// Metadata-only cleanup for generated fixtures. Never activates Chrome,
    /// posts input, reads editable values, or closes an entire window.
    private func chromeFixtureTabs(url: String, title: String, close: Bool) async throws -> String {
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return try await appleScript("""
        tell application "Google Chrome"
            considering case
                set matches to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t as text) is \(quoted(url)) then
                            if (title of t as text) is not \(quoted(title)) then return "changed-title"
                            set end of matches to t
                        end if
                    end repeat
                end repeat
                if (count of matches) is 0 then return "absent"
                if (count of matches) is not 1 then return "ambiguous"
                if \(close ? "true" : "false") then
                    set targetTab to item 1 of matches
                    if (URL of targetTab as text) is not \(quoted(url)) then return "changed-url"
                    if (title of targetTab as text) is not \(quoted(title)) then return "changed-title"
                    close targetTab
                    return "closed"
                end if
                return "present"
            end considering
        end tell
        """)
    }

    private func cleanupStaleChromeFixtures() async throws {
        guard let root = Bundle.main.object(forInfoDictionaryKey: "IntentionFixtureRepositoryRoot") as? String else { throw Failure.fixture }
        let base = URL(fileURLWithPath: root).appendingPathComponent("apps/macos/.build/caret-lab").standardizedFileURL
        let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: appURL))
        var receipt: [[String: String]] = []
        for path in paths {
            let file = URL(fileURLWithPath: path).standardizedFileURL
            guard file.path.hasPrefix(base.path + "/"), file.resolvingSymlinksInPath() == file,
                  file.pathExtension == "html", FileManager.default.fileExists(atPath: file.path) else { throw Failure.fixture }
            let html = try String(contentsOf: file, encoding: .utf8)
            guard let begin = html.range(of: "<title>"), let end = html.range(of: "</title>", range: begin.upperBound..<html.endIndex) else { throw Failure.fixture }
            let title = String(html[begin.upperBound..<end.lowerBound])
            let parts = title.split(separator: " ")
            guard parts.count == 5, parts[0...2].joined(separator: " ") == "Intention caret lab",
                  UUID(uuidString: String(parts[3])) != nil,
                  String(parts[4]) == file.deletingPathExtension().lastPathComponent,
                  ["chrome-input", "chrome-search", "chrome-textarea-dark", "chrome-placeholder", "chrome-placeholder-dark-tall"].contains(String(parts[4])) else { throw Failure.fixture }
            let status = try await chromeFixtureTabs(url: file.absoluteString, title: title, close: true)
            guard ["closed", "absent"].contains(status), try await chromeFixtureTabs(url: file.absoluteString, title: title, close: false) == "absent" else { throw Failure.fixture }
            receipt.append(["fixture": file.path, "status": status])
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("cleanup-receipt.json"), options: .atomic)
        }
    }

    /// Reacquire the fixture with the signed candidate already ready. This
    /// prevents app-launch time from hiding the first-focus acquisition gap.
    private func refocusReadyFixture() async throws -> Double {
        guard valid(), candidate?.isTerminated == false else { throw Failure.focusLost }
        let other = NSWindow(contentRect: CGRect(x: 240, y: 260, width: 400, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.title = token + " acquisition setup"
        other.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { other.close() }
        let transferTitle = other.title
        let transferWindowID = other.windowNumber
        let transferResponder = other.firstResponder
        func ownsTransferFocus() -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else { gateFailure = "transfer frontmost PID"; return false }
            guard NSApp.keyWindow === other, other.isVisible else { gateFailure = "transfer key window"; return false }
            guard other.title == transferTitle, other.windowNumber == transferWindowID else { gateFailure = "transfer window identity"; return false }
            guard other.firstResponder === transferResponder else { gateFailure = "transfer focused control"; return false }
            return true
        }
        try await Task.sleep(for: .milliseconds(200))
        guard ownsTransferFocus() else { throw Failure.focusLost }
        let began = clock()
        if panelMode {
            try await keyPanelOverAnotherApp()
            window.makeFirstResponder(input ?? editor)
        } else if native {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(input ?? editor)
        } else if let electronApp {
            electronApp.activate()
        } else if terminal, let terminalWindow {
            _ = try await appleScript("""
            tell application "Terminal"
                if exists window id \(terminalWindow) then
                    set w to window id \(terminalWindow)
                    if name of current settings of selected tab of w starts with "\(token)" then
                        set index of w to 1
                        activate
                    end if
                end if
            end tell
            """)
            // Apple Event activation from this runner can leave Terminal's
            // window unkeyed (its inactive outline cursor); LaunchServices
            // activation makes the ordered-front fixture window key.
            let activation = NSWorkspace.OpenConfiguration()
            activation.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: activation)
        } else if let chromeWindow {
            _ = try await appleScript("""
            tell application "Google Chrome"
                if title of active tab of window id "\(chromeWindow)" starts with "\(token)" then
                    set index of window id "\(chromeWindow)" to 1
                    activate
                end if
            end tell
            """)
        }
        for _ in 0..<20 {
            if valid() { return began }
            // While this single planned transfer is pending, only the exact
            // owned temporary window may retain focus. Any third window or
            // control aborts; a later return must never resume the run.
            guard ownsTransferFocus() else { throw Failure.focusLost }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure.focusLost
    }

    private func focusAway() async throws -> Bool {
        guard valid(), candidate?.isTerminated == false else { throw Failure.focusLost }
        let other = NSWindow(contentRect: CGRect(x: 240, y: 260, width: 400, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.title = token + " controlled focus transfer"
        other.contentView = NSTextField(labelWithString: "Owned synthetic focus destination")
        other.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { other.close() }
        try await Task.sleep(for: .milliseconds(250))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), NSApp.keyWindow === other,
              other.isVisible, candidate?.isTerminated == false else { throw Failure.focusLost }
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { throw Failure.capture }
        return !windows.contains { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == candidate?.processIdentifier && ($0[kCGWindowName as String] as? String)?.hasPrefix("dot ") == true && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01 }
    }

    func run() async {
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            if CommandLine.arguments[3] == "cleanup-owned-chrome" {
                try await cleanupStaleChromeFixtures()
                print("PASS exact synthetic Chrome tab cleanup")
                exit(0)
            }
            guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { throw Failure.permissions }
            let cases = [
                Case(name: "native-light", engine: "native", dark: false, tall: false, secure: false, visual: true),
                Case(name: "latency-native", engine: "native", dark: false, tall: false, secure: false, visual: true),
                Case(name: "latency-chrome", engine: "textarea", dark: false, tall: false, secure: false, visual: true),
                Case(name: "latency-electron", engine: "electron-tiptap", dark: false, tall: false, secure: false, visual: true),
                Case(name: "native-single", engine: "native", dark: false, tall: false, secure: false, visual: true),
                Case(name: "native-search", engine: "native", dark: false, tall: false, secure: false, visual: true),
                Case(name: "native-panel", engine: "native", dark: false, tall: false, secure: false, visual: true),
                Case(name: "native-dark-tall", engine: "native", dark: true, tall: true, secure: false, visual: true),
                Case(name: "chrome-input", engine: "input", dark: false, tall: false, secure: false, visual: true),
                Case(name: "chrome-search", engine: "search", dark: false, tall: false, secure: false, visual: true),
                Case(name: "chrome-textarea-dark", engine: "textarea", dark: true, tall: false, secure: false, visual: true),
                Case(name: "chrome-placeholder", engine: "contenteditable", dark: false, tall: false, secure: false, visual: true),
                Case(name: "chrome-placeholder-dark-tall", engine: "contenteditable", dark: true, tall: true, secure: false, visual: true),
                Case(name: "electron-t3-layout", engine: "electron-t3-layout", dark: false, tall: false, secure: false, visual: true),
                Case(name: "electron-tiptap", engine: "electron-tiptap", dark: false, tall: false, secure: false, visual: true),
                Case(name: "electron-lexical", engine: "electron-lexical", dark: true, tall: true, secure: false, visual: true),
                Case(name: "electron-placeholder", engine: "electron-placeholder", dark: true, tall: true, secure: false, visual: true),
                Case(name: "terminal-beam", engine: "terminal", dark: false, tall: false, secure: false, visual: true),
                Case(name: "native-secure", engine: "native", dark: false, tall: false, secure: true, visual: true),
            ]
            let only = CommandLine.arguments[3]
            guard cases.contains(where: { $0.name == only }) else { throw Failure.fixture }
            var aborted = false
            for item in cases where only == item.name {
                var result: Result
                if aborted {
                    result = Result(scenario: item)
                    result.reason = "not run after blocked fixture"
                } else { result = await exercise(item) }
                results.append(result)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(results).write(to: output.appendingPathComponent("results.json"), options: .atomic)
                print("\(result.verdict.uppercased()) \(item.name): \(result.reason)")
                fflush(stdout)
                // A setup failure can mask focus loss. Every blocked result
                // ends the run; never activate a later fixture or resume input.
                if result.verdict == "blocked" { aborted = true }
            }
            if aborted { exit(3) }
            exit(!results.isEmpty && results.allSatisfy { $0.verdict == "pass" } ? 0 : 1)
        } catch {
            print("BLOCKED caret lab: \(error)")
            exit(2)
        }
    }
}
