import AppKit
import SwiftUI

// The entry point of the small bundle scripts/report-shots.sh builds.
// `--report-snapshots <directory>` draws the menu bar item's menu as a
// signed-in Release build shows it while idle, and the Report a problem
// window in each of its states, Light and Dark, with an invented note, then
// quits. The process may not activate and no window is ordered onto the
// screen; each is drawn off screen. A real menu
// cannot be opened without appearing on the screen, so this draws its rows
// with the menu font, sizes and separators; the rows mirror `MenuContent`
// in App/IntentionApp.swift and change with it. Every window is drawn behind
// the desktop picture, never seen, and nothing is read from any app.
@main
struct ReportShots: GuardedRender {
    @MainActor
    static func render() {
        _ = NSApplication.shared
        // Never in front, never in the Dock, never taking the keyboard.
        NSApp.setActivationPolicy(.prohibited)
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--report-snapshots"), arguments.indices.contains(index + 1) else { exit(2) }
        var failed: Bool?
        Task {
            do {
                try await render(to: URL(fileURLWithPath: arguments[index + 1]))
                failed = false
            } catch {
                FileHandle.standardError.write(Data("report snapshots failed: \(error)\n".utf8))
                failed = true
            }
        }
        while failed == nil { RunLoop.current.run(mode: .default, before: .now + 0.02) }
        exit(failed == true ? 1 : 0)
    }

    /// `MenuContent`'s rows for a person who finished setup, granted
    /// Accessibility, chose the dot and kept Fn, with updates on: ready,
    /// recording, finishing, writing an email, signed out, with the
    /// microphone refused and with none that opens. `nil` is a separator;
    /// a disabled row is a `Text`.
    static let menus: [(String, [MenuRow?])] = {
        let tail: [MenuRow?] = [MenuRow("Dictation history…"), nil, MenuRow("Check for updates…"), MenuRow("Report a problem…"),
                                MenuRow("Settings…"), nil, MenuRow("Quit Intention")]
        let off = MenuRow("Dictate: click the dot or hold Fn (globe)", enabled: false)
        return [
            ("menu-ready", [MenuRow("Start dictation, or hold Fn (globe)")] + tail),
            ("menu-recording", [MenuRow("Stop dictation"), MenuRow("Cancel dictation")] + tail),
            ("menu-working", [MenuRow("Cancel dictation while it finishes")] + tail),
            ("menu-writing-email", [MenuRow("Cancel dictation while the email is written")] + tail),
            ("menu-signed-out", [MenuRow("Sign in to dictate…"), nil, off] + tail),
            ("menu-microphone-denied", [off, MenuRow("Allow the microphone…")] + tail),
            ("menu-microphone-unavailable", [off, MenuRow("No microphone could be opened: choose one…")] + tail),
        ]
    }()

