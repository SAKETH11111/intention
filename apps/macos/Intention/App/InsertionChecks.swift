#if DEBUG
import AVFoundation
import AppKit
import ApplicationServices
import ScreenCaptureKit
import UniformTypeIdentifiers
import os

/// Insertion checks against real apps, for the support matrix. Run from a
/// Debug build through `./dev mac-insertion-check`, which launches the app
/// with `--insertion-checks <new-output-directory> --fixtures <dir>` and
/// optionally `--only <scene,scene>`.
///
/// Every insertion runs through the production `TextInserter`, which has no
/// undo. The expected field text is computed here from the fixture's own
/// strings and read back with separate Accessibility queries, never through
/// the inserter's reads. After each case the scene puts the field back
/// itself, through the same setup that prepared it, and reads it back again.
///
/// Safety: a scene writes only into fields it set up itself, and checks that
/// keyboard focus is on that field before each insertion: the synthetic page
/// `Fixtures/insertion.html`, copied under a fresh name that appears in its
/// title; a TextEdit document created in the output directory. The scenes
/// that use the person's own accounts run only when named and say what they
/// write into; those that relied on undo to leave the app as they found it
/// report that they did not run. Return is never pressed and nothing is
/// sent. The clipboard holds a synthetic sentinel during the paste scenes
/// and gets its earlier contents back at the end.
///
/// With `--dictation` (and `--dictation-audio <recording>`, which the app
/// model plays in place of the microphone) each insertion is a dictation
/// instead: started and stopped alternately by a click on the dot and by
/// holding Right Option, both posted as real events, with the text the
/// endpoint returns expected at the caret. The paste scenes, the menu and
/// the inserter-only cases are skipped.
@MainActor
final class InsertionChecks {
    struct Result: Codable {
        var scene: String
        var app: String
        var appVersion: String
        var field: String
        var check: String
        /// "pass", "fail" or "not run".
        var status: String
        var insertion: String?
        var insertMilliseconds: Double?
        var notes: String?
    }

    struct Report: Codable {
        var macOS: String
        var startedAt: Date
        /// The system's rule for this app reading the clipboard: 0 default,
        /// 1 ask, 2 always allow, 3 always deny.
        var clipboardAccess: Int?
        var externalClipboard: Bool
        var clipboardReadable: Bool
        var results: [Result]
    }

    static let text = "The synthetic meeting is on Thursday. Please reply with a short note."
    static let unicode = "Plan 👋🏽 with 👩‍💻 cafe\u{301} 東京 today"
    static let insertion = " Synthetic insertion: café, 東京, 👩‍💻."
    static let leadingBreak = "\nSecond synthetic paragraph."

    private let output: URL
    private let fixtures: URL
    private let token = UUID().uuidString.lowercased()
    private var results: [Result] = []
    private let inserter: TextInserter
    private let pasteInserter: TextInserter
    private var sentinel: (string: String, data: Data?)?
    /// Every string the checks put on the clipboard, directly or by pasting.
    private var ownedClipboardStrings: Set<String> = []
    /// Sentinels are safe to restore over even after an unconfirmed paste.
    /// Pasted strings in ownedClipboardStrings may still be read by an app.
    private var clipboardSentinels: Set<String> = []
    private let recoveryFile = InsertionCheckClipboard.RecoveryFile(url: InsertionCheckClipboard.RecoveryFile.defaultURL)
    private lazy var clipboardRun = InsertionCheckClipboard.Run(file: recoveryFile)
    /// Puts the paste scenes' sentinel on the clipboard from another process,
    /// so Intention's clipboard backup reads another app's data.
    private var externalClipboard = false
    /// Slack accepted a value the scene set and did not show it. It may
    /// still land, so the scene writes nothing more.
    private var slackWritePending = false
    /// A paste the checks sent went unconfirmed, so an app may still read
    /// the clipboard, so it is not borrowed again during this run. Cleanup
    /// can put the saved copy back only once a sentinel is back there.
    /// Set from each insertion's own outcome, whatever happens to the
    /// clipboard afterwards.
    private var pasteUnconfirmed: Bool { clipboardRun.pasteUnconfirmed }
    /// Runs the inserters as if macOS would ask before Intention reads the
    /// clipboard, so they paste without a backup.
    private let clipboardReadable: Bool
    /// Records the run with captions and pauses, for a person to watch.
    private var demo: InsertionDemo?
    /// In dictation mode: the app, and how long the recording plays.
    private var dictation: (model: AppModel, playback: Duration)?
    private var dictations = 0
    /// Why the current scene writes nothing more, once a case left a field
    /// it may not touch again: an insertion whose result is unknown, which
    /// may still land, or a field that changed under the scene. Each scene
    /// starts clear. Later cases record that they did not run, since their
    /// setups reuse the same fields.
    private var stopped: String?
    /// The Slack workspace and the person's own member ID, as "T…:U…", for
    /// the slack scene, which writes only in their message to themselves.
    private var slackSelf: (team: String, user: String)?
    /// What the last dictation did, for a failure's notes.
    private var dictationTrace: [String] = []

