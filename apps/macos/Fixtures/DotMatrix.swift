import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit

// The dot matrix: puts the caret in a row of fields, synthetic and real, on a
// test Mac, and checks that the dot Intention draws sits on it. For each case it
// focuses the field by a click or by Tab, empty and with a letter typed, then
// reads where Intention placed the dot from the Debug build's `--dot-log`, finds
// the caret itself in the field's window (the green caret of the synthetic
// page, or the pixels that blink) and prints the offset in points with the
// tracker's last outcome. Overlay cases expect no dot. It takes over the
// screen and posts clicks and keys, so it runs only on a Mac set aside for
// it; see apps/macos/scripts/dot-matrix.sh.
//
// Every key and click is guarded: the case's app must be frontmost and its
// window the focused one. Browsers and editors run as a separate instance on
// a profile of their own; TextEdit's document and Terminal's window are the
// ones the matrix made, closed by their own names. Return is never pressed.
// Captures include only the window the matrix opened and Intention's own dot
// panels, never a region of the screen. Nothing is typed into an app with a
// person's data; the real sites it visits are ones a signed-out browser can
// type into.

struct Arguments {
    var app = ""
    var out = ""
    var fixture = ""
    var chrome = "/Applications/Google Chrome Beta.app"
    var only: Set<String> = []
    var settle = 1.6
    var record = false
    var sites = false
    var native = true
    var safari = true
    var keepIntention = false
    /// Only the capture the caret measurement needs, no picture or
    /// recording for a person.
    var pictures = true
    /// Ask macOS for the grants the matrix needs and stop.
    var permissions = false
    /// Real Gmail and Google Docs in the person's own Chrome Beta, each in a
    /// new window the matrix opens and closes itself.
    var gmail = false
    var docs = false
    var chromeBeta = "/Applications/Google Chrome Beta.app"
    /// The caret lab's WebKit and Electron fixture apps, when built.
    var webkitHost = ""
    var electronHost = ""

    init() {
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--app": app = it.next() ?? ""
            case "--out": out = it.next() ?? ""
            case "--fixture": fixture = it.next() ?? ""
            case "--chrome": chrome = it.next() ?? chrome
            case "--only": only = Set((it.next() ?? "").split(separator: ",").map(String.init))
            case "--settle": settle = Double(it.next() ?? "") ?? settle
            case "--record": record = true
            case "--sites": sites = true
            case "--no-native": native = false
            case "--no-safari": safari = false
            case "--keep-intention": keepIntention = true
            case "--no-pictures": pictures = false
            case "--permissions": permissions = true
            case "--gmail": gmail = true
            case "--docs": docs = true
            case "--chrome-beta": chromeBeta = it.next() ?? chromeBeta
            case "--webkit-host": webkitHost = it.next() ?? ""
            case "--electron-host": electronHost = it.next() ?? ""
            default: fputs("unknown argument \(a)\n", stderr); exit(2)
            }
        }
        guard permissions || (!app.isEmpty && !out.isEmpty && !fixture.isEmpty) else {
            fputs("usage: dot-matrix --app <Intention.app> --out <dir> --fixture <dot-fields.html> [--chrome <app>] [--only a,b] [--settle s] [--record] [--sites] [--gmail] [--docs] [--webkit-host <app>] [--electron-host <app>] [--no-native] [--no-safari] [--no-pictures] | --permissions\n", stderr)
            exit(2)
        }
    }
}

enum Host: String { case chrome, safari, webkit, electron, chromeBeta, textedit, terminal, vscode, cursor }
enum Focus: String { case click, tab }
enum Expect: String { case shown, hidden }

struct Case {
    let name: String
    let host: Host
    /// A fixture field id, or empty for a site, an address bar or a native app.
    let field: String
    var url: String? = nil
    var overlay: String? = nil
    var dark = false
    var focus = Focus.click
    var expect = Expect.shown
    /// A real site: find its first text control through Accessibility.
    var site = false
    var addressBar = false
    /// Where to click inside the field, from its top-left, in points.
    var clickOffset = CGPoint(x: 40, y: 18)
    /// The fixture page's fields, in a browser that can pass a query.
    var synthetic: Bool { !site && !addressBar && (host == .chrome || host == .safari) }
    /// The fixture page in a host that loads it by path: no title receipt,
    /// the case is baked in as a meta tag, the caret is still green.
    var bakedFixture: Bool { host == .webkit || host == .electron }
    var green: Bool { synthetic || bakedFixture }
}

struct Outcome: Codable {
    var name: String
    var host: String
    var state: String
    var focus: String
    var expect: String
    var result: String
    var shown: Bool
    var source: String
    var reason: String
    var dotX: Double?
    var dotY: Double?
    var diameter: Double?
    var caretX: Double?
    var caretTop: Double?
    var caretHeight: Double?
    var offsetX: Double?
    var gap: Double?
    var latencyMs: Double?
    var ink: [Double]?
    var note: String
}