    @MainActor
    private static func render(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, rows) in menus {
            try await save(MenuScene(rows: rows), to: directory.appendingPathComponent("\(name).png"))
        }
        let note = "The dot stayed on the old line after I pasted a long paragraph into Notes."
        let states: [(String, String, Outcome?)] = [
            ("report-empty", "", nil),
            ("report-note", note, nil),
            ("report-note-focused", note, nil),
            ("report-sending", note, .waits),
            ("report-sent", note, .returns),
            ("report-failed", note, .throws(.sendFailed)),
            ("report-rate-limited", note, .throws(.rateLimited(until: Date().addingTimeInterval(3600)))),
            ("report-signed-out", "", .throws(.signedOut)),
            ("report-too-long", String(repeating: "The dot stayed on the old line. ", count: 130), nil),
            // The controls' passing states, and a long note locked while it sends.
            ("report-send-hover", note, nil),
            ("report-send-pressed", note, nil),
            ("report-send-focused", note, nil),
            ("report-cancel-pressed", note, nil),
            ("report-cancel-focused", note, nil),
            ("report-done-focused", note, .returns),
            ("report-sending-long", (1...24).map { "Line \($0): the dot stayed on the old line after the paste." }.joined(separator: "\n"), .waits),
        ]
        SetupMotion.isStill = true
        for (name, text, outcome) in states {
          for look in Appearance.allCases {
            let prompt = ReportProblemPrompt(send: { _ in
                switch outcome {
                case .waits?: try await Task.sleep(for: .seconds(3600))
                case .throws(let failure)?: throw failure
                case .returns?, nil: return
                }
            })
            prompt.text = text
            if outcome != nil { Task { await prompt.submit() } }
            ReportProblemView.drawsFocusForStills = name == "report-note-focused"
            let still: StillControlState? = name.hasSuffix("-hover") ? .hover : name.hasSuffix("-pressed") ? .pressed
                : name.hasSuffix("-focused") && name != "report-note-focused" ? .focused : nil
            let onCancel = name.hasPrefix("report-cancel-")
            ReportProblemView.stillCancel = onCancel ? still : nil
            ReportProblemView.stillAction = onCancel ? nil : still
            let panel = ReportProblemPanel(present: { _ in }, appearance: { look })
            let window = panel.prepare(prompt)
            // A window drawn off screen never becomes key, so it is told it
            // has, as a shown window is, and the note takes the keyboard.
            try await Task.sleep(for: .milliseconds(200))
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            try await capture(window, size: window.frame.size, to: directory.appendingPathComponent("\(name)-\(look.rawValue).png"))
          }
        }
        ReportProblemView.drawsFocusForStills = false
        ReportProblemView.stillCancel = nil
        ReportProblemView.stillAction = nil
        try await checkKeys(writingTo: directory.appendingPathComponent("keys.txt"))
    }

    /// Return sends the note, and does nothing while it is too long, and
    /// Escape closes the window, as on main. The keys go to the window
    /// itself, in this process, as key equivalents; nothing is posted to
    /// the system. Each line of `file` is a check and its result, and any
    /// failure fails the run.
    @MainActor
    static func checkKeys(writingTo file: URL) async throws {
        func key(_ characters: String, _ code: UInt16, in window: NSWindow) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return false }
            return window.performKeyEquivalent(with: event)
        }
        func shown(_ prompt: ReportProblemPrompt) async throws -> (ReportProblemPanel, NSWindow) {
            let panel = ReportProblemPanel(present: { _ in })
            let window = panel.prepare(prompt)
            try? await Task.sleep(for: .milliseconds(400))
            try offScreen(window, before: "a key check")
            return (panel, window)
        }
        /// Whether the panel let its window go, as closing it does.
        func closed(_ panel: ReportProblemPanel) -> Bool { panel.window == nil }
        var lines: [String] = []
        var failed = false
        func note(_ check: String, _ passed: Bool) {
            lines.append("\(passed ? "pass" : "FAIL") \(check)")
            if !passed { failed = true }
        }

        var sent: [String] = []
        let ready = ReportProblemPrompt(send: { sent.append($0) })
        ready.text = "The dot stayed on the old line."
        let (readyPanel, readyWindow) = try await shown(ready)
        _ = key("\r", 36, in: readyWindow)
        try await Task.sleep(for: .milliseconds(200))
        note("Return sends the note", sent == ["The dot stayed on the old line."] && ready.phase == .sent)
        _ = key("\r", 36, in: readyWindow)
        try await Task.sleep(for: .milliseconds(200))
        note("Return on Sent closes the window (Done)", closed(readyPanel))

        sent = []
        let long = ReportProblemPrompt(send: { sent.append($0) })
        long.text = String(repeating: "The dot stayed on the old line. ", count: 130)
        let (_, longWindow) = try await shown(long)
        _ = key("\r", 36, in: longWindow)
        try await Task.sleep(for: .milliseconds(200))
        note("Return does nothing while the note is too long", sent.isEmpty && long.phase == .editing)

        let cancelled = ReportProblemPrompt(send: { sent.append($0) })
        let (cancelPanel, cancelWindow) = try await shown(cancelled)
        _ = key("\u{1b}", 53, in: cancelWindow)
        try await Task.sleep(for: .milliseconds(200))
        note("Escape closes the window", closed(cancelPanel) && sent.isEmpty)

        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        if failed { throw CocoaError(.validationMultipleErrors) }
    }

    enum Outcome: Equatable {
        case waits, returns
        case `throws`(ProblemReportSubmission.Failure)
    }

    /// Draws the scene off screen at 2x, in a view no window shows.
    @MainActor
    static func save(_ scene: some View, to file: URL) async throws {
        let fitting = NSHostingView(rootView: scene).fittingSize
        let size = CGSize(width: fitting.width.rounded(.up), height: fitting.height.rounded(.up))
        let host = NSHostingView(rootView: scene.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        host.frame = CGRect(origin: .zero, size: size)
        try await draw(host, to: file)
    }

    /// Draws `window`'s content at 2x without the window ever being ordered
    /// onto the screen, after checking that it is not on screen and the
    /// process is not active, and saying which check failed if one does.
    @MainActor
    static func capture(_ window: NSWindow, size: CGSize, to file: URL) async throws {
        try await Task.sleep(for: .milliseconds(250))
        try offScreen(window, before: file.lastPathComponent)
        guard let view = window.contentView else { throw CocoaError(.fileWriteUnknown) }
        try await draw(view, to: file)
    }

    @MainActor
    static func draw(_ view: NSView, to file: URL) async throws {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: file)
    }

    /// The rule for every frame and key check: the window was never shown
    /// and the process never came forward.
    @MainActor
    static func offScreen(_ window: NSWindow, before step: String) throws {
        var failures: [String] = []
        if window.isVisible { failures.append("window visible") }
        if NSApp.isActive { failures.append("process active") }
        if NSRunningApplication.current.isActive { failures.append("running application active") }
        guard failures.isEmpty else {
            FileHandle.standardError.write(Data("off-screen check failed before \(step): \(failures.joined(separator: ", "))\n".utf8))
            throw CocoaError(.featureUnsupported)
        }
    }
}

struct MenuRow {
    let title: String
    let enabled: Bool
    init(_ title: String, enabled: Bool = true) {
        self.title = title
        self.enabled = enabled
    }
}

/// A menu's rows on a plain backdrop: the menu font, 22-point rows, inset
/// separators, rounded corners and the menu's shadow.
private struct MenuScene: View {
    let rows: [MenuRow?]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if let row {
                    Text(row.title)
                        .font(Font(NSFont.menuFont(ofSize: 0)))
                        .foregroundStyle(row.enabled ? Color(nsColor: .labelColor) : Color(nsColor: .disabledControlTextColor))
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                        .padding(.horizontal, 14)
                } else {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                }
            }
        }
        .padding(.vertical, 5)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.97)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .padding(32)
        .background(Color(white: 0.86))
    }
}