    static func runIfRequested(arguments: [String], model: AppModel) {
        guard ProcessSafety.allowsCheckInput else { return }
        guard let outputPath = value(after: "--insertion-checks", in: arguments),
              let fixturesPath = value(after: "--fixtures", in: arguments) else { return }
        let only = Set((value(after: "--only", in: arguments) ?? "").split(separator: ",").map(String.init))
        let checks = InsertionChecks(output: URL(fileURLWithPath: outputPath, isDirectory: true),
                                     fixtures: URL(fileURLWithPath: fixturesPath, isDirectory: true),
                                     clipboardReadable: !arguments.contains("--clipboard-not-readable"))
        checks.externalClipboard = arguments.contains("--external-clipboard")
        if arguments.contains("--demo") { checks.demo = InsertionDemo() }
        if let ids = value(after: "--slack-self", in: arguments)?.split(separator: ":"), ids.count == 2 {
            checks.slackSelf = (String(ids[0]), String(ids[1]))
        }
        if arguments.contains("--dictation"), let path = value(after: "--dictation-audio", in: arguments),
           let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) {
            checks.dictation = (model, .milliseconds(Int(Double(file.length) / file.fileFormat.sampleRate * 1000)))
            // Right Option has no action of its own in other apps, unlike Fn.
            model.holdKey.key = .rightOption
        }
        Task {
            await checks.run(only: only)
            exit(checks.results.allSatisfy { $0.status == "pass" } ? 0 : 1)
        }
    }

    private init(output: URL, fixtures: URL, clipboardReadable: Bool) {
        self.output = output
        self.fixtures = fixtures
        self.clipboardReadable = clipboardReadable
        let owner = { clipboardReadable ? PasteboardOwner() : PasteboardOwner(mayRead: { false }) }
        inserter = TextInserter(pasteboard: owner())
        pasteInserter = TextInserter(pasteboard: owner())
        pasteInserter.pasteOnly = true
    }

    private func run(only: Set<String>) async {
        let started = Date()
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { write(started: started) }
        guard await recoverClipboard() else { return }
        await runScenes(only: only)
        await cleanUpClipboard()
    }

    private func runScenes(only: Set<String>) async {
        guard AXIsProcessTrusted() else {
            record("setup", "Intention", "", "-", "Accessibility granted", false, notes: "Grant Accessibility to Intention Dev and rerun.")
            return
        }
        // Lets the caret tracker ask Chrome for its web tree, as it does in use.
        try? await Task.sleep(for: .seconds(1))
        if let demo {
            guard await demo.start(recordingTo: output.appendingPathComponent("insertion-demo.mov")) else {
                record("setup", "Intention", "", "-", "start the recording", false, notes: "Screen Recording is needed for --demo")
                return
            }
            await demo.say("Intention inserts synthetic text at the caret. Every field is read back independently.", for: 3)
        }
        let scenes: [(String, () async -> Void)] = [
            ("textedit", { await self.textEdit(paste: false) }),
            ("textedit-paste", { await self.textEdit(paste: true) }),
            ("chrome", { await self.browser("com.google.Chrome", paste: false) }),
            ("chrome-paste", { await self.browser("com.google.Chrome", paste: true) }),
            ("safari", { await self.browser("com.apple.Safari", paste: false) }),
            ("safari-paste", { await self.browser("com.apple.Safari", paste: true) }),
            ("notes", { self.notRun("notes", "Notes", reason: Self.noteLeft) }),
            ("notes-paste", { self.notRun("notes-paste", "Notes", reason: Self.noteLeft) }),
            ("menu", { await self.menu() }),
            ("gmail-chrome", { self.notRun("gmail-chrome", "Chrome", reason: Self.draftLeft) }),
            ("gmail-safari", { self.notRun("gmail-safari", "Safari", reason: Self.draftLeft) }),
            ("gmail-chrome-beta", { await self.gmailChromeBeta() }),
            ("messages", { self.notRun("messages", "Messages", reason: Self.messageLeft) }),
            ("mail", { await self.mail() }),
            ("slack", { await self.slack() }),
            ("electron", { await self.electron(paste: false) }),
            ("electron-paste", { await self.electron(paste: true) }),
            ("webkit", { await self.webKit(paste: false) }),
            ("webkit-paste", { await self.webKit(paste: true) }),
            ("webkit-leading-editable", { await self.extraLineCase("webkit-leading-editable", field: "contenteditable", editor: "editable") }),
            ("webkit-leading-lines", { await self.extraLineCase("webkit-leading-lines", field: "line editor", editor: "lines") }),
            ("webkit-leading-paragraphs", { await self.extraLineCase("webkit-leading-paragraphs", field: "paragraph editor", editor: "paragraphs") }),
        ]
        // These run only when named: Notes and the next five use the
        // person's own accounts, and the fixture hosts need building first.
        let accountScenes: Set = ["notes", "notes-paste", "gmail-chrome", "gmail-safari", "gmail-chrome-beta", "messages", "mail", "slack",
                                  "electron", "electron-paste", "webkit", "webkit-paste",
                                  "webkit-leading-editable", "webkit-leading-lines", "webkit-leading-paragraphs"]
        // A demonstration skips the forced paste scenes; the fallback cases
        // still show the paste route.
        // Notes is left out of a recording because its sidebar lists every note.
        let chosen = only.isEmpty && demo != nil ? ["textedit", "chrome", "safari", "menu"]
            : only.isEmpty && dictation != nil ? ["textedit", "chrome", "safari"] : Array(only)
        for (name, scene) in scenes where chosen.contains(name) || (chosen.isEmpty && !accountScenes.contains(name)) {
            stopped = nil
            await scene()
        }
        if let failure = demo?.failure {
            record("demo", "Intention", "", "-", "recording kept to the fixture windows", false, notes: failure)
        }
        if let demo {
            let passed = results.filter { $0.status == "pass" }.count
            await demo.say("\(passed) of \(results.count) checks passed.", for: 3)
            await demo.stop()
        }
    }

    // MARK: - Cases

    /// One insertion in a field that `setup` focused with `base` and
    /// `selection`. Passes when the field shows exactly the expected text
    /// and the scene can then put the field back: through `restore` where
    /// given, or else by running `setup` again, after which the field must
    /// read `base` once more. With `closes`, the scene closes its own
    /// document after the case instead. With `appUndo`, an instance of the
    /// fixture app that the check itself started and verified, the case also
    /// notes what that app's own Edit > Undo does to the insertion before
    /// the field is put back. Never an app of the person's: their Safari, or
    /// a TextEdit that was already running.
    private func editCase(
        _ scene: String, _ app: String, _ version: String, _ field: String, _ check: String,
        base: String, selection: NSRange, valueSelection: NSRange? = nil, text: String = InsertionChecks.insertion,
        paste: Bool, pasteFallback: Bool = false, anyRoute: Bool = false,
        setup: @MainActor () async -> AXUIElement?, restore: (@MainActor () async -> AXUIElement?)? = nil, closes: Bool = false,
        appUndo: NSRunningApplication? = nil, extra: (@MainActor (AXUIElement) -> String?)? = nil,
        shown: (@MainActor () -> String?)? = nil, still: (@MainActor () -> Bool)? = nil
    ) async {
        // `selection` is what the field reports. Where its offsets leave
        // paragraph breaks out, `valueSelection` is the same place in its
        // value, which counts them.
        let place = valueSelection ?? selection
        guard !skipped(scene, app, version, field, check) else { return }
        guard let element = await setup() else {
            record(scene, app, version, field, check, false, notes: "setup failed: field not found")
            return
        }
        // The field's text as the checks read it: its Accessibility value,
        // or the fixture's own account where the value shows fewer breaks.
        let reading: @MainActor () -> String? = shown ?? { self.fieldText(element) }
        guard await focused(is: element), reading().map(normalized) == normalized(base) else {
            record(scene, app, version, field, check, false, notes: "setup failed: \(setupProblem(element, base: base))")
            return
        }
        if paste || pasteFallback || anyRoute || dictation != nil {
            guard await placeSentinel() else {
                record(scene, app, version, field, check, false, notes: "the clipboard could not be copied, so it was left alone and the case did not run")
                return
            }
        }
        var text = text
        var check = check
        let insertion: InsertionResult
        let insertMilliseconds: Double
        if dictation != nil {
            guard let dictated = await dictate(element) else {
                record(scene, app, version, field, check + " (dictated)", false,
                       notes: "no dictation finished: " + dictationTrace.joined(separator: ", "))
                return
            }
            text = dictated.text
            insertion = dictated.result ?? .notInserted(.nothingToInsert)
            // From the stop to the text in the field.
            insertMilliseconds = dictated.afterStop ?? -1
            check = "dictated by \(dictated.trigger): " + check
        } else {
            let inserter = paste ? pasteInserter : self.inserter
            await demo?.say("\(app) · \(field) · \(check)")
            // The inserter writes into whatever has focus. Copying the clipboard
            // and the caption leave time for the person to move on or type, so
            // the field, its text and the scene's own condition, `still`, are
            // checked again right before it.
            guard hasFocus(element), reading().map(normalized) == normalized(base), still?() ?? true else {
                record(scene, app, version, field, check, false, notes: "the field changed before the insertion, so nothing was written")
                return
            }
            let start = ContinuousClock.now
            insertion = await insert(text, with: inserter)
            insertMilliseconds = milliseconds(since: start)
        }
        ownedClipboardStrings.insert(text)
        // In a real app the route is whatever the field takes.
        let pasted = paste || pasteFallback || ((anyRoute || dictation != nil) && insertion == .inserted(.paste, clipboardRestored: clipboardReadable))
        let expected = (base as NSString).replacingCharacters(in: place, with: text)
        let blank = base.allSatisfy(\.isNewline)
        let insertedOK = await settled(reading, expected, blankBase: blank)
        let insertedDifference = insertedOK ? nil : difference(reading(), from: expected)
        // Without a backup the pasted text stays on the clipboard.
        let clipboardOK = !pasted || (clipboardReadable ? sentinelRestored() : NSPasteboard.general.string(forType: .string) == text)
        let extraAfterInsert = extra?(element)
        await demo?.say("\(Self.describe(insertion)) in \(Int(insertMilliseconds)) ms" + (insertedOK ? ", read back exactly" : ", but the field differs"), for: 1.8)
        // Any Accessibility write is fine; the report names the one used.
        let methodOK = pasted ? insertion == .inserted(.paste, clipboardRestored: clipboardReadable)
            : [.selectedText, .replaceRange, .textOperation].contains { insertion == .inserted($0, clipboardRestored: nil) }
                && !text.isEmpty
        // A result of unknown means a write may still land in this field,
        // so the scene writes nothing more to it: no app undo, no put back,
        // and no later case, since their setups reuse the same fields. In
        // the person's own app the scene's text may stay there.
        if case .unknown = insertion {
            stop(still == nil ? Self.unknownInFixture : Self.unknownInPersonsApp)
            record(scene, app, version, field, check, false, insertion: TextInserter.name(insertion), insertMilliseconds: insertMilliseconds,
                   notes: [insertedDifference.map { "field after insertion differs from expected (\($0))" }, stopped]
                       .compactMap { $0 }.joined(separator: "; "))
            return
        }
        // What the field holds when the case is done with it, and so what
        // the cleanup requires before it writes. A refused insertion left
        // the field as the setup made it.
        var left: String? = { if case .notInserted = insertion { return base } else { return expected } }()
        var observed: String?
        if let appUndo, dictation == nil, insertedOK, case .inserted = insertion {
            let seen = await observeAppUndo(appUndo, element, reading, base: base, inserted: expected, blank: blank)
            observed = seen.note
            left = seen.left
        }
        // The scene's own cleanup, in place of an undo Intention no longer has.
        let putBack: String?
        if closes {
            putBack = nil
        } else if let restore {
            putBack = await self.putBack(reading, left: left, base: base, blank: blank, by: restore, still: still)
        } else {
            putBack = await self.putBack(reading, left: left, base: base, blank: blank, by: setup, still: still)
        }
        let notes = [
            insertedDifference.map { "field after insertion differs from expected (\($0))" },
            clipboardOK ? nil : "clipboard not restored after insertion",
            putBack, extraAfterInsert, observed,
        ].compactMap { $0 }
        record(scene, app, version, field, check,
               methodOK && insertedOK && clipboardOK && putBack == nil && extraAfterInsert == nil,
               insertion: TextInserter.name(insertion), insertMilliseconds: insertMilliseconds,
               notes: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }

    /// Puts a field back as the scene found it through `restore`, the
    /// scene's own setup, only while the field holds exactly `left`, what
    /// the case left there, and `still` holds. Anything else, or a nil
    /// `left` where the case cannot say, is someone's typing or a late
    /// write: the field is left as it is and the scene stops. Nil once the
    /// field reads `base` again, otherwise what went wrong, without the
    /// field's text.
    private func putBack(_ reading: @MainActor () -> String?, left: String?, base: String, blank: Bool,
                         by restore: @MainActor () async -> AXUIElement?, still: (@MainActor () -> Bool)?) async -> String? {
        guard let left, await settled(reading, left, blankBase: blank), still?() ?? true else {
            stop("the field holds something other than what the case left, so it was left as it is and the scene stopped")
            return stopped
        }
        // A reset that did not run, or did not show, may still land, so
        // nothing more is written to the field either way.
        guard await restore() != nil else {
            stop("the field was not put back: its setup did not run, so the scene stopped")
            return stopped
        }
        if await settled(reading, base, blankBase: blank) { return nil }
        stop("the field was not put back (\(difference(reading(), from: base))), so the scene stopped")
        return stopped
    }

    /// What a fixture app's own Edit > Undo does to an insertion that was
    /// just confirmed, as a note for the support matrix, and what the field
    /// then holds (nil where it holds something else). Intention offers no
    /// undo; this only observes the receiving app's. `app` must be an
    /// instance the check started, so every earlier action on its undo
    /// stack is the check's own. The caller passes only an insertion it has
    /// just confirmed in this field, with nothing done to the app since, and
    /// the field must still read exactly as inserted right before the
    /// press. The item is looked up only in the Edit menu and pressed
    /// through Accessibility, never with a key, and only while the field
    /// still has keyboard focus, so it acts on the scene's own window.
    private func observeAppUndo(_ app: NSRunningApplication, _ element: AXUIElement, _ reading: @MainActor () -> String?,
                                base: String, inserted: String, blank: Bool) async -> (note: String, left: String?) {
        let label = "observed, not checked: the app's own Edit > Undo "
        guard let bar = menuBar(of: app),
              let edit = children(bar, kAXChildrenAttribute).first(where: { string($0, kAXTitleAttribute) == "Edit" }),
              let item = findNow(in: edit, { self.role($0) == kAXMenuItemRole && (self.string($0, kAXTitleAttribute) ?? "").hasPrefix("Undo") })
        else { return (label + "was not found in the Edit menu", inserted) }
        guard (boolValue(item, kAXEnabledAttribute) ?? false) else { return (label + "was not available", inserted) }
        guard hasFocus(element), reading().map(normalized) == normalized(inserted) else {
            return (label + "was not pressed: the field lost focus or changed", inserted)
        }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        if await settled(reading, base, blankBase: blank) { return (label + "took the insertion back", base) }
        if await settled(reading, inserted, blankBase: blank) { return (label + "left the insertion in place", inserted) }
        return (label + "changed the field otherwise (\(difference(reading(), from: base)))", nil)
    }

    private func menuBar(of app: NSRunningApplication) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXMenuBarAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func boolValue(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// Stops the current scene's writes, with the reason; see `stopped`.
    private func stop(_ reason: String) {
        if stopped == nil { stopped = reason }
    }

    /// Records a case that did not run because the scene stopped. True when
    /// it did.
    private func skipped(_ scene: String, _ app: String, _ version: String, _ field: String, _ check: String) -> Bool {
        guard let stopped else { return false }
        record(scene, app, version, field, check, nil, notes: "not run: an earlier case stopped the scene: " + stopped)
        return true
    }

    static let unknownInFixture = "the insertion's result is unknown and a write may still land, so the scene wrote nothing more to the field"
        + " and ran no later case"
    static let unknownInPersonsApp = "the insertion's result is unknown and a write may still land, so the scene wrote nothing more:"
        + " the scene's synthetic text may remain in the field; check it by hand"

    /// A scene that is not run, with the reason.
    private func notRun(_ scene: String, _ app: String, reason: String) {
        record(scene, app, "", "-", "scene", nil, notes: reason)
    }

    static let noteLeft = "not run: it relied on Intention's undo to leave its new note empty, and Intention no longer has one; "
        + "clearing the note by setting its value has not been observed"
    static let draftLeft = "not run: it relied on Intention's undo to leave the Gmail draft as Gmail made it before discarding it, "
        + "and Intention no longer has one; a draft holding the scene's text could stay in the account if the discard fails"
    static let messageLeft = "not run: it relied on Intention's undo to leave the new message empty, and Intention no longer has one; "
        + "no way to clear Messages' field has been observed"

    /// A field that accepts an Accessibility write and never shows it. The
    /// first insertion must report unknown and paste nothing, since the write
    /// could still land, and the next insertion into that field must be
    /// refused (`earlierUnsettled`) and paste nothing either: nothing shows
    /// the write cannot land, so the field stays held while the page shows
    /// it. The fixture's guarded editor drops every Accessibility write by
    /// construction, so the first one can never land later. It is the one
    /// unknown result after which a scene writes to the field again, and
    /// only while the field still reads as it did; otherwise the scene
    /// stops.
    private func ignoredWriteCase(
        _ scene: String, _ app: String, _ version: String, _ field: String, base: String, selection: NSRange,
        setup: @MainActor () async -> AXUIElement?, extra: (@MainActor (AXUIElement) -> String?)? = nil
    ) async {
        let check = "accepted write not shown: reported unknown, nothing pasted"
        guard !skipped(scene, app, version, field, check) else { return }
        guard let element = await setup(), await focused(is: element), fieldText(element).map(normalized) == normalized(base) else {
            record(scene, app, version, field, check, false, notes: "setup failed")
            return
        }
        await demo?.say("\(app) · an editor that accepts Accessibility writes and ignores them")
        let first: InsertionResult
        if dictation != nil {
            let dictated = await dictate(element)
            first = dictated?.result ?? .notInserted(.nothingToInsert)
            // The text it may not have shown is kept in history as uncertain.
            if dictation?.model.dictation.history.entries.first?.outcome != .uncertain {
                record(scene, app, version, field, check + " (dictated)", false, notes: "the dictation is not in history as uncertain")
                return
            }
        } else {
            first = await insert(Self.insertion, with: inserter)
        }
        // Long enough for a late write to show: the fixture's editors apply
        // a write they take within a frame.
        try? await Task.sleep(for: .seconds(2))
        let untouched = fieldText(element).map(normalized) == normalized(base)
        await demo?.say(first == .unknown(.writeUnconfirmed) && untouched
                        ? "Reported unknown and nothing pasted, since the write could still land" : TextInserter.name(first), for: 2)
        guard untouched else {
            stop("the guarded editor showed a write it should have dropped, so it was left as it is and the scene stopped")
            record(scene, app, version, field, check, false, insertion: TextInserter.name(first), notes: stopped)
            return
        }
        record(scene, app, version, field, check, first == .unknown(.writeUnconfirmed), insertion: TextInserter.name(first))
        let next = "the next insertion is refused: the write may still land"
        guard !skipped(scene, app, version, field, next) else { return }
        guard await focused(is: element), fieldText(element).map(normalized) == normalized(base) else {
            record(scene, app, version, field, next, false, notes: "the field changed before the insertion, so nothing was written")
            return
        }
        let second: InsertionResult
        if dictation != nil {
            second = await dictate(element)?.result ?? .notInserted(.nothingToInsert)
        } else {
            second = await insert(Self.insertion, with: inserter)
        }
        let stillUntouched = fieldText(element).map(normalized) == normalized(base)
        // The page's own account, such as that nothing was submitted.
        let page = extra?(element)
        let notes = [stillUntouched ? nil : "the field changed: \(difference(fieldText(element), from: base))", page].compactMap { $0 }
        await demo?.say(TextInserter.name(second), for: 2)
        record(scene, app, version, field, next, second == .notInserted(.earlierUnsettled) && stillUntouched && page == nil,
               insertion: TextInserter.name(second), notes: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }

    /// How a field's text differs from the text expected there, as lengths
    /// and the place of the first difference, never the text: a person can
    /// type into any field while a scene runs.
    private func difference(_ actual: String?, from expected: String) -> String {
        guard let actual else { return "the field could not be read" }
        let (shown, wanted) = (Array(normalized(actual).utf16), Array(normalized(expected).utf16))
        let first = zip(shown, wanted).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(shown.count, wanted.count)
        return "length \(shown.count), expected \(wanted.count), first difference at offset \(first)"
    }

    /// Says which part of a setup did not hold, with lengths but no text.
    private func setupProblem(_ element: AXUIElement, base: String) -> String {
        let focus = focusedElement()
        let focusedSame = focus.map { CFEqual($0, element) } ?? false
        let focusDescription = focus.map { role($0) ?? "?" } ?? "nothing"
        return "focus on field: \(focusedSame) (focused \(focusDescription)); value length \(fieldText(element)?.utf16.count ?? -1), expected \(base.utf16.count)"
    }

    // MARK: - TextEdit

    private func textEdit(paste: Bool) async {
        let scene = paste ? "textedit-paste" : "textedit"
        let field = "NSTextView, plain text document"
        let document = output.appendingPathComponent("insertion-\(token)-\(scene).txt")
        try? Self.text.write(to: document, atomically: true, encoding: .utf8)
        // A TextEdit that was already running may hold the person's own
        // documents, so its menus are never pressed; only one this scene
        // started is observed.
        let runningBefore = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").map(\.processIdentifier)
        guard let app = await open([document], with: "com.apple.TextEdit"),
              let window = await window(of: app, containing: document.lastPathComponent),
              let area = await find(in: window, { self.role($0) == kAXTextAreaRole })
        else {
            record(scene, "TextEdit", "", field, "open fixture", false, notes: "fixture window or text area not found")
            return
        }
        let ownInstance = runningBefore.isEmpty ? app : nil
        await demo?.include(pid: app.processIdentifier, title: document.lastPathComponent)
        let version = app.version
        func setUp(_ value: String, _ selection: NSRange) async -> AXUIElement? {
            guard frontmost(app) || activate(app) else { return nil }
            AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, value as CFString)
            AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            setRange(area, selection)
            try? await Task.sleep(for: .milliseconds(150))
            return range(area) == selection ? area : nil
        }
        await editCase(scene, "TextEdit", version, field, "insert at the caret",
                       base: Self.text, selection: NSRange(location: 37, length: 0), paste: paste,
                       setup: { await setUp(Self.text, NSRange(location: 37, length: 0)) }, appUndo: ownInstance)
        await editCase(scene, "TextEdit", version, field, "replace an emoji, ZWJ and combining selection",
                       base: Self.unicode, selection: NSRange(location: 5, length: 15), paste: paste,
                       setup: { await setUp(Self.unicode, NSRange(location: 5, length: 15)) })
        await editCase(scene, "TextEdit", version, field, "insert two lines",
                       base: Self.text, selection: NSRange(location: 37, length: 0), text: " First line.\nSecond line.", paste: paste,
                       setup: { await setUp(Self.text, NSRange(location: 37, length: 0)) })
        if !paste {
            await guardCases(scene, "TextEdit", version, field, base: Self.text, selection: NSRange(location: 37, length: 0),
                             setup: { await setUp(Self.text, NSRange(location: 37, length: 0)) })
        }
        await closeWindow(window)
        if !paste { await formattedSelection() }
    }

    /// A caller's guard on the field (`FocusedField.stillCurrent`), in the
    /// scene's own document. The field is captured as a caller would
    /// capture it, then inserted into twice: with a guard that says the
    /// compose changed, which must leave the document as it was, and with
    /// one that passes, which must insert as usual. Each guard only counts
    /// its calls and reads nothing.
    private func guardCases(_ scene: String, _ app: String, _ version: String, _ field: String, base: String, selection: NSRange,
                            setup: @MainActor () async -> AXUIElement?) async {
        guard dictation == nil else { return }
        let cases: [(check: String, caption: String, answer: EditReason?)] = [
            ("a guard that refuses: nothing is written", "a caller's guard says the compose changed", .composeChanged),
            ("a guard that passes: inserted at the caret", "a caller's guard says it is still the same compose", nil),
        ]
        for (check, caption, answer) in cases {
            guard !skipped(scene, app, version, field, check) else { continue }
            guard let element = await setup() else {
                record(scene, app, version, field, check, false, notes: "setup failed: field not found")
                continue
            }
            let reading: @MainActor () -> String? = { self.fieldText(element) }
            guard await focused(is: element), reading().map(normalized) == normalized(base) else {
                record(scene, app, version, field, check, false, notes: "setup failed: \(setupProblem(element, base: base))")
                continue
            }
            guard case var .success(captured) = await inserter.readFocusedField().value.field else {
                record(scene, app, version, field, check, false, notes: "the focused field could not be captured")
                continue
            }
            let asked = OSAllocatedUnfairLock(initialState: 0)
            captured.stillCurrent = {
                asked.withLock { $0 += 1 }
                return answer
            }
            await demo?.say("\(app) · \(field) · \(caption)", for: 1.8)
            // The caption leaves time for the person to move on or type.
            guard hasFocus(element), reading().map(normalized) == normalized(base) else {
                record(scene, app, version, field, check, false, notes: "the field changed before the insertion, so nothing was written")
                continue
            }
            let start = ContinuousClock.now
            let insertion = await inserter.insert(Self.insertion, into: captured)
            let insertMilliseconds = milliseconds(since: start)
            clipboardRun.recordInsertion(insertion, with: inserter)
            let calls = asked.withLock { $0 }
            if case .unknown = insertion {
                stop(Self.unknownInFixture)
                record(scene, app, version, field, check, false, insertion: TextInserter.name(insertion),
                       insertMilliseconds: insertMilliseconds, notes: stopped)
                continue
            }
            let expected = answer == nil ? (base as NSString).replacingCharacters(in: selection, with: Self.insertion) : base
            let shown = await settled(reading, expected)
            if answer == nil {
                await demo?.say("\(Self.describe(insertion)) in \(Int(insertMilliseconds)) ms" + (shown ? ", read back exactly" : ", but the field differs"), for: 1.8)
            } else {
                await demo?.say(insertion == .notInserted(.composeChanged) && shown
                                ? "Refused: the compose changed. Nothing was written" : TextInserter.name(insertion), for: 2.4)
            }
            // The guard is asked when the insertion starts and again right
            // before the write; a refusal at the start ends it there.
            let wanted: (result: InsertionResult, calls: Int) = answer.map { (.notInserted($0), 1) }
                ?? (.inserted(.selectedText, clipboardRestored: nil), 2)
            let putBack = await self.putBack(reading, left: expected, base: base, blank: false, by: setup, still: nil)
            let notes = [
                shown ? nil : "field after the insertion differs from expected (\(difference(reading(), from: expected)))",
                "guard asked \(calls) time\(calls == 1 ? "" : "s")",
                putBack,
            ].compactMap { $0 }
            record(scene, app, version, field, check, insertion == wanted.result && calls == wanted.calls && shown && putBack == nil,
                   insertion: TextInserter.name(insertion), insertMilliseconds: insertMilliseconds, notes: notes.joined(separator: "; "))
        }
    }

    /// Replaces a selection in rich text: one that holds a link, and one
    /// that is bold throughout. Each document is the check's own, with one
    /// case, and is closed after it.
    private func formattedSelection() async {
        guard dictation == nil else { return }
        let scene = "textedit"
        let field = "NSTextView, rich text document"
        let text = "Alpha Beta Gamma"
        let selection = NSRange(location: 0, length: 10)
        let bold = NSFont.boldSystemFont(ofSize: 13)
        let linked = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        linked.addAttribute(.link, value: URL(string: "https://example.invalid")!, range: NSRange(location: 6, length: 4))
        let uniform = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        uniform.addAttribute(.font, value: bold, range: selection)
        for (name, content, check) in [("link", linked, "replace a selection holding a link"), ("bold", uniform, "replace a uniformly bold selection")] {
            let document = output.appendingPathComponent("insertion-\(token)-\(name).rtf")
            guard let data = try? content.data(from: NSRange(location: 0, length: content.length),
                                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]),
                  (try? data.write(to: document)) != nil,
                  let app = await open([document], with: "com.apple.TextEdit"),
                  let window = await window(of: app, containing: document.lastPathComponent),
                  let area = await find(in: window, { self.role($0) == kAXTextAreaRole })
            else {
                record(scene, "TextEdit", "", field, check, false, notes: "fixture window or text area not found")
                continue
            }
            await demo?.include(pid: app.processIdentifier, title: document.lastPathComponent)
            await editCase(scene, "TextEdit", app.version, field, check, base: text, selection: selection, text: "Synthetic",
                           paste: false, setup: {
                               AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                               self.setRange(area, selection)
                               try? await Task.sleep(for: .milliseconds(150))
                               return self.range(area) == selection ? area : nil
                           }, closes: true)
            await closeWindow(window)
        }
    }

    // MARK: - Browsers

    private func browser(_ bundleID: String, paste: Bool) async {
        let bundleID = bundleID == "com.google.Chrome" ? Self.chrome : bundleID
        let name = bundleID == "com.apple.Safari" ? "Safari" : "Chrome"
        let scene = name.lowercased() + (paste ? "-paste" : "")
        let page = output.appendingPathComponent("insertion-\(token)-\(scene).html")
        try? FileManager.default.removeItem(at: page)
        try? FileManager.default.copyItem(at: fixtures.appendingPathComponent("insertion.html"), to: page)
        // Chrome runs as a separate instance on an empty profile, so the
        // person's own Chrome, windows and tabs are never touched.
        let chrome = bundleID.hasPrefix("com.google.Chrome")
        let profile = chrome ? output.appendingPathComponent("chrome-profile-\(scene)") : nil
        let running = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        guard let app = await open([page], with: bundleID, profile: profile) else {
            record(scene, name, "", "fixture page", "open fixture", false, notes: "the browser did not come forward")
            return
        }
        // Only an instance this check started, on its own profile, may be
        // quit or have a window closed. Anything else stops the scene.
        if let profile, running.contains(app.processIdentifier) || Self.arguments(of: app.processIdentifier)?.contains(profile.path) != true {
            record(scene, name, app.version, "fixture page", "open fixture in a separate instance", false,
                   notes: "the browser handed the page to an instance the check did not start; nothing was closed")
            return
        }
        defer { if profile != nil { app.terminate() } }
        guard let window = await window(of: app, containing: page.lastPathComponent),
              await find(in: window, { self.domID($0) == "setup-input-caret" }, timeout: .seconds(10)) != nil
        else {
            record(scene, name, "", "fixture page", "open fixture", false, notes: "fixture window or page content not found")
            return
        }
        await demo?.include(pid: app.processIdentifier, title: page.lastPathComponent)
        let version = app.version
        func setUp(_ button: String, _ field: String) async -> AXUIElement? {
            guard frontmost(app) || activate(app) else { return nil }
            return await pressSetup(button, field, in: window)
        }
        let status: @MainActor (AXUIElement) -> String? = { [self] _ in
            guard let element = findNow(in: window, { self.domID($0) == "status" }) else { return "status field not found" }
            return read(element) == "submitted: no" ? nil : "the page reports a submission"
        }
        // Observed in Chromium only; Safari has not run the paragraph cases.
        // The app's own undo is observed only in Chrome on the separate
        // profile verified above, never in the person's Safari.
        await pageCases(scene, name, version, paste: paste, window: window, paragraphs: bundleID == "com.google.Chrome",
                        ownInstance: profile != nil ? app : nil, setUp: setUp, status: status)
        await closeWindow(window)
    }

    /// Presses one of the fixture page's setup buttons, which sets a
    /// field's text and selection and gives it keyboard focus, and returns
    /// that field. Keyboard focus is first moved into the page, as a click
    /// would, so the button's focus() reaches the field even when an
    /// address bar had it. An engine acts on a press in its own time, and
    /// does nothing for a press on a button from a tree it has since
    /// rebuilt, while the field may still have focus from the case before.
    /// So each of three tries looks the button and the field up again,
    /// presses, and waits for the page to say that this setup ran.
    private func pressSetup(_ button: String, _ field: String, in window: AXUIElement) async -> AXUIElement? {
        if let page = await find(in: window, { self.role($0) == "AXWebArea" }) {
            AXUIElementSetAttributeValue(page, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        func lastSetup() -> String? { findNow(in: window, { self.domID($0) == "setup-state" }).flatMap(read) }
        for _ in 0..<3 {
            guard let control = await find(in: window, { self.domID($0) == button }),
                  let element = await find(in: window, { self.domID($0) == field }) else { return nil }
            let before = lastSetup()
            guard AXUIElementPerformAction(control, kAXPressAction as CFString) == .success else { return nil }
            var ran = false
            for _ in 0..<20 where !ran {
                try? await Task.sleep(for: .milliseconds(50))
                ran = lastSetup().map { $0 != before && $0.hasPrefix(button + " ") } ?? false
            }
            if ran, await focused(is: element) { return element }
        }
        return nil
    }

    /// The fixture page's fields, in whichever engine shows the page: an
    /// input, a text area, plain editable elements, one that sends on
    /// Return, one that ignores Accessibility writes, the editor with one
    /// paragraph per line when `paragraphs` says the engine has run it, and
    /// a password field, which must be refused. The browser scenes and the
    /// Electron scenes run the same cases.
    private func pageCases(
        _ scene: String, _ name: String, _ version: String, paste: Bool, window: AXUIElement, paragraphs: Bool, webKit: Bool = false,
        ownInstance: NSRunningApplication?, setUp: @escaping (String, String) async -> AXUIElement?,
        status: @escaping @MainActor (AXUIElement) -> String?
    ) async {
        await editCase(scene, name, version, "input", "insert at the caret",
                       base: Self.text, selection: NSRange(location: 28, length: 0), paste: paste,
                       setup: { await setUp("setup-input-caret", "input") }, appUndo: ownInstance, extra: status)
        await editCase(scene, name, version, "textarea", "replace an emoji, ZWJ and combining selection",
                       base: Self.unicode, selection: NSRange(location: 5, length: 15), paste: paste,
                       setup: { await setUp("setup-textarea-selection", "textarea") }, extra: status)
        await editCase(scene, name, version, "textarea", "insert at the caret",
                       base: Self.text, selection: NSRange(location: 37, length: 0), paste: paste,
                       setup: { await setUp("setup-textarea-edit", "textarea") }, extra: status)
        await editCase(scene, name, version, "contenteditable", "insert at the caret",
                       base: Self.text, selection: NSRange(location: 37, length: 0), paste: paste,
                       setup: { await setUp("setup-editable-caret", "editable") }, appUndo: ownInstance, extra: status)
        // Empty, a Chromium editor takes the paste (`FieldAccess.insertDirectly`);
        // a WebKit one keeps the replace range.
        let webKitEngine = webKit || name == "Safari"
        await editCase(scene, name, version, "contenteditable, empty", "insert into an empty editor",
                       base: "", selection: NSRange(location: 0, length: 0), text: "Synthetic insertion.", paste: paste,
                       pasteFallback: !webKitEngine,
                       setup: { await setUp("setup-editable-empty", "editable") }, extra: status)
        await editCase(scene, name, version, "contenteditable composer, Enter sends", "insert two lines without sending",
                       base: "Draft reply.", selection: NSRange(location: 12, length: 0), text: " First line.\nSecond line.", paste: paste,
                       setup: { await setUp("setup-composer-caret", "composer") }, extra: status)
        if paste {
            await editCase(scene, name, version, "contenteditable that ignores Accessibility writes", "paste",
                           base: "Draft reply.", selection: NSRange(location: 12, length: 0), paste: true,
                           setup: { await setUp("setup-guarded-caret", "guarded") }, extra: status)
        } else {
            await ignoredWriteCase(scene, name, version, "contenteditable that ignores Accessibility writes",
                                   base: "Draft reply.", selection: NSRange(location: 12, length: 0),
                                   setup: { await setUp("setup-guarded-caret", "guarded") }, extra: status)
        }
        // Pasted into, as the paste route does every field. The case above
        // leaves the editor held while the page shows it, so only this
        // route reaches it.
        if paste {
            await editCase(scene, name, version, "contenteditable that ignores Accessibility writes", "paste two lines",
                           base: "Draft reply.", selection: NSRange(location: 12, length: 0), text: " First line.\nSecond line.",
                           paste: true, setup: { await setUp("setup-guarded-caret", "guarded") }, extra: status)
        }
        // A password field is refused before anything is read or written.
        if !skipped(scene, name, version, "password input", "insertion refused") {
            if let password = await setUp("setup-password", "password"), await focused(is: password), dictation != nil {
                // The dot never shows over a password field, so the key starts it.
                let earlier = dictation?.model.dictation.history.entries.first?.id
                let dictated = await dictate(password, trigger: "Right Option")
                let length = intValue(password, kAXNumberOfCharactersAttribute)
                let kept = dictation?.model.dictation.history.entries.first
                // Either nothing starts, as when secure keyboard entry keeps the
                // key from every app, or the text is refused and kept in history.
                let refused = dictated?.result == .notInserted(.secureField) && kept?.reason == "secureField" && kept?.text.isEmpty == false
                let neverStarted = dictated == nil && kept?.id == earlier
                record(scene, name, version, "password input", "dictated by Right Option: nothing inserted",
                       (length ?? 0) == 0 && (refused || neverStarted),
                       insertion: dictated?.result.map(TextInserter.name),
                       notes: neverStarted ? "no dictation started" : refused ? "refused and kept in history" : nil)
            } else if let password = await setUp("setup-password", "password"), await focused(is: password) {
                let inserter = paste ? pasteInserter : inserter
                await demo?.say("\(name) · password input · insertion is refused before anything is read")
                let result = await insert(Self.insertion, with: inserter)
                let length = intValue(password, kAXNumberOfCharactersAttribute)
                await demo?.say(result == .notInserted(.secureField) ? "Refused: secure field. Nothing was read or written" : TextInserter.name(result), for: 1.6)
                record(scene, name, version, "password input", "insertion refused", result == .notInserted(.secureField) && (length ?? 0) == 0,
                       insertion: TextInserter.name(result))
            } else {
                record(scene, name, version, "password input", "insertion refused", false, notes: "setup failed")
            }
        }
        if webKit {
            // A text area takes text that starts with a line break as
            // written, by either route.
            await editCase(scene, name, version, "textarea", "insert text that starts with a line break",
                           base: Self.text, selection: NSRange(location: 37, length: 0), text: Self.leadingBreak, paste: paste,
                           setup: { await setUp("setup-textarea-edit", "textarea") }, extra: status)
        }
        // The editor whose lines are plain blocks, with no script of the
        // page's between an insertion and what the browser makes of it.
        // Observed in WebKit only.
        if paragraphs, webKit {
            await paragraphCases(scene, name, version, paste: paste, webKit: true, editor: "lines", ownInstance: nil,
                                 setUp: setUp, status: status, shown: paragraphText(in: window, editor: "lines"))
            await imageCases(scene, name, version, paste: paste, window: window, setUp: setUp, status: status)
            await listCases(scene, name, version, paste: paste, window: window, setUp: setUp, status: status)
        }
        // A case there whose result is unknown leaves that editor alone
        // for the rest of the scene.
        if paragraphs {
            await paragraphCases(scene, name, version, paste: paste, webKit: webKit, ownInstance: ownInstance, setUp: setUp, status: status,
                                 shown: paragraphText(in: window))
        }
        // Last: its field is used by no other case, and in WebKit its
        // result is unknown by design.
        await hintedBodyCases(scene, name, version, paste: paste, window: window, webKit: webKitEngine, setUp: setUp, status: status)
    }

    /// The mail body with a hint the accessibility tree does not show
    /// (`hinted`), as Gmail's empty compose body carries Gemini's "Press /
    /// to write": empty, and with a letter typed. The page's own mirror of
    /// the body's text without the hint stands for its value, since
    /// WebKit's value holds the hint's words and Chromium's does not.
    /// Empty, a Chromium body takes the paste, the one route whose write
    /// lands there (`FieldAccess.insertDirectly`), and the paste route
    /// pastes as everywhere. A WebKit body reads as the hint's words with
    /// the caret in front of them, takes the replace range, which writes
    /// at the caret, and the words then vanish from the text after the
    /// caret, so the insertion is reported unknown with the text in the
    /// body; that is recorded as the expected result and the field is not
    /// written to again. With a letter typed the hint is gone and the body
    /// is an ordinary editor.
    private func hintedBodyCases(
        _ scene: String, _ name: String, _ version: String, paste: Bool, window: AXUIElement, webKit: Bool,
        setUp: @escaping (String, String) async -> AXUIElement?, status: @escaping @MainActor (AXUIElement) -> String?
    ) async {
        let field = "mail body with a hidden hint"
        let shown: @MainActor () -> String? = { [self] in findNow(in: window, { self.domID($0) == "hinted-text" }).flatMap(read) }
        await editCase(scene, name, version, field + ", with a letter typed", "insert after the text",
                       base: "Hi", selection: NSRange(location: 2, length: 0), text: " there.", paste: paste,
                       setup: { await setUp("setup-hinted-typed", "hinted") }, extra: status, shown: shown)
        guard webKit else {
            await editCase(scene, name, version, field + ", empty", "insert into the empty body",
                           base: "", selection: NSRange(location: 0, length: 0), text: "Synthetic insertion.", paste: paste, pasteFallback: true,
                           setup: { await setUp("setup-hinted-empty", "hinted") }, extra: status, shown: shown)
            return
        }
        // In WebKit the forced paste ends unknown as the replace range does,
        // and an unknown paste prevents borrowing the clipboard again during
        // the run, so the empty body runs in the plain scene only.
        guard !paste else { return }
        let check = "insert into the empty body"
        guard !skipped(scene, name, version, field + ", empty", check) else { return }
        guard let element = await setUp("setup-hinted-empty", "hinted"), await focused(is: element), shown() == "" else {
            record(scene, name, version, field + ", empty", check, false, notes: "setup failed: the field, its focus or its text")
            return
        }
        let text = "Synthetic insertion."
        ownedClipboardStrings.insert(text)
        await demo?.say("\(name) · \(field), empty · \(check)")
        let start = ContinuousClock.now
        let insertion = await insert(text, with: inserter)
        let insertMilliseconds = milliseconds(since: start)
        let landed = await settled(shown, text, blankBase: true)
        // The text is in the body and the hint's words are gone from the
        // text after the caret, which no read can tell from the person's
        // text going: unknown is the result expected here.
        let expected = insertion == .unknown(.readbackMismatch)
        await demo?.say("\(Self.describe(insertion)) in \(Int(insertMilliseconds)) ms" + (landed ? ", the body shows the text" : ", but the body differs"), for: 1.8)
        record(scene, name, version, field + ", empty", check, landed && expected, insertion: TextInserter.name(insertion),
               insertMilliseconds: insertMilliseconds,
               notes: landed
                   ? "the text is in the body; reported unknown because the hint's words left the text after the caret, as expected in WebKit"
                   : "the body does not show the text")
    }

    // MARK: - Gmail in the person's own Chrome Beta

    /// What goes into Gmail's compose body: a sentence that can only be
    /// this check's, and one for the body that already holds a letter.
    static let gmailInsertion = "Synthetic insertion into an empty Gmail body."
    static let gmailInsertionAfterLetter = " Synthetic insertion after a typed letter."

    /// Gmail's compose body in the person's own Chrome Beta, with their
    /// agreement, for the empty body that shows Gemini's "Press / to write"
    /// hint, which Intention 0.1.4 did not insert into: once as Gmail opens it
    /// and once with one letter typed, each in a compose window of its own.
    /// Runs only when named.
    ///
    /// What touches the person's browser, and nothing else: a new window
    /// asked for through Chrome's own command line, the one new window the
    /// window server and Accessibility then show, holding a new message
    /// with no recipient;
    /// keyboard focus moved to its body through Accessibility, never a click;
    /// one letter posted to that process while that window is in front and
    /// the body has focus; the insertion itself through the production
    /// inserter; Gmail's own "Discard draft" control under that window,
    /// pressed once; and that window's close button. Anything unexpected
    /// is left as it is and reported. Only that window and Intention's own dot
    /// panels are recorded, from the body's top edge down, so the compose
    /// header with the person's address stays out of the picture.
    private func gmailChromeBeta() async {
        let scene = "gmail-chrome-beta", name = "Chrome Beta"
        // The person's own instance is the one on the default profile.
        // The fixture scenes and probes start others with `--user-data-dir`,
        // whose windows are not where Chrome opens the new window, so one
        // of those watched by mistake would leave the new window untracked
        // in the person's browser. Exactly one default instance, or nothing
        // is opened.
        // An instance whose command line cannot be read is not taken for
        // the person's own.
        let own = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome.beta")
            .filter { Self.arguments(of: $0.processIdentifier).map { !$0.contains("--user-data-dir") } == true }
        guard own.count == 1, let beta = own.first else {
            record(scene, name, "", "compose body", "open a compose window", nil,
                   notes: own.isEmpty ? "Chrome Beta is not running on its own profile; nothing was opened"
                       : "\(own.count) Chrome Beta instances on the default profile; nothing was opened")
            return
        }
        for typed in [false, true] {
            await gmailComposeCase(scene, name, beta, typed: typed)
        }
    }

    /// One compose window: opened, its body focused and, with `typed`, given
    /// one letter, inserted into, read back, discarded and closed.
    private func gmailComposeCase(_ scene: String, _ name: String, _ beta: NSRunningApplication, typed: Bool) async {
        let field = typed ? "compose body with a letter typed" : "empty compose body with the hint"
        let check = typed ? "insert after the letter" : "insert into the empty body"
        let version = beta.version
        let pid = beta.processIdentifier
        guard let made = await makeChromeBetaWindow(beta) else {
            record(scene, name, version, field, check, false, notes: chromeBetaNote)
            return
        }
        var notes: [String] = []
        // Gmail's body, by the description it gives it; up to fifteen
        // seconds for the compose to load.
        let body = await find(in: made.window, { self.string($0, kAXDescriptionAttribute) == "Message Body" && self.role($0) == kAXTextAreaRole },
                              timeout: .seconds(15))
        guard let body else {
            notes.append("no compose body appeared in the window")
            await closeChromeBetaWindow(made, pid: pid, discard: false, notes: &notes)
            record(scene, name, version, field, check, false, notes: notes.joined(separator: "; "))
            return
        }
        // Keyboard focus to the body through Accessibility, as Gmail's own
        // reply does by script; the compose opens with focus in the To
        // field. Nothing is clicked.
        var focusedBody = false
        for _ in 0..<5 where !focusedBody {
            AXUIElementSetAttributeValue(body, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            focusedBody = await focused(is: body)
        }
        guard focusedBody, frontmost(beta), focusedWindow(of: pid).map({ CFEqual($0, made.window) }) == true else {
            notes.append("the body did not take keyboard focus; nothing was typed or inserted")
            await closeChromeBetaWindow(made, pid: pid, discard: true, holding: [""], notes: &notes)
            record(scene, name, version, field, check, false, notes: notes.joined(separator: "; "))
            return
        }
        // The body must be empty: nothing of a person's draft is written
        // into or read beyond its length.
        let length = intValue(body, kAXNumberOfCharactersAttribute) ?? -1
        guard length >= 0, length <= 1, let value = read(body), value.allSatisfy(\.isNewline) else {
            notes.append(length < 0 || read(body) == nil ? "the body did not answer for its length or value, so nothing was written"
                : "the body was not empty, so nothing was written")
            await closeChromeBetaWindow(made, pid: pid, discard: false, notes: &notes)
            record(scene, name, version, field, check, false, notes: notes.joined(separator: "; "))
            return
        }
        // The recording: this window and Intention's dot panels, from the
        // body's top edge down, so the header stays out of it.
        // The region is read again for every frame from the window's and the
        // body's current frames, so a window that moves keeps its header
        // out of the picture, and a frame is skipped while either does not
        // answer or the body is not inside the window.
        let recorder = WindowRecorder()
        let region: @MainActor () -> CGRect? = { [self] in
            guard let frame = elementFrame(body), let windowFrame = elementFrame(made.window), windowFrame.contains(frame.origin) else { return nil }
            let top = max(windowFrame.minY, frame.minY - 16)
            return CGRect(x: windowFrame.minX, y: top, width: windowFrame.width, height: windowFrame.maxY - top)
        }
        var recording = false
        if let wid = made.serverWindow, region() != nil {
            recorder.start(window: wid, pid: pid, region: region, into: output.appendingPathComponent("\(scene)-\(typed ? "typed" : "empty")"))
            recording = true
        } else {
            notes.append("no recording: the body's or the window's frame was not read")
        }
        /// Ends the recording and notes one that saved no frame.
        func stopRecording() async {
            let frames = await recorder.stop()
            if recording, frames == 0 { notes.append("no recording: no frame was captured (Screen Recording?)") }
        }
        try? await Task.sleep(for: .milliseconds(1200))
        var base = ""
        if typed {
            // One letter, to that process only, while the window is in
            // front and the body has focus; then the body must show it.
            guard ProcessSafety.allowsCheckInput, frontmost(beta), focusedWindow(of: pid).map({ CFEqual($0, made.window) }) == true, hasFocus(body),
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                notes.append("the window or the body lost focus before the letter; nothing was typed")
                await stopRecording()
                await closeChromeBetaWindow(made, pid: pid, discard: true, holding: [""], notes: &notes)
                record(scene, name, version, field, check, false, notes: notes.joined(separator: "; "))
                return
            }
            down.postToPid(pid)
            try? await Task.sleep(for: .milliseconds(30))
            up.postToPid(pid)
            base = "a"
            guard await settled(body, base, blankBase: true) else {
                notes.append("the body did not show the typed letter; nothing was inserted")
                await stopRecording()
                await closeChromeBetaWindow(made, pid: pid, discard: true, holding: ["", "a"], notes: &notes)
                record(scene, name, version, field, check, false, notes: notes.joined(separator: "; "))
                return
            }
            try? await Task.sleep(for: .milliseconds(800))
        }
        let text = typed ? Self.gmailInsertionAfterLetter : Self.gmailInsertion
        guard await placeSentinel() else {
            notes.append("the clipboard could not be copied, so it was left alone and nothing was inserted")
            await stopRecording()
            await closeChromeBetaWindow(made, pid: pid, discard: true, holding: [base], notes: &notes)
            record(scene, name, version, field, check, false, notes: notes.joined(separator: "; "))
            return
        }
        ownedClipboardStrings.insert(text)
        guard hasFocus(body), frontmost(beta) else {
            notes.append("the body lost focus before the insertion, so nothing was written")
            await stopRecording()
            await closeChromeBetaWindow(made, pid: pid, discard: true, holding: [base], notes: &notes)
            record(scene, name, version, field, check, false, notes: notes.joined(separator: "; "))
            return
        }
        let start = ContinuousClock.now
        let insertion = await insert(text, with: inserter)
        let insertMilliseconds = milliseconds(since: start)
        let expected = base + text
        let landed = await settled(body, expected, blankBase: true)
        try? await Task.sleep(for: .milliseconds(1500))
        await stopRecording()
        // A paste must have put the clipboard back when Intention may read it,
        // and otherwise have left the text there, whatever it reported.
        var clipboardOK = true
        if case .inserted(.paste, let restored) = insertion {
            clipboardOK = restored == clipboardReadable && (clipboardReadable ? sentinelRestored() : NSPasteboard.general.string(forType: .string) == text)
        }
        var passed = landed && clipboardOK
        switch insertion {
        case .inserted: break
        case .notInserted, .unknown:
            passed = false
            notes.append(landed ? "the body shows the text" : "the body does not show the text")
        }
        if !clipboardOK { notes.append("clipboard not as expected after insertion") }
        if landed, case .inserted = insertion, !notes.contains(where: { $0.hasPrefix("no recording") }) {
            notes.append("the body shows the text, read back independently")
        }
        // A result of unknown means a write may still land: the draft is
        // discarded through Gmail's control all the same, since the text
        // is this check's, and the window closed; nothing more is written.
        // The discard goes only to a body that still holds exactly what the
        // scene put there, read once more right before it, so words the
        // person typed meanwhile are never thrown away.
        await closeChromeBetaWindow(made, pid: pid, discard: true, holding: [base, expected], notes: &notes)
        record(scene, name, version, field, check, passed, insertion: TextInserter.name(insertion), insertMilliseconds: insertMilliseconds,
               notes: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }

    /// A window of the person's own Chrome Beta that this check made: its
    /// Accessibility window and the window server's id, the only one
    /// captures may hold.
    private struct MadeWindow {
        let window: AXUIElement
        let serverWindow: CGWindowID?
    }

    /// Why the last window could not be made.
    private var chromeBetaNote = ""

    /// Makes a new window in the running Chrome Beta holding an empty new
    /// message, through Chrome's own command line: a second Chrome Beta
    /// process started with `--new-window` and the address hands them to
    /// the running one and exits, so no Apple Event and no Automation
    /// grant is needed and nothing is opened in an existing window. The
    /// Accessibility and window server windows that existed before are
    /// never the made one; exactly one new window of each kind must
    /// appear, Chrome Beta must be in front, brought there if it is not,
    /// and the new window must be its focused window. Anything else closes
    /// the one new window, if there is exactly one, and returns nil with
    /// the reason in `chromeBetaNote`.
    private func makeChromeBetaWindow(_ beta: NSRunningApplication) async -> MadeWindow? {
        let pid = beta.processIdentifier
        let url = "https://mail.google.com/mail/u/0/?view=cm&fs=1&tf=1"
        let before = children(AXUIElementCreateApplication(pid), kAXWindowsAttribute)
        guard let serverBefore = serverWindows(of: pid), let executable = beta.executableURL else {
            chromeBetaNote = "Chrome Beta's windows could not be listed; no window was made"
            return nil
        }
        let serverBeforeIDs = Set(serverBefore.map(\.id))
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--new-window", url]
        do {
            try process.run()
        } catch {
            chromeBetaNote = "Chrome Beta could not be asked for a window; nothing was made"
            return nil
        }
        var seen = ""
        for _ in 0..<80 {
            let windows = children(AXUIElementCreateApplication(pid), kAXWindowsAttribute).filter { candidate in !before.contains { CFEqual($0, candidate) } }
            let serverNew = (serverWindows(of: pid) ?? []).filter { !serverBeforeIDs.contains($0.id) }
            if windows.count == 1, serverNew.count == 1, !frontmost(beta) { beta.activate() }
            let focused = focusedWindow(of: pid)
            // The window server's new window must be the Accessibility
            // window: same frame within a point, so the recording's filter
            // names the made window and no other.
            if windows.count == 1, let made = windows.first, serverNew.count == 1, let frame = elementFrame(made),
               Self.same(frame, serverNew[0].bounds), frontmost(beta), let focused, CFEqual(focused, made) {
                return MadeWindow(window: made, serverWindow: serverNew[0].id)
            }
            seen = "\(windows.count) new window(s), \(serverNew.count) on screen"
                + (windows.count == 1 && serverNew.count == 1 && !(elementFrame(windows[0]).map { Self.same($0, serverNew[0].bounds) } ?? false) ? " with another frame" : "")
                + ", Chrome Beta "
                + (frontmost(beta) ? "in front" : "not in front, \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nothing") is")
                + ", its focused window " + (focused.map { f in windows.first.map { CFEqual(f, $0) } == true ? "the made one" : "another" } ?? "none")
            try? await Task.sleep(for: .milliseconds(250))
        }
        chromeBetaNote = "Chrome Beta did not focus the one new window (\(seen)); nothing was typed"
        // Closed only when it is the one new window by both counts with
        // one frame, as the window made would be; a window the person
        // opened meanwhile is not.
        let windows = children(AXUIElementCreateApplication(pid), kAXWindowsAttribute).filter { candidate in !before.contains { CFEqual($0, candidate) } }
        let serverNew = (serverWindows(of: pid) ?? []).filter { !serverBeforeIDs.contains($0.id) }
        if windows.count == 1, serverNew.count == 1, let frame = elementFrame(windows[0]), Self.same(frame, serverNew[0].bounds) {
            await closeWindow(windows[0])
            chromeBetaNote += children(AXUIElementCreateApplication(pid), kAXWindowsAttribute).contains(where: { CFEqual($0, windows[0]) })
                ? ", and the made window did not close" : ", and the made window was closed"
        } else {
            chromeBetaNote += ", and with \(windows.count) new window(s) by Accessibility and \(serverNew.count) on screen none was closed"
        }
        return nil
    }

    /// Discards the draft through Gmail's own control under the made
    /// window, only while that window is Chrome Beta's focused one and its
    /// body, read once more, holds one of the texts in `holding`, what the
    /// scene itself put there, alone or with the editor's trailing line
    /// break, and closes the window through its close button once its
    /// compose is gone. A control that is not found, a body that holds
    /// anything else, which may be the person's words, a body that does not
    /// answer, a compose that stays, which closing could meet with a dialog,
    /// or a window that will not close is left as it is and noted; nothing
    /// else is pressed.
    private func closeChromeBetaWindow(_ made: MadeWindow, pid: pid_t, discard: Bool, holding: [String] = [], notes: inout [String]) async {
        if discard {
            guard frontmost(pid: pid), focusedWindow(of: pid).map({ CFEqual($0, made.window) }) == true else {
                notes.append("the compose window was no longer the focused one; the draft, if any, and the window were left")
                return
            }
            guard let body = findNow(in: made.window, { self.string($0, kAXDescriptionAttribute) == "Message Body" }),
                  let text = fieldText(body).map(normalized),
                  holding.contains(where: { text == normalized($0) || text == normalized($0) + "\n" }) else {
                notes.append("the body no longer holds only what the scene put there, or did not answer, so the draft and the window were left as they are")
                return
            }
            guard let control = findNow(in: made.window, { element in
                self.string(element, kAXDescriptionAttribute).map { $0 == "Discard draft" || $0.hasPrefix("Discard draft ") } == true
            }) else {
                notes.append("no Discard draft control found; the draft, if any, and the window were left")
                return
            }
            guard AXUIElementPerformAction(control, kAXPressAction as CFString) == .success else {
                notes.append("Gmail's discard control did not take the press; the draft, if any, and the window were left")
                return
            }
            // Gmail closes a compose window of its own a few seconds after
            // the discard; the compose, or the window with it, must be gone.
            var gone = false
            for _ in 0..<40 where !gone {
                try? await Task.sleep(for: .milliseconds(250))
                let open = children(AXUIElementCreateApplication(pid), kAXWindowsAttribute).contains(where: { CFEqual($0, made.window) })
                gone = !open || findNow(in: made.window, { self.string($0, kAXDescriptionAttribute) == "Message Body" }) == nil
            }
            guard gone else {
                notes.append("Gmail's discard control took the press, but the compose stayed, so the window was left open; check the drafts")
                return
            }
            notes.append("draft discarded through Gmail's control; the compose closed")
        }
        guard children(AXUIElementCreateApplication(pid), kAXWindowsAttribute).contains(where: { CFEqual($0, made.window) }) else { return }
        await closeWindow(made.window)
        try? await Task.sleep(for: .milliseconds(500))
        if children(AXUIElementCreateApplication(pid), kAXWindowsAttribute).contains(where: { CFEqual($0, made.window) }) {
            notes.append("the window did not close and was left as it is")
        }
    }

    private func frontmost(pid: pid_t) -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }

    /// Whether two window frames are the same within a point on each edge.
    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    private func focusedWindow(of pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func elementFrame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    /// The window server's ids of the on-screen ordinary windows of `pid`
    /// with their bounds; nil when the window server does not answer.
    private func serverWindows(of pid: pid_t) -> [(id: CGWindowID, bounds: CGRect)]? {
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

    // MARK: - Paragraph editor and Electron

    /// The fixture's editor that keeps each line in its own paragraph, as
    /// Slack's does. Chromium leaves the break between two paragraphs out of
    /// the offsets its selection and ranged reads take, and its value shows
    /// fewer breaks than the text holds; other engines may count them all.
    /// Each case therefore takes the selection the field reports after its
    /// setup, which must be the fixture's own with the breaks counted or left
    /// out, and compares the field with `shown`, the page's own account of
    /// the editor's text. `editor` names the fixture's editor: `paragraphs`,
    /// or `lines`, whose lines are plain `div` elements and whose counts
    /// all agree, so that once it holds several lines it takes the paste,
    /// with the clipboard put back, in WebKit as in Chromium.
    private func paragraphCases(
        _ scene: String, _ app: String, _ version: String, paste: Bool, webKit: Bool = false, editor: String = "paragraphs",
        ownInstance: NSRunningApplication?,
        setUp: @escaping (String, String) async -> AXUIElement?, status: @escaping @MainActor (AXUIElement) -> String?,
        shown: @escaping @MainActor () -> String?
    ) async {
        let field = editor == "lines" ? "line editor" : "paragraph editor"
        let lead = "First synthetic paragraph."
        let two = lead + "\n" + Self.text
        let lines = " First line.\nSecond line."
        let caret = NSRange(location: 37, length: 0)
        let second = NSRange(location: lead.utf16.count + 1 + 37, length: 0)
        let acrossTwo = NSRange(location: 16, length: lead.utf16.count - 16 + 1 + 13)
        /// The field after `button`, and the selection it reports, when that
        /// is `place` with the paragraph breaks before or inside it counted
        /// or left out.
        func ready(_ button: String, _ base: String, _ place: NSRange, breaksBefore: Int = 0, breaksInside: Int = 0) async -> (AXUIElement, NSRange)? {
            guard let element = await setUp(button, editor), await focused(is: element) else { return nil }
            let leftOut = NSRange(location: place.location - breaksBefore, length: place.length - breaksInside)
            // The page sets the text and then the selection, and the field
            // can answer for the old ones for a moment.
            for _ in 0..<20 {
                if shown().map(normalized) == normalized(base), let reported = range(element), reported == place || reported == leftOut {
                    return (element, reported)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }
        func run(_ check: String, _ button: String, _ base: String, _ place: NSRange, _ text: String, breaksBefore: Int = 0,
                 appUndo: Bool = false) async {
            // The setup writes to the field, so a stopped scene must not
            // reach it: an earlier insertion may still land there.
            guard !skipped(scene, app, version, field, check) else { return }
            guard let (element, reported) = await ready(button, base, place, breaksBefore: breaksBefore) else {
                record(scene, app, version, field, check, false, notes: "setup failed: the field, its text or its selection")
                return
            }
            // A field that already holds a paragraph break takes a paste,
            // except a WebKit paragraph editor, whose breaks read doubled.
            // The line editor's route is known either way.
            let lineBlocks = editor == "lines" && !paste
            await editCase(scene, app, version, field, check, base: base, selection: reported, valueSelection: place, text: text,
                           paste: paste, pasteFallback: lineBlocks && base.contains("\n"), anyRoute: !paste && editor != "lines",
                           setup: { await self.focused(is: element) ? element : nil },
                           restore: { await ready(button, base, place, breaksBefore: breaksBefore)?.0 },
                           appUndo: appUndo ? ownInstance : nil, extra: status, shown: shown)
        }
        /// Puts the editor back with `button` while it holds `left`; nil
        /// once it reads `base` again.
        func putBack(_ button: String, _ base: String, _ place: NSRange, left: String) async -> String? {
            await self.putBack(shown, left: left, base: base, blank: false, by: { await ready(button, base, place)?.0 }, still: nil)
        }
        await run("insert two lines", "setup-\(editor)-caret", Self.text, caret, lines, appUndo: true)
        await run("replace a word with two lines", "setup-\(editor)-word", Self.text, NSRange(location: 4, length: 9), lines)
        await run("insert two paragraphs with an empty line between", "setup-\(editor)-caret", Self.text, caret,
                  " First line.\n\nSecond line.")
        await run("insert text that ends with a line break", "setup-\(editor)-caret", Self.text, caret,
                  " A synthetic sentence.\n")
        await run("insert after an earlier paragraph", "setup-\(editor)-second", two, second, Self.insertion, breaksBefore: 1)
        await run("insert two lines after an earlier paragraph", "setup-\(editor)-second", two, second, lines, breaksBefore: 1)
        // The caret sits before the break that ends the first paragraph.
        await run("insert at the end of a paragraph", "setup-\(editor)-end", two,
                  NSRange(location: lead.utf16.count, length: 0), " Synthetic insertion.")
        // An empty paragraph that was there before the insertion. The breaks
        // around it show in neither of the field's lengths, and a replace
        // range after it would count them differently.
        let spaced = lead + "\n\n" + Self.text
        await run("insert after an empty paragraph", "setup-\(editor)-after-empty", spaced,
                  NSRange(location: lead.utf16.count + 2 + 37, length: 0), Self.insertion, breaksBefore: 1)
        /// Replaces a selection that holds a paragraph break, which
        /// Chromium's offsets leave out and WebKit's count.
        func across(_ check: String, _ button: String, _ base: String, _ place: NSRange) async {
            guard !skipped(scene, app, version, field, check) else { return }
            guard let (element, reported) = await ready(button, base, place, breaksInside: 1) else {
                record(scene, app, version, field, check, false, notes: "setup failed: the field, its text or its selection")
                return
            }
            guard await placeSentinel() else {
                record(scene, app, version, field, check, false, notes: "the clipboard could not be copied, so it was left alone and the case did not run")
                return
            }
            // Copying the clipboard takes a moment, so the field is checked
            // again after it.
            guard hasFocus(element), shown().map(normalized) == normalized(base), range(element) == reported else {
                record(scene, app, version, field, check, false, notes: "the field changed before the insertion, so nothing was written")
                return
            }
            ownedClipboardStrings.insert("Synthetic")
            let insertion = await insert("Synthetic", with: inserter)
            let inserted = (base as NSString).replacingCharacters(in: place, with: "Synthetic")
            let insertedOK = await settled(shown, inserted)
            // The line editor holds several blocks here, so it takes the
            // paste and the clipboard is put back.
            let routeOK = editor == "lines"
                ? insertion == .inserted(.paste, clipboardRestored: clipboardReadable) && (!clipboardReadable || sentinelRestored())
                : [.inserted(.replaceRange, clipboardRestored: nil), .inserted(.paste, clipboardRestored: clipboardReadable)].contains(insertion)
            var putBack: String?
            if case .unknown = insertion {
                stop(Self.unknownInFixture)
                putBack = stopped
            } else {
                putBack = await self.putBack(shown, left: inserted, base: base, blank: false,
                                             by: { await ready(button, base, place, breaksInside: 1)?.0 }, still: nil)
            }
            record(scene, app, version, field, check, routeOK && insertedOK && putBack == nil,
                   insertion: TextInserter.name(insertion),
                   notes: [insertedOK ? nil : "insertion did not land (\(difference(shown(), from: inserted)))", putBack]
                       .compactMap { $0 }.joined(separator: "; ").nilIfEmpty)
        }
        if !paste {
            await across("replace a selection across two paragraphs", "setup-\(editor)-across", two, acrossTwo)
            // The empty paragraph reads as one line break.
            await across("replace a selection across an empty paragraph", "setup-\(editor)-across-empty", spaced,
                         NSRange(location: 16, length: lead.utf16.count - 16 + 2 + 13))
        }
        // In WebKit its result is unknown, so that case runs in a host of
        // its own; see `extraLineCase`.
        guard !webKit else { return }
        let leading = Self.leadingBreak
        if paste {
            // Chromium pastes text that starts with a line break as a
            // paragraph break and an empty line. The field reads that back
            // as the text written, so the insertion is confirmed.
            let check = "paste text that starts with a line break: an empty line is added, confirmed"
            // Copying the clipboard takes a moment, so the field is checked
            // again after it.
            if skipped(scene, app, version, field, check) {
            } else if let (element, _) = await ready("setup-\(editor)-caret", Self.text, caret), await placeSentinel(),
               hasFocus(element), shown().map(normalized) == normalized(Self.text) {
                ownedClipboardStrings.insert(leading)
                let insertion = await insert(leading, with: pasteInserter)
                let pasted = (Self.text as NSString).replacingCharacters(in: caret, with: "\n" + leading)
                let pastedOK = await settled(shown, pasted)
                let submitted = status(element)
                var cleanup: String?
                if case .unknown = insertion {
                    stop(Self.unknownInFixture)
                    cleanup = stopped
                } else {
                    cleanup = await putBack("setup-\(editor)-caret", Self.text, caret, left: pasted)
                }
                record(scene, app, version, field, check,
                       insertion == .inserted(.paste, clipboardRestored: clipboardReadable) && pastedOK && submitted == nil && cleanup == nil,
                       insertion: TextInserter.name(insertion),
                       notes: [pastedOK ? nil : "the field differs (\(difference(shown(), from: pasted)))", submitted, cleanup]
                           .compactMap { $0 }.joined(separator: "; ").nilIfEmpty)
            } else {
                record(scene, app, version, field, check, false, notes: "setup failed: the field, its text, its selection or the clipboard")
            }
        } else {
            await run("insert text that starts with a line break", "setup-\(editor)-caret", Self.text, caret, leading)
        }
    }

    /// Text that starts with a line break at offset 37 of the fixture's
    /// text, in WebKit's plain editable element (`editor` "editable"), line
    /// editor ("lines") or paragraph editor ("paragraphs"). WebKit writes it
    /// with one break more, an empty line before the text, so the field does
    /// not read as written and the insertion is reported
    /// `unknown.readbackMismatch`. The case passes on that result with the
    /// field reading as the text written with the extra break.
    ///
    /// After an unknown result a scene writes nothing more, so each editor
    /// has a scene of its own: it starts its own WebKit host, runs this one
    /// case, stops, and asks the host to quit with the field left as it
    /// is. There is no paste scene for it: an unconfirmed paste would end
    /// the run's use of the clipboard.
    private func extraLineCase(_ scene: String, field: String, editor: String) async {
        let check = "text that starts with a line break: an empty line is added, reported unknown"
        let caret = NSRange(location: 37, length: 0)
        let written = (Self.text as NSString).replacingCharacters(in: caret, with: "\n" + Self.leadingBreak)
        guard let (app, window, version) = await openWebKitHost(scene, page: scene) else { return }
        defer { app.terminate() }
        let reading: @MainActor (AXUIElement) -> String? = { [self] element in
            editor == "editable" ? fieldText(element) : paragraphText(in: window, editor: editor)()
        }
        var ready: AXUIElement?
        if await comeForward(app), let found = await pressSetup("setup-\(editor)-caret", editor, in: window), await focused(is: found) {
            // The page sets the text and then the selection, and the field
            // can answer for the old ones for a moment.
            for _ in 0..<20 {
                if reading(found).map(normalized) == normalized(Self.text), range(found) == caret {
                    ready = found
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        guard let element = ready else {
            record(scene, "WebKit", version, field, check, false, notes: "setup failed: the field, its text or its selection")
            return
        }
        await demo?.say("WebKit · \(field) · \(check)")
        guard hasFocus(element), reading(element).map(normalized) == normalized(Self.text) else {
            record(scene, "WebKit", version, field, check, false, notes: "the field changed before the insertion, so nothing was written")
            return
        }
        let start = ContinuousClock.now
        let insertion = await insert(Self.leadingBreak, with: inserter)
        let insertMilliseconds = milliseconds(since: start)
        let writtenOK = await settled({ reading(element) }, written)
        let submitted = status(element, in: window)
        await demo?.say("\(Self.describe(insertion)) in \(Int(insertMilliseconds)) ms", for: 1.8)
        if case .unknown = insertion { stop(Self.unknownInFixture) }
        record(scene, "WebKit", version, field, check,
               insertion == .unknown(.readbackMismatch) && writtenOK && submitted == nil,
               insertion: TextInserter.name(insertion), insertMilliseconds: insertMilliseconds,
               notes: [writtenOK ? nil : "the field differs (\(difference(reading(element), from: written)))", submitted,
                       "the field was left as it is and its host asked to quit"]
                   .compactMap { $0 }.joined(separator: "; "))
    }

    /// The fixture page's account of whether anything was submitted.
    private func status(_ element: AXUIElement, in window: AXUIElement) -> String? {
        guard let status = findNow(in: window, { self.domID($0) == "status" }) else { return "status field not found" }
        return read(status) == "submitted: no" ? nil : "the page reports a submission"
    }

    /// Reads the fixture page's own account of an editor's text, which
    /// writes a line break as "⏎": `editor` is `paragraphs` or `lines`.
    /// `mirror` is `text`, which leaves images out, or `shape`, which shows
    /// each image as "▣" and each line break inside a block as "↵".
    private func paragraphText(in window: AXUIElement, editor: String = "paragraphs", mirror: String = "text") -> @MainActor () -> String? {
        { [self] in
            findNow(in: window, { self.domID($0) == editor + "-" + mirror }).flatMap(read)?.replacingOccurrences(of: "⏎", with: "\n")
        }
    }

    // MARK: - Images in WebKit editors

    /// Insertions beside an image in the fixture's WebKit editors, in the
    /// shapes the reviews of #148 measured. No Accessibility read of a
    /// WebKit field shows an image without alt text, while its replace
    /// range counts one, and its markers count an image with alt text where
    /// its ranged reads do not, so text can land on the wrong side of an
    /// image, or the image go, while the inserter's own readback agrees.
    /// Each case therefore reads the page's own account of the editor, with
    /// each image as "▣" and each line break inside a block as "↵", and
    /// passes only when that is exactly the text written out below, the
    /// insertion took the route the case names, the clipboard holds what
    /// it should and the field was put back by its setup.
    ///
    /// The line editor's image has no alt text and sits after "The " in its
    /// second line; the editor holds two blocks, so it takes the paste. The
    /// paragraph editor's has alt text, and each case replaces "note.",
    /// the word right before it: at the end of the last paragraph and with
    /// a `<br>` between, read by the field's own marker range and pasted
    /// into; followed by an empty last paragraph and alone in the last one,
    /// inside that range, where the paragraphs' breaks read doubled and the
    /// field takes `AXReplaceRangeWithText`. The paste scene pastes all.
    private func imageCases(
        _ scene: String, _ app: String, _ version: String, paste: Bool, window: AXUIElement,
        setUp: @escaping (String, String) async -> AXUIElement?, status: @escaping @MainActor (AXUIElement) -> String?
    ) async {
        // A dictation inserts text of its own, so these run only as the
        // inserter's cases.
        guard dictation == nil else { return }
        typealias Case = ShapeCase
        let lineField = "line editor, image without alt text"
        let paragraphField = "paragraph editor, image with alt text"
        let lineBase = "First synthetic paragraph.\nThe ▣synthetic meeting is on Thursday. Please reply with a short note."
        let word = "synthetic note: café, 東京, 👩‍💻."
        let cases = [
            Case(editor: "lines", field: lineField, check: "insert right before the image, which stays",
                 button: "setup-lines-image-before", base: lineBase, selection: NSRange(location: 31, length: 0), text: Self.insertion,
                 expected: "First synthetic paragraph.\nThe  Synthetic insertion: café, 東京, 👩‍💻.▣synthetic meeting is on Thursday. Please reply with a short note.",
                 route: .paste),
            Case(editor: "lines", field: lineField, check: "insert right after the image, which stays",
                 button: "setup-lines-image-after", base: lineBase, selection: NSRange(location: 31, length: 0), text: Self.insertion,
                 expected: "First synthetic paragraph.\nThe ▣ Synthetic insertion: café, 東京, 👩‍💻.synthetic meeting is on Thursday. Please reply with a short note.",
                 route: .paste),
            Case(editor: "lines", field: lineField, check: "replace the word right after the image, which stays",
                 button: "setup-lines-image-word", base: lineBase, selection: NSRange(location: 31, length: 9), text: Self.insertion,
                 expected: "First synthetic paragraph.\nThe ▣ Synthetic insertion: café, 東京, 👩‍💻. meeting is on Thursday. Please reply with a short note.",
                 route: .paste),
            Case(editor: "paragraphs", field: paragraphField, check: "replace the word before an image that ends the last paragraph",
                 button: "setup-paragraphs-image-end",
                 base: "First synthetic paragraph.\nThe synthetic meeting is on Thursday. Please reply with a short note.▣",
                 selection: NSRange(location: 91, length: 5), text: word,
                 expected: "First synthetic paragraph.\nThe synthetic meeting is on Thursday. Please reply with a short synthetic note: café, 東京, 👩‍💻.▣",
                 route: .paste),
            Case(editor: "paragraphs", field: paragraphField, check: "replace the word before a line break and an image that end the last paragraph",
                 button: "setup-paragraphs-image-break",
                 base: "First synthetic paragraph.\nThe synthetic meeting is on Thursday. Please reply with a short note.↵▣",
                 selection: NSRange(location: 91, length: 5), text: word,
                 expected: "First synthetic paragraph.\nThe synthetic meeting is on Thursday. Please reply with a short synthetic note: café, 東京, 👩‍💻.↵▣",
                 route: .paste),
            Case(editor: "paragraphs", field: paragraphField, check: "replace the word before an image followed by an empty last paragraph",
                 button: "setup-paragraphs-image-then-empty",
                 base: "First synthetic paragraph.\nThe synthetic meeting is on Thursday. Please reply with a short note.▣\n",
                 selection: NSRange(location: 91, length: 5), text: word,
                 expected: "First synthetic paragraph.\nThe synthetic meeting is on Thursday. Please reply with a short synthetic note: café, 東京, 👩‍💻.▣\n",
                 route: .replaceRange),
            Case(editor: "paragraphs", field: paragraphField, check: "replace the word before an image alone in the last paragraph",
                 button: "setup-paragraphs-image-alone",
                 base: "First synthetic paragraph.\nThe synthetic meeting is on Thursday. Please reply with a short note.\n▣",
                 selection: NSRange(location: 91, length: 5), text: word,
                 expected: "First synthetic paragraph.\nThe synthetic meeting is on Thursday. Please reply with a short synthetic note: café, 東京, 👩‍💻.\n▣",
                 route: .replaceRange),
        ]
        await shapeCases(cases, scene, app, version, paste: paste, window: window, setUp: setUp, status: status, kept: "image in place")
    }

    /// Insertions in the fixture's WebKit editor that holds a list between
    /// two paragraphs without margins, the shape whose markers read each
    /// item with its label in front, "• " or "1. ", while the selection,
    /// the markers' lengths and every other read give the label no place.
    /// The inserter takes the labels out and the field takes the paste, so
    /// each case is confirmed with the clipboard put back. The caret sits
    /// at the end of the paragraph before the list, at the start, in the
    /// middle and at the end of the first item and at the start of the
    /// paragraph after the list, in a bulleted and a numbered list; and in
    /// an item holding an image with alt text, right before it, right
    /// after it, and with the word after it selected, where WebKit's
    /// replace range wrote before the image or removed it. The page's
    /// account shows each item with its label and the image as "▣".
    private func listCases(
        _ scene: String, _ app: String, _ version: String, paste: Bool, window: AXUIElement,
        setUp: @escaping (String, String) async -> AXUIElement?, status: @escaping @MainActor (AXUIElement) -> String?
    ) async {
        // A dictation inserts text of its own, so these run only as the
        // inserter's cases.
        guard dictation == nil else { return }
        let text = "synthetic café, 東京, 👩‍💻"
        var cases: [ShapeCase] = []
        for (kind, field, first, second) in [("bullets", "list editor, bulleted", "• ", "• "), ("numbers", "list editor, numbered", "1. ", "2. ")] {
            let base = "Start.\n\(first)One\n\(second)Two\nEnd."
            let places = [
                ("before", "insert at the end of the paragraph before the list", 6, "Start.\(text)\n\(first)One\n\(second)Two\nEnd."),
                ("start", "insert at the start of an item", 7, "Start.\n\(first)\(text)One\n\(second)Two\nEnd."),
                ("middle", "insert in the middle of an item", 8, "Start.\n\(first)O\(text)ne\n\(second)Two\nEnd."),
                ("end", "insert at the end of an item", 10, "Start.\n\(first)One\(text)\n\(second)Two\nEnd."),
                ("after", "insert at the start of the paragraph after the list", 15, "Start.\n\(first)One\n\(second)Two\n\(text)End."),
            ]
            for (place, check, caret, expected) in places {
                cases.append(ShapeCase(editor: "list", field: field, check: check, button: "setup-list-\(kind)-\(place)", base: base,
                                       selection: NSRange(location: caret, length: 0), text: text, expected: expected, route: .paste))
            }
        }
        let field = "list editor, image with alt text in an item"
        let base = "Start.\n• One▣Six\n• Two\nEnd."
        for (place, check, selection, expected) in [
            ("before", "insert right before the image, which stays", NSRange(location: 10, length: 0), "Start.\n• One\(text)▣Six\n• Two\nEnd."),
            ("after", "insert right after the image, which stays", NSRange(location: 10, length: 0), "Start.\n• One▣\(text)Six\n• Two\nEnd."),
            ("word", "replace the word right after the image, which stays", NSRange(location: 10, length: 3), "Start.\n• One▣\(text)\n• Two\nEnd."),
        ] {
            cases.append(ShapeCase(editor: "list", field: field, check: check, button: "setup-list-image-\(place)", base: base,
                                   selection: selection, text: text, expected: expected, route: .paste))
        }
        await shapeCases(cases, scene, app, version, paste: paste, window: window, setUp: setUp, status: status, kept: "list in place")
    }

    /// A case that reads the page's own account of an editor with each
    /// image as "▣", each line break inside a block as "↵" and, in the
    /// list editor, each item's label in front of it: the route the
    /// insertion must take, the text the account must show after it.
    private enum ShapeRoute { case paste, replaceRange }
    private struct ShapeCase {
        let editor: String, field: String, check: String, button: String, base: String
        let selection: NSRange, text: String, expected: String, route: ShapeRoute
    }

    /// Runs `cases`, each from its setup: the insertion must take the
    /// case's route, the page's account must then read exactly as
    /// expected, the clipboard must hold what it should and the field must
    /// be put back by its setup. `kept` ends the caption of one that
    /// passed, saying what stayed as it was.
    private func shapeCases(
        _ cases: [ShapeCase], _ scene: String, _ app: String, _ version: String, paste: Bool, window: AXUIElement,
        setUp: @escaping (String, String) async -> AXUIElement?, status: @escaping @MainActor (AXUIElement) -> String?, kept: String
    ) async {
        typealias Route = ShapeRoute
        for item in cases {
            // The setup writes to the field, so a stopped scene must not
            // reach it: an earlier insertion may still land there.
            guard !skipped(scene, app, version, item.field, item.check) else { continue }
            let shown = paragraphText(in: window, editor: item.editor, mirror: "shape")
            /// The field after the case's setup, once the page shows its
            /// text and the field reports its selection. The page sets the
            /// text and then the selection, and the field can answer for the
            /// old ones for a moment.
            func ready() async -> AXUIElement? {
                guard let element = await setUp(item.button, item.editor), await focused(is: element) else { return nil }
                for _ in 0..<20 {
                    if shown().map(normalized) == normalized(item.base), range(element) == item.selection { return element }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return nil
            }
            guard let element = await ready() else {
                record(scene, app, version, item.field, item.check, false, notes: "setup failed: the field, its text or its selection")
                continue
            }
            guard await placeSentinel() else {
                record(scene, app, version, item.field, item.check, false,
                       notes: "the clipboard could not be copied, so it was left alone and the case did not run")
                continue
            }
            await demo?.say("\(app) · \(item.field) · \(item.check)")
            // Copying the clipboard and the caption take a moment, so the
            // field is checked again right before the insertion.
            guard hasFocus(element), shown().map(normalized) == normalized(item.base), range(element) == item.selection else {
                record(scene, app, version, item.field, item.check, false, notes: "the field changed before the insertion, so nothing was written")
                continue
            }
            // The paste scene's inserter pastes into every field.
            let route = paste ? Route.paste : item.route
            ownedClipboardStrings.insert(item.text)
            let start = ContinuousClock.now
            let insertion = await insert(item.text, with: paste ? pasteInserter : inserter)
            let insertMilliseconds = milliseconds(since: start)
            let insertedOK = await settled(shown, item.expected)
            let differs = insertedOK ? nil : "the field after insertion differs (\(difference(shown(), from: item.expected)))"
            let routeOK = route == .paste
                ? insertion == .inserted(.paste, clipboardRestored: clipboardReadable)
                : insertion == .inserted(.replaceRange, clipboardRestored: nil)
            // A paste puts the sentinel back, or without a backup leaves the
            // pasted text; a replace range never touches the clipboard.
            let clipboardOK = route == .paste && !clipboardReadable
                ? NSPasteboard.general.string(forType: .string) == item.text
                : sentinelRestored()
            let submitted = status(element)
            await demo?.say("\(Self.describe(insertion)) in \(Int(insertMilliseconds)) ms" + (insertedOK ? ", \(kept)" : ", but the field differs"), for: 1.8)
            let expectedRoute = route == .paste ? "inserted.paste" : "inserted.replaceRange"
            let routeNote = routeOK ? nil : "expected \(expectedRoute)"
            if case .unknown = insertion {
                stop(Self.unknownInFixture)
                record(scene, app, version, item.field, item.check, false, insertion: TextInserter.name(insertion),
                       insertMilliseconds: insertMilliseconds,
                       notes: [routeNote, differs, stopped].compactMap { $0 }.joined(separator: "; "))
                continue
            }
            // A refused insertion left the field as the setup made it.
            let left: String = { if case .notInserted = insertion { return item.base } else { return item.expected } }()
            let putBack = await self.putBack(shown, left: left, base: item.base, blank: false, by: { await ready() }, still: nil)
            let notes = [routeNote, differs, clipboardOK ? nil : "clipboard not as expected after insertion", submitted, putBack]
                .compactMap { $0 }
            record(scene, app, version, item.field, item.check,
                   routeOK && insertedOK && clipboardOK && submitted == nil && putBack == nil,
                   insertion: TextInserter.name(insertion), insertMilliseconds: insertMilliseconds,
                   notes: notes.isEmpty ? nil : notes.joined(separator: "; "))
        }
    }

    /// The fixture page in an Electron app built from an installed runtime by
    /// `scripts/build-caret-electron.py`, for Chromium as an Electron app
    /// ships it. Runs only when named, since the app has to be built first.
    private func electron(paste: Bool) async {
        let scene = paste ? "electron-paste" : "electron"
        let page = output.appendingPathComponent("insertion-\(token)-\(scene).html")
        try? FileManager.default.removeItem(at: page)
        try? FileManager.default.copyItem(at: fixtures.appendingPathComponent("insertion.html"), to: page)
        let bundle = fixtures.deletingLastPathComponent().appendingPathComponent(".build/caret-lab/Intention Electron Fixture.app")
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            record(scene, "Electron", "", "fixture page", "open fixture", false,
                   notes: "no fixture app; build it with python3 scripts/build-caret-electron.py")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        // The fixture's main script accepts only a page in its own output
        // directory and a caret lab title.
        configuration.arguments = ["--fixture-page", page.path, "--fixture-output", output.path,
                                   "--fixture-title", "Intention caret lab \(UUID().uuidString) electron-insertion"]
        let launched: NSRunningApplication? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { app, _ in continuation.resume(returning: app) }
        }
        guard let app = launched else {
            record(scene, "Electron", "", "fixture page", "open fixture", false, notes: "the fixture app did not start")
            return
        }
        defer { app.terminate() }
        guard await comeForward(app), let window = await window(of: app, containing: page.lastPathComponent),
              await find(in: window, { self.domID($0) == "setup-paragraphs-caret" }, timeout: .seconds(15)) != nil
        else {
            record(scene, "Electron", "", "fixture page", "open fixture", false, notes: "fixture window or page content not found")
            return
        }
        // The fixture is a copy of another app's runtime; its Chromium is
        // what the cases exercise, so the report names that.
        let runtime = (try? Data(contentsOf: output.appendingPathComponent("electron-runtime.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let version = "Electron \(runtime?["electron"] as? String ?? "?"), Chromium \(runtime?["chrome"] as? String ?? "?")"
        func setUp(_ button: String, _ field: String) async -> AXUIElement? {
            guard await comeForward(app) else { return nil }
            return await pressSetup(button, field, in: window)
        }
        let status: @MainActor (AXUIElement) -> String? = { [self] _ in
            guard let element = findNow(in: window, { self.domID($0) == "status" }) else { return "status field not found" }
            return read(element) == "submitted: no" ? nil : "the page reports a submission"
        }
        await pageCases(scene, "Electron", version, paste: paste, window: window, paragraphs: true, ownInstance: app, setUp: setUp, status: status)
    }

    /// The fixture page in a WKWebView, in the host app that
    /// `scripts/build-caret-lab.sh` builds: WebKit's web fields as Safari
    /// shows them, with no browser, account or other window involved. Runs
    /// only when named, since the app has to be built first.
    private func webKit(paste: Bool) async {
        let scene = paste ? "webkit-paste" : "webkit"
        guard let (app, window, version) = await openWebKitHost(scene, page: scene) else { return }
        func setUp(_ button: String, _ field: String) async -> AXUIElement? {
            guard await comeForward(app) else { return nil }
            return await pressSetup(button, field, in: window)
        }
        let status: @MainActor (AXUIElement) -> String? = { [self] element in self.status(element, in: window) }
        await pageCases(scene, "WebKit", version, paste: paste, window: window, paragraphs: true, webKit: true, ownInstance: app, setUp: setUp, status: status)
        app.terminate()
        for _ in 0..<50 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Starts a new instance of the WebKit fixture host on a copy of the
    /// fixture page named after `page`, and waits for its content. Records
    /// the failure and asks the host to quit when it does not come up.
    private func openWebKitHost(_ scene: String, page name: String) async -> (NSRunningApplication, AXUIElement, String)? {
        let page = output.appendingPathComponent("insertion-\(token)-\(name).html")
        try? FileManager.default.removeItem(at: page)
        try? FileManager.default.copyItem(at: fixtures.appendingPathComponent("insertion.html"), to: page)
        let bundle = fixtures.deletingLastPathComponent().appendingPathComponent(".build/caret-lab/Intention WebKit Fixture.app")
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            record(scene, "WebKit", "", "fixture page", "open fixture", false,
                   notes: "no fixture app; build it with bash scripts/build-caret-lab.sh")
            return nil
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--fixture-page", page.path]
        let launched: NSRunningApplication? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { app, _ in continuation.resume(returning: app) }
        }
        guard let app = launched else {
            record(scene, "WebKit", "", "fixture page", "open fixture", false, notes: "the fixture app did not start")
            return nil
        }
        guard await comeForward(app), let window = await window(of: app, containing: page.lastPathComponent),
              await find(in: window, { self.domID($0) == "setup-input-caret" }, timeout: .seconds(15)) != nil
        else {
            record(scene, "WebKit", "", "fixture page", "open fixture", false, notes: "fixture window or page content not found")
            app.terminate()
            return nil
        }
        // The recording shows the host's window, like the other fixtures'.
        await demo?.include(pid: app.processIdentifier, title: page.lastPathComponent)
        // The engine is the system's, so the report names its version.
        let engine = Bundle(path: "/System/Library/Frameworks/WebKit.framework")?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return (app, window, "WebKit \(engine ?? "?")")
    }

    // MARK: - Mail and Slack

    /// A new Mail message with no recipient, which cannot be sent. Opt-in,
    /// since Mail is signed in to the person's accounts. The scene writes
    /// only into the body of the window it opened, stops unless that message
    /// is empty, and closes the window without saving a draft.
    private func mail() async {
        let scene = "mail"
        let field = "new message body"
        // Mail can take longer to start than `open` waits for it.
        var launched = await open([], with: "com.apple.mail")
        if launched == nil { launched = await open([], with: "com.apple.mail") }
        guard let app = launched, let item = await menuItem(of: app, titled: "New Message") else {
            record(scene, "Mail", "", field, "open a new message", false, notes: "Mail or its New Message item not found")
            return
        }
        let version = app.version
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // The message window is the one that was not there before, so the
        // windows before have to be known. Mail started cold brings its
        // windows back over a few seconds, the person's open drafts among
        // them, so the list is taken once it has stopped changing. Only one
        // message window may be new: one the person opens in the same
        // moment, or one Mail brings back late, is not the scene's.
        guard let before = await settledWindows(of: element) else {
            record(scene, "Mail", version, field, "open a new message", false, notes: "Mail's windows did not settle, so no message was opened")
            return
        }
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            record(scene, "Mail", version, field, "open a new message", false, notes: "New Message is unavailable; Mail may have no account")
            return
        }
        func newMessages() -> [AXUIElement] {
            (windows(of: element) ?? []).filter { candidate in
                !before.contains { CFEqual($0, candidate) }
                    && findNow(in: candidate, { self.string($0, "AXIdentifier") == "Mail.toField" }) != nil
            }
        }
        var opened: [AXUIElement] = []
        for _ in 0..<50 where opened.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            opened = newMessages()
        }
        // Long enough for a second window to show.
        try? await Task.sleep(for: .milliseconds(500))
        opened = newMessages()
        guard opened.count == 1, let window = opened.first else {
            record(scene, "Mail", version, field, "open a new message", false,
                   notes: opened.isEmpty ? "no new message window" : "more than one new message window, so none was touched; close the empty one by hand")
            return
        }
        // A window that is not an empty new message is never closed or
        // written to: it may be one of the person's that Mail showed late.
        guard let body = await find(in: window, { self.role($0) == "AXWebArea" }, timeout: .seconds(10)) else {
            record(scene, "Mail", version, field, "open a new message", false,
                   notes: "the new message has no body; the window was left open, so close it by hand if it is empty")
            return
        }
        // Read each time, since a header field such as Bcc can be added later.
        func headers() -> [AXUIElement] { textControls(window).filter { self.role($0) == kAXTextFieldRole } }
        // Everything the scene writes. It replaces the body, and clears and
        // discards the message, only while the To, Cc and Subject fields are
        // empty and the body holds one of these, so anything a person types
        // into the message while the scene runs stops it instead.
        var written: Set<String> = [""]
        // The header fields the message had when the scene took it. A later
        // read that finds fewer, or no To field, did not see the whole
        // message, and an unread field is not an empty one.
        let headerCount = headers().count
        func untouched() -> Bool {
            let text = fieldText(body).map(normalized) ?? "?"
            let fields = headers()
            return fields.count >= headerCount && fields.contains { self.string($0, "AXIdentifier") == "Mail.toField" }
                && fields.allSatisfy { (self.fieldText($0) ?? "x").isEmpty } && (written.contains(text) || text.allSatisfy(\.isNewline))
        }
        func finish() async {
            // After an unknown result the body is not written again, so the
            // message is left open as it is.
            if let stopped {
                record(scene, "Mail", version, field, "message discarded", false,
                       notes: stopped + "; the message window was left open, so close it without saving")
                return
            }
            let ours = untouched()
            if ours, fieldText(body)?.isEmpty == false { _ = replaceDocumentText(body, nil, with: "") }
            let discarded = ours ? await discardMessage(window, of: element) : false
            record(scene, "Mail", version, field, "message discarded", discarded,
                   notes: discarded ? nil : ours ? "the message window is still open; close it without saving"
                       : "the message holds something the scene did not write, so it was left open")
        }
        guard headers().contains(where: { self.string($0, "AXIdentifier") == "Mail.toField" }),
              headers().allSatisfy({ (self.fieldText($0) ?? "x").isEmpty }),
              (fieldText(body) ?? "x").allSatisfy(\.isNewline) else {
            // Nothing was written, and the window stays open.
            record(scene, "Mail", version, field, "open a new message", false,
                   notes: "not an empty new message, perhaps because of a signature; body length \(fieldText(body)?.utf16.count ?? -1), "
                       + "\(headers().count) header fields; the window was left open, so close it by hand if it is the scene's")
            return
        }
        func setUp(_ base: String, _ selection: NSRange) async -> AXUIElement? {
            guard await comeForward(app), untouched() else { return nil }
            AXUIElementSetAttributeValue(body, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            // No click stands in for a focus request Mail ignores: the case
            // fails instead. Checked again right before the body is
            // replaced, since the wait leaves time for a person to type.
            guard await focused(is: body), hasFocus(body), untouched() else { return nil }
            written.insert(normalized(base))
            guard replaceDocumentText(body, nil, with: base) else { return nil }
            setRange(body, selection)
            try? await Task.sleep(for: .milliseconds(150))
            return range(body) == selection ? body : nil
        }
        func expect(_ base: String, _ selection: NSRange, _ text: String) {
            written.insert(normalized((base as NSString).replacingCharacters(in: selection, with: text)))
        }
        let caret = NSRange(location: 37, length: 0)
        let empty = NSRange(location: 0, length: 0)
        for (text, kind) in [(" Synthetic insertion from Intention.", "plain text"), (Self.insertion, "accented, CJK and emoji text")] {
            expect("", empty, text)
            await editCase(scene, "Mail", version, field, "\(kind): insert into an empty message",
                           base: "", selection: empty, text: text, paste: false, setup: { await setUp("", empty) }, still: untouched)
        }
        expect(Self.text, caret, Self.insertion)
        await editCase(scene, "Mail", version, field, "insert at the caret",
                       base: Self.text, selection: caret, paste: false, setup: { await setUp(Self.text, caret) }, still: untouched)
        let unicodeSelection = NSRange(location: 5, length: 15)
        expect(Self.unicode, unicodeSelection, Self.insertion)
        await editCase(scene, "Mail", version, field, "replace an emoji, ZWJ and combining selection",
                       base: Self.unicode, selection: unicodeSelection, paste: false, setup: { await setUp(Self.unicode, unicodeSelection) }, still: untouched)
        let lines = " First line.\nSecond line."
        expect(Self.text, caret, lines)
        await editCase(scene, "Mail", version, field, "insert two lines",
                       base: Self.text, selection: caret, text: lines, paste: false, setup: { await setUp(Self.text, caret) }, still: untouched)
        let wordInText = NSRange(location: 4, length: 9)
        expect(Self.text, wordInText, lines)
        await editCase(scene, "Mail", version, field, "replace a word with two lines",
                       base: Self.text, selection: wordInText, text: lines, paste: false, setup: { await setUp(Self.text, wordInText) }, still: untouched)
        await editCase(scene, "Mail", version, field, "paste at the caret",
                       base: Self.text, selection: caret, paste: true, setup: { await setUp(Self.text, caret) }, still: untouched)
        await editCase(scene, "Mail", version, field, "paste two lines",
                       base: Self.text, selection: caret, text: lines, paste: true, setup: { await setUp(Self.text, caret) }, still: untouched)
        await mailFormattedSelection(app, version, setUp: setUp, expect: expect, still: untouched)
        await mailDot(app, window, body, version, setUp: setUp)
        await finish()
    }

    /// The dot over the caret in the message body, at the start of the text,
    /// inside a line and on a second line. The caret tracker finds the caret
    /// there from the selection's marker offsets; this reads the caret's
    /// rectangle from the selection markers' bounds, compares it with where
    /// the dot is drawn, and requires Mail's window to be the frontmost
    /// ordinary window there. No picture is taken.
    private func mailDot(_ app: NSRunningApplication, _ window: AXUIElement, _ body: AXUIElement, _ version: String,
                         setUp: (String, NSRange) async -> AXUIElement?) async {
        guard !skipped("mail", "Mail", version, "new message body", "the dot sits over the caret") else { return }
        let text = Self.text + "\nSecond synthetic line."
        var misses: [String] = []
        for location in [0, 37, Self.text.utf16.count + 1 + 6] {
            guard await setUp(text, NSRange(location: location, length: 0)) != nil, let caret = documentCaret(body) else {
                misses.append("offset \(location): setup failed")
                continue
            }
            var placed = false
            for _ in 0..<30 where !placed {
                try? await Task.sleep(for: .milliseconds(50))
                placed = dotCenter().map { abs($0.x - caret.midX) <= 1.5 && $0.y < caret.minY && $0.y > caret.minY - 24 } ?? false
            }
            if !placed {
                misses.append("offset \(location): caret at x \(Int(caret.midX)) y \(Int(caret.minY)), dot "
                    + (dotCenter().map { "at x \(Int($0.x)) y \(Int($0.y))" } ?? "hidden"))
            } else if !shows(window, of: app, at: CGPoint(x: caret.midX, y: caret.midY), anyKind: false) {
                misses.append("offset \(location): Mail's window is not what the screen shows at the caret; in front: "
                    + windowInFront(of: app, at: CGPoint(x: caret.midX, y: caret.midY)))
            }
        }
        record("mail", "Mail", version, "new message body", "the dot sits over the caret", misses.isEmpty,
               notes: misses.isEmpty ? nil : misses.joined(separator: "; "))
    }

    /// The caret's rectangle in a document field, from its selection markers.
    private func documentCaret(_ element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        var rect = CGRect.zero
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &value) == .success, let value,
              let bounds = parameterized(element, "AXBoundsForTextMarkerRange", value), CFGetTypeID(bounds) == AXValueGetTypeID(),
              AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        return rect
    }

    /// Where Intention's dot is drawn, in Accessibility coordinates, or nil
    /// while it is hidden. The dot is one layer on a surface that covers a
    /// screen, in a flipped view.
    private func dotCenter() -> CGPoint? {
        guard let panel = NSApp.windows.first(where: { $0.title == "dot surface" }), panel.alphaValue > 0,
              let dot = panel.contentView?.layer?.sublayers?.first(where: { $0 is CAShapeLayer }), !dot.isHidden,
              let primary = NSScreen.screens.first?.frame.height else { return nil }
        return CGPoint(x: panel.frame.minX + dot.position.x, y: primary - panel.frame.maxY + dot.position.y)
    }

    /// Replaces one word made bold through Mail's own Bold menu item. The
    /// body is put back as plain text afterwards.
    private func mailFormattedSelection(
        _ app: NSRunningApplication, _ version: String,
        setUp: @escaping (String, NSRange) async -> AXUIElement?, expect: (String, NSRange, String) -> Void, still: @escaping @MainActor () -> Bool
    ) async {
        let scene = "mail"
        let field = "new message body, one word bold"
        let check = "replace a bold word"
        guard !skipped(scene, "Mail", version, field, check) else { return }
        let text = "Alpha Beta Gamma"
        let word = NSRange(location: 6, length: 4)
        guard let body = await setUp(text, word), let bold = await menuItem(of: app, titled: "Bold"),
              AXUIElementPerformAction(bold, kAXPressAction as CFString) == .success else {
            record(scene, "Mail", version, field, check, false, notes: "setup failed: the body or Mail's Bold item")
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        expect(text, word, "Synthetic")
        await editCase(scene, "Mail", version, field, check, base: text, selection: word, text: "Synthetic", paste: false,
                       setup: { await self.focused(is: body) && self.range(body) == word ? body : nil },
                       restore: { await setUp(text, word) }, still: still)
    }

    /// Closes the message window and answers Mail's question about saving a
    /// draft with Don't Save. True once the window is gone.
    private func discardMessage(_ window: AXUIElement, of app: AXUIElement) async -> Bool {
        await closeWindow(window)
        for _ in 0..<30 {
            if let open = windows(of: app), !open.contains(where: { CFEqual($0, window) }) { return true }
            for sheet in children(window, kAXChildrenAttribute) where role(sheet) == "AXSheet" {
                if let button = findNow(in: sheet, { self.role($0) == kAXButtonRole
                    && ["Don’t Save", "Don't Save"].contains(self.string($0, kAXTitleAttribute) ?? "") }) {
                    AXUIElementPerformAction(button, kAXPressAction as CFString)
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// The message field of the person's own direct message in Slack, which
    /// only they can see. Opt-in, since Slack is signed in to the person's
    /// workspaces. The person opens that conversation first; the scene stops
    /// unless Slack's front window shows it and its message field is empty.
    /// It does not go there itself: Slack's lists hold the conversation only
    /// once it is looked up by typing, a typed lookup listed nothing to
    /// press, and a `slack://channel` link to it was not followed. Nothing is
    /// sent, and the field is left empty.
    private func slack() async {
        let scene = "slack"
        let field = "message field, own direct message"
        // Slack can take longer to start than `open` waits for it.
        var launched = await open([], with: "com.tinyspeck.slackmacgap")
        if launched == nil { launched = await open([], with: "com.tinyspeck.slackmacgap") }
        guard let app = launched else {
            record(scene, "Slack", "", field, "open Slack", false, notes: "Slack did not come forward")
            return
        }
        let version = app.version
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Electron builds its tree once the caret tracker asks, which can
        // take a few seconds after Slack comes forward.
        var found: (window: AXUIElement, composer: AXUIElement)?
        for _ in 0..<40 where found == nil {
            if let window = children(element, kAXWindowsAttribute).first,
               let composer = findNow(in: window, { self.role($0) == kAXTextAreaRole && (self.label($0) ?? "").hasPrefix("Message to ") }) {
                found = (window, composer)
            } else {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        guard let (window, composer) = found else {
            record(scene, "Slack", version, field, "find the message field", false, notes: "no message field in Slack's front window")
            return
        }
        // The scene cannot open the conversation itself, so another one
        // showing stops it here.
        guard slackShowsOwnConversation(window, composer: composer) else {
            record(scene, "Slack", version, field, "own direct message is open", false,
                   notes: "open the direct message to yourself in Slack, the one marked (you), scrolled to its start, and run the scene again")
            return
        }
        // Everything the scene writes, without the one line break a rich
        // editor keeps at the end. Any other line break counts: an empty
        // line is something a person typed.
        var written: Set<String> = [""]
        func bare(_ text: String) -> String {
            let text = normalized(text)
            return text.hasSuffix("\n") ? String(text.dropLast()) : text
        }
        guard bare(fieldText(composer) ?? "x").isEmpty else {
            record(scene, "Slack", version, field, "message field is empty", false, notes: "the message field holds a draft; clear it and run the scene again")
            return
        }
        // The scene writes and clears only while Slack still shows
        // the person's own conversation and the field holds only text the
        // scene wrote. Every write below asks this first.
        func owned() -> Bool {
            !slackWritePending && slackShowsOwnConversation(window, composer: composer) && written.contains(bare(fieldText(composer) ?? "?"))
        }
        /// Puts `base` alone in the field with `selection`, and returns the
        /// field's text as it then reads.
        func setUp(_ base: String, _ selection: NSRange) async -> String? {
            guard await comeForward(app) else { return nil }
            AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            // No click stands in for a focus request Slack ignores: the
            // case fails instead. Another conversation, or anything a
            // person typed into the field while the scene runs, stops it
            // before the field changes.
            guard await focused(is: composer), owned() else { return nil }
            written.insert(bare(base))
            guard await setSlackText(composer, base, owned: owned), let actual = fieldText(composer) else { return nil }
            setRange(composer, selection)
            try? await Task.sleep(for: .milliseconds(150))
            return range(composer) == selection ? actual : nil
        }
        func run(_ check: String, _ base: String, _ selection: NSRange, _ text: String, paste: Bool = false) async {
            guard !skipped(scene, "Slack", version, field, check) else { return }
            guard let actual = await setUp(base, selection) else {
                record(scene, "Slack", version, field, check, false, notes: "setup failed: \(setupProblem(composer, base: base))")
                return
            }
            written.insert(bare((actual as NSString).replacingCharacters(in: selection, with: text)))
            await editCase(scene, "Slack", version, field, check, base: actual, selection: selection, text: text, paste: paste, anyRoute: !paste,
                           setup: { await self.focused(is: composer) ? composer : nil },
                           restore: { await setUp(base, selection) != nil ? composer : nil }, still: owned)
        }
        let base = "The synthetic note is for Thursday."
        let caret = NSRange(location: 18, length: 0)
        let empty = NSRange(location: 0, length: 0)
        await run("plain text: insert into the empty field", "", empty, "Synthetic insertion from Intention.")
        // Slack turns an emoji into an inline image, so these cases use text
        // without one; the last case shows what an emoji does.
        let accented = " Synthetic insertion: café, 東京."
        await run("accented and CJK text: insert into the empty field", "", empty, accented)
        await run("insert at the caret", base, caret, accented)
        await run("replace a selected word", base, NSRange(location: 4, length: 9), "Synthetic")
        let lines = " First line.\nSecond line."
        await run("insert two lines without sending", base, caret, lines)
        await run("paste at the caret", base, caret, accented, paste: true)
        await run("paste two lines without sending", base, caret, lines, paste: true)
        // Text with an emoji is not run: Slack turns the emoji into an
        // inline image, the result is unknown, and after an unknown result
        // the scene may not clear the field.
        // Leaves the field empty, so no draft stays behind, but only while
        // it holds text the scene wrote and no result was unknown.
        if let stopped {
            record(scene, "Slack", version, field, "message field left empty", false, notes: stopped)
            return
        }
        let ours = owned()
        let cleared = ours ? await setSlackText(composer, "", owned: owned) : false
        record(scene, "Slack", version, field, "message field left empty", cleared,
               notes: cleared ? nil
                   : slackWritePending ? "Slack accepted a value and did not show it, so nothing more was written; check the field by hand"
                   : ours ? "could not clear the scene's text; clear the field by hand" : "the field holds other text, left alone")
    }

    /// Puts `text` alone in Slack's message field, for setting up a case or
    /// clearing it, by setting the field's value. Right before the write the
    /// field must have keyboard focus and `owned` must say it is still the
    /// scene's, holding only text the scene wrote. Where Slack refuses the
    /// value, the scene writes nothing else: it posts no key in the person's
    /// app, and the case or the cleanup records that it failed. A value Slack
    /// accepted and did not show may still land, so nothing more is written
    /// after one. An empty field reads as nothing or as its one placeholder
    /// line break.
    private func setSlackText(_ element: AXUIElement, _ text: String, owned: () -> Bool) async -> Bool {
        guard !slackWritePending else { return false }
        func placeholder(_ text: String) -> String { text.hasSuffix("\n") ? String(text.dropLast()) : text }
        if let current = fieldText(element), placeholder(normalized(current)) == placeholder(normalized(text)) { return true }
        guard hasFocus(element), owned() else { return false }
        let code = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        if await settled(element, text, blankBase: true) { return true }
        if code == .success { slackWritePending = true }
        return false
    }

    /// Whether Slack's window shows the person's own direct message. That
    /// conversation opens with a button naming the person followed by
    /// "(you)", and its message field is addressed to the same name. The
    /// button is in the window only while the start of the conversation is
    /// loaded.
    private func slackShowsOwnConversation(_ window: AXUIElement, composer: AXUIElement) -> Bool {
        let name = (string(composer, kAXDescriptionAttribute) ?? "").dropFirst("Message to ".count).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        let marked = [name + "(you)", name + " (you)"]
        return findNow(in: window, { self.role($0) == kAXButtonRole
            && marked.contains((self.label($0) ?? "").trimmingCharacters(in: .whitespaces)) }) != nil
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private func label(_ element: AXUIElement) -> String? {
        [string(element, kAXDescriptionAttribute), string(element, kAXTitleAttribute), string(element, kAXPlaceholderValueAttribute)]
            .compactMap { $0 }.joined(separator: " ")
    }

    private func textControls(_ window: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let element = queue.removeFirst()
            visited += 1
            if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role(element) ?? ""),
               string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole {
                found.append(element)
            }
            queue.append(contentsOf: children(element, kAXChildrenAttribute))
        }
        return found
    }

    // MARK: - Menu items

    /// The Debug menu item, chosen the way a person would: a click on
    /// Intention's menu bar item, then the arrow keys and Return inside that
    /// menu, posted to Intention only.
    private func menu() async {
        let scene = "menu"
        let field = "NSTextView, plain text document"
        let check = "Insert sample text from the menu bar item"
        let document = output.appendingPathComponent("insertion-\(token)-menu.txt")
        try? Self.text.write(to: document, atomically: true, encoding: .utf8)
        guard let app = await open([document], with: "com.apple.TextEdit"),
              let window = await window(of: app, containing: document.lastPathComponent),
              let area = await find(in: window, { self.role($0) == kAXTextAreaRole }),
              let statusItem = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("StatusBarWindow") })
        else {
            record(scene, "TextEdit", "", field, check, false, notes: "fixture or Intention's menu bar item not found")
            return
        }
        await demo?.include(pid: app.processIdentifier, title: document.lastPathComponent)
        let caret = NSRange(location: 37, length: 0)
        AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        setRange(area, caret)
        guard await focused(is: area) else {
            record(scene, "TextEdit", app.version, field, check, false, notes: "setup failed: focus")
            return
        }
        await demo?.say("TextEdit · Insert sample text from Intention's menu bar item")
        await choose("Insert sample text", in: statusItem)
        let inserted = (Self.text as NSString).replacingCharacters(in: caret, with: AppModel.sampleText)
        let insertedOK = await settled(area, inserted)
        await demo?.say(insertedOK ? "Inserted at the caret" : "The field does not show the sample text", for: 1.8)
        // The document is the check's own; its text goes back before it closes.
        let putBack = await putBack({ self.fieldText(area) }, left: inserted, base: Self.text, blank: false, by: {
            AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, Self.text as CFString)
            return area
        }, still: nil)
        record(scene, "TextEdit", app.version, field, check, insertedOK && putBack == nil,
               notes: [insertedOK ? nil : "insertion did not land", putBack].compactMap { $0 }.joined(separator: "; ").nilIfEmpty)
        await closeWindow(window)
    }

    /// Opens Intention's menu with a click on its menu bar item and picks the
    /// entry with this title, as a person would by typing its first letters
    /// and pressing Return. The entries above it come and go with setup,
    /// permissions and dictation, so its place in the menu is never
    /// counted. The menu tracks on the main thread, so the keys are posted
    /// from another task, to Intention only.
    private func choose(_ title: String, in statusItem: NSWindow) async {
        guard ProcessSafety.allowsCheckInput else { return }
        let top = NSScreen.screens[0].frame.maxY
        let point = CGPoint(x: statusItem.frame.midX, y: top - statusItem.frame.midY)
        let pid = ProcessInfo.processInfo.processIdentifier
        let keys = Task.detached {
            guard ProcessSafety.allowsCheckInput else { return }
            try? await Task.sleep(for: .milliseconds(900))
            let source = CGEventSource(stateID: .privateState)
            // Enough letters to name the entry among the menu's others.
            for character in title.prefix(6) {
                let units = Array(String(character).utf16)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    event?.postToPid(pid)
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
            try? await Task.sleep(for: .milliseconds(350))
            for down in [true, false] {
                CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.postToPid(pid)
            }
            try? await Task.sleep(for: .milliseconds(350))
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        await keys.value
        try? await Task.sleep(for: .milliseconds(300))
    }

    private static func describe(_ result: InsertionResult) -> String {
        switch result {
        case .inserted(.selectedText, _): "Inserted through Accessibility (AXSelectedText)"
        case .inserted(.replaceRange, _): "Inserted through Accessibility (AXReplaceRangeWithText)"
        case .inserted(.textOperation, _): "Inserted through Accessibility (AXTextOperation)"
        case let .inserted(.paste, restored): "Pasted" + (restored == true ? ", clipboard restored" : ", pasted text left on the clipboard")
        default: TextInserter.name(result)
        }
    }

    // MARK: - Clipboard

    /// Recovery and cleanup read through PasteboardOwner off the main
    /// thread, under macOS's clipboard rule. Restore rechecks that read's
    /// count, so a copy made while the file was read stays on the clipboard.
    private func recoverClipboard() async -> Bool {
        do {
            // Discard a partial atomic write even if no full backup exists.
            guard FileManager.default.fileExists(atPath: recoveryFile.url.path) else {
                try recoveryFile.discard()
                return true
            }
            let owner = PasteboardOwner()
            if let outcome = try recoveryFile.recover(current: await owner.backUp(),
                                                      restore: { owner.restore($0, ifUnchangedSince: $1) }) {
                reportClipboard(outcome, scene: "recovery")
                return outcome.mayStartRun
            }
            return true
        } catch {
            record("recovery", "Intention", "", "-", "clipboard recovered", false,
                   notes: "the private clipboard recovery file could not be handled; it was kept and the run did not start")
            return false
        }
    }

    private var clipboardInserters: [TextInserter] {
        var all = [inserter, pasteInserter]
        if let dictation { all.append(dictation.model.inserter) }
        return all
    }

    private func cleanUpClipboard() async {
        let owner = PasteboardOwner()
        do {
            if let outcome = try await clipboardRun.cleanUp(inserters: clipboardInserters,
                sentinels: clipboardSentinels, pastedStrings: ownedClipboardStrings,
                read: { await owner.backUp() }, restore: { owner.restore($0, ifUnchangedSince: $1) }) {
                reportClipboard(outcome, scene: "cleanup")
            }
        } catch {
            record("cleanup", "Intention", "", "-", "clipboard put back", false,
                   notes: "the private clipboard recovery file could not be handled; any remaining backup was kept for the next start")
        }
    }

    private func reportClipboard(_ outcome: InsertionCheckClipboard.Outcome, scene: String) {
        let note: String
        switch outcome {
        case .restored: note = "the saved clipboard was put back"
        case .pastedText: note = "the clipboard holds the checks' pasted text, which an app may still read, so the saved copy was not put back"
        case .newerCopy: note = "the clipboard changed to a later copy, so the saved copy was not put back"
        case .restoreFailed: note = "the saved clipboard could not be put back completely, or another copy arrived before restoration"
        case .invalidBackup: note = "the crash recovery file was unreadable or incomplete, so the clipboard was left alone"
        case .unreadable: note = "the clipboard could not be read or classified safely, so it was left alone"
        case .restorationPending: note = "an inserter still has pending clipboard restoration, so cleanup stopped before reading or changing the clipboard"
        }
        let retained = FileManager.default.fileExists(atPath: recoveryFile.url.path)
        record(scene, "Intention", "", "-", "clipboard put back", outcome == .restored,
               notes: note + (retained
                   ? "; the private backup was kept for retry at the next start; the run stopped"
                   : "; the private backup file has been removed"))
    }

    /// Puts a synthetic sentinel on the clipboard for a case that borrows
    /// it. The clipboard is copied before the first such case, and again
    /// whenever it holds something the checks did not put there: a copy the
    /// person made between cases, which is then what comes back at the end.
    /// False, with the clipboard left alone, when that copy cannot be taken.
    private func placeSentinel() async -> Bool {
        // After a paste that may still be pending the clipboard is not
        // borrowed again: a copy the person makes from then on could be
        // saved and replaced, and never put back.
        guard await clipboardRun.mayPrepareSentinel(inserters: clipboardInserters) else { return false }
        let backup = await PasteboardOwner().backUp()
        guard case let .copied(current) = backup, current.complete else { return false }
        let string = "Intention clipboard sentinel \(UUID().uuidString)"
        ownedClipboardStrings.insert(string)
        clipboardSentinels.insert(string)
        // The sentinel is recorded before it is placed, so even a crash
        // immediately after the clipboard write can recover the saved copy.
        do {
            guard try await clipboardRun.prepareSentinel(current: current,
                ownsCurrent: current.checkString.map(ownedClipboardStrings.contains) ?? false,
                sentinels: clipboardSentinels, currentChangeCount: { NSPasteboard.general.changeCount }) else { return false }
        } catch {
            record("setup", "Intention", "", "-", "temporary clipboard backup saved", false,
                   notes: "the private clipboard recovery file could not be saved; the clipboard was left alone and further borrowing stopped")
            return false
        }
        if externalClipboard {
            let copy = Process()
            copy.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
            let input = Pipe()
            copy.standardInput = input
            try? copy.run()
            input.fileHandleForWriting.write(Data(string.utf8))
            try? input.fileHandleForWriting.close()
            copy.waitUntilExit()
            sentinel = (string, nil)
            return sentinelPlaced(written: nil)
        }
        let data = Data(string.utf8.reversed())
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        item.setData(data, forType: NSPasteboard.PasteboardType("co.intention.insertion-check"))
        pasteboard.writeObjects([item])
        sentinel = (string, data)
        return sentinelPlaced(written: pasteboard.changeCount)
    }

    /// Whether the sentinel just written is on the clipboard. When it is
    /// not, the case sends no paste, and the saved copy goes straight back
    /// over whatever part of the sentinel was written, on two conditions.
    /// No earlier paste in the run may be unconfirmed, since an app could
    /// still read the clipboard. And it goes back only over the checks' own
    /// write: a copy the person made in the meantime is theirs and stays.
    /// Where the checks wrote the clipboard themselves that is its change
    /// count, `written`. Where another process wrote it for them the count
    /// of that write is not known, so the clipboard must hold the checks'
    /// text or nothing.
    private func sentinelPlaced(written: Int?) -> Bool {
        if sentinelRestored() { return true }
        defer {
            if clipboardRun.saved != nil { clipboardRun.stopBorrowing() }
        }
        let pasteboard = NSPasteboard.general
        let own = written.map { pasteboard.changeCount == $0 }
            ?? (clipboardHoldsOwnText() || pasteboard.pasteboardItems?.isEmpty != false)
        if own, !pasteUnconfirmed {
            do {
                let owner = PasteboardOwner()
                if let outcome = try clipboardRun.restoreFailedSentinel(changeCount: pasteboard.changeCount,
                    restore: { owner.restore($0, ifUnchangedSince: $1) }) {
                    reportClipboard(outcome, scene: "cleanup")
                }
            } catch {
                record("cleanup", "Intention", "", "-", "temporary clipboard backup removed", false,
                       notes: "the private clipboard recovery file could not be removed")
            }
        }
        return false
    }

    /// Inserts through `inserter`, and notes a paste that may still be
    /// pending. An unknown paste retains the inserter's clipboard borrow;
    /// an unknown Accessibility write has no borrow. Copies made by other
    /// apps during the call do not tell which route this insertion took.
    private func insert(_ text: String, with inserter: TextInserter) async -> InsertionResult {
        let result = await inserter.insert(text)
        clipboardRun.recordInsertion(result, with: inserter)
        return result
    }

    private func clipboardHoldsOwnText() -> Bool {
        guard let string = NSPasteboard.general.string(forType: .string) else { return false }
        return ownedClipboardStrings.contains(string)
    }

    private func sentinelRestored() -> Bool {
        guard let sentinel, let item = NSPasteboard.general.pasteboardItems?.first,
              NSPasteboard.general.pasteboardItems?.count == 1 else { return false }
        return item.string(forType: .string) == sentinel.string
            && (sentinel.data == nil || item.data(forType: NSPasteboard.PasteboardType("co.intention.insertion-check")) == sentinel.data)
    }

    // MARK: - Apps and windows

    /// Opens `urls` in the app. With `profile`, launches a separate Chrome
    /// instance on that new, empty profile, so no signed-in account or other
    /// tab shares the fixture's window; the caller quits it afterwards.
    private func open(_ urls: [URL], with bundleID: String, profile: URL? = nil) async -> NSRunningApplication? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let profile {
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check"]
        }
        let app: NSRunningApplication? = await withCheckedContinuation { continuation in
            let done: @Sendable (NSRunningApplication?, Error?) -> Void = { app, _ in continuation.resume(returning: app) }
            if urls.isEmpty {
                NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: done)
            } else {
                NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration, completionHandler: done)
            }
        }
        guard let app else { return nil }
        for _ in 0..<50 {
            if frontmost(app) { return app }
            app.activate()
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// A process's command line, to tell an instance the check started.
    /// The command line of `pid`, or nil when it cannot be read: `ps`
    /// then prints nothing or the name in parentheses, and a line that does
    /// not start with the executable's path says nothing about the
    /// process, which a caller must not take for its own instance.
    private static func arguments(of pid: pid_t) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "args=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        ps.waitUntilExit()
        let line = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return line.hasPrefix("/") ? line : nil
    }

    /// Chrome, or Chrome Beta on a Mac that has only that.
    static var chrome: String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") == nil
            && NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome.beta") != nil
            ? "com.google.Chrome.beta" : "com.google.Chrome"
    }

    // MARK: - Dictation

    /// Dictates the recording into the focused `field`: a click on the dot
    /// or Right Option held, alternately unless `trigger` names one, for as
    /// long as the recording plays. Returns the insertion, the wait from the
    /// stop to the text in the field, and the text the endpoint returned.
    private func dictate(_ field: AXUIElement, trigger: String? = nil)
        async -> (result: InsertionResult?, afterStop: Double?, text: String, trigger: String)? {
        guard let (model, playback) = dictation else { return nil }
        dictations += 1
        var click = trigger == nil ? dictations % 2 == 1 : trigger == "a click on the dot"
        var outcome: (result: InsertionResult?, afterStop: Double?, text: String)?
        model.dictation.onOutcome = { result, timing, text in
            self.clipboardRun.recordInsertion(result, with: model.inserter)
            outcome = (result, timing.afterStop, text)
        }
        let began = ContinuousClock.now
        dictationTrace = ["phase \(model.dictation.phase) at start"]
        let note = { [weak self] (event: String) in
            self?.dictationTrace.append("\(event) at \(Int((ContinuousClock.now - began) / .milliseconds(1))) ms")
        }
        let phaseChanged = model.dictation.phaseChanged
        model.dictation.phaseChanged = { phase in
            phaseChanged?(phase)
            note("\(phase)")
        }
        defer {
            model.dictation.onOutcome = nil
            model.dictation.phaseChanged = phaseChanged
        }
        // The dot follows the caret a moment after focus moves.
        var center: CGPoint?
        for _ in 0..<40 where click && center == nil {
            center = model.caretDot.targetCenter
            if center == nil { try? await Task.sleep(for: .milliseconds(50)) }
        }
        // A person reacts to the dot in a few hundred milliseconds at best:
        // click only once it has stayed in one place that long.
        var still = ContinuousClock.now
        for _ in 0..<40 where click && center != nil && ContinuousClock.now - still < .milliseconds(300) {
            try? await Task.sleep(for: .milliseconds(50))
            let now = model.caretDot.targetCenter
            if now != center {
                center = now
                still = ContinuousClock.now
            }
        }
        // No dot over a selection or before the caret is found: the key it is.
        var label = click ? "a click on the dot" : "Right Option"
        if click, center == nil {
            click = false
            label = "Right Option, as no dot was shown to click"
        }
        // A click starts and a second click stops; the key is held between.
        let press = { (down: Bool) async in
            if click, let center = model.caretDot.targetCenter ?? center {
                note((model.caretDot.targetCenter == nil ? "click where the dot was" : "click on the dot") + " (top: \(self.topWindow(at: center)))")
                await self.click(at: center)
            } else {
                note(down ? "Right Option down" : "Right Option up")
                self.holdRightOption(down)
            }
        }
        await press(true)
        try? await Task.sleep(for: playback + .milliseconds(200))
        await press(false)
        for _ in 0..<200 where outcome == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let outcome else {
            note("no outcome; problem \(model.dictation.problem?.rawValue ?? "none")")
            // A dictation still running would land in the next case's field.
            model.dictation.cancel()
            return nil
        }
        return (outcome.result, outcome.afterStop.map { $0 * 1000 }, outcome.text, label)
    }

    /// The owner, title and layer of the frontmost window at `point`, in
    /// AppKit screen coordinates, for a click that went nowhere.
    private func topWindow(at point: CGPoint) -> String {
        let top = NSScreen.screens[0].frame.maxY
        let location = CGPoint(x: point.x, y: top - point.y)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0).contains(location),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            return "\(window[kCGWindowOwnerName as String] ?? "?") '\(window[kCGWindowName as String] ?? "")' layer \(window[kCGWindowLayer as String] ?? "?")"
        }
        return "none"
    }

    /// A left click at `point`, in AppKit screen coordinates, after moving
    /// the pointer there as a person would; a click posted where the pointer
    /// has not been can reach the window that was under it before.
    private func click(at point: CGPoint) async {
        guard ProcessSafety.allowsCheckInput else { return }
        let top = NSScreen.screens[0].frame.maxY
        let location = CGPoint(x: point.x, y: top - point.y)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(80))
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    /// Right Option going down or up, as the keyboard posts it.
    private func holdRightOption(_ down: Bool) {
        guard ProcessSafety.allowsCheckInput else { return }
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 61, keyDown: down) else { return }
        event.type = .flagsChanged
        // The option flag and the right-hand device bit (NX_DEVICERALTKEYMASK).
        event.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40) : []
        event.post(tap: .cghidEventTap)
    }

    private func frontmost(_ app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private func activate(_ app: NSRunningApplication) -> Bool {
        app.activate()
        return frontmost(app)
    }

    /// Whether the scene's own window is what the screen shows at `point`, in
    /// Accessibility coordinates: the frontmost window there, apart from
    /// Intention's own, is an ordinary window of the app with that window's
    /// frame. Another window of the same app, a window on another desktop or
    /// one behind another app's are not. For a click, `anyKind` also counts
    /// windows above the ordinary ones, such as a panel floating over the
    /// point, since a click could land on one. Without it they are passed
    /// over, as the see-through overlay a writing assistant lays over a text
    /// field must be when asking what a person sees there.
    private func shows(_ window: AXUIElement, of app: NSRunningApplication, at point: CGPoint, anyKind: Bool = true) -> Bool {
        guard let frame = frame(window) else { return false }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for entry in windows {
            guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ProcessInfo.processInfo.processIdentifier,
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.contains(point) else { continue }
            let ordinary = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
            if !ordinary, !anyKind { continue }
            return pid == app.processIdentifier && ordinary
                && abs(bounds.minX - frame.minX) <= 1 && abs(bounds.minY - frame.minY) <= 1
                && abs(bounds.width - frame.width) <= 1 && abs(bounds.height - frame.height) <= 1
        }
        return false
    }

    /// The frontmost window at `point` apart from Intention's own, as its layer,
    /// size and whether the app owns it, for a check that found the wrong one.
    /// Never the owner's name: a report carries no app identities.
    private func windowInFront(of app: NSRunningApplication, at point: CGPoint) -> String {
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for entry in windows {
            guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ProcessInfo.processInfo.processIdentifier,
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.contains(point) else { continue }
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            return "layer \(layer), \(Int(bounds.width)) by \(Int(bounds.height)), \(pid == app.processIdentifier ? "the app's own" : "another process's")"
        }
        return "none"
    }

    /// Whether the element has keyboard focus right now, without waiting.
    private func hasFocus(_ element: AXUIElement) -> Bool {
        focusedElement().map { CFEqual($0, element) } ?? false
    }

    /// Brings the app forward and waits for it. macOS grants the request
    /// late while another app is still launching.
    private func comeForward(_ app: NSRunningApplication) async -> Bool {
        for _ in 0..<30 {
            if frontmost(app) { return true }
            app.activate()
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func window(of app: NSRunningApplication, containing title: String) async -> AXUIElement? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for _ in 0..<100 {
            for window in children(element, kAXWindowsAttribute) where string(window, kAXTitleAttribute)?.contains(title) == true {
                return window
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func closeWindow(_ window: AXUIElement) async {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &value) == .success,
              let button = value, CFGetTypeID(button) == AXUIElementGetTypeID() else { return }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        try? await Task.sleep(for: .milliseconds(500))
    }

    private func menuItem(of app: NSRunningApplication, titled title: String) async -> AXUIElement? {
        var value: CFTypeRef?
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard AXUIElementCopyAttributeValue(element, kAXMenuBarAttribute as CFString, &value) == .success, let bar = value,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        return await find(in: bar as! AXUIElement, { self.string($0, kAXTitleAttribute) == title && self.role($0) == kAXMenuItemRole })
    }

    // MARK: - Accessibility reads, independent of TextInserter

    /// Generous waits: a busy Mac can take seconds to expose a page's tree.
    private func find(in root: AXUIElement, _ match: @escaping (AXUIElement) -> Bool, timeout: Duration = .seconds(6)) async -> AXUIElement? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let found = findNow(in: root, match) { return found }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    private func findNow(in root: AXUIElement, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < 4000 {
            let element = queue.removeFirst()
            visited += 1
            if match(element) { return element }
            queue.append(contentsOf: children(element, kAXChildrenAttribute))
        }
        return nil
    }

    /// An app's windows, or nil when it does not answer. A scene that tells
    /// its own window from the person's by this list must not take silence
    /// for no windows.
    private func windows(of app: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return nil }
        return array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    /// An app's windows once the list has stayed the same for a second, or
    /// nil when it does not within ten.
    private func settledWindows(of app: AXUIElement) async -> [AXUIElement]? {
        var last: [AXUIElement]?
        var steady = 0
        for _ in 0..<40 {
            let now = windows(of: app)
            let same = now != nil && now?.count == last?.count
                && zip(now ?? [], last ?? []).allSatisfy { CFEqual($0, $1) }
            steady = same ? steady + 1 : 0
            if steady >= 4, let now { return now }
            last = now
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return [] }
        return array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func intValue(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private func role(_ element: AXUIElement) -> String? { string(element, kAXRoleAttribute) }
    private func domID(_ element: AXUIElement) -> String? { string(element, "AXDOMIdentifier") }
    private func read(_ element: AXUIElement) -> String? { string(element, kAXValueAttribute) }

    /// A field's whole text. An empty field in some apps, such as a new
    /// note, answers no value and zero characters.
    private func fieldText(_ element: AXUIElement) -> String? {
        if isDocument(element) { return documentText(element) }
        return read(element) ?? (intValue(element, kAXNumberOfCharactersAttribute) == 0 ? "" : nil)
    }

    // A web area that is itself the editable text, as Mail's message body
    // is, answers an empty value and no selection range. The checks read it
    // through text markers: its text as the string between its first and
    // last marker, and its selection from the lengths of marker ranges. The
    // inserter reads the same field by AXStringForRange and marker indexes.

    private func isDocument(_ element: AXUIElement) -> Bool { role(element) == "AXWebArea" }

    private func marker(_ element: AXUIElement, _ attribute: String) -> AXTextMarker? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXTextMarkerGetTypeID() else { return nil }
        return (value as! AXTextMarker)
    }

    private func parameterized(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success ? value : nil
    }

    private func documentText(_ element: AXUIElement) -> String? {
        guard let start = marker(element, "AXStartTextMarker"), let end = marker(element, "AXEndTextMarker") else { return nil }
        return parameterized(element, "AXStringForTextMarkerRange", AXTextMarkerRangeCreate(nil, start, end)) as? String
    }

    private func documentRange(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXTextMarkerRangeGetTypeID(), let start = marker(element, "AXStartTextMarker") else { return nil }
        let selection = value as! AXTextMarkerRange
        let lead = AXTextMarkerRangeCreate(nil, start, AXTextMarkerRangeCopyStartMarker(selection))
        guard let location = parameterized(element, "AXLengthForTextMarkerRange", lead) as? NSNumber,
              let length = parameterized(element, "AXLengthForTextMarkerRange", selection) as? NSNumber else { return nil }
        return NSRange(location: location.intValue, length: length.intValue)
    }

    private func documentMarkers(_ element: AXUIElement, _ range: NSRange) -> AXTextMarkerRange? {
        guard let start = parameterized(element, "AXTextMarkerForIndex", range.location as CFNumber),
              let end = parameterized(element, "AXTextMarkerForIndex", NSMaxRange(range) as CFNumber),
              CFGetTypeID(start) == AXTextMarkerGetTypeID(), CFGetTypeID(end) == AXTextMarkerGetTypeID() else { return nil }
        return AXTextMarkerRangeCreate(nil, start as! AXTextMarker, end as! AXTextMarker)
    }

    /// The checks' own write into a document field, for setting up and
    /// clearing Mail's message body. A nil range is the whole text.
    private func replaceDocumentText(_ element: AXUIElement, _ range: NSRange?, with text: String) -> Bool {
        var markers: AXTextMarkerRange?
        if let range {
            markers = documentMarkers(element, range)
        } else if let start = marker(element, "AXStartTextMarker"), let end = marker(element, "AXEndTextMarker") {
            markers = AXTextMarkerRangeCreate(nil, start, end)
        }
        guard let markers else { return false }
        let operation = [
            "AXTextOperationType": "TextOperationReplacePreserveCase" as CFString,
            "AXTextOperationMarkerRanges": [markers] as CFArray,
            "AXTextOperationReplacementString": text as CFString,
            "AXTextOperationSmartReplace": kCFBooleanFalse!,
        ] as CFDictionary
        return parameterized(element, "AXTextOperation", operation) != nil
    }

    private func range(_ element: AXUIElement) -> NSRange? {
        if isDocument(element) { return documentRange(element) }
        var value: CFTypeRef?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cfRange, &range)
        else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func setRange(_ element: AXUIElement, _ range: NSRange) {
        if isDocument(element) {
            if let markers = documentMarkers(element, range) {
                AXUIElementSetAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, markers)
            }
            return
        }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return }
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    }

    private func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func focused(is element: AXUIElement) async -> Bool {
        for _ in 0..<40 {
            if let focused = focusedElement(), CFEqual(focused, element) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Waits briefly for the field to show `expected`, since browsers apply
    /// edits asynchronously. When the field started blank, rich editors may
    /// keep or drop one placeholder line break at the end, so that one is
    /// ignored. Any other line break is an empty line and counts.
    private func settled(_ element: AXUIElement, _ expected: String, blankBase: Bool = false) async -> Bool {
        await settled({ self.fieldText(element) }, expected, blankBase: blankBase)
    }

    private func settled(_ text: @MainActor () -> String?, _ expected: String, blankBase: Bool = false) async -> Bool {
        func shown(_ text: String) -> String {
            let text = normalized(text)
            return blankBase && text.hasSuffix("\n") ? String(text.dropLast()) : text
        }
        for _ in 0..<20 {
            if let text = text(), shown(text) == shown(expected) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Web editors write U+00A0 where two spaces meet; compare it as a space.
    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: - Report

    /// Records one check; `passed` is nil for a scene that did not run.
    private func record(
        _ scene: String, _ app: String, _ version: String, _ field: String, _ check: String, _ passed: Bool?,
        insertion: String? = nil, insertMilliseconds: Double? = nil, notes: String? = nil
    ) {
        let status = passed.map { $0 ? "pass" : "fail" } ?? "not run"
        results.append(Result(scene: scene, app: app, appVersion: version, field: field, check: check, status: status,
                              insertion: insertion, insertMilliseconds: insertMilliseconds, notes: notes))
        print("\(status.uppercased()) \(scene) | \(field) | \(check) | \(insertion ?? "-")\(notes.map { " | \($0)" } ?? "")")
    }

    private func write(started: Date) {
        var access: Int?
        if #available(macOS 15.4, *) { access = NSPasteboard.general.accessBehavior.rawValue }
        let report = Report(macOS: ProcessInfo.processInfo.operatingSystemVersionString, startedAt: started,
                            clipboardAccess: access, externalClipboard: externalClipboard,
                            clipboardReadable: clipboardReadable, results: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(report).write(to: output.appendingPathComponent("insertion-checks.json"))
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        (ContinuousClock.now - start) / .milliseconds(1)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension NSRunningApplication {
    var version: String {
        guard let url = bundleURL, let bundle = Bundle(url: url) else { return "" }
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}
/// Records one window of another app, cropped to a region, with Intention's
/// own dot panels drawn in, as a run of PNG frames at about eight a second
/// for the before and after pictures of the Gmail check. Nothing else of
/// the screen is in a frame: the content filter names that window and
/// Intention's own, and the crop keeps to `region`.
@MainActor
private final class WindowRecorder {
    private var task: Task<Int, Never>?
    /// The PNG writes still running, awaited by `stop` so no frame is lost
    /// when the checks exit right after the last case.
    private var writes: [Task<Void, Never>] = []

    /// Captures until `stop`, asking `region` for the crop before each
    /// frame and skipping the frame when it answers nil.
    func start(window wid: CGWindowID, pid: pid_t, region: @escaping @MainActor () -> CGRect?, into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let own = ProcessInfo.processInfo.processIdentifier
        task = Task { @MainActor in
            var index = 0
            let began = ContinuousClock.now
            while !Task.isCancelled {
                if let crop = region(), let image = await Self.capture(window: wid, pid: pid, own: own, region: crop) {
                    index += 1
                    let elapsed = began.duration(to: .now)
                    let name = String(format: "frame-%04d-%06.0fms.png", index, Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                    let url = directory.appendingPathComponent(name)
                    // Encoded off the main actor, which the dot's panels and the scene's timings share.
                    writes.append(Task.detached(priority: .utility) { Self.write(image, to: url) })
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
            return index
        }
    }

    /// Ends the recording, waits for every frame's write and answers how
    /// many frames were captured.
    func stop() async -> Int {
        task?.cancel()
        let frames = await task?.value ?? 0
        task = nil
        for write in writes { await write.value }
        writes = []
        return frames
    }

    private static func capture(window wid: CGWindowID, pid: pid_t, own: pid_t, region: CGRect) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
              let target = content.windows.first(where: { $0.windowID == wid && $0.owningApplication?.processID == pid }),
              let display = content.displays.first(where: { $0.frame.intersects(region) }) else { return nil }
        let windows = [target] + content.windows.filter { $0.owningApplication?.processID == own && $0.title?.hasPrefix("dot ") == true }
        let filter = SCContentFilter(display: display, including: windows)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        let crop = region.intersection(display.frame)
        configuration.sourceRect = crop.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = Int(crop.width * scale)
        configuration.height = Int(crop.height * scale)
        configuration.captureResolution = .best
        configuration.ignoreShadowsDisplay = true
        configuration.showsCursor = false
        guard configuration.width > 0, configuration.height > 0 else { return nil }
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    nonisolated private static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

#endif