@MainActor
final class Matrix: OwnedWindows {
    let args = Arguments()
    var outcomes: [Outcome] = []
    var logURL: URL { URL(fileURLWithPath: args.out).appendingPathComponent("dot-log.jsonl") }
    var fixtureURL: URL { URL(fileURLWithPath: args.fixture) }
    var outURL: URL { URL(fileURLWithPath: args.out) }

    // MARK: Accessibility helpers (reads only, plus the clicks and keys below)

    func isTextControl(_ e: AXUIElement?) -> Bool {
        guard let e, let role = str(e, kAXRoleAttribute) else { return false }
        return ["AXTextArea", "AXTextField", "AXComboBox", "AXWebArea"].contains(role)
    }
    /// The caret the page itself reports in its title receipt, in screen
    /// points: its viewport rectangle offset by the web area's origin.
    func caretFromReceipt(window: AXUIElement, field: AXUIElement) -> CGRect? {
        guard let title = str(window, kAXTitleAttribute), let range = title.range(of: " rect=") else { return nil }
        let value = title[range.upperBound...].prefix { $0 != " " }
        let parts = value.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        var node = field
        for _ in 0..<40 {
            if str(node, kAXRoleAttribute) == "AXWebArea", let origin = frame(node) {
                return CGRect(x: origin.minX + parts[0], y: origin.minY + parts[1], width: parts[2], height: parts[3])
            }
            guard let parent = elem(node, kAXParentAttribute) else { return nil }
            node = parent
        }
        return nil
    }
    /// The first text control in `window`, breadth first, roles only.
    func firstTextControl(in window: AXUIElement) -> AXUIElement? {
        var queue = [window], visited = 0
        while !queue.isEmpty, visited < 6000 {
            let e = queue.removeFirst(); visited += 1
            if let role = str(e, kAXRoleAttribute), ["AXTextArea", "AXTextField", "AXComboBox"].contains(role), let f = frame(e), f.width > 40, f.height > 14 { return e }
            queue.append(contentsOf: elems(e, kAXChildrenAttribute))
        }
        return nil
    }

    // MARK: Guards, clicks and keys


