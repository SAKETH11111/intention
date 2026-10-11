import AppKit
import ApplicationServices
import Foundation

// The reply timing run: how long a Gmail reply waits for its proposal card,
// measured by Intention itself. It starts the Debug build with `--proposal-log`
// and, run after run, opens a new window of the person's own Chrome Beta at
// one thread, presses Gmail's own Reply control for the last message
// through Accessibility, waits for the proposal's line or Intention's own
// line that its card showed, discards the reply through Gmail's own
// "Discard draft" control, checks that the body is gone and closes only
// that window. The waits come from the log's lines; the runner only tells
// which run each line belongs to.
// See apps/macos/scripts/reply-timing.sh.
//
// It never posts a key or a click, types nothing, presses no dialog and
// closes no window but the one it made. A window or draft that will not go
// is left as it is, reported with the thread's id, and ends the runs. It
// captures nothing unless asked for one picture, and that holds only the
// window it made and Intention's own panels.

struct TimingArguments {
    var app = ""
    var out = ""
    var thread = ""
    var runs = 10
    /// One picture of the made window with the card over it.
    var picture = false
    /// Ask macOS for the grants the runner needs and stop.
    var permissions = false

    init() {
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--app": app = it.next() ?? ""
            case "--out": out = it.next() ?? ""
            case "--thread": thread = it.next() ?? ""
            case "--runs": runs = Int(it.next() ?? "") ?? 0
            case "--picture": picture = true
            case "--permissions": permissions = true
            default: fputs("unknown argument \(a)\n", stderr); exit(2)
            }
        }
        guard permissions || (!app.isEmpty && !out.isEmpty && !thread.isEmpty && runs > 0) else {
            fputs("usage: reply-timing --app <Intention.app> --out <dir> --thread <Gmail thread URL> [--runs N] [--picture] | --permissions\n", stderr)
            exit(2)
        }
    }
}

@MainActor
final class ReplyTiming: OwnedWindows {
    let args = TimingArguments()
    var runs: [ReplyTimingRun] = []
    /// Every proposal line read from the log so far.
    var seen: [ProposalLogLine] = []
    /// Every note read from the log so far.
    var notes: [ProposalLogNote] = []
    /// Complete lines of the log read so far.
    var consumed = 0
    /// The run whose window is open.
    var current: Int?
    var pictureTaken = false
    var outURL: URL { URL(fileURLWithPath: args.out) }
    var logURL: URL { outURL.appendingPathComponent("proposal-log.jsonl") }
    var dotLogURL: URL { outURL.appendingPathComponent("dot-log.jsonl") }

    /// Gmail's id for the thread, the last part of the address's fragment,
    /// as in `#inbox/<id>`. Nil for an address that is not a Gmail thread,
    /// or that could not be passed to Chrome's scripting as it is.
    static func threadID(_ address: String) -> String? {
        guard address.hasPrefix("https://mail.google.com/"), !address.contains("\""), !address.contains("\\"),
              let url = URL(string: address), let fragment = url.fragment, fragment.contains("/"),
              let id = fragment.split(separator: "/").last, id.count >= 10 else { return nil }
        return String(id)
    }

    // MARK: Intention's log and card

    /// Reads the complete lines the log gained since the last read. Each
    /// line says when its proposal began, so when it is read does not
    /// matter.
    func readLog() {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeLast() // after the last newline: empty, or a line still being written
        for line in lines.dropFirst(consumed) {
            if let parsed = ProposalLogLine(line) { seen.append(parsed) } else if let note = ProposalLogNote(line) { notes.append(note) }
        }
        consumed = max(consumed, lines.count)
    }

    /// The runs with every line and note read so far given to them, by
    /// the report's own matching.
    func matched() -> [ReplyTimingRun] {
        var copy = runs
        _ = ReplyTimingReport.match(seen, to: &copy)
        _ = ReplyTimingReport.attach(notes, to: &copy)
        return copy
    }

    /// Whether run `index` has its line yet.
    func hasLine(_ index: Int) -> Bool { matched()[index].line != nil }

    /// Whether Intention has logged the card showing for run `index`: its
    /// own "proposal.shown" while the run's window is open. The dot's
    /// surface and the card are both windows of Intention's above the normal
    /// level, and without Screen Recording the window server gives no
    /// titles to tell them apart, so the log is the signal, not a window.
    func cardShown(_ index: Int) -> Bool { matched()[index].cardShown }

    /// Waits `seconds`, reading the log every tenth of a second; returns
    /// early once `done` holds.
    @discardableResult
    func wait(_ seconds: Double, until done: () -> Bool = { false }) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            readLog()
            if done() { return true }
            if Date() >= deadline { return false }
            await sleep(0.1)
        }
    }

    // MARK: Gmail's controls

    /// Gmail's own Reply control for the thread's last message, by the
    /// walk in `TreeSearch.swift`: nothing when the page is not there yet,
    /// and no control, with why, when the page could not be read whole or
    /// has no one such control.
    func replyControl(in window: AXUIElement) -> TreeLookup<AXUIElement> {
        guard str(window, kAXRoleAttribute) != nil else { return .unknown("the window did not answer") }
        return tree.replyControl(in: window)
    }

    /// The open reply's body in the window, whether there is none, or
    /// whether that could not be told.
    func replyBody(in window: AXUIElement) -> TreeLookup<AXUIElement> { lookup(described: "Message Body", under: window) }

    // MARK: One run

    /// One run, from a new window to that window closed. False when a
    /// window or draft was left, which ends the runs.
    func run(_ index: Int) async -> Bool {
        runs.append(ReplyTimingRun(number: index + 1))
        current = index
        defer { current = nil }
        func note(_ text: String) { runs[index].note += (runs[index].note.isEmpty ? "" : "; ") + text }
        func leave(_ why: String) -> Bool {
            note(why + " (thread \(threadID))")
            runs[index].endedAt = Date().timeIntervalSince1970
            chromeBetaWindowID = nil
            chromeBetaWindow = nil
            chromeBetaServerWindow = nil
            return false
        }
        /// Closes the made window, which holds no draft of the run's.
        func close() async -> Bool {
            runs[index].endedAt = Date().timeIntervalSince1970
            return await closeMadeWindow() ? true : leave("the window did not close and was left as it is")
        }

        chromeBetaNote = ""
        guard let (pid, window) = await openChromeBetaWindow(url: args.thread, settle: 1) else {
            note(chromeBetaNote.isEmpty ? "the window did not open" : chromeBetaNote)
            return !chromeBetaNote.contains("still open")
        }
        // The thread view has loaded once its Reply control is there. The
        // page's tree is walked every half second, not on every tick, and
        // a walk that could not finish is tried again, as the page may
        // still be settling.
        var found = replyControl(in: window)
        for _ in 0..<50 where found.node == nil {
            await wait(0.5)
            found = replyControl(in: window)
        }
        guard let reply = found.node else {
            note("no Reply control in the thread view within 25 seconds" + (found.why.map { " (\($0))" } ?? "") + "; nothing was pressed")
            return await close()
        }
        // A reply already open or a draft in the thread is the person's,
        // and so is anything in a page that could not be read whole.
        let before = replyBody(in: window), draft = lookup(described: "Discard draft", under: window)
        guard before.isAbsent, draft.isAbsent else {
            if let why = before.why ?? draft.why {
                note("the thread view could not be read whole (\(why)); nothing was pressed")
            } else {
                note("the thread already has a reply open or a draft; nothing was pressed")
            }
            return await close()
        }
        guard guardWindow(pid, window) else {
            note("the made window was no longer the focused one; nothing was pressed")
            return await close()
        }
        runs[index].pressedAt = Date().timeIntervalSince1970
        guard AXUIElementPerformAction(reply, kAXPressAction as CFString) == .success else {
            runs[index].pressedAt = nil
            note("Gmail's Reply control did not take the press")
            return await close()
        }

        // The body takes focus, and Intention reads it and asks for a proposal.
        await wait(20) { self.cardShown(index) || self.hasLine(index) }
        if cardShown(index), args.picture, !pictureTaken { await takePicture(pid: pid, window: window) }
        if !cardShown(index), !hasLine(index) {
            switch replyBody(in: window) {
            case .absent: note("the reply did not open")
            case .found: note("neither a line nor the card within 20 seconds")
            case .unknown(let why): note("neither a line nor the card within 20 seconds, and the page could not be read whole (\(why))")
            }
        }
        await wait(2)

        // The reply goes through Gmail's own control, and the window
        // closes only once a whole read of it finds no body. A body that
        // is still there, or a page that cannot be read whole, leaves the
        // window open and reported, as a draft may be in it.
        if !replyBody(in: window).isAbsent {
            let discarded = await discardDraft()
            if discarded != "draft discarded through Gmail's control" { note(discarded) }
        }
        var body = replyBody(in: window)
        for _ in 0..<10 where !body.isAbsent {
            await wait(0.3)
            body = replyBody(in: window)
        }
        switch body {
        case .absent: return await close()
        case .found: return leave("the reply's body is still there, so its window was left open")
        case .unknown(let why): return leave("whether the reply's body is still there could not be told (\(why)), so its window was left open")
        }
    }

    /// One picture of the made window with Intention's card and dot over it.
    func takePicture(pid: pid_t, window: AXUIElement) async {
        guard let wid = chromeBetaServerWindow, let rect = frame(window),
              let (image, _) = await capture(window: wid, pid: pid, rect: rect, withDot: true, panels: ["proposal card", "dot "]) else {
            print("  no picture: the made window could not be captured")
            return
        }
        save(image, to: outURL.appendingPathComponent("card.png"))
        pictureTaken = true
    }

    var threadID: String { Self.threadID(args.thread) ?? "" }

    // MARK: Intention

    func startIntention() async -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "co.intention.mac").isEmpty
            || !NSRunningApplication.runningApplications(withBundleIdentifier: "co.intention.mac").isEmpty {
            print("An Intention is already running. Quit it first (Quit Intention in its menu bar item); the timing runs the Debug build under test alone.")
            return false
        }
        try? FileManager.default.removeItem(at: logURL)
        try? FileManager.default.removeItem(at: dotLogURL)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.arguments = ["--proposal-log", logURL.path, "--dot-log", dotLogURL.path]
        guard let app = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: args.app), configuration: config) else {
            print("Intention did not start")
            return false
        }
        intention = app
        await sleep(3)
        // A build that is not set up opens its setup window, and makes no
        // proposals until it is signed in.
        if elems(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute).contains(where: { str($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }) {
            print("The Debug build opened its setup window. Set it up first (signed in, the dot as the indicator, Draft replies for me on) and run again.")
            return false
        }
        // The handshake: the dot tracker's first outcome reaches the dot
        // log within seconds, or this is not a Debug build that takes the
        // log arguments, and no proposal line would ever come.
        for _ in 0..<20 {
            if ((try? Data(contentsOf: dotLogURL))?.count ?? 0) > 0 { return true }
            await sleep(0.25)
        }
        print("Intention wrote nothing to the dot log in five seconds: not a Debug build, or one without the log arguments.")
        return false
    }

    func stopIntention() async {
        guard let intention else { return }
        intention.terminate()
        for _ in 0..<50 { if intention.isTerminated { return }; await sleep(0.1) }
        intention.forceTerminate()
    }

    /// Asks macOS once for what the runner needs: Accessibility to read
    /// Gmail's controls and press them, Automation for Chrome Beta to make
    /// and close its window, and Screen Recording for `--picture` alone.
    func requestPermissions() {
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        print("Accessibility: \(AXIsProcessTrustedWithOptions(prompt) ? "granted" : "not granted; System Settings > Privacy & Security > Accessibility")")
        let screen = CGPreflightScreenCaptureAccess()
        print("Screen Recording, for --picture only: \(screen ? "granted" : "not granted")")
        if !screen { CGRequestScreenCaptureAccess() }
        let answer = appleScript("tell application \"Google Chrome Beta\" to get name") ?? "refused"
        print("Automation for Google Chrome Beta: \(answer == "Google Chrome Beta" ? "granted" : answer)")
        exit(0)
    }

    // MARK: The runs and the report

    func main() async {
        if args.permissions { requestPermissions() }
        guard AXIsProcessTrusted() else {
            print("The timing run needs Accessibility to find and press Gmail's controls. Grant it in System Settings to the app the script runs in, such as the terminal, which macOS counts the grant against, and run again.")
            exit(3)
        }
        if args.picture, !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            print("--picture needs Screen Recording for the app the script runs in. Grant it and run again, or run without --picture.")
            exit(3)
        }
        guard Self.threadID(args.thread) != nil else {
            print("--thread must be the address of a Gmail thread, as https://mail.google.com/mail/u/0/#inbox/<thread id>.")
            exit(2)
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome.beta").isEmpty else {
            print("Open Chrome Beta, signed in to the Gmail account the thread is in; the runs open their windows in it.")
            exit(3)
        }
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        guard await startIntention() else { await stopIntention(); exit(4) }
        print("\(args.runs) runs on thread \(threadID); Intention \(args.app)")
        var stopped = false
        for index in 0..<args.runs {
            if stopped {
                runs.append(ReplyTimingRun(number: index + 1, note: "an earlier run left a window or draft"))
                continue
            }
            stopped = !(await run(index))
            let run = matched()[index]
            print("run \(run.number): " + [run.cardShown ? "card shown" : "no card", run.note].filter { !$0.isEmpty }.joined(separator: "; "))
            if !stopped, index < args.runs - 1 { await wait(5) }
        }

        // A card that hid with its reply ends, and writes its line, when the
        // next reply opens or its five minutes pass, so the last run's line
        // comes that late.
        let waiting = { self.runs.indices.filter { self.runs[$0].pressedAt != nil && !self.hasLine($0) } }
        if let last = runs.compactMap(\.pressedAt).max(), !waiting().isEmpty {
            print("Waiting up to five and a half minutes from the last press for \(waiting().count) line(s): Intention ends a proposal whose reply closed when its five minutes pass.")
            await wait(max(0, last + 330 - Date().timeIntervalSince1970)) { waiting().isEmpty }
        }
        await stopIntention()
        readLog()

        var matched = runs
        let unmatched = ReplyTimingReport.match(seen, to: &matched)
        let outside = ReplyTimingReport.attach(notes, to: &matched)
        let report = ReplyTimingReport(runs: matched, unmatched: unmatched, outside: outside.map(\.name))
        let markdown = report.markdown()
        print("\n" + markdown)
        do {
            try report.json().write(to: outURL.appendingPathComponent("results.json"))
            try markdown.write(to: outURL.appendingPathComponent("results.md"), atomically: true, encoding: .utf8)
        } catch {
            print("The report could not be saved in \(args.out): \(error.localizedDescription)")
            exit(5)
        }
        print("Report in \(args.out)")
        exit(!stopped && !report.shown.isEmpty ? 0 : 1)
    }
}

@main
enum ReplyTimingMain {
    static func main() {
        // Progress reaches a pipe line by line, so a run can be followed.
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in await ReplyTiming().main() }
        app.run()
    }
}