    /// Whether the element the window server would send a click at `point`
    /// to belongs to `pid` and sits in `window`: an overlay of another
    /// process, or another window of the same one, refuses the click.
    func pointReaches(_ point: CGPoint, pid: pid_t, window: AXUIElement) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success, let hit else { return false }
        var owner: pid_t = 0
        guard AXUIElementGetPid(hit, &owner) == .success, owner == pid else { return false }
        var node = hit
        for _ in 0..<60 {
            if CFEqual(node, window) { return true }
            if str(node, kAXRoleAttribute) == kAXWindowRole { return false }
            guard let parent = elem(node, kAXParentAttribute) else { return false }
            node = parent
        }
        return false
    }
    /// A click at `point`, posted only when the focused window of `pid` is
    /// `window`, the point is inside it and the element there is `window`'s
    /// own; the release goes out whatever happened meanwhile, so no button
    /// stays down.
    func click(at point: CGPoint, pid: pid_t, window: AXUIElement) async -> Bool {
        guard ProcessSafety.allowsCheckInput, guardWindow(pid, window), frame(window)?.contains(point) == true, pointReaches(point, pid: pid, window: window),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return false }
        down.post(tap: .cghidEventTap)
        await sleep(0.04)
        let still = guardWindow(pid, window)
        up.post(tap: .cghidEventTap)
        return still
    }
    /// A key to `pid` alone, never to whatever is frontmost, with the window
    /// guard checked before the press and before the release.
    func key(_ code: CGKeyCode, flags: CGEventFlags = [], pid: pid_t, window: AXUIElement) async -> Bool {
        guard ProcessSafety.allowsCheckInput, guardWindow(pid, window), let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        await sleep(0.03)
        let still = guardWindow(pid, window)
        up.postToPid(pid)
        await sleep(0.03)
        return still
    }
    let keyA: CGKeyCode = 0, keyTab: CGKeyCode = 48, keyDelete: CGKeyCode = 51, keyEscape: CGKeyCode = 53, keyL: CGKeyCode = 37, keyN: CGKeyCode = 45

    // MARK: Intention's log

    struct LogLine { let time: Double; let event: String; let source: String; let reason: String; let dot: (x: Double, y: Double, d: Double)?; let caret: CGRect?; let ink: [Double]? }
    func log(since: Double) -> [LogLine] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line -> LogLine? in
            guard let data = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let time = o["time"] as? Double, time >= since, let event = o["event"] as? String else { return nil }
            var dot: (Double, Double, Double)?
            if let d = o["dot"] as? [String: Double], let x = d["x"], let y = d["y"], let dd = d["diameter"] { dot = (x, y, dd) }
            var caret: CGRect?
            if let c = o["caret"] as? [String: Double], let x = c["x"], let y = c["y"], let w = c["width"], let h = c["height"] { caret = CGRect(x: x, y: y, width: w, height: h) }
            return LogLine(time: time, event: event, source: o["source"] as? String ?? "", reason: o["reason"] as? String ?? "", dot: dot, caret: caret, ink: o["ink"] as? [Double])
        }
    }

    func pixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }
    /// The caret inside `field` (screen points, top-left origin) in the
    /// window `wid`, without the dot: the green stroke of a synthetic page,
    /// else the thin vertical region that changes between frames as the
    /// caret blinks. Returns a rectangle in screen points.
    var lastCaptureNote = ""
    func caretFromPixels(window wid: CGWindowID, pid: pid_t, field: CGRect, green: Bool) async -> CGRect? {
        lastCaptureNote = ""
        var frames: [[UInt8]] = []
        var size = (w: 0, h: 0), scale: CGFloat = 1
        for _ in 0..<5 {
            if let (image, s) = await capture(window: wid, pid: pid, rect: field, withDot: false), let px = pixels(image) {
                if frames.isEmpty || (image.width == size.w && image.height == size.h) { size = (image.width, image.height); scale = s; frames.append(px) }
            }
            await sleep(0.22)
        }
        guard frames.count >= 2, size.w > 0 else { lastCaptureNote = "the window could not be captured (\(frames.count) frames)"; return nil }
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        func include(_ x: Int, _ y: Int) { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        for y in 0..<size.h {
            for x in 0..<size.w {
                let i = (y * size.w + x) * 4
                if green {
                    if frames.contains(where: { f in Int(f[i + 1]) > 150 && Int(f[i]) < 110 && Int(f[i + 2]) < 110 }) { include(x, y) }
                } else {
                    for k in 1..<frames.count {
                        let a = frames[0], b = frames[k]
                        if max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2]))) > 48 { include(x, y); break }
                    }
                }
            }
        }
        guard maxX >= 0 else { lastCaptureNote = green ? "no green caret in \(frames.count) frames" : "nothing changed between \(frames.count) frames"; return nil }
        let rect = CGRect(x: field.minX + Double(minX) / scale, y: field.minY + Double(minY) / scale,
                          width: Double(maxX - minX + 1) / scale, height: Double(maxY - minY + 1) / scale)
        // A caret is thin and at least half a line tall; anything wider is
        // text that changed, which says nothing about the caret.
        guard rect.width <= 4, rect.height >= 7 else { lastCaptureNote = String(format: "the changed region is %.0f by %.0f points, not a caret", rect.width, rect.height); return nil }
        return rect
    }

    // MARK: Hosts

    var chromeApp: NSRunningApplication?
    var editorApp: NSRunningApplication?
    var fixtureApp: NSRunningApplication?
    var safariWindowID: String?
    var textEditDocument: String?
    var terminalWindowID: String?
    /// A copy of the page with the case baked in, named and placed as the
    /// host demands: the WebKit fixture opens only `insertion-*.html`, and
    /// the Electron fixture only a page inside its output folder.
    func bakedPage(_ c: Case, in directory: URL, name: String) -> URL? {
        let query = "focus=\(c.field)&by=\(c.focus.rawValue)" + (c.overlay.map { "&overlay=\($0)" } ?? "") + (c.dark ? "&dark=1" : "")
        guard var html = try? String(contentsOf: fixtureURL, encoding: .utf8) else { return nil }
        html = html.replacingOccurrences(of: "<title>Intention dot fields</title>", with: "<title>Intention dot fields</title><meta name=\"intention-case\" content=\"\(query)\">")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try? html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func pageURL(_ c: Case) -> String {
        fixtureURL.absoluteString + "?focus=\(c.field)&by=\(c.focus.rawValue)" + (c.overlay.map { "&overlay=\($0)" } ?? "") + (c.dark ? "&dark=1" : "")
    }

    /// Opens the case's window and returns its process and AX window.
    func open(_ c: Case) async -> (pid: pid_t, window: AXUIElement)? {
        switch c.host {
        case .chrome:
            let url = c.synthetic ? pageURL(c) : (c.url ?? fixtureURL.absoluteString)
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.activates = true
            let profile = outURL.appendingPathComponent("chrome-profile").path
            var arguments = ["--user-data-dir=\(profile)", "--no-first-run", "--no-default-browser-check", "--disable-sync", "--disable-features=TranslateUI",
                             "--window-position=120,120", "--window-size=820,700"]
            if c.addressBar { arguments += ["--new-window", url] } else { arguments.append("--app=\(url)") }
            config.arguments = arguments
            guard let app = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: args.chrome), configuration: config) else { return nil }
            chromeApp = app
            for _ in 0..<80 {
                if frontmost(app.processIdentifier), let w = focusedWindow(app.processIdentifier), frame(w).map({ $0.width > 300 }) == true { await sleep(c.site ? 2.5 : 0.8); return (app.processIdentifier, w) }
                await sleep(0.1)
            }
            return nil
        case .safari:
            let url = c.synthetic ? pageURL(c) : (c.url ?? fixtureURL.absoluteString)
            guard let id = appleScript("""
            tell application "Safari"
                set d to make new document with properties {URL:"\(url)"}
                activate
                set bounds of front window to {120, 120, 940, 820}
                return id of front window as string
            end tell
            """) else { return nil }
            safariWindowID = id
            guard let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first else { return nil }
            for _ in 0..<80 {
                if frontmost(safari.processIdentifier), let w = focusedWindow(safari.processIdentifier) { await sleep(c.site ? 2.5 : 1.0); return (safari.processIdentifier, w) }
                await sleep(0.1)
            }
            return nil
        case .webkit:
            guard !args.webkitHost.isEmpty, let page = bakedPage(c, in: outURL, name: "insertion-\(c.name).html") else { return nil }
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.activates = true
            config.arguments = ["--fixture-page", page.path]
            guard let app = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: args.webkitHost), configuration: config) else { return nil }
            fixtureApp = app
            for _ in 0..<60 { if frontmost(app.processIdentifier), let w = focusedWindow(app.processIdentifier) { await sleep(1.2); return (app.processIdentifier, w) }; await sleep(0.1) }
            return nil
        case .electron:
            let dir = outURL.appendingPathComponent("\(c.name)-electron")
            guard !args.electronHost.isEmpty, let page = bakedPage(c, in: dir, name: "\(c.name).html") else { return nil }
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.activates = true
            config.arguments = ["--fixture-page", page.path, "--fixture-output", dir.path, "--fixture-title", "Intention caret lab \(UUID().uuidString) electron-dot \(c.name)"]
            guard let app = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: args.electronHost), configuration: config) else { return nil }
            fixtureApp = app
            for _ in 0..<100 { if frontmost(app.processIdentifier), let w = focusedWindow(app.processIdentifier) { await sleep(1.2); return (app.processIdentifier, w) }; await sleep(0.1) }
            return nil
        case .chromeBeta:
            guard let url = c.url else { return nil }
            return await openChromeBetaWindow(url: url, settle: c.field == "docs" ? 6 : 5)
        case .textedit:
            // The document is remembered by name, and only it is closed.
            guard let name = appleScript("""
            tell application "TextEdit"
                activate
                set d to make new document
                set bounds of front window to {120, 120, 760, 560}
                return name of d
            end tell
            """), let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else { return nil }
            textEditDocument = name
            for _ in 0..<50 {
                if frontmost(app.processIdentifier), let w = focusedWindow(app.processIdentifier), str(w, kAXTitleAttribute) == name { await sleep(0.5); return (app.processIdentifier, w) }
                await sleep(0.1)
            }
            return nil
        case .terminal:
            guard let id = appleScript("""
            tell application "Terminal"
                activate
                set t to do script ""
                set bounds of front window to {120, 120, 760, 520}
                return id of front window as string
            end tell
            """), let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else { return nil }
            terminalWindowID = id
            for _ in 0..<150 { if frontmost(app.processIdentifier), let w = focusedWindow(app.processIdentifier) { await sleep(1.5); return (app.processIdentifier, w) }; await sleep(0.1) }
            return nil
        case .vscode, .cursor:
            // An instance of its own, on data and extension folders of its
            // own, so a running editor and its windows are never touched.
            let bundle = c.host == .vscode ? "com.microsoft.VSCode" : "com.todesktop.230313mzl4w4u92"
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
            let data = outURL.appendingPathComponent("\(c.host.rawValue)-data").path, extensions = outURL.appendingPathComponent("\(c.host.rawValue)-extensions").path
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.arguments = ["--user-data-dir=\(data)", "--extensions-dir=\(extensions)", "--new-window", "--disable-workspace-trust", "--disable-extensions", "--skip-welcome", "--skip-release-notes"]
            config.activates = true
            guard let app = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config) else { return nil }
            editorApp = app
            for _ in 0..<150 {
                if frontmost(app.processIdentifier), let w = focusedWindow(app.processIdentifier) {
                    await sleep(2.0)
                    _ = await key(keyN, flags: .maskCommand, pid: app.processIdentifier, window: w)
                    await sleep(1.0)
                    return (app.processIdentifier, focusedWindow(app.processIdentifier) ?? w)
                }
                await sleep(0.1)
            }
            return nil
        }
    }

    func close(_ c: Case) async {
        func end(_ app: NSRunningApplication?) async {
            guard let app else { return }
            app.terminate()
            for _ in 0..<30 { if app.isTerminated { break }; await sleep(0.1) }
            if !app.isTerminated { app.forceTerminate() }
        }
        switch c.host {
        case .chrome:
            await end(chromeApp); chromeApp = nil
        case .safari:
            if let id = safariWindowID { _ = appleScript("tell application \"Safari\" to close (first window whose id is \(id))") }
            safariWindowID = nil
        case .textedit:
            if let name = textEditDocument { _ = appleScript("tell application \"TextEdit\" to if exists document \"\(name)\" then close document \"\(name)\" saving no") }
            textEditDocument = nil
        case .terminal:
            if let id = terminalWindowID { _ = appleScript("tell application \"Terminal\" to close (first window whose id is \(id))") }
            terminalWindowID = nil
        case .vscode, .cursor:
            await end(editorApp); editorApp = nil
        case .webkit, .electron:
            await end(fixtureApp); fixtureApp = nil
        case .chromeBeta:
            // Only the window the matrix opened, by its id, and only after the
            // draft it made is discarded through Gmail's own control. A
            // window that will not close, or a sheet, is left and reported.
            guard chromeBetaWindowID != nil else { return }
            if c.field == "gmail" { chromeBetaNote = await discardDraft() }
            if await !closeMadeWindow() { chromeBetaNote += "; the window did not close and was left as it is" }
        }
        await sleep(0.4)
    }

    // MARK: One case

    func run(_ c: Case) async {
        guard let (pid, window) = await open(c) else {
            let why = chromeBetaNote.isEmpty ? "the app or window did not open" : chromeBetaNote
            chromeBetaNote = ""
            outcomes.append(Outcome(name: c.name, host: c.host.rawValue, state: "setup", focus: c.focus.rawValue, expect: c.expect.rawValue, result: "blocked", shown: false, source: "", reason: "", note: why))
            print(line(outcomes.last!))
            return
        }
        let bounds = frame(window) ?? .zero
        let wid = c.host == .chromeBeta ? chromeBetaServerWindow : windowID(window, pid: pid)
        // The field: a fixture field by its receipt, a site's first text
        // control, the address bar, or the window's focused control.
        var field: AXUIElement?
        var fieldFrame: CGRect?
        for _ in 0..<(c.host == .chromeBeta ? 100 : 30) {
            if c.addressBar {
                _ = await key(keyL, flags: .maskCommand, pid: pid, window: window); await sleep(0.3)
                _ = await key(keyDelete, pid: pid, window: window); await sleep(0.3)
                field = focusedElement(pid)
            } else if c.site {
                field = firstTextControl(in: window)
            } else if c.synthetic {
                if let title = str(window, kAXTitleAttribute), title.contains("case=\(c.field) ") { field = focusedElement(pid); if c.focus == .tab { break } }
            } else if c.host == .chromeBeta, c.field == "gmail" {
                // Gmail's empty body reports no height, so the click goes
                // into the compose area that holds it: the nearest ancestor
                // at least 100 points tall. Without the body, nothing is clicked.
                field = element(described: "Message Body", under: window)
                if let f = field {
                    var node = f
                    for _ in 0..<12 {
                        guard let parent = elem(node, kAXParentAttribute) else { break }
                        if let pf = frame(parent), pf.height >= 100, pf.width >= 200 { fieldFrame = pf; break }
                        node = parent
                    }
                    if fieldFrame != nil { break }
                }
                field = nil
            } else if c.host == .chromeBeta {
                // Docs' own editing surface: the page below its toolbars.
                field = nil
                if let f = frame(window) { fieldFrame = CGRect(x: f.minX + 120, y: f.minY + 260, width: f.width - 240, height: f.height - 320); break }
            } else {
                field = focusedElement(pid)
            }
            if let field, let f = frame(field), f.width > 0 { fieldFrame = f; break }
            await sleep(0.1)
        }
        // A recording of the window and the dot while the case runs.
        var video: CaretFixtureVideo?
        var recording: Task<Void, Never>?
        if args.record, args.pictures, let wid, bounds.width > 0 {
            let region = (fieldFrame ?? bounds).insetBy(dx: -24, dy: -32).intersection(bounds)
            let began = ProcessInfo.processInfo.systemUptime
            recording = Task { @MainActor in
                while !Task.isCancelled {
                    if let (image, _) = await capture(window: wid, pid: pid, rect: region, withDot: true) {
                        if video == nil { video = try? CaretFixtureVideo(url: outURL.appendingPathComponent("\(c.name).mov"), image: image) }
                        try? video?.append(image, time: ProcessInfo.processInfo.systemUptime - began, validate: { true })
                    }
                    await sleep(0.1)
                }
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        // Focus by the chosen route. A fixture page already focused the
        // field by script; a click moves the caret where a person would
        // put it, a Tab lands on the field from the button before it.
        var focused = false
        if c.focus == .tab, c.synthetic {
            focused = await key(keyTab, pid: pid, window: window)
        } else if !c.addressBar {
            // In the person's own browser the click goes only into the area
            // the case found, never into the window at large.
            if let f = fieldFrame ?? (c.site || c.host == .chromeBeta ? nil : frame(window)) {
                focused = await click(at: CGPoint(x: f.minX + min(c.clickOffset.x, f.width - 4), y: f.minY + min(c.clickOffset.y, f.height - 4)), pid: pid, window: window)
            }
        } else { focused = true }
        await sleep(0.4)
        if c.host == .chromeBeta, c.field == "gmail" {
            // The body must be the focused element after the click, or the
            // case stops here with nothing typed.
            if let f = focusedElement(pid), str(f, kAXDescriptionAttribute) == "Message Body" { field = f } else {
                outcomes.append(Outcome(name: c.name, host: c.host.rawValue, state: "setup", focus: c.focus.rawValue, expect: c.expect.rawValue, result: "blocked", shown: false, source: "", reason: "", note: focused ? "the click did not put keyboard focus in the compose body; nothing was typed" : "no compose body to click; nothing was typed"))
                print(line(outcomes.last!))
                recording?.cancel()
                _ = await recording?.value
                try? await video?.finish()
                await close(c)
                return
            }
        }
        if field == nil || c.focus == .tab || c.site {
            // Chromium answers the newly focused control a moment after the key.
            for _ in 0..<15 {
                if let f = focusedElement(pid), let fr = frame(f), fr.width > 0 { field = f; fieldFrame = fr; break }
                await sleep(0.1)
            }
        }
        for (state, typed) in [("empty", false), ("typed", true)] {
            if typed {
                // In the person's own browser the letter goes only into the
                // compose body the case found, and only while it has focus.
                if c.host == .chromeBeta, c.field == "gmail" {
                    guard let field, focusedElement(pid).map({ CFEqual($0, field) }) == true else { break }
                }
                guard await key(keyA, pid: pid, window: window) else { break }
                await sleep(0.3)
            }
            let t0 = typed ? ProcessInfo.processInfo.systemUptime : started
            await sleep(args.settle)
            // The field must have keyboard focus, by the page's own receipt
            // for a synthetic field and by the focused control's role else.
            let fieldFocused = c.synthetic ? (str(window, kAXTitleAttribute)?.contains("focused=1") == true) : isTextControl(focusedElement(pid))
            if c.host == .chromeBeta, c.field == "docs" { field = focusedElement(pid); fieldFrame = field.flatMap(frame) ?? fieldFrame }
            // Intention logs changes only, so the dot's state and the tracker's
            // outcome are the latest events in the log, which an outcome that
            // did not change since the case began carries forward; the log
            // must have moved in the last twenty seconds and Intention must be
            // running for that to count as an observation. Lines since this
            // state began give the latency.
            let all = log(since: 0)
            let lines = log(since: t0)
            let observed = intention?.isTerminated == false && !log(since: started - 20).isEmpty
            let placedLines = lines.filter { $0.event == "dot-placed" }
            let last = all.last { $0.event == "dot-placed" || $0.event == "dot-hidden" }
            let shown = last?.event == "dot-placed"
            let reason = all.last { $0.event == "tracker" }?.reason ?? ""
            let latency = placedLines.first.map { ($0.time - t0) * 1000 }
            let evidence = outURL.appendingPathComponent("\(c.name)-\(state)")
            var caret: CGRect?
            var caretSource = "pixels"
            if let wid, let fieldFrame {
                caret = await caretFromPixels(window: wid, pid: pid, field: fieldFrame.insetBy(dx: -2, dy: -2).intersection(bounds), green: c.green)
            } else { lastCaptureNote = wid == nil ? "the window server's window was not found for the field's window" : "the field's frame was not read" }
            // The page's own layout answers where pixels cannot see the caret,
            // as under the role-less box drawn over it on purpose.
            if caret == nil, c.synthetic, let field, let fromPage = caretFromReceipt(window: window, field: field) {
                caret = fromPage; caretSource = "the page's own layout"
            }
            // One picture of the window and the dot, for a person.
            if args.pictures, let wid, bounds.width > 0,
               let (image, _) = await capture(window: wid, pid: pid, rect: (fieldFrame ?? bounds).insetBy(dx: -24, dy: -32).intersection(bounds), withDot: true) {
                save(image, to: evidence.appendingPathExtension("png"))
            }
            var offsetX: Double?, gap: Double?
            if let d = last?.dot, let caret { offsetX = d.x - caret.midX; gap = caret.minY - (d.y + d.d / 2) }
            var result: String
            var note = focused ? "" : "focus action refused by the guard; "
            // No line from Intention since the case began means nothing was
            // observed: a dot that is not shown proves nothing then, and
            // neither does one whose caret the pixels did not find.
            if !observed {
                result = "blocked"; note += "no observation from Intention in the dot log"
            } else if !fieldFocused {
                result = "blocked"; note += "the field did not have keyboard focus"
            } else {
                switch c.expect {
                case .hidden:
                    if shown { result = "fail"; note += "dot shown over the overlay" }
                    else if reason.hasPrefix("absent.covered") || reason.hasPrefix("absent.menu") { result = "pass" }
                    else { result = "blocked"; note += "no dot, but the tracker's outcome is \(reason), not a cover" }
                case .shown:
                    if !shown { result = "fail"; note += "no dot" }
                    else if let offsetX, let gap {
                        let estimate = last?.source == "hint"
                        let within = abs(offsetX) <= (estimate ? 4 : 2) && gap >= 0.5 && gap <= 8
                        result = within ? (estimate ? "pass (estimate)" : "pass") : "fail"
                        if !within { note += String(format: "dot %.1f pt from the caret, gap %.1f pt", offsetX, gap) }
                        if caretSource != "pixels" { note += " caret from \(caretSource)" }
                    } else { result = "blocked"; note += "dot shown, but no caret found in the window's pixels to measure it against: \(lastCaptureNote)" }
                }
            }
            if let latency, latency > 1000 { note += String(format: " first dot after %.0f ms", latency) }
            outcomes.append(Outcome(name: c.name, host: c.host.rawValue, state: state, focus: c.focus.rawValue, expect: c.expect.rawValue, result: result, shown: shown,
                                    source: last?.source ?? "", reason: reason, dotX: last?.dot?.x, dotY: last?.dot?.y, diameter: last?.dot?.d,
                                    caretX: caret.map { Double($0.midX) }, caretTop: caret.map { Double($0.minY) }, caretHeight: caret.map { Double($0.height) }, offsetX: offsetX, gap: gap, latencyMs: latency, ink: last?.ink, note: note.trimmingCharacters(in: .whitespaces)))
            print(line(outcomes.last!))
        }
        // Leave the field as found: the typed letter goes, in the person's
        // browser only from the body it went into.
        if c.host != .chromeBeta || (field.map { f in focusedElement(pid).map { CFEqual($0, f) } == true } ?? false) {
            _ = await key(keyDelete, pid: pid, window: window)
        }
        if c.addressBar { _ = await key(keyEscape, pid: pid, window: window) }
        await sleep(0.2)
        recording?.cancel()
        _ = await recording?.value
        try? await video?.finish()
        await close(c)
        if !chromeBetaNote.isEmpty { print("  \(c.name): \(chromeBetaNote)"); if var last = outcomes.popLast() { last.note += " " + chromeBetaNote; outcomes.append(last) }; chromeBetaNote = "" }
    }

    func line(_ o: Outcome) -> String {
        let dx = o.offsetX.map { String(format: "%+.1f", $0) } ?? "-"
        let gap = o.gap.map { String(format: "%.1f", $0) } ?? "-"
        return "\(o.name.padding(toLength: 30, withPad: " ", startingAt: 0)) \(o.state.padding(toLength: 6, withPad: " ", startingAt: 0)) \(o.focus.padding(toLength: 5, withPad: " ", startingAt: 0)) \(o.result.padding(toLength: 16, withPad: " ", startingAt: 0)) dx=\(dx) gap=\(gap) source=\(o.source) reason=\(o.reason) \(o.note)"
    }

    // MARK: The matrix

    func cases() -> [Case] {
        var list: [Case] = []
        let fields = ["gmail", "gmail-sibling", "textarea-ph", "input-ph", "textarea-bare", "input-bare", "ce-before", "ce-bare", "ce-br", "ce-p", "ce-ghost", "ce-list", "iframe", "shadow"]
        for host in [Host.chrome] + (args.safari ? [Host.safari] : []) {
            for f in fields {
                list.append(Case(name: "\(host.rawValue)-\(f)", host: host, field: f))
                list.append(Case(name: "\(host.rawValue)-\(f)-tab", host: host, field: f, focus: .tab))
            }
            list.append(Case(name: "\(host.rawValue)-gmail-dark", host: host, field: "gmail", dark: true))
            list.append(Case(name: "\(host.rawValue)-input-bare-dark", host: host, field: "input-bare", dark: true))
            for overlay in ["mention", "menu", "tooltip", "dialog", "roleless"] {
                list.append(Case(name: "\(host.rawValue)-overlay-\(overlay)", host: host, field: "ce-overlay", overlay: overlay, expect: .hidden, clickOffset: CGPoint(x: 400, y: 50)))
            }
            // A role-less box inside the editor over the caret is a known
            // limit: inside the field only a covering role hides the dot.
            list.append(Case(name: "\(host.rawValue)-overlay-roleless-inside", host: host, field: "ce-overlay", overlay: "roleless-inside", expect: .shown, clickOffset: CGPoint(x: 400, y: 50)))
            list.append(Case(name: "\(host.rawValue)-address-bar", host: host, field: "", url: fixtureURL.absoluteString, addressBar: true))
        }
        if !args.webkitHost.isEmpty || !args.electronHost.isEmpty {
            for host in (args.webkitHost.isEmpty ? [] : [Host.webkit]) + (args.electronHost.isEmpty ? [] : [Host.electron]) {
                for f in fields { list.append(Case(name: "\(host.rawValue)-\(f)", host: host, field: f)) }
                for overlay in ["mention", "menu", "tooltip", "dialog", "roleless"] {
                    list.append(Case(name: "\(host.rawValue)-overlay-\(overlay)", host: host, field: "ce-overlay", overlay: overlay, expect: .hidden, clickOffset: CGPoint(x: 400, y: 50)))
                }
            }
        }
        if args.gmail {
            list.append(Case(name: "chrome-beta-gmail-compose", host: .chromeBeta, field: "gmail", url: "https://mail.google.com/mail/u/0/?view=cm&fs=1&tf=1", clickOffset: CGPoint(x: 60, y: 60)))
        }
        if args.docs {
            list.append(Case(name: "chrome-beta-docs", host: .chromeBeta, field: "docs", url: "https://docs.new", clickOffset: CGPoint(x: 60, y: 40)))
        }
        if args.sites {
            list.append(Case(name: "chrome-google-search", host: .chrome, field: "", url: "https://www.google.com/", site: true))
            list.append(Case(name: "chrome-chatgpt", host: .chrome, field: "", url: "https://chatgpt.com/", site: true, clickOffset: CGPoint(x: 60, y: 14)))
            list.append(Case(name: "chrome-duckduckgo", host: .chrome, field: "", url: "https://duckduckgo.com/", site: true))
        }
        if args.native {
            list.append(Case(name: "textedit", host: .textedit, field: ""))
            list.append(Case(name: "terminal", host: .terminal, field: ""))
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") != nil { list.append(Case(name: "vscode", host: .vscode, field: "")) }
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") != nil { list.append(Case(name: "cursor", host: .cursor, field: "")) }
        }
        if !args.only.isEmpty { list = list.filter { args.only.contains($0.name) } }
        return list
    }

    func startIntention() async -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "co.intention.mac").isEmpty || !NSRunningApplication.runningApplications(withBundleIdentifier: "co.intention.mac").isEmpty {
            print("Another Intention is running; quit it first so the Debug build under test is the only dot."); return false
        }
        try? FileManager.default.removeItem(at: logURL)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.arguments = ["--dot-log", logURL.path]
        guard let app = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: args.app), configuration: config) else { print("Intention did not start"); return false }
        intention = app
        // A first launch opens Intention's setup window, which would take the
        // keyboard from every case; the dot needs no sign-in, so it is
        // closed through its own close button. Intention's own window only.
        for _ in 0..<12 {
            await sleep(0.5)
            let windows = elems(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute)
            for window in windows where str(window, kAXSubroleAttribute) == kAXStandardWindowSubrole {
                if let close = elem(window, kAXCloseButtonAttribute) { AXUIElementPerformAction(close, kAXPressAction as CFString) }
            }
        }
        // The handshake: the tracker's first outcome reaches the log within
        // its first reads, or this is not a Debug build with --dot-log.
        for _ in 0..<20 {
            if !log(since: 0).isEmpty { return true }
            await sleep(0.25)
        }
        print("Intention wrote nothing to the dot log in five seconds: not a Debug build, or --dot-log is not supported by this app.")
        return false
    }

    /// Asks macOS once for what the matrix needs: Screen Recording for its
    /// own bundle, and Automation for the apps it scripts. Each ask is a
    /// prompt or a System Settings page the person answers.
    func requestPermissions() {
        print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted; System Settings > Privacy & Security > Accessibility")")
        let screen = CGPreflightScreenCaptureAccess()
        print("Screen Recording preflight: \(screen)")
        if !screen { CGRequestScreenCaptureAccess() }
        for app in ["TextEdit", "Terminal", "Google Chrome Beta"] {
            let answer = appleScript("tell application \"\(app)\" to get name") ?? "refused"
            print("Automation for \(app): \(answer == app ? "granted" : answer)")
        }
        exit(0)
    }

    func main() async {
        if args.permissions { requestPermissions() }
        guard AXIsProcessTrusted() else { print("The matrix needs Accessibility for its clicks, keys and reads. Grant it to this app in System Settings and run again."); exit(3) }
        guard CGPreflightScreenCaptureAccess() else { CGRequestScreenCaptureAccess(); print("The matrix needs Screen Recording to find the caret in the field's window. Grant it to this app and run again."); exit(3) }
        try? FileManager.default.createDirectory(atPath: args.out, withIntermediateDirectories: true)
        guard await startIntention() else { intention?.terminate(); exit(4) }
        let list = cases()
        print("\(list.count) cases; Intention \(args.app)")
        for c in list { await run(c) }
        if !args.keepIntention { intention?.terminate() }
        // The report.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(outcomes) { try? data.write(to: outURL.appendingPathComponent("results.json")) }
        var md = "| case | state | focus | result | dx (pt) | gap (pt) | source | tracker | note |\n|---|---|---|---|---|---|---|---|---|\n"
        for o in outcomes {
            md += "| \(o.name) | \(o.state) | \(o.focus) | \(o.result) | \(o.offsetX.map { String(format: "%+.1f", $0) } ?? "") | \(o.gap.map { String(format: "%.1f", $0) } ?? "") | \(o.source) | \(o.reason) | \(o.note) |\n"
        }
        try? md.write(to: outURL.appendingPathComponent("results.md"), atomically: true, encoding: .utf8)
        let passed = outcomes.filter { $0.result.hasPrefix("pass") }.count, failed = outcomes.filter { $0.result == "fail" }.count, blocked = outcomes.count - passed - failed
        print("\npassed \(passed), failed \(failed), blocked \(blocked); report in \(args.out)")
        exit(failed == 0 && blocked == 0 ? 0 : 1)
    }
}

@main
enum DotMatrixMain {
    static func main() {
        // Progress reaches a pipe line by line, so a run can be followed.
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in await Matrix().main() }
        app.run()
    }
}
