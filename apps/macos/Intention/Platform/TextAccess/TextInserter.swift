import AppKit
import ApplicationServices

/// How text reached a field.
enum InsertionMethod: String, Sendable {
    /// Sets the field's selected text. Native AppKit text honours it.
    case selectedText
    /// AXReplaceRangeWithText at the selection. Safari and Chrome report
    /// AXSelectedText as settable, accept the write and ignore it, so fields
    /// in web content use this instead.
    case replaceRange
    /// WebKit's AXTextOperation over the selection's text markers, for a web
    /// area that is itself the editable text, such as Mail's message body.
    /// AXReplaceRangeWithText there ignores its range and writes at the start
    /// of the message.
    case textOperation
    /// Command-V with the text on the clipboard, for fields that refuse or
    /// lack an Accessibility write.
    case paste
}

/// Why an insertion stopped or could not be confirmed. Fixed names, safe to
/// log.
enum EditReason: String, Error, Sendable {
    case permissionMissing, nothingToInsert, busy
    /// Nothing has keyboard focus, or the focus is not editable text.
    case noTextField
    /// Intention's own windows, which show their own words, as setup's last
    /// page does.
    case ownApp
    case secureField
    case targetUnresponsive
    case focusChanged
    /// The field's text or selection changed before the write.
    case fieldChanged
    case pasteUnavailable
    /// The clipboard changed while a paste was using it: while Intention was
    /// copying it, before Intention's write, after it or before the paste key.
    /// Nothing was pasted, and the copy that changed it is left alone.
    case clipboardBusy
    /// A caller's `FocusedField.stillCurrent` found that the field no longer
    /// belongs to what the caller captured, such as a compose window now
    /// showing another message.
    case composeChanged
    /// The field shows something other than the expected result.
    case readbackMismatch
    /// The write was issued but the field did not show it in time.
    case writeUnconfirmed
    /// The field's text cannot be read, so the paste was sent unverified.
    case unreadableField
    case appEnded
    /// An earlier insertion's Accessibility write into this field, whose
    /// effect is unknown, has not shown there. It may still land, after
    /// anything written now or over it, so nothing was written, and nothing
    /// will be while that field stays as it is. See `UnsettledWrite`.
    case earlierUnsettled
    /// An earlier insertion's Accessibility write into a web field whose
    /// object is gone, so whose field cannot be told, has not shown in this
    /// page, or in this window where the page's object is gone too. It may
    /// still land here, so nothing was written; ten seconds after that
    /// write, text goes in again. See `UnsettledWrite`.
    case earlierUnsettledNearby
}

enum InsertionResult: Equatable, Sendable {
    /// The field shows the text. `clipboardRestored` is nil when the
    /// clipboard was not used.
    case inserted(InsertionMethod, clipboardRestored: Bool?)
    /// Nothing was written.
    case notInserted(EditReason)
    /// A write was issued and its effect is not known. Check the field. After
    /// a paste, the text stays on the clipboard for
    /// `TextInserter.lateReadWindow`, then the person's own goes back, and
    /// the next insertion waits until then. After an Accessibility write,
    /// every insertion into the field it went to is refused
    /// (`earlierUnsettled`) until something shows the write cannot land
    /// later, and where that field's object goes, into its page or window
    /// for up to ten seconds after the write (`earlierUnsettledNearby`);
    /// see `UnsettledWrite`.
    case unknown(EditReason)
}

/// Carries one insertion's confirmation from the Accessibility executor to
/// its caller, before the main-actor handoff or clipboard restoration.
final class InsertionConfirmation: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> ContinuousClock.Instant
    private var instant: ContinuousClock.Instant?

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    var confirmedAt: ContinuousClock.Instant? { lock.withLock { instant } }

    fileprivate func record() {
        let observed = now()
        lock.withLock {
            if instant == nil { instant = observed }
        }
    }
}

/// Puts text at the caret of the field the person is typing in, in another
/// app.
///
/// An insertion targets whatever has keyboard focus when it starts, in any
/// app, and replaces the selection if there is one. It writes through
/// Accessibility and reads the field back to confirm the text landed. A
/// field that refuses the write or offers none gets a paste instead, and so
/// does text Intention cannot read or confirm, whose outcome is then unknown.
/// It refuses only a secure field, focus on something that is not text, and
/// Intention's own windows; `FieldAccess.focusedTarget` says how each is told.
/// A write the field accepted but did not show is reported unknown and never
/// followed by a paste, since it could still land; that field is remembered
/// and, once the write has shown, gets a paste. Words equal to the selected
/// text are already there, so nothing is written for them. It never presses
/// Return or anything that could send.
///
/// Every insertion goes in after the one before has settled, however far
/// apart the two are, so text never lands out of order. After a paste no
/// field showed, whose app may still read the clipboard, the next
/// insertion writes and pastes nothing until that paste's
/// `lateReadWindow` has passed and the person's clipboard is back. After
/// an Accessibility write whose effect is unknown, every insertion into
/// the field it went to is refused with `earlierUnsettled` until something
/// shows that write cannot land later (`UnsettledWrite`): it may still
/// land, after the later text or over it. No time ends that, and nothing
/// watches for it in between. Where a web field's object is gone, its page
/// or window is held instead, for up to `webScopeHold`.
///
/// Intention offers no undo of its own. A person who wants the text gone uses
/// the receiving app's own editing, and Intention never sends that app's
/// Command-Z. Nothing read from the field is kept once the insertion
/// returns.
///
/// One insertion runs at a time. Accessibility calls run on the
/// inserter's own executor; the clipboard is touched only on the main actor,
/// apart from its change count, read on the executor right before the paste
/// key.
@MainActor
final class TextInserter {
    private let executor = AccessibilityExecutor(capacity: 2)
    /// Notice snapshots must never wait behind insertion jobs. Executors keep
    /// their threads alive, so ordinary insertion starts no unused snapshot thread.
    lazy var proposalSnapshotExecutor = AccessibilityExecutor(capacity: 2)
    private let pasteboard: PasteboardOwner
    private var busy = false
    /// The wait, after the latest paste no field showed, until its app can
    /// no longer read the clipboard and the person's copy is back. The next
    /// insertion waits for it.
    private var lateRestoring: Task<Void, Never>?
    /// Accessibility writes whose effect is unknown and that may still
    /// land, each holding the field it went to; see `UnsettledWrite`.
    private var unsettled: [UnsettledWrite] = []
    /// The fields recent insertions showed their text in, and when each was
    /// known to, most recent last, for `showedText`. Compared only on the
    /// executor.
    private var shownIn: [(element: AXElement, pid: pid_t, started: UInt64?, at: ContinuousClock.Instant)] = []
    /// Fields that accepted an Accessibility write and did not show it, most
    /// recent last. Further insertions into them go straight to the paste
    /// route. Kept per field, since one editor in a browser tab says nothing
    /// about the rest of the browser. Compared only on the executor.
    private var ignoringFields: [AXElement] = []
    #if DEBUG
    /// Sends every insertion through the paste route, so the insertion
    /// checks can exercise it in fields that take Accessibility writes.
    var pasteOnly = false

    /// The Debug checks must let every pending clipboard borrow end before cleanup.
    var clipboardRestorationPending: Bool { pasteboard.borrowed }
    #endif

    init(pasteboard: PasteboardOwner = PasteboardOwner()) {
        self.pasteboard = pasteboard
    }

    // MARK: - Insertion

    /// Starts reading, on the inserter's executor and before this returns,
    /// the field that has keyboard focus, with up to
    /// `FieldEdit.contextLength` UTF-16 units before its caret. A dictation
    /// reads this at its trigger, so its text goes only to the field the
    /// person was in and can continue the text before it. The read fails
    /// with why text could not go there, such as `secureField`, and reports
    /// when the app said which element had focus, since a late answer may
    /// name a field the person moved to since.
    func readFocusedField() -> FieldRead {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let read = FieldRead()
        let queued = executor.submit { _ in
            var answered: ContinuousClock.Instant?
            let field = FieldAccess.focusedField(ownPID: ownPID) { answered = $0 }
            read.finish(field, began: answered)
        }
        if !queued { read.finish(.failure(.busy), began: nil) }
        return read
    }

    /// Inserts `text` at the caret of the focused field. With `field`, only
    /// while that same field still has focus; anywhere else it refuses with
    /// `focusChanged` and writes nothing. A field that carries
    /// `stillCurrent` is also asked before anything is written or pasted,
    /// and a reason it gives ends the insertion as `notInserted` with that
    /// reason. It first waits out an earlier unconfirmed paste's
    /// `lateReadWindow`, and while an earlier Accessibility write into the
    /// same field may still land it refuses with `earlierUnsettled`; see
    /// `UnsettledWrite`.
    ///
    /// `linkEmailFooter` is for accepted emails only. An exact terminal server
    /// footer offers HTML and the unchanged plain text together through paste.
    ///
    /// `finalCheck` is the caller's last word, asked on the executor right
    /// before each Accessibility write and the paste key, after every
    /// check of the field, so nothing is read between its answer and the
    /// write. It must read nothing of any app: an accepted reply proposal
    /// passes its cancellation latch and its deadline, which can change
    /// while the field's own checks wait on the app. A reason it gives
    /// ends the insertion as `notInserted` with that reason.
    func insert(_ text: String, into field: FocusedField? = nil, linkEmailFooter: Bool = false, finalCheck: FocusedField.Guard? = nil) async -> InsertionResult {
        await insert(text, into: field, spaced: false, linkEmailFooter: linkEmailFooter, finalCheck: finalCheck).result
    }

    /// `insert`, for words the server spaced for a caret that may have
    /// moved since, such as a dictation's that waited for an earlier one's
    /// text to go in. With `spaced`, `text` gets the one space it needs
    /// after the text before the caret as the write itself reads it
    /// (`FieldEdit.spaced`), on the executor, so no separate read can
    /// space it for another place. A field whose text cannot be read takes
    /// `text` as it is. Answers with the text as it was written, or as it
    /// came when nothing could be.
    func insert(_ text: String, into field: FocusedField? = nil, spaced: Bool, linkEmailFooter: Bool = false,
                finalCheck: FocusedField.Guard? = nil,
                destination: (@Sendable (String?, String) -> Void)? = nil,
                confirmation: InsertionConfirmation? = nil) async -> (result: InsertionResult, text: String) {
        guard FieldEdit.insertable(text) else { return (.notInserted(.nothingToInsert), text) }
        guard !busy else { return (.notInserted(.busy), text) }
        busy = true
        defer { busy = false }
        let started = ContinuousClock.now
        // The app an earlier unconfirmed paste went to may read the
        // clipboard until that paste's window ends. Nothing is pasted or
        // written before then, nor before the person's copy is back, so that
        // app reads the earlier text, never this, and the earlier text
        // lands first. Waiting is safe: after the window nothing more reads
        // the clipboard. It is bounded by `lateReadWindow`.
        if let restoring = lateRestoring {
            await restoring.value
            lateRestoring = nil
        }
        let inserted = await insertNow(text, into: field, spaced: spaced, linkEmailFooter: linkEmailFooter, finalCheck: finalCheck,
                                       destination: destination, confirmation: confirmation)
        AppLog.edit("insert.\(Self.name(inserted.result))", since: started)
        return inserted
    }

    private func insertNow(_ text: String, into field: FocusedField?, spaced: Bool, linkEmailFooter: Bool,
                           finalCheck: FocusedField.Guard?,
                           destination: (@Sendable (String?, String) -> Void)?,
                           confirmation: InsertionConfirmation?) async -> (result: InsertionResult, text: String) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let skip = ignoringFields
        let held = unsettled
        #if DEBUG
        let pasteOnly = pasteOnly
        #else
        let pasteOnly = false
        #endif
        let direct = await run { () -> (FieldAccess.DirectInsertion, String, [UUID], [UUID], [UUID]) in
            var text = text
            var settled: [UUID] = [], expired: [UUID] = [], collapsed: [UUID] = []
            let outcome = FieldAccess.insertDirectly(&text, ownPID: ownPID, ignoringFields: skip, unsettled: held, settled: &settled,
                                                     expired: &expired, collapsed: &collapsed, pasteOnly: pasteOnly || (linkEmailFooter && EmailFooter(text) != nil), expected: field, spaced: spaced,
                                                     finalCheck: finalCheck, destination: destination)
            switch outcome {
            case .shown, .finished(.inserted): confirmation?.record()
            default: break
            }
            return (outcome, text, settled, expired, collapsed)
        }
        // An issued caret change's hold survives any refusal of the later insertion,
        // across attempts, including the paste route's final checks. WebKit
        // can reselect the earlier words while those checks run, so dropping
        // the hold then would let the following insertion replace them.
        // Retire it only once the later text was issued or already shown.
        // Other settled holds and timed page/window holds keep their rule.
        if let (_, _, _, _, collapsed) = direct {
            for id in collapsed {
                if let index = unsettled.firstIndex(where: { $0.id == id }) { unsettled[index].caretCollapses += 1 }
            }
        }
        var laterIssuedOrShown = false
        defer {
            if let (_, _, settled, expired, _) = direct {
                unsettled.removeAll {
                    expired.contains($0.id) || (settled.contains($0.id) && ($0.caretCollapses == 0 || laterIssuedOrShown))
                }
            }
        }
        if let (_, _, _, expired, _) = direct {
            for write in unsettled where expired.contains(write.id) { AppLog.edit("hold.webScopeExpired", since: write.issued) }
        }
        let written = direct?.1 ?? text
        switch direct?.0 {
        case nil:
            return (.notInserted(.busy), written)
        case let .finished(outcome):
            if case .notInserted = outcome {} else { laterIssuedOrShown = true }
            return (outcome, written)
        case let .shown(target):
            laterIssuedOrShown = true
            noteShown(in: target)
            return (.inserted(target.method, clipboardRestored: nil), written)
        case let .unsettled(write, reason):
            laterIssuedOrShown = true
            // A field that accepted a write and did not show it is pasted
            // into once the write has shown.
            if reason == .writeUnconfirmed { ignoringFields = Array((ignoringFields + [write.element]).suffix(8)) }
            unsettled.append(write)
            return (.unknown(reason), written)
        case let .needsPaste(target):
            let pasted = target.lineBreaksAsSpaces ? FieldEdit.oneLine(written) : written
            let footer = linkEmailFooter && !target.lineBreaksAsSpaces ? EmailFooter(pasted) : nil
            let inserted = await paste(pasted, footer: footer, into: target, stillCurrent: field?.stillCurrent,
                                       finalCheck: finalCheck, confirmation: confirmation)
            if case .notInserted = inserted.result { return (inserted.result, written) }
            laterIssuedOrShown = true
            return inserted
        }
    }

    /// Selects the whole text of the field `expecting` names, and only
    /// while that same element of that launch of its app has focus, for a
    /// reply proposal accepted after the person typed in its body: the
    /// insertion that follows replaces the selection, so the proposal
    /// takes the place of everything in the body, and the app's own
    /// Command-Z brings the typed text back. Nothing is written; the
    /// selection is the one change. It is made, as a write is, only after
    /// an earlier paste's late-read window has passed, only while no
    /// earlier write may still land in the field, and only after the field
    /// and its ancestors answer that they are not secure and `finalCheck`
    /// answers nil, right before the selection is set. Answers the range
    /// the field reports selected afterwards, which the caller's next read
    /// must find, or why nothing was selected.
    func selectWholeField(expecting: ExpectedFocus, finalCheck: FocusedField.Guard?) async -> Result<FieldRange, EditReason> {
        guard !busy else { return .failure(.busy) }
        busy = true
        defer { busy = false }
        let started = ContinuousClock.now
        if let restoring = lateRestoring {
            await restoring.value
            lateRestoring = nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let held = unsettled
        let selected = await run {
            FieldAccess.selectWhole(ownPID: ownPID, expecting: expecting, unsettled: held, finalCheck: finalCheck)
        } ?? .failure(.busy)
        switch selected {
        case .success: AppLog.edit("selectWhole.selected", since: started)
        case let .failure(reason): AppLog.edit("selectWhole.\(reason.rawValue)", since: started)
        }
        return selected
    }

    /// Whether text an insertion put into `field`'s element, in the same
    /// launch of its app, was known to show there after `since`. A
    /// dictation that waited for earlier ones asks it of the field it
    /// noted at its start, to tell its own field's text before the caret
    /// moving because an earlier dictation's text went in from anything
    /// else changing it.
    func showedText(in field: FocusedField, since: ContinuousClock.Instant) async -> Bool {
        let candidates = shownIn.filter { $0.pid == field.pid && $0.started == field.started && $0.at > since }.map(\.element)
        guard !candidates.isEmpty else { return false }
        let element = field.element
        return await run { candidates.contains { $0.sameElement(as: element) } } ?? false
    }

    /// Notes that an insertion's text shows in `target`, now.
    private func noteShown(in target: FieldTarget) {
        shownIn = Array((shownIn + [(target.element, target.pid, target.started, .now)]).suffix(8))
    }

    private func paste(_ text: String, footer: EmailFooter?, into target: FieldTarget, stillCurrent: FocusedField.Guard?,
                       finalCheck: FocusedField.Guard?, confirmation: InsertionConfirmation?) async -> (result: InsertionResult, text: String) {
        // Checked before the clipboard is touched, since it may not be
        // restorable, and again just before the key, after the wait for
        // the clipboard's copy. The caller's guard is asked in both: a
        // compose that already changed must not cost the person a
        // clipboard Intention could not read and so cannot put back.
        switch await run({ FieldAccess.recheck(target, stillCurrent: stillCurrent) }) {
        case nil: return (.notInserted(.busy), text)
        case let reason??: return (.notInserted(reason), text)
        case .some(nil): break
        }
        let keyCode = KeyEvents.pasteKeyCode()
        pasteboard.borrow()
        defer { pasteboard.giveBack() }
        let backup = await pasteboard.backUp()
        if case .changing = backup { return (.notInserted(.clipboardBusy), text) }
        let snapshot = backup.snapshot
        let written: Int
        switch pasteboard.writeTransient(text, html: footer?.html, ifUnchangedSince: snapshot?.changeCount) {
        case let .written(changeCount): written = changeCount
        case .changed: return (.notInserted(.clipboardBusy), text)
        case .failed:
            // Back only over Intention's own cleared clipboard, never over a
            // copy made since. A write fails when another app cleared the
            // clipboard after Intention, and that app's copy is then left as
            // it is; this write lands only when Intention's clearing is still
            // the latest.
            if let snapshot { pasteboard.putBack(snapshot) }
            return (.notInserted(.pasteUnavailable), text)
        }
        // Whether the copy goes back whole, unless something was copied
        // since. A copy that could not be read whole never goes back whole,
        // so it says not.
        let putBack = { snapshot.map { self.pasteboard.restore($0, ifUnchangedSince: written) } ?? false }
        let stillHolds = pasteboard.stillHolds(written)
        switch await run({
            let outcome = FieldAccess.paste(text, alternativeText: footer?.renderedText, into: target, keyCode: keyCode, stillCurrent: stillCurrent, finalCheck: finalCheck, clipboardHolds: stillHolds)
            if case .landed = outcome { confirmation?.record() }
            return outcome
        }) {
        case nil:
            _ = putBack()
            return (.notInserted(.busy), text)
        case let .notSent(reason):
            // No key was posted, so nothing can still read the clipboard.
            // After `clipboardBusy` the clipboard holds a newer copy, which
            // `restore` leaves alone, as it does any copy made since.
            _ = putBack()
            return (.notInserted(reason), text)
        case let .landed(confirmedText):
            noteShown(in: target)
            return (.inserted(.paste, clipboardRestored: putBack()), confirmedText)
        case let .unconfirmed(reason):
            // The app may still read the clipboard, so restoring now could
            // paste the person's own clipboard. It goes back once the app has
            // had `lateReadWindow` to read it, and other clipboard writes
            // and the next insertion wait until then. Wispr Flow puts the
            // clipboard back half a second after every paste; a paste no
            // field shows waits longer.
            putBackLater(snapshot, over: written)
            return (.unknown(reason), text)
        }
    }

    /// Holds the clipboard for `lateReadWindow`, while the app a paste went
    /// to may still read it, and then puts `snapshot` back over Intention's
    /// write numbered `written`, unless something was copied since.
    private func putBackLater(_ snapshot: PasteboardOwner.Snapshot?, over written: Int) {
        pasteboard.borrow()
        let until = ContinuousClock.now + Self.lateReadWindow
        lateRestoring = Task {
            try? await Task.sleep(until: until, clock: .continuous)
            if let snapshot { _ = pasteboard.restore(snapshot, ifUnchangedSince: written) }
            pasteboard.giveBack()
        }
    }

    /// Whether an insertion runs or a paste still holds the clipboard. An
    /// insertion asked for now would wait and only then read the focused
    /// field, which the person may have changed meanwhile.
    var isSettling: Bool { busy || pasteboard.borrowed }

    /// How long after an unconfirmed paste the app might still read the
    /// clipboard, during which nothing else writes it and nothing more is
    /// inserted. An app that reads the clipboard later pastes the person's
    /// own clipboard.
    static let lateReadWindow: Duration = .seconds(2)

    /// How long after an Accessibility write whose effect is unknown its
    /// page, or its window, is held once its field's object is gone
    /// (`FieldAccess.earlier`). The coordinator decided on October 8, 2026
    /// that refusing every dictation into a Chrome window with no end,
    /// Gmail's among them, is worse than the overwrite it prevents, so
    /// after this the page or window takes text again, and a write that
    /// lands later still in a field Chrome rebuilt can overwrite it. The
    /// field's own hold, while its object is there, has no such limit.
    nonisolated static let webScopeHold: Duration = .seconds(10)

    // MARK: - Support

    /// Queues a read on the inserter's executor, for the compose read in
    /// `ComposeAccess.swift`. False when the bounded queue is full.
    @discardableResult
    func submit(_ work: @escaping @Sendable () -> Void) -> Bool {
        executor.submit { _ in work() }
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { continuation in
            let queued = executor.submit { _ in continuation.resume(returning: work()) }
            if !queued { continuation.resume(returning: nil) }
        }
    }

    nonisolated static func name(_ result: InsertionResult) -> String {
        switch result {
        case let .inserted(method, restored):
            "inserted.\(method.rawValue)" + (restored.map { $0 ? ".clipboardRestored" : ".clipboardKept" } ?? "")
        case let .notInserted(reason): "notInserted.\(reason.rawValue)"
        case let .unknown(reason): "unknown.\(reason.rawValue)"
        }
    }
}

/// An Accessibility write whose effect is unknown: one the field accepted
/// and did not show, one the app did not answer, one whose readback showed
/// neither the write nor the field as it was, nor the write's text at its
/// place in another form, or one whose readback was withheld because the
/// field did not answer that it is not secure. It may still land, at the
/// place it was given, over anything written there since, so it holds
/// every insertion into the field it went to until something shows it
/// cannot land later (`FieldAccess.earlier`):
///
/// - Its own text shows at its own place: the field is as long as the
///   write leaves it and the range the write fills holds its text
///   (`FieldAccess.landed`). Text that merely matches somewhere, or a field
///   that read the same before the write, shows nothing.
/// - Its field's object is gone, in an app other than a web page's. Such an
///   app finds the object a write names when it handles the write, and a
///   gone object is nothing; Intention's read that finds it gone reached the
///   app after the write did, so the write had been handled by then.
/// - The launch of its app has ended.
///
/// No time ends that hold, since no wait proves an accepted write will not
/// land. A web field's object can go while the field stays, as Chrome
/// gives a field a new object or rebuilds a page's tree for the same
/// document, and nothing tells which field the write's is then: its page is
/// held, or its window where the page's object is gone too, until the
/// window closes, the app quits or `TextInserter.webScopeHold` has passed
/// since the write. Text matching the write in a field there does not end
/// it, since that field may be another one holding the same words.
///
/// Across time it keeps, besides the text Intention wrote and which field,
/// window and page it went to, only numbers: where the written text goes,
/// the field's length once it lands, and when it was written. What its
/// checks read of a field (`FieldAccess.landed`) is compared and dropped
/// at once. Native
/// objects are compared only on the inserter's executor.
struct UnsettledWrite: @unchecked Sendable {
    let id = UUID()
    let pid: pid_t
    /// When the process started; with `pid` it names one launch of the app.
    let started: UInt64?
    let element: AXElement
    let window: AXElement
    /// The field is in a web page, where Chrome can give it a new object
    /// while it stays where it is; see `FieldAccess.earlier`.
    let web: Bool
    /// For a web field, the page it is in, read right after the write; nil
    /// where it did not answer.
    let page: AXElement?
    /// The text as it was written, after any spacing.
    let text: String
    /// Where the written text goes once it lands, in the offsets the
    /// field's selection takes: the start of the range it replaced, and
    /// its own length.
    let range: FieldRange
    /// The field's length once the write lands as written.
    let lengthAfter: Int
    /// A nonempty selection replaced through WebKit's marker operation.
    /// Only that route may finish its own replacement's caret collapse.
    let replacedSelectionLength: Int
    /// Caret changes issued or confirmed for this write. A confirmation
    /// can fail after the caret moved, so a refused later insertion keeps
    /// this count until its own text is issued or shown.
    var caretCollapses = 0
    /// When the write was issued, for `TextInserter.webScopeHold`.
    let issued: ContinuousClock.Instant

    /// The write of `text` over `state`'s selection in `target`, issued at
    /// `issued`. Reads a web field's page, on the executor.
    init(_ text: String, replacing state: FieldState, in target: FieldTarget, issued: ContinuousClock.Instant) {
        pid = target.pid
        started = target.started
        element = target.element
        window = target.window
        web = target.web
        page = target.web ? target.element.nearestWebArea() : nil
        self.text = text
        range = FieldRange(location: state.selection.location, length: text.utf16.count)
        lengthAfter = state.length - state.selection.length + text.utf16.count
        replacedSelectionLength = target.method == .textOperation ? state.selection.length : 0
        self.issued = issued
    }
}

/// The field an insertion went into, as observed just before the write.
/// Native objects are used only on the inserter's executor.
/// A focused-field read handed to the executor, awaited later.
final class FieldRead: @unchecked Sendable {
    typealias Answer = (field: Result<FocusedField, EditReason>, began: ContinuousClock.Instant?)
    private let lock = NSLock()
    private var answer: Answer?
    private var waiting: CheckedContinuation<Answer, Never>?

    func finish(_ field: Result<FocusedField, EditReason>, began: ContinuousClock.Instant?) {
        lock.lock()
        let answer = (field, began)
        guard let waiting else {
            self.answer = answer
            lock.unlock()
            return
        }
        self.waiting = nil
        lock.unlock()
        waiting.resume(returning: answer)
    }

    var value: Answer {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let answer {
                    lock.unlock()
                    continuation.resume(returning: answer)
                } else {
                    waiting = continuation
                    lock.unlock()
                }
            }
        }
    }
}

/// A field identified when a dictation starts. `before` stays in memory for
/// that dictation only.
struct FocusedField: @unchecked Sendable {
    let pid: pid_t
    /// When the process started; with `pid` it names one launch of the app.
    let started: UInt64?
    let element: AXElement
    let window: AXElement
    /// Nil when the field did not report its frame.
    let frame: CGRect?
    /// Up to `FieldEdit.contextLength` units before the caret; a field whose
    /// text cannot be read is never a dictation's target. A dictation that
    /// waited for earlier ones takes it again from the body read when an
    /// earlier one's text went into this field since
    /// (`TextInserter.showedText`).
    var before: String
    /// The app's, to choose the register the text is written in.
    let bundleIdentifier: String?
    /// The field's description and placeholder, which name the channel or
    /// conversation in apps that reuse one composer ("Message #general").
    let labels: String
    var kind: String? = nil
    /// Gmail identity established from role, editor metadata and page host.
    var gmailBody = false

    /// Answers nil while the field still belongs to what the caller
    /// captured, and otherwise why not.
    typealias Guard = @Sendable () -> EditReason?

    /// A caller's own check that this is still the place it meant, for what
    /// the inserter cannot see: which message a compose window shows, its
    /// recipients or its subject. Nil means no such check. The caller
    /// captures what it expects, unchanging, when it makes this value, and
    /// the closure compares a fresh read with that; it takes nothing from
    /// the inserter and cannot change what the inserter expects.
    ///
    /// The inserter calls it on its own executor, once when the insertion
    /// starts and once at the start of the check before each Accessibility
    /// write, before the clipboard is borrowed for a paste and before the
    /// paste key, and never after a write or a key was
    /// issued. A reason it returns ends the insertion as `notInserted` with
    /// that reason, `composeChanged` for a compose that is no longer the
    /// one captured. Focus can move while it runs, so the inserter makes
    /// all of its own checks again after it returns.
    ///
    /// What the closure must keep to, since the inserter cannot enforce it:
    /// - It only reads. It never writes, presses, posts a key or touches
    ///   the clipboard.
    /// - It checks the field and its ancestors for the secure subrole
    ///   itself before each read of text.
    /// - It keeps its Accessibility objects on the inserter's executor,
    ///   where it is always called.
    /// - It is quick and bounded: it runs right before the write. Before
    ///   the paste key the clipboard already holds the text, so the
    ///   person's own clipboard is not put back until it returns, and one
    ///   that never returns leaves it borrowed.
    /// - It never waits on the inserter or on work queued to the
    ///   inserter's executor, such as another read of the focused field:
    ///   it is running on that executor, and the wait would not end.
    /// - When a read does not answer, times out or is ambiguous it returns
    ///   a reason, never nil.
    var stillCurrent: Guard? = nil

    /// Tells the caller's guard of Intention's own confirmed selection
    /// collapse, from the selected range to the caret at its end. Called
    /// only after the fresh state matches the expected text and length.
    /// It runs on the executor, reads nothing, and may allow only this
    /// selection change in the guard's captured state.
    var didConfirmCaretCollapse: (@Sendable (FieldRange, FieldRange) -> Void)? = nil

    /// Whether `target` is this field. The text before the caret and the
    /// field's labels must still read as they did. An app that reuses one
    /// composer across channels or tabs, as Slack and Gmail can, shows that
    /// channel's draft and names that channel there, and two empty drafts
    /// differ only by name; two empty composers that name nothing cannot be
    /// told apart, and the text goes to the one with focus, as other
    /// dictation apps always do. Chrome can also replace a field's Accessibility
    /// object while the person speaks, so a new object counts as the same
    /// field only when the old one is gone, it sits in the same window with
    /// exactly the same frame, and there was text before the caret to
    /// compare; an empty composer in another channel could otherwise pass.
    /// Runs on the inserter's executor.
    func matches(_ target: FieldTarget) -> Bool {
        guard pid == target.pid, started == target.started else { return false }
        guard target.state?.before == before, target.labels == labels else { return false }
        if element.sameElement(as: target.element) { return true }
        guard let frame, !before.isEmpty, element.isGone,
              window.sameElement(as: target.window), case let .success(now) = target.element.frame() else { return false }
        return now == frame
    }
}

/// The field a read is made for: one element in one launch of one app. A
/// read given it reads nothing of any other field (`FieldAccess.focusedTarget`).
/// Native objects are used only on the inserter's executor.
struct ExpectedFocus: @unchecked Sendable {
    let pid: pid_t
    /// When the process started; with `pid` it names one launch of the app.
    let started: UInt64?
    let element: AXElement
}

struct FieldTarget: @unchecked Sendable {
    let pid: pid_t
    /// When the process started; with `pid` it names one launch of the app.
    let started: UInt64?
    let element: AXElement
    /// The field's window, the end of the secure-ancestor recheck.
    let window: AXElement
    let method: InsertionMethod
    let stringForRange: Bool
    /// The field is a web area that is itself the editable text. It reports
    /// no selection range or character count, so its selection and length
    /// are read and set through text markers.
    var markers = false
    /// The field is in web content and offers its length as its text markers
    /// measure it; see `FieldState.characters`.
    var rangedLength = false
    /// The field is WebKit's, which a web field shows by offering the text
    /// operation; Chromium's offer none. It says how a marker length
    /// shorter than the character count is to be read; see
    /// `TextReader.lengths`.
    var webKit = false
    /// A Chromium Outlook body captured at the start of one or two blank
    /// lines. Its first existing break can become a paragraph boundary.
    var outlookBlankParagraph = false
    /// Gmail may consume its one empty-body break while creating pasted paragraphs.
    var gmailBlankParagraph = false
    var gmailBody = false
    /// The field is in a web page; see `UnsettledWrite.web`.
    var web = false
    /// Admission fell back to an unlisted surface. Its ancestry did not
    /// establish whether it is web content, so a failed page read cannot
    /// identify it as a native field outside a moved tab's hold.
    var unlisted = false
    /// The field's text is a CSS placeholder Chromium reports as its own,
    /// which the text that goes in replaces; see
    /// `FieldAccess.insertDirectly`. Its paste is read back against an
    /// empty field.
    var generated = false
    /// Nil when the field's selection or text cannot be read.
    let state: FieldState?
    /// What the field says it is for (`FieldAccess.labels`), checked again
    /// before each write so a composer reused for another channel is caught.
    let labels: String
    /// The app answered that nothing had focus, and `element` is its focused
    /// window, which exposes no text; see `FieldAccess.bareTarget`. Focus
    /// stays put while the app still answers so and that window is still
    /// its focused one.
    var unfocused = false
    /// The target was taken only because its window exposed no text
    /// (`AXWritingSurface.bare`). A window can gain a field, a password
    /// field among them, while focus answers the same, so it is scanned
    /// again before the clipboard is borrowed and before the paste key.
    var needsBareWindow = false
    /// The paste goes in with each run of line breaks as one space: the
    /// field is a terminal's, or may be, and a pasted line break there can
    /// run a command where the shell does not take pastes as a whole.
    var lineBreaksAsSpaces = false
}

/// Accessibility reads and writes for `TextInserter`, run only on its
/// executor. Text read here is compared and dropped, never logged. The field
/// and its ancestors are checked for the secure subrole before every read of
/// its text.
enum FieldAccess {
    enum DirectInsertion: Sendable {
        case finished(InsertionResult)
        /// The field shows the text, written by `target.method`.
        case shown(FieldTarget)
        /// A write was issued and its effect is unknown, for `reason`. It
        /// may still land, so nothing more is written into its field until
        /// something shows it cannot.
        case unsettled(UnsettledWrite, EditReason)
        /// The field refused the write or offers none: paste instead.
        case needsPaste(FieldTarget)
    }

    /// What an earlier write whose effect is unknown makes of an insertion.
    enum EarlierWrite: Sendable {
        /// The insertion is into another field, outside any page or window
        /// it holds.
        case elsewhere
        /// The insertion is into its field, and it may still land there.
        case mayLand
        /// Its field's object is gone, and the insertion is into the page or
        /// window it holds, where it may still land; for at most
        /// `TextInserter.webScopeHold` after it.
        case mayLandNearby
        /// It cannot land later: it showed, its field's object in an app
        /// other than a web page's is gone, the window of a web field's
        /// gone object closed, or its app's launch ended.
        case settled
        /// The insertion is into the page or window it holds, and
        /// `TextInserter.webScopeHold` has passed since it: the hold ends.
        case expired
    }

    enum Paste: Sendable {
        case notSent(EditReason)
        case landed(String)
        case unconfirmed(EditReason)
    }

    /// Readback attempts after an Accessibility write, 600 ms in all. Chrome
    /// applies writes in about 50 ms and Safari's readback has lagged a
    /// multi-line edit by about 400 ms.
    static let writeSettle = (attempts: 13, interval: 0.05)
    /// Readback attempts after a posted key, which the app handles in its own
    /// time: up to one second.
    static let keySettle = (attempts: 21, interval: 0.05)

    /// The focused field and the text before its caret, as a dictation reads
    /// them at its trigger for the writing's context. A field whose text
    /// cannot be read gives none.
    static func focusedField(ownPID: pid_t, focusAnswered: ((ContinuousClock.Instant) -> Void)? = nil) -> Result<FocusedField, EditReason> {
        // Electron builds its accessibility tree only for a client that asks,
        // and the dot, which asks, may not be shown. Asked at the trigger,
        // the app has the length of the dictation to build it before the text
        // goes in. Other apps refuse the attribute.
        if case let .success(app) = AXElement(ref: AXUIElementCreateSystemWide()).element(kAXFocusedApplicationAttribute),
           let pid = app.pid(), pid != ownPID {
            _ = app.setValue("AXManualAccessibility", kCFBooleanTrue)
        }
        let target: FieldTarget
        switch focusedTarget(ownPID: ownPID, focusAnswered: focusAnswered) {
        case let .success(found): target = found
        case let .failure(reason): return .failure(reason)
        }
        guard let before = target.state?.before else { return .failure(.unreadableField) }
        guard case let .success(frame) = target.element.frame() else { return .failure(.targetUnresponsive) }
        return .success(FocusedField(pid: target.pid, started: target.started, element: target.element, window: target.window,
                                     frame: frame, before: before,
                                     bundleIdentifier: NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier,
                                     labels: target.labels,
                                     kind: target.unlisted ? "unlisted" : target.lineBreaksAsSpaces ? "terminal" : target.web ? "web" : "native",
                                     gmailBody: target.gmailBody))
    }

    /// What the field says it is for, empty where it says nothing.
    static func labels(of element: AXElement) -> String {
        [kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
            .map { (try? element.string($0).get()) ?? "" }
            .joined(separator: "\n")
    }

    static func insertDirectly(_ text: String, ownPID: pid_t, ignoringFields: [AXElement], unsettled: [UnsettledWrite] = [],
                               pasteOnly: Bool, expected: FocusedField? = nil, finalCheck: FocusedField.Guard? = nil) -> DirectInsertion {
        var text = text
        var settled: [UUID] = [], expired: [UUID] = [], collapsed: [UUID] = []
        return insertDirectly(&text, ownPID: ownPID, ignoringFields: ignoringFields, unsettled: unsettled, settled: &settled,
                              expired: &expired, collapsed: &collapsed, pasteOnly: pasteOnly, expected: expected, spaced: false, finalCheck: finalCheck)
    }

    /// With `spaced`, `text` becomes the text spaced for the text before
    /// the caret this read finds (`FieldEdit.spaced`), and that is what is
    /// written or left to paste.
    ///
    /// `unsettled` are the earlier writes that may still land. A field one
    /// of them may still land in is refused with `earlierUnsettled`, and a
    /// field in a page or window one of them holds with
    /// `earlierUnsettledNearby` (`earlier`). `settled` gets the ids of those
    /// found unable to land later, and `expired` those whose page or window
    /// hold ended on its time. `collapsed` names holds whose caret change
    /// was issued or confirmed: they survive a refusal of this insertion.
    static func insertDirectly(_ text: inout String, ownPID: pid_t, ignoringFields: [AXElement], unsettled: [UnsettledWrite],
                               settled: inout [UUID], expired: inout [UUID], collapsed: inout [UUID], pasteOnly: Bool, expected: FocusedField?, spaced: Bool,
                               finalCheck: FocusedField.Guard? = nil,
                               destination: (@Sendable (String?, String) -> Void)? = nil) -> DirectInsertion {
        // The caller's guard is asked before focus is read at all: it can
        // take a while, and nothing read before it could be relied on after.
        if let reason = expected?.stillCurrent?() { return .finished(.notInserted(reason)) }
        var target: FieldTarget
        switch focusedTarget(ownPID: ownPID) {
        case let .success(found): target = found
        case let .failure(reason): return .finished(.notInserted(reason))
        }
        if let expected, !expected.matches(target) { return .finished(.notInserted(.focusChanged)) }
        if let destination {
            let kind = target.unlisted ? "unlisted" : target.lineBreaksAsSpaces ? "terminal" : target.web ? "web" : "native"
            destination(NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier, kind)
        }
        // An earlier write into this field whose effect is unknown may still
        // land: after this text, or over it where it goes in at the offsets
        // it was given. Until something shows it cannot, nothing is written
        // or pasted, by any route; the caller keeps the text.
        var mayLand = false, nearby = false
        var collapsedCarets: [FieldRange] = []
        for earlier in unsettled {
            var collapsedCaret: FieldRange?
            var caretChangeIssued = false
            switch Self.earlier(earlier, on: target, collapsedCaret: &collapsedCaret, caretChangeIssued: &caretChangeIssued) {
            case .elsewhere: break
            case .mayLand: mayLand = true
            case .mayLandNearby: nearby = true
            case .settled:
                settled.append(earlier.id)
                if let collapsedCaret {
                    collapsedCarets.append(collapsedCaret)
                }
            case .expired: expired.append(earlier.id)
            }
            if caretChangeIssued || collapsedCaret != nil { collapsed.append(earlier.id) }
        }
        if mayLand { return .finished(.notInserted(.earlierUnsettled)) }
        if nearby { return .finished(.notInserted(.earlierUnsettledNearby)) }
        // A hold may have completed its earlier marker write's caret
        // collapse. Nothing observed before that selection change is the
        // later insertion's state. Read this field again, never another,
        // and require the text and length observed before the collapse,
        // with only the confirmed selection change allowed. A hold
        // that ended without a collapse keeps the ordinary recheck: a fresh
        // snapshot could otherwise adopt a selection that changed during
        // the landing read and replace the earlier words.
        if !collapsedCarets.isEmpty {
            let prior = target
            let focus = ExpectedFocus(pid: prior.pid, started: prior.started, element: prior.element)
            switch focusedTarget(ownPID: ownPID, expecting: focus) {
            case let .success(found):
                guard found.window.sameElement(as: prior.window), found.labels == prior.labels else {
                    return .finished(.notInserted(.focusChanged))
                }
                guard var afterCollapse = prior.state, let fresh = found.state,
                      collapsedCarets.allSatisfy({ $0 == FieldRange(location: afterCollapse.selection.upperBound, length: 0) }) else {
                    return .finished(.notInserted(.fieldChanged))
                }
                let selection = afterCollapse.selection
                afterCollapse = FieldEdit.afterCollapsing(afterCollapse)
                guard FieldEdit.sameState(fresh, afterCollapse) else {
                    return .finished(.notInserted(.fieldChanged))
                }
                expected?.didConfirmCaretCollapse?(selection, afterCollapse.selection)
                target = found
            case let .failure(reason): return .finished(.notInserted(reason))
            }
        }
        // Without the field's text nothing can be verified; a paste at least
        // leaves the text on the clipboard.
        guard let state = target.state else { return .needsPaste(target) }
        // Chromium reports a CSS placeholder as an editor's text, with the
        // caret after it, and accepts a replace range there that changes
        // nothing, while a paste goes in with the placeholder gone (support
        // matrix, October 7, 2026). That write's effect would be unknown and
        // hold the field for as long as it lasts, so the editor takes the
        // paste, spaced and read back as an empty field. Its static text
        // lists no editable ancestor, where text the person can edit does;
        // a walk that does not answer says nothing, so the field takes the
        // paste with its text taken as its own.
        let generated = target.method == .replaceRange && !target.webKit && !state.blank ? target.element.generatedText() : false
        target.generated = generated == true
        if spaced { text = FieldEdit.spaced(text, after: target.generated ? "" : state.before) }
        if generated != false || pasteOnly || target.method == .paste
            || ignoringFields.contains(where: { $0.sameElement(as: target.element) }) {
            return .needsPaste(target)
        }

        var facts = EditFacts(replacing: state, with: text)
        // Chromium's AXReplaceRangeWithText turns the offset it is given
        // into a place in the page through the text its tree shows, and in
        // a field that holds nothing, or only its placeholder line break,
        // that place can be inside an element the tree leaves out. Gmail's
        // empty compose body starts with Gemini's "Press / to write" hint,
        // a non-editable span whose words are hidden from the tree, so the
        // body reads as one line break with the caret in front of it,
        // exactly as any empty editor does, and Chromium accepted the write
        // and put nothing anywhere (Chrome 156, October 7, 2026). No read
        // tells the two apart. A paste goes where the page's own caret is,
        // which in an empty field is the only place text can go, so a
        // blank Chromium field takes the paste. WebKit's replace range
        // wrote at the caret in the same structure, so its blank fields
        // keep the write.
        if target.method == .replaceRange, facts.blankBefore, !target.webKit { return .needsPaste(target) }
        // Chromium's AXReplaceRangeWithText counts the break between block
        // paragraphs differently again from the selection it is given: in a
        // field that holds such breaks the text lands before the caret. A
        // paste goes where the selection is. The character count shows such
        // a break unless an empty paragraph sits beside it, so a field of
        // several block paragraphs takes the paste as well.
        // WebKit's replace range takes the selection's own offsets, so a
        // field whose breaks read doubled keeps it.
        if target.method == .replaceRange, !facts.blankBefore,
           state.characters != nil || (state.blockParagraphs && !state.breaksDoubled) {
            return .needsPaste(target)
        }
        // A WebKit field read past the end of its own marker range, or one
        // whose list labels were taken out of its text, would not have been
        // read this way before that reading was added, and was then pasted
        // into. Reading it better may confirm a paste; it does not open the
        // replace range, which counts an image the reads leave out.
        if target.method == .replaceRange, state.pastOwnRange || state.listLabels { return .needsPaste(target) }
        // Words equal to the selected text, as every check here compares
        // text, and as long, are already there. Written over it, they would
        // leave the field reading as it did, which a readback takes for the
        // write having landed whether the app applied it, holds it or did
        // not answer, and one still on its way would land over whatever
        // goes there next. So nothing is written: the field is checked as
        // before a write, and the insertion reports the words in, which the
        // field shows. The selection stays where the person left it: moving
        // the caret past it would be one more write whose effect could be
        // unknown, and a person who dictates the words they selected again
        // means to replace them, which the next dictation then does. An
        // accent spelled in other units is written, since the field's
        // length tells that write from none.
        if state.selection.length == text.utf16.count, FieldEdit.comparable(state.selectedText) == FieldEdit.comparable(text) {
            if let reason = recheck(target, stillCurrent: expected?.stillCurrent) { return .finished(.notInserted(reason)) }
            if let reason = finalCheck?() { return .finished(.notInserted(reason)) }
            return .finished(.inserted(target.method, clipboardRestored: nil))
        }
        // Observing takes a moment: write only to the same field, selection
        // and text it saw.
        if let reason = recheck(target, stillCurrent: expected?.stillCurrent, replacingRange: target.method == .replaceRange) {
            return .finished(.notInserted(reason))
        }
        // The caller's final check, after every read of the field and
        // right before the write; the text operation reads its markers
        // first, so it asks there.
        if target.method != .textOperation, let reason = finalCheck?() { return .finished(.notInserted(reason)) }
        // When the write is issued, taken right before it on every route,
        // after the text operation's own reads, so a page or window hold
        // lasts `TextInserter.webScopeHold` from the write itself.
        let issued: ContinuousClock.Instant
        let code: AXError
        switch target.method {
        case .selectedText:
            issued = .now
            code = target.element.setString(kAXSelectedTextAttribute, text)
        case .replaceRange:
            issued = .now
            code = target.element.replace(state.selection, with: text)
        case .textOperation:
            // Written at the selection's own markers, so the text goes
            // where the caret is. Reading them is one more read after the
            // recheck, so they must still be the selection that was
            // observed, with focus still on the field.
            guard let markers = markerSelection(target), target.element.offsets(of: markers) == state.selection else {
                return .finished(.notInserted(.fieldChanged))
            }
            if let reason = focusMoved(target) { return .finished(.notInserted(reason)) }
            // Asked after those reads too, as at the end of `recheck`.
            if let reason = secureBeforeEdit(target) { return .finished(.notInserted(reason)) }
            if let reason = finalCheck?() { return .finished(.notInserted(reason)) }
            issued = .now
            code = target.element.replace(markers, with: text)
        case .paste:
            issued = .now
            code = .actionUnsupported
        }
        var caretChangeIssued = false
        func held(_ reason: EditReason) -> DirectInsertion {
            var write = UnsettledWrite(text, replacing: state, in: target, issued: issued)
            if caretChangeIssued { write.caretCollapses = 1 }
            return .unsettled(write, reason)
        }
        guard let verdict = settle(writeSettle, { verifyInsertion(&facts, state: state, in: target) }) else {
            // The readback was withheld: the field turned secure, or did not
            // answer that it is not. A write the app accepted, or did not
            // answer, may still land; one it refused cannot.
            switch code {
            case .success: return held(.secureField)
            case .cannotComplete: return held(.targetUnresponsive)
            default: return .finished(.notInserted(.secureField))
            }
        }
        switch (verdict, code) {
        case (.expected, _):
            // A selected marker replacement is complete only when its
            // caret collapse is confirmed with its text unchanged.
            if target.method == .textOperation, state.selection.length > 0,
               !collapseReplacement(facts.range, text: facts.readText, length: facts.lengthAfter, in: target,
                                    onCaretChange: { caretChangeIssued = true }) {
                return held(.writeUnconfirmed)
            }
            return .shown(target)
        case (_, .cannotComplete):
            // The app did not answer the write in time. It may still apply
            // it once it catches up.
            return held(.targetUnresponsive)
        case (.unchanged, .apiDisabled):
            return .finished(.notInserted(.permissionMissing))
        case (.unchanged, .success):
            // Accepted but not shown. No wait proves it will not land later,
            // so a paste now could insert the text twice.
            return held(.writeUnconfirmed)
        case (.unchanged, _):
            return .needsPaste(target)
        case (.differs, _):
            // The field shows neither the write nor what it held. A rich
            // editor that reformats what goes in leaves the write's text at
            // its own place in another form, and then it has landed; where
            // that text is not there, something else changed the field and
            // the write may still be on its way (`reformatted`). Either way
            // the text is not the text written, and the result says so.
            guard let shown = reformatted(text, replacing: state, in: target) else { return held(.readbackMismatch) }
            if target.method == .textOperation, state.selection.length > 0,
               !collapseReplacement(shown.range, text: shown.text, length: shown.length, in: target,
                                    onCaretChange: { caretChangeIssued = true }) {
                return held(.readbackMismatch)
            }
            return .finished(.unknown(.readbackMismatch))
        }
    }

    /// Whether `text`, written over `state`'s selection with a readback that
    /// matched neither the write nor the field as it was, stands at its own
    /// place in another form, as a rich editor reformats what goes in.
    /// Returns that range and the text shown there for the marker route's
    /// checked caret collapse, kept only during this insertion.
    ///
    /// The evidence is tied to the write's own text. From where the
    /// selection began, the field must hold, up to a place, text that shows
    /// the written text by its letters and digits (`Reformatting.shows`),
    /// and from that place the text that followed the selection, as far as
    /// it was read. The place must be about as far on as the written text
    /// is long: shorter by no more than its spaces, punctuation and markup,
    /// and longer by a few units (`Reformatting`). Where the selection ran
    /// to the field's end, with the text after it, the field's length puts
    /// the place. The text before the selection must read as it did, and
    /// the selection with the text after it must not still be there: in a
    /// run of one letter that is what tells a place that did not change.
    /// Unrelated text at the place, however long, is not the write's, and a
    /// write whose letters and digits are those it replaced, near enough,
    /// cannot be told from them, so neither has landed.
    ///
    /// It reads only what a readback reads: the field's length, the text
    /// before the place, and from the place the longer of the written text
    /// with its slack and the selection, with the text read after the
    /// selection, each after the secure check, compared and dropped.
    static func reformatted(_ text: String, replacing state: FieldState, in target: FieldTarget) -> (range: FieldRange, text: String, length: Int)? {
        let shape = Reformatting(text)
        guard shape.differs(from: state.selectedText) else { return nil }
        let location = state.selection.location
        let written = text.utf16.count
        let least = max(0, written - shape.shorter), most = written + shape.longer
        let before = FieldRange(location: location - state.before.utf16.count, length: state.before.utf16.count)
        let none = FieldRange(location: location, length: 0)
        guard let length = readback(target, text: none, before: none, after: none)?.length, length >= location else { return nil }
        let afterUnits = Array((FieldEdit.comparable(state.after) ?? "").utf16)
        let span = min(max(most, state.selection.length) + afterUnits.count, length - location)
        guard let shown = readback(target, text: FieldRange(location: location, length: span), before: before, after: none),
              shown.length == length, FieldEdit.comparable(shown.before) == FieldEdit.comparable(state.before),
              let read = FieldEdit.comparable(shown.text) else { return nil }
        let units = Array(read.utf16), selected = Array((FieldEdit.comparable(state.selectedText) ?? "").utf16)
        // The selection, and the text after it, still at the place. Nothing
        // to compare is no evidence either way: at a caret at the field's
        // end the place itself tells. The selection alone still there says
        // nothing, since the written text can start with it, as "old news"
        // written over "old" does; the text at the place tells.
        if !(selected + afterUnits).isEmpty, units.starts(with: selected + afterUnits) { return nil }
        // Read to the field's end before, it ends the field now.
        let end = state.selection.upperBound + afterUnits.count == state.length ? length - location - afterUnits.count : nil
        let places = shape.places(in: read).filter { place in
            (least...most).contains(place) && (end == nil || place == end)
                && place + afterUnits.count <= units.count && units[place..<place + afterUnits.count].elementsEqual(afterUnits)
        }
        // The field's length puts the end if nothing else changed. An
        // ambiguous endpoint cannot authorize a selection change.
        let place = length - state.length + state.selection.length
        guard let place = places.contains(place) ? place : (target.method == .textOperation && state.selection.length > 0 ? nil : places.first) else { return nil }
        let range = FieldRange(location: location, length: place)
        return (range, String(decoding: units[..<place], as: UTF16.self), length)
    }

    /// What `write` makes of an insertion into `target`, on the executor.
    ///
    /// The write may still land in the field whose object it named. While
    /// that object is there, it is the field's only one: an app keeps one
    /// object for each element it shows, so another object is another
    /// field, and the write cannot land in it. In another app, or another
    /// launch of the same one, it cannot land at all. In the field it holds,
    /// the write has landed once its text shows at its own place as written
    /// (`landed`), and nothing else ends that hold.
    ///
    /// Once the object is gone, an app other than a web page's has handled
    /// the write: it finds the object a write names when it handles the
    /// write, Intention's read that found the object gone reached it after the
    /// write did, and a gone object is nothing to write into. Chrome,
    /// though, can give a field that stays where it is a new object, moved
    /// or resized as it does, and can rebuild a page's whole tree for the
    /// same document, and a write it has passed to the page may still land
    /// in that field. Nothing tells which field that is, so the write holds
    /// every field of its page while the page's object is there, wherever
    /// the page is, and a field of its window that is in no page or whose
    /// page does not answer; and every field of its window once the page's
    /// object is gone too or does not answer, now or at the write. An object that does not answer
    /// whether it is there counts as one that may be gone. A page whose
    /// object is there and is not the write's is another document, in
    /// another tab or frame, which the write cannot reach. The
    /// hold ends when the window closes, when the app quits, or
    /// `TextInserter.webScopeHold` after the write. Text in another object
    /// cannot identify the rebuilt field, even at the same offset and
    /// length, so it never ends the scope hold early.
    static func earlier(_ write: UnsettledWrite, on target: FieldTarget, collapsedCaret: inout FieldRange?,
                        caretChangeIssued: inout Bool) -> EarlierWrite {
        guard processStart(write.pid) == write.started else { return .settled }
        guard write.pid == target.pid, write.started == target.started else { return .elsewhere }
        if write.element.sameElement(as: target.element) {
            return landed(write, in: target, collapsedCaret: &collapsedCaret,
                          caretChangeIssued: &caretChangeIssued) ? .settled : .mayLand
        }
        // An object that does not answer may be gone: in a web page that
        // makes the field uncertain, while elsewhere the insertion is into
        // another object, which the write cannot reach either way.
        switch write.element.stillThere {
        case true?: return .elsewhere
        case false?: guard write.web else { return .settled }
        case nil: guard write.web else { return .elsewhere }
        }
        if let page = write.page, page.stillThere == true {
            // The write's own page holds wherever it is. Any other field is
            // held in the write's window when it has no known page, or
            // in another window when it is web content, or an unlisted
            // surface, whose page did not answer: the held tab may have
            // moved. Known other pages and native fields of other windows
            // are elsewhere.
            let now = target.element.nearestWebArea()
            if now?.sameElement(as: page) != true {
                guard now == nil, write.window.sameElement(as: target.window) || target.web || target.unlisted else { return .elsewhere }
            }
        } else {
            guard write.window.stillThere != false else { return .settled }
            guard write.window.sameElement(as: target.window) else { return .elsewhere }
        }
        // With the original object gone, even matching text at the same
        // offset and length can belong to another field of this page.
        // Nothing under the own-range read rule establishes its identity.
        // Keep the bounded scope hold rather than retire it on that text.
        return ContinuousClock.now - write.issued < TextInserter.webScopeHold ? .mayLandNearby : .expired
    }

    /// Whether `write` shows in its original field: the field has the
    /// length the write leaves, and its own range holds the exact text.
    /// A selected marker replacement counts only after its checked caret
    /// collapse. The range and length are compared and dropped at once.
    static func landed(_ write: UnsettledWrite, in target: FieldTarget, collapsedCaret: inout FieldRange?,
                       caretChangeIssued: inout Bool) -> Bool {
        guard let state = target.state else { return false }
        let written = write.range.length, place = state.length - write.lengthAfter + written
        guard place == written,
              let shown = readback(target, text: FieldRange(location: write.range.location, length: place),
                                   before: FieldRange(location: write.range.location, length: 0),
                                   after: FieldRange(location: write.range.location + place, length: 0)),
              shown.length == state.length, let read = FieldEdit.comparable(shown.text)
        else { return false }
        let range = FieldRange(location: write.range.location, length: place)
        let exact = place == written && read == FieldEdit.comparable(write.text)
        guard exact else { return false }
        if state.selection == write.range || state.selection == range {
            // Only the original marker field's exact replacement can have
            // its selection collapsed. A rebuilt field's identity is unknown.
            guard exact, write.replacedSelectionLength > 0, target.method == .textOperation,
                  write.element.sameElement(as: target.element) else { return false }
            guard collapseReplacement(range, text: write.text, length: state.length, in: target,
                                      onCaretChange: { caretChangeIssued = true }) else { return false }
            collapsedCaret = FieldRange(location: range.upperBound, length: 0)
        }
        return true
    }

    /// Posts the paste key once the field passes its recheck and while
    /// `clipboardHolds` answers that the clipboard is still at the change
    /// count of Intention's own write, then reads the field back.
    static func paste(_ text: String, alternativeText: String? = nil, into target: FieldTarget, keyCode: CGKeyCode, stillCurrent: FocusedField.Guard?,
                      finalCheck: FocusedField.Guard? = nil, clipboardHolds: () -> Bool) -> Paste {
        if let reason = recheck(target, stillCurrent: stillCurrent) { return .notSent(reason) }
        // A copy the person or another app made since Intention's write,
        // during the recheck, the caller's guard or the wait for this
        // executor, would be what the key pastes. Nothing is read between
        // this and the key, but another app can still write in that moment:
        // the two are not atomic.
        // The final check cannot wait or read the field. Check the clipboard
        // after it, so any copy made during the callback refuses the paste.
        if let reason = finalCheck?() { return .notSent(reason) }
        guard clipboardHolds() else { return .notSent(.clipboardBusy) }
        guard KeyEvents.post(.paste(keyCode), to: target.pid) else { return .notSent(.pasteUnavailable) }
        guard let observed = target.state else { return .unconfirmed(.unreadableField) }
        // A CSS placeholder goes once text comes, so the field is read back
        // as one that was empty.
        let state = target.generated ? FieldState(selection: FieldRange(location: 0, length: 0), selectedText: "", before: "", after: "", length: 0)
            : observed
        var facts = EditFacts(replacing: state, with: text)
        // Text equal to the selection it replaces reads as inserted before
        // the app has taken the key, and the clipboard must not go back
        // until it has. The selection becoming a caret after the text shows
        // that it did.
        let sameAsSelected = state.selection.length > 0 && FieldEdit.comparable(state.selectedText) == FieldEdit.comparable(text)
        var confirmedText = text
        var alternative = alternativeText.map { EditFacts(replacing: state, with: $0) }
        let caret = FieldRange(location: state.selection.upperBound, length: 0)
        switch settle(keySettle, {
            guard let verdict = verifyInsertion(&facts, state: state, in: target) else { return nil }
            if verdict == .expected {
                if sameAsSelected, selectedRange(of: target.element, markers: target.markers) != caret { return .unchanged }
                confirmedText = facts.insertedText
                return verdict
            }
            // A plain-text consumer pastes the original footer; an HTML consumer
            // pastes its label. Verify either complete insertion through the same
            // guarded reader. A withheld read ends verification immediately.
            if var other = alternative {
                guard let richVerdict = verifyInsertion(&other, state: state, in: target) else { return nil }
                alternative = other
                if richVerdict == .expected {
                    // Verification may have adapted paragraph breaks to this
                    // editor's offsets. Compare the text it actually read, or
                    // an unchanged selection could look like a finished paste.
                    if state.selection.length > 0,
                       FieldEdit.comparable(state.selectedText) == FieldEdit.comparable(other.readText),
                       selectedRange(of: target.element, markers: target.markers) != FieldRange(location: other.range.upperBound, length: 0) {
                        return .unchanged
                    }
                    confirmedText = other.insertedText
                    return .expected
                }
            }
            return verdict
        }) {
        case .expected?: return .landed(confirmedText)
        case .unchanged?: return .unconfirmed(.writeUnconfirmed)
        case .differs?: return .unconfirmed(.readbackMismatch)
        case nil: return .unconfirmed(.secureField)
        }
    }

    static let markerSelectionAttribute = "AXSelectedTextMarkerRange"

    /// The selection as the field's own text markers name it.
    static func markerSelection(_ target: FieldTarget) -> AXTextMarkerRange? {
        guard case let .success(value) = target.element.value(markerSelectionAttribute),
              CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
        return (value as! AXTextMarkerRange)
    }

    // MARK: - Target

    /// `focusAnswered` gets the moment the app said which element has focus.
    /// With `expecting`, focus must be that element of that launch of that
    /// app: anything else answers `focusChanged` before the field's
    /// ancestry, selection or text is read, so a read made for one field
    /// reads nothing of another that took focus meanwhile.
    ///
    /// Every app is in scope. Text goes in unless the focus is a secure
    /// field, is not text at all, or is one of Intention's own windows. Text the
    /// app exposes only under another role, text it reports no write for
    /// (Terminal's), and an app that exposes no text anywhere in its window
    /// all get a paste.
    static func focusedTarget(ownPID: pid_t, expecting: ExpectedFocus? = nil,
                              focusAnswered: ((ContinuousClock.Instant) -> Void)? = nil) -> Result<FieldTarget, EditReason> {
        var observed = expecting
        let first = focusedTargetOnce(ownPID: ownPID, expecting: expecting, focusAnswered: focusAnswered) {
            observed = $0
        }
        guard case let .failure(reason) = first, reason == .noTextField || reason == .targetUnresponsive else { return first }
        // One complete reread, before any write. If the first read identified a
        // field, the retry must stay in it, even when its window did not answer.
        Thread.sleep(forTimeInterval: 0.033)
        return focusedTargetOnce(ownPID: ownPID, expecting: observed, focusAnswered: focusAnswered, observed: { _ in })
    }

    private static func focusedTargetOnce(ownPID: pid_t, expecting: ExpectedFocus?,
                                         focusAnswered: ((ContinuousClock.Instant) -> Void)?,
                                         observed: (ExpectedFocus) -> Void) -> Result<FieldTarget, EditReason> {
        guard AXIsProcessTrusted() else { return .failure(.permissionMissing) }
        let element: AXElement
        let focus = AXElement(ref: AXUIElementCreateSystemWide()).element(kAXFocusedUIElementAttribute)
        focusAnswered?(.now)
        switch focus {
        case let .success(focused): element = focused
        case let .failure(failure) where failure.isTimeout: return .failure(.targetUnresponsive)
        case let .failure(failure) where failure.isPermissionDenied: return .failure(.permissionMissing)
        case let .failure(failure) where failure.code == .noValue || failure.code == .attributeUnsupported:
            // The app answers that nothing has focus. One that exposes no text
            // at all answers so with its cursor in its own text.
            if expecting != nil { return .failure(.focusChanged) }
            return bareTarget(ownPID: ownPID)
        case .failure: return .failure(.noTextField)
        }
        guard let pid = element.pid() else { return .failure(.noTextField) }
        guard pid != ownPID else { return .failure(.ownApp) }
        if let expecting, !isExpected(element, pid: pid, expecting) { return .failure(.focusChanged) }
        observed(ExpectedFocus(pid: pid, started: processStart(pid), element: element))
        let surface = AXWritingSurface.surface(element, pid: pid, editableDocument: true)
        switch surface.admission {
        case .secure: return .failure(.secureField)
        case .unsupported: return unlistedTarget(element, pid: pid)
        case .allowed: break
        }

        let selectedTextSettable = element.isSettable(kAXSelectedTextAttribute)
        // What a web field offers says which engine it is and so how its
        // text is counted, so one that does not answer is not guessed at.
        // The target's single reread also covers this query; a nested retry
        // would let repeated metadata failures outlive that limit.
        let names = element.parameterizedNames()
        if names == nil, surface.web { return .failure(.targetUnresponsive) }
        let parameterized = names ?? []
        guard case let .success(window) = element.element(kAXWindowAttribute) else { return .failure(.noTextField) }
        // A text control that reports neither its value nor its selected
        // text as settable takes a paste when its selection can be set, as
        // Terminal's text area's can, since it takes typing. One whose
        // selection cannot be set either is read-only text, no text box.
        let writable = selectedTextSettable || element.isSettable(kAXValueAttribute)

        // A web area with keyboard focus is editable text only when its whole
        // document is, which WebKit reports as a settable value. Without
        // marker editing it takes a paste: its AXReplaceRangeWithText writes
        // at the start of the document whatever range it is given.
        let webArea = surface.web && (try? element.string(kAXRoleAttribute).get()) == "AXWebArea"
        guard !webArea || element.isSettable(kAXValueAttribute) else { return .failure(.noTextField) }
        guard writable || webArea || element.isSettable(kAXSelectedTextRangeAttribute) else { return .failure(.noTextField) }
        let markers = webArea && parameterized.isSuperset(of: AXElement.markerEditing)

        let method: InsertionMethod = if !writable || (webArea && !markers) {
            .paste
        } else if markers {
            .textOperation
        } else if surface.web {
            parameterized.contains(AXElement.replaceRangeWithText) ? .replaceRange : .paste
        } else {
            selectedTextSettable ? .selectedText : .paste
        }
        let stringForRange = parameterized.contains(kAXStringForRangeParameterizedAttribute)
        let rangedLength = surface.web && !markers && stringForRange && parameterized.isSuperset(of: AXElement.rangedLengthReads)
        let webKit = surface.web && parameterized.contains(AXElement.textOperation)
        var state = readState(TextReader(element: element, stringForRange: stringForRange, markers: markers, rangedLength: rangedLength,
                                         webKit: webKit, clear: { AXWritingSurface.secureAncestry(element, window: window) == false }))
        // Roles only: each block paragraph of a web editor is a child of
        // the field. Children that do not answer could be several.
        if rangedLength { state?.blockParagraphs = element.blockChildren().map { $0 > 1 } ?? true }
        // Text that takes typing and reports no write is a terminal's, where
        // a pasted line break can run a command.
        var target = FieldTarget(
            pid: pid, started: processStart(pid), element: element, window: window,
            method: method, stringForRange: stringForRange, markers: markers, rangedLength: rangedLength, webKit: webKit, state: state,
            labels: labels(of: element)
        )
        target.lineBreaksAsSpaces = !writable && !webArea
        target.web = surface.web
        let blankParagraph = rangedLength && !webKit && writable
            && state?.blank == true && state?.length == 1 && state?.selection == FieldRange(location: 0, length: 0)
        let description = target.labels.components(separatedBy: "\n").first ?? ""
        if surface.web, blankParagraph || !GmailBodyIdentity.matches(description: description, classes: nil),
           WritingSurfacePolicy.isChromiumBrowser(bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier),
           (try? element.string(kAXRoleAttribute).get()) == kAXTextAreaRole,
           GmailBodyIdentity.matches(description: description, classes: element.domClasses()),
           pageHost(of: element, window: window) == GmailBodyIdentity.host {
            target.gmailBody = true
        }
        target.gmailBlankParagraph = target.gmailBody && blankParagraph
        if surface.web, rangedLength, !webKit, writable,
           state?.blank == true, state?.selection == FieldRange(location: 0, length: 0),
           let length = state?.length, (1...2).contains(length),
           WritingSurfacePolicy.isChromiumBrowser(bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier),
           (try? element.string(kAXRoleAttribute).get()) == kAXTextAreaRole,
           OutlookBodyIdentity.descriptions.contains(target.labels.components(separatedBy: "\n").first ?? ""),
           let host = pageHost(of: element, window: window), OutlookBodyIdentity.hosts.contains(host) {
            target.outlookBlankParagraph = true
        }
        return .success(target)
    }

    /// Whether `element`, focused in `pid`, is the field `expected` names:
    /// the same element in the same launch of the same app. Nothing of the
    /// element is read but its identity.
    static func isExpected(_ element: AXElement, pid: pid_t, _ expected: ExpectedFocus) -> Bool {
        pid == expected.pid && element.sameElement(as: expected.element) && processStart(pid) == expected.started
    }

    /// Whether the field `expected` names still has focus, at the cost of
    /// one read of which element has focus. A read that does not answer is
    /// focus gone.
    static func hasFocus(_ expected: ExpectedFocus) -> Bool {
        guard case let .success(element) = AXElement(ref: AXUIElementCreateSystemWide()).element(kAXFocusedUIElementAttribute),
              let pid = element.pid() else { return false }
        return isExpected(element, pid: pid, expected)
    }

    /// Focus on an element `AXWritingSurface.surface` does not list as a text
    /// control, or whose ancestry it could not finish. It is text when it
    /// has a selection range, as a custom editor's does. In a window that
    /// exposes no text at all, what has focus says nothing about where the
    /// app's own cursor is. Either takes a paste that is never read: how
    /// such an element counts its text is not known, so no reading of it
    /// could confirm one. Anything else is not a text box.
    static func unlistedTarget(_ element: AXElement, pid: pid_t) -> Result<FieldTarget, EditReason> {
        let role = try? element.string(kAXRoleAttribute).get()
        // `surface` refuses a secure role as it does a secure subrole.
        if role == kAXSecureTextFieldSubrole { return .failure(.secureField) }
        let window: AXElement
        if role == kAXWindowRole {
            window = element
        } else if case let .success(found) = element.element(kAXWindowAttribute) {
            window = found
        } else {
            return .failure(.noTextField)
        }
        // Nothing of the element beyond its role is read before it answers
        // that neither it nor an ancestor is secure.
        switch AXWritingSurface.secureAncestry(element, window: window) {
        case true?: return .failure(.secureField)
        case nil: return .failure(.targetUnresponsive)
        case false?: break
        }
        // A web area or static text answers a selection range for the page's
        // selection, which is no place to type.
        let text = role != "AXWebArea" && role != kAXStaticTextRole && (try? element.range(kAXSelectedTextRangeAttribute).get()) != nil
        // A control that is plainly not text is no text box, even in a
        // window that exposes no text.
        if !text {
            guard !nonText.contains(role ?? "") else { return .failure(.noTextField) }
            // A window with a password field, or one that does not say, may
            // have the person's cursor in it: refused as a password field,
            // so the popup hides the words.
            switch AXWritingSurface.exposure(of: window) {
            case .nothing: break
            case .text: return .failure(.noTextField)
            case .secure: return .failure(.secureField)
            }
        }
        var target = FieldTarget(pid: pid, started: processStart(pid), element: element, window: window, method: .paste,
                                 stringForRange: false, state: nil, labels: labels(of: element))
        target.needsBareWindow = !text
        target.unlisted = true
        // Terminals that draw their own text are most of the apps that
        // expose none, and a pasted line break there can run a command.
        target.lineBreaksAsSpaces = !text
        return .success(target)
    }

    /// Roles of controls that never take typing.
    static let nonText: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXMenuItemRole,
        kAXMenuBarItemRole, kAXSliderRole, kAXIncrementorRole, kAXDisclosureTriangleRole, kAXScrollBarRole, kAXImageRole,
        kAXListRole, kAXTableRole, kAXOutlineRole, kAXRowRole, kAXCellRole, kAXTabGroupRole, "AXLink",
    ]

    /// The focused window of the focused app when nothing in it has focus
    /// and it exposes no text at all, as a paste target that is never read.
    /// A window that exposes text, with nothing focused, has no text box to
    /// type into.
    static func bareTarget(ownPID: pid_t) -> Result<FieldTarget, EditReason> {
        guard case let .success(app) = AXElement(ref: AXUIElementCreateSystemWide()).element(kAXFocusedApplicationAttribute),
              let pid = app.pid() else { return .failure(.noTextField) }
        guard pid != ownPID else { return .failure(.ownApp) }
        guard case let .success(window) = app.element(kAXFocusedWindowAttribute) else { return .failure(.noTextField) }
        switch AXWritingSurface.secureAncestry(window, window: window) {
        case true?: return .failure(.secureField)
        case nil: return .failure(.targetUnresponsive)
        case false?: break
        }
        switch AXWritingSurface.exposure(of: window) {
        case .nothing: break
        case .text: return .failure(.noTextField)
        case .secure: return .failure(.secureField)
        }
        var target = FieldTarget(pid: pid, started: processStart(pid), element: window, window: window, method: .paste,
                                 stringForRange: false, state: nil, labels: labels(of: window))
        target.unfocused = true
        target.needsBareWindow = true
        target.lineBreaksAsSpaces = true
        return .success(target)
    }

    /// When a process started, in microseconds, from the kernel, or nil when
    /// it is gone. A pid can be reused, and this does not depend on what
    /// LaunchServices records for the app.
    static func processStart(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    /// Nil when the same launch of the app still has the same field focused,
    /// not secure, with the observed text and selection. Focus is read again
    /// after the text, since those reads leave time for it to move.
    ///
    /// `stillCurrent` is the caller's guard, given only for the checks right
    /// before an Accessibility write, before the clipboard is borrowed for a
    /// paste and before the paste key, and nil for any other. It is asked
    /// first and once: focus can move while it runs, so every read of the
    /// inserter's own comes after it, and its answer is never the last
    /// thing checked.
    ///
    /// `replacingRange` is the check before `AXReplaceRangeWithText`. That
    /// route was chosen for a field read by its own range and holding no
    /// list labels, so a field that now has to be read past it, or whose
    /// labels now have to be taken out, is refused there, though its text,
    /// its selection and its length read the same. A paste goes where the
    /// selection is however the field was measured, so its checks pass it.
    static func recheck(_ target: FieldTarget, stillCurrent: FocusedField.Guard?, replacingRange: Bool = false) -> EditReason? {
        if let reason = stillCurrent?() { return reason }
        // Before focus is read again and the field is asked once more that
        // it is not secure, which stay the last reads before the key.
        if target.needsBareWindow {
            switch AXWritingSurface.exposure(of: target.window) {
            case .nothing: break
            case .text: return .fieldChanged
            case .secure: return .secureField
            }
        }
        if let reason = recheckFocus(target) { return reason }
        if let state = target.state {
            let reader = reader(target)
            // A read withheld because the field did not answer that it is
            // not secure is asked about once more, for the reason.
            guard let now = readState(reader) else { return reader.withheld ? recheckFocus(target) ?? .fieldChanged : .fieldChanged }
            guard FieldEdit.sameState(now, state) else { return .fieldChanged }
            if replacingRange, now.pastOwnRange || now.listLabels { return .fieldChanged }
        }
        if let reason = focusMoved(target) { return reason }
        guard labels(of: target.element) == target.labels else { return .focusChanged }
        // The field can turn secure while the reads above are answered, so
        // it is asked once more after the last of them. Nothing of the
        // field is read between this and the write; before the paste key
        // only the clipboard's change count follows.
        return secureBeforeEdit(target)
    }

    /// The last check of the field before a write, or before the clipboard's
    /// change count and the paste key: nil only on a complete answer that
    /// the field and every ancestor up to its window are not secure. A
    /// secure answer refuses at once. One that does not answer (a subrole
    /// read that timed out or failed, or a walk to the window that did not
    /// finish) is asked once more, at once: a single missed answer would
    /// otherwise refuse a field `main` writes to, and asking more often, or
    /// after a wait, would only widen the moment between this check and
    /// the write. Focus is read again first, since the person may have
    /// moved to another field while the first asking went unanswered, so
    /// the secure check stays the last read of the field. Focus that moved
    /// refuses; no answer the second time refuses as unresponsive.
    static func secureBeforeEdit(_ target: FieldTarget) -> EditReason? {
        let first = secureNow(target)
        guard first == .targetUnresponsive else { return first }
        if let reason = focusMoved(target) { return reason }
        return secureNow(target)
    }

    /// Nil while the field and every ancestor up to its window answer that
    /// they are not secure; one asking.
    static func secureNow(_ target: FieldTarget) -> EditReason? {
        switch AXWritingSurface.secureAncestry(target.element, window: target.window) {
        case false?: return nil
        case true?: return .secureField
        case nil: return .targetUnresponsive
        }
    }

    /// Nil while the same launch of the app still has the field focused: one
    /// read, for the moment before a write or a key.
    static func focusMoved(_ target: FieldTarget) -> EditReason? {
        guard let started = processStart(target.pid), started == target.started else { return .appEnded }
        switch AXElement(ref: AXUIElementCreateSystemWide()).element(kAXFocusedUIElementAttribute) {
        case let .success(focused) where focused.sameElement(as: target.element): return nil
        case let .failure(failure) where failure.isTimeout: return .targetUnresponsive
        case let .failure(failure) where target.unfocused && (failure.code == .noValue || failure.code == .attributeUnsupported):
            // Another app that answers nothing has focus would answer the
            // same, so the app with focus is asked for first.
            guard case let .success(app) = AXElement(ref: AXUIElementCreateSystemWide()).element(kAXFocusedApplicationAttribute),
                  app.pid() == target.pid,
                  case let .success(window) = AXElement.application(target.pid).element(kAXFocusedWindowAttribute),
                  window.sameElement(as: target.window) else { return .focusChanged }
            return nil
        default: return .focusChanged
        }
    }

    static func recheckFocus(_ target: FieldTarget) -> EditReason? {
        guard AXIsProcessTrusted() else { return .permissionMissing }
        if let reason = focusMoved(target) { return reason }
        // A wrapper can turn secure without focus moving.
        return secureNow(target)
    }

    /// Whether the field and every ancestor up to its window answer that
    /// they are not secure. Checked before each read of the field's text
    /// after admission.
    static func secureClear(_ target: FieldTarget) -> Bool {
        AXWritingSurface.secureAncestry(target.element, window: target.window) == false
    }

    /// A WebKit field's text as a marker range and its length by markers,
    /// from the start of the range the field gives for its own text to the
    /// later of that range's end and its last descendant's end, and whether
    /// it reaches past the field's own range. Nil when a read does not
    /// answer.
    ///
    /// WebKit ends a field's own range early: at the end of the first text
    /// of its last block, or before an image there. In the fixture's editor
    /// with a `div` for each line, two lines written at a caret in the
    /// middle of a line leave the last line in two text nodes, and the
    /// field's range then ended at the caret, 62 of 94, while the last
    /// block's range reached 94. A trailing `<br>` in a last paragraph,
    /// which is no element of its own, ends past the last descendant
    /// instead: 12 by the field's range, 11 by its last block.
    ///
    /// `own` and `ownLength` are the field's own range and its length, for
    /// the one case where the reach past it is not text; see
    /// `TextReader.webKitLengths`.
    static func webKitText(
        of element: AXElement
    ) -> (range: AXTextMarkerRange, length: Int, pastOwnRange: Bool, own: AXTextMarkerRange, ownLength: Int)? {
        guard let own = element.textMarkers(), let last = lastDescendantEnd(of: element) else { return nil }
        let (start, ownEnd) = (AXTextMarkerRangeCopyStartMarker(own), AXTextMarkerRangeCopyEndMarker(own))
        guard let ownLength = element.length(from: start, to: ownEnd), let lastLength = element.length(from: start, to: last),
              ownLength >= 0, lastLength >= 0 else { return nil }
        return lastLength > ownLength
            ? (AXTextMarkerRangeCreate(nil, start, last), lastLength, true, own, ownLength)
            : (own, ownLength, false, own, ownLength)
    }

    /// The end of the text of the element's last descendant, reached by
    /// taking the last child down to one with no children; the element's
    /// own end where it has none. Nil when a read does not answer, and
    /// past 64 levels.
    static func lastDescendantEnd(of element: AXElement) -> AXTextMarker? {
        var element = element
        for _ in 0...64 {
            guard case let .success(children) = element.children() else { return nil }
            guard let last = children.last else { return element.textMarkers().map { AXTextMarkerRangeCopyEndMarker($0) } }
            element = last
        }
        return nil
    }

    static func pageHost(of element: AXElement, window: AXElement) -> String? {
        var current = element
        for _ in 0..<40 {
            guard case let .success(role) = current.string(kAXRoleAttribute) else { return nil }
            if role == "AXWebArea" { return address(of: current)?.host?.lowercased() }
            if current.sameElement(as: window) { return nil }
            guard case let .success(parent) = current.element(kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    /// A web area's address, from `AXURL`, which WebKit and Chromium both
    /// give on a web area, as a URL or as text; where an engine does not
    /// offer that attribute, from `AXDocument`. A read that fails in any
    /// other way is no address.
    static func address(of webArea: AXElement) -> URL? {
        switch webArea.value(kAXURLAttribute) {
        case let .success(value):
            return url(from: value)
        case let .failure(failure) where failure.code == .attributeUnsupported || failure.code == .noValue:
            guard case let .success(value) = webArea.value(kAXDocumentAttribute) else { return nil }
            return url(from: value)
        case .failure:
            return nil
        }
    }

    private static func url(from value: CFTypeRef) -> URL? {
        if CFGetTypeID(value) == CFURLGetTypeID() { return value as? URL }
        if CFGetTypeID(value) == CFStringGetTypeID() { return URL(string: value as! String) }
        return nil
    }

    // MARK: - Reading and verifying

    /// The selection and its surroundings. The reader asks that the field is
    /// not secure before each read of its text.
    fileprivate static func readState(_ reader: TextReader) -> FieldState? {
        let (element, markers) = (reader.element, reader.markers)
        guard let selection = selectedRange(of: element, markers: markers) else { return nil }
        guard let (length, characters) = reader.lengths(), selection.location >= 0, selection.upperBound <= length,
              let selected = reader.text(selection),
              let before = reader.text(FieldEdit.beforeRange(for: selection)),
              let after = reader.text(FieldEdit.afterRange(for: selection, length: length)),
              // A field can turn secure while a read is answered, which the
              // asking before that read cannot see, so it is asked once more
              // after the last one: nothing read here counts unless the
              // field was not secure before each read and after all of them.
              reader.isClear()
        else { return nil }
        return FieldState(selection: selection, selectedText: selected, before: before, after: after, length: length,
                          characters: characters, breaksDoubled: reader.breaksDoubled, pastOwnRange: reader.pastOwnRange,
                          listLabels: reader.listLabels, lastRun: reader.endsByOwnRange ? reader.lastRun : nil,
                          endingRun: reader.lastRun)
    }

    /// Reads `text` and its surroundings, and the whole field when it is
    /// no longer than `wholeLimit`. Nil when the field or an ancestor is
    /// secure, or fails to answer that: it is asked before the lengths,
    /// again before each read of text and once more after the last read,
    /// as in `readState`, and one refusal ends the readback.
    ///
    /// With `lastRun`, the run of line breaks the insertion should leave at
    /// the field's end, the readback also says what run the field ends in
    /// (`Readback.lastRun`): from its text by markers where it was read
    /// whole that way, and otherwise from a read of its last `lastRun` + 1
    /// units, in the offsets its length was measured in. A longer run reads
    /// there as `lastRun` + 1, which is not the run expected.
    static func readback(_ target: FieldTarget, text: FieldRange, before: FieldRange, after: FieldRange, wholeLimit: Int = 0,
                         lastRun: Int? = nil) -> Readback? {
        guard secureClear(target) else { return nil }
        let reader = reader(target)
        guard let (length, characters) = reader.lengths() else { return reader.withheld ? nil : Readback() }
        func read(_ range: FieldRange) -> String? {
            guard range.location >= 0, range.upperBound <= length else { return nil }
            return reader.text(range)
        }
        var shown = Readback(length: length, text: read(text), before: read(before), after: read(after),
                             whole: length <= wholeLimit ? read(FieldRange(location: 0, length: length)) : nil, characters: characters)
        if let lastRun {
            shown.lastRun = reader.lastRun ?? read(FieldRange(location: length - lastRun - 1, length: lastRun + 1)).map {
                $0.utf16.reversed().prefix(while: { $0 == 10 }).count
            }
        }
        guard !reader.withheld, reader.isClear() else { return nil }
        return shown
    }

    private static func reader(_ target: FieldTarget) -> TextReader {
        TextReader(element: target.element, stringForRange: target.stringForRange, markers: target.markers, rangedLength: target.rangedLength,
                   webKit: target.webKit, clear: { secureClear(target) })
    }

    /// The field's selection and the text around it as it is now, for a
    /// caller's guard to compare with what it captured. Read under the
    /// same rules as a recheck: the field and its ancestors are asked that
    /// they are not secure before each read of text. Nil when they do not
    /// answer that, or the text does not come.
    static func currentState(of target: FieldTarget) -> FieldState? {
        readState(reader(target))
    }

    /// The readback at the place `facts` puts the inserted text.
    static func inserted(_ facts: EditFacts, in target: FieldTarget) -> Readback? {
        readback(target, text: facts.range, before: facts.beforeRange, after: facts.afterRange, wholeLimit: facts.wholeLimit,
                 lastRun: facts.lastRunAfter)
    }

    /// Nil when the field turned secure or stopped answering. A field that
    /// came out shorter than expected may hold the inserted text's line
    /// breaks as paragraph breaks that its offsets leave out; see
    /// `EditFacts.leftOut`. That reading is tried beside the plain one and
    /// adopted only when its own readback confirms it, since a field not yet
    /// written can show the same length; `facts` then takes that reading.
    static func verifyInsertion(_ facts: inout EditFacts, state: FieldState, in target: FieldTarget) -> ReadbackVerdict? {
        func verdict(_ facts: EditFacts) -> (ReadbackVerdict, Readback)? {
            guard let shown = inserted(facts, in: target),
                  let unchanged = readback(
                      target, text: state.selection, before: facts.beforeRange,
                      after: FieldRange(location: state.selection.upperBound, length: facts.after.utf16.count),
                      wholeLimit: facts.wholeLimit
                  ) else { return nil }
            return (FieldEdit.verifyInsertion(shown, unchangedProbe: unchanged, facts: facts), shown)
        }
        func checked(_ candidate: EditFacts) -> (ReadbackVerdict, EditFacts, Readback)? {
            guard let (plain, shown) = verdict(candidate) else { return nil }
            if plain == .expected { return (plain, candidate, shown) }
            // Chromium may leave one break out of each inserted run.
            let runs = FieldEdit.breakRuns(candidate.insertedText).count
            guard runs > 0, let length = shown.length,
                  case let short = candidate.lengthAfter - length, short > 0, short <= runs,
                  let there = readback(target, text: FieldRange(location: candidate.range.location, length: candidate.range.length - short),
                                       before: candidate.beforeRange, after: FieldRange(location: 0, length: 0)),
                  let read = there.text, let leftOut = FieldEdit.breaksLeftOut(of: candidate.insertedText, in: read)
            else { return (plain, candidate, shown) }
            let other = candidate.reading(leftOut: leftOut)
            guard let (adapted, adaptedRead) = verdict(other) else { return nil }
            return adapted == .expected ? (adapted, other, adaptedRead) : (plain, candidate, shown)
        }
        guard let (plain, confirmed, _) = checked(facts) else { return nil }
        if plain == .expected { facts = confirmed; return plain }
        if target.gmailBlankParagraph, let other = facts.withConsumedGmailPlaceholder() {
            guard let (gmail, adapted, shown) = checked(other) else { return nil }
            // Only a complete, otherwise exact body can consume this placeholder.
            // Paragraph offsets and character counts still use the ordinary checks.
            if gmail == .expected,
               FieldEdit.comparable(shown.whole) == FieldEdit.comparable(adapted.readText) {
                guard let matches = outlookParagraphEvidence(adapted, shown: shown, target: target) else { return nil }
                guard matches else { return plain }
                facts = adapted
                return .expected
            }
        }
        guard target.outlookBlankParagraph,
              let other = facts.withOutlookBlankParagraph() else { return plain }
        guard let (outlook, confirmed, shown) = checked(other) else { return nil }
        // Account for exactly the observed first placeholder being consumed.
        // Require the complete ranged text, including
        // every remaining blank line, as well as the normal range/count
        // checks. A signature, extra edit or a paste elsewhere cannot pass.
        guard outlook == .expected,
              FieldEdit.comparable(shown.whole) == FieldEdit.comparable(confirmed.readText + confirmed.after) else { return plain }
        guard let matches = outlookParagraphEvidence(confirmed, shown: shown, target: target) else { return nil }
        guard matches else { return plain }
        facts = confirmed
        return .expected
    }

    /// Corroborate the omitted boundary through the value and paragraph
    /// start markers, independently of the ranged read. This value is never
    /// sliced in ranged offsets and never supplies a missing ranged read.
    /// Counts alone cannot distinguish "aa\n" from "a\na"; value alone
    /// cannot distinguish one paragraph break from two empty paragraphs.
    private static func outlookParagraphEvidence(_ facts: EditFacts, shown: Readback, target: FieldTarget) -> Bool? {
        let expected = facts.outlookParagraphEvidence
        guard let length = shown.length,
              let starts = target.element.blockStarts(expectedLength: length), starts == expected.starts,
              case let .success(count) = target.element.int(kAXNumberOfCharactersAttribute),
              count == expected.value.utf16.count, count == (shown.characters ?? shown.length) else { return false }
        guard secureClear(target) else { return nil }
        guard case let .success(value) = target.element.string(kAXValueAttribute) else { return false }
        guard secureClear(target) else { return nil }
        return value.utf16.count == count && FieldEdit.comparable(value) == FieldEdit.comparable(expected.value)
    }

    /// The selection as UTF-16 offsets, from the selection range or, for a
    /// field addressed by markers, from the offsets of its selection markers.
    static func selectedRange(of element: AXElement, markers: Bool) -> FieldRange? {
        try? (markers ? element.markerSelection() : element.range(kAXSelectedTextRangeAttribute)).get()
    }

    /// `TextInserter.selectWholeField` on the executor: the expected field
    /// read as a write would read it, refused where an earlier write may
    /// still land as `insertDirectly` refuses it, then the secure check and
    /// the caller's final check as the last reads before the selection is
    /// set over the field's whole length, in the offsets its selection
    /// takes, and confirmed.
    static func selectWhole(ownPID: pid_t, expecting: ExpectedFocus, unsettled: [UnsettledWrite],
                            finalCheck: FocusedField.Guard?) -> Result<FieldRange, EditReason> {
        let target: FieldTarget
        switch focusedTarget(ownPID: ownPID, expecting: expecting) {
        case let .success(found): target = found
        case let .failure(reason): return .failure(reason)
        }
        for earlier in unsettled {
            var collapsedCaret: FieldRange?
            var caretChangeIssued = false
            switch Self.earlier(earlier, on: target, collapsedCaret: &collapsedCaret, caretChangeIssued: &caretChangeIssued) {
            case .mayLand: return .failure(.earlierUnsettled)
            case .mayLandNearby: return .failure(.earlierUnsettledNearby)
            case .elsewhere, .settled, .expired: break
            }
            if collapsedCaret != nil || caretChangeIssued { return .failure(.fieldChanged) }
        }
        guard let state = target.state else { return .failure(.unreadableField) }
        let whole = FieldRange(location: 0, length: state.length)
        if let reason = focusMoved(target) ?? secureBeforeEdit(target) { return .failure(reason) }
        if let reason = finalCheck?() { return .failure(reason) }
        if state.selection == whole { return .success(whole) }
        return select(whole, in: target) ? .success(whole) : .failure(.fieldChanged)
    }

    /// Selects `range` and confirms the field reports it selected.
    static func select(_ range: FieldRange, in target: FieldTarget) -> Bool {
        if target.markers {
            guard let markers = target.element.markers(for: range),
                  target.element.setValue(markerSelectionAttribute, markers) == .success else { return false }
        } else {
            guard target.element.setRange(kAXSelectedTextRangeAttribute, range) == .success else { return false }
        }
        for attempt in 0..<writeSettle.attempts {
            if attempt > 0 { Thread.sleep(forTimeInterval: writeSettle.interval) }
            if selectedRange(of: target.element, markers: target.markers) == range { return true }
        }
        return false
    }

    /// Completes a marker replacement without writing any text. Only its
    /// exact selected range may become the empty range at its end. Reads
    /// only that replacement and the field's length, compares and drops
    /// them, and confirms both again after the selection change.
    /// Selection and text reads precede the final focus and secure checks;
    /// making the caret markers also precedes them. Like a text write,
    /// this check is not atomic with the receiving app.
    static func collapseReplacement(_ range: FieldRange, text: String, length: Int, in target: FieldTarget,
                                    onCaretChange: () -> Void = {}) -> Bool {
        let caret = FieldRange(location: range.upperBound, length: 0)
        let none = FieldRange(location: range.location, length: 0)
        func unchanged() -> Bool {
            guard let shown = readback(target, text: range, before: none, after: none) else { return false }
            return shown.length == length && FieldEdit.comparable(shown.text) == FieldEdit.comparable(text)
        }
        guard recheckFocus(target) == nil, unchanged(),
              let markers = target.element.markers(for: caret), target.element.offsets(of: markers) == caret,
              let selection = selectedRange(of: target.element, markers: target.markers),
              selection == range || selection == caret,
              labels(of: target.element) == target.labels, focusMoved(target) == nil,
              secureBeforeEdit(target) == nil else { return false }
        if selection == range {
            // The call can move the caret even when its answer or the
            // confirmation is lost. Protect the earlier words from here.
            onCaretChange()
            guard target.element.setValue(markerSelectionAttribute, markers) == .success else { return false }
        }
        for attempt in 0..<writeSettle.attempts {
            if attempt > 0 { Thread.sleep(forTimeInterval: writeSettle.interval) }
            guard recheckFocus(target) == nil, unchanged() else { return false }
            if selectedRange(of: target.element, markers: target.markers) == caret,
               focusMoved(target) == nil, secureBeforeEdit(target) == nil { return true }
        }
        return false
    }

    /// Repeats a readback until it shows the expected result or the attempts
    /// run out, since apps can apply an accepted write later. Stops with nil
    /// when `verify` does, such as when the field turns secure.
    static func settle(_ schedule: (attempts: Int, interval: Double), _ verify: () -> ReadbackVerdict?) -> ReadbackVerdict? {
        guard var verdict = verify() else { return nil }
        for _ in 1..<schedule.attempts where verdict != .expected {
            Thread.sleep(forTimeInterval: schedule.interval)
            guard let next = verify() else { return nil }
            verdict = next
        }
        return verdict
    }
}

/// Reads field text by UTF-16 range. Uses the ranged attribute when the
/// field offers it. A field that offers none has its full value sliced,
/// read once and dropped with the reader. A field addressed by markers answers an empty
/// value whatever it holds, so its length comes from its end marker and its
/// text only from the ranged attribute. Before every read of text it asks
/// `clear` whether the field and its ancestors still answer that they are
/// not secure, and withholds the read when they do not.
private final class TextReader {
    let element: AXElement
    let markers: Bool
    private let stringForRange: Bool
    private let rangedLength: Bool
    private let webKit: Bool
    private let clear: () -> Bool
    private var value: NSString?
    /// The field's whole text as its markers read it, once `lengths` has
    /// found that its ranged reads count paragraph breaks twice.
    private var byMarkers: NSString?
    /// A read of text was withheld because `clear` did not pass.
    private(set) var withheld = false

    /// See `FieldState.breaksDoubled`.
    var breaksDoubled: Bool { byMarkers != nil }
    /// See `FieldState.pastOwnRange`.
    private(set) var pastOwnRange = false
    /// See `FieldState.listLabels`.
    private(set) var listLabels = false
    /// The field was read by the range WebKit gives for its own text, with
    /// no list labels, so the run of breaks that ends its text by markers
    /// was held against the ranged reads only as m facing m to 2m; see
    /// `FieldState.lastRun`.
    private(set) var endsByOwnRange = false
    /// The run of line breaks that ends the text kept from `lengths`, which
    /// is read whole by markers; nil where it was not.
    var lastRun: Int? {
        byMarkers.map { text in (text as String).utf16.reversed().prefix(while: { $0 == 10 }).count }
    }

    init(element: AXElement, stringForRange: Bool, markers: Bool, rangedLength: Bool, webKit: Bool, clear: @escaping () -> Bool) {
        self.element = element
        self.stringForRange = stringForRange
        self.markers = markers
        self.rangedLength = rangedLength
        self.webKit = webKit
        self.clear = clear
    }

    /// Asks `clear`, and records a refusal.
    func isClear() -> Bool {
        if clear() { return true }
        withheld = true
        return false
    }

    /// The field's length in the offsets its ranged reads take, and its
    /// character count where that differs; see `FieldState.characters`.
    ///
    /// Where the markers measure a web field shorter than its character
    /// count, the engines differ, and the field's engine says which reading
    /// holds; no read that could fail decides it. Chromium's ranged reads
    /// leave paragraph breaks out, and the markers' length is theirs, when
    /// no character answers at that length. WebKit's ranged reads count a
    /// paragraph break twice, while its selection and replace range take
    /// the markers' offsets. There the text is read whole through the
    /// markers and sliced. It must be as long as the markers say, and
    /// agree with the ranged reads run by run; see `webKitLengths`. That
    /// read costs what a ranged read of 64 units does: 0.4 ms in a field
    /// of 100,000 characters and 3.5 ms in one of a million, measured.
    ///
    /// A length in one kind of offset never stands in for one in another:
    /// a field that grew by nothing can differ between the two by exactly
    /// the length of the text just written. So a web field whose count or
    /// marker length does not answer, or whose text by markers has another
    /// length once a list's labels are taken out, has no length this time.
    func lengths() -> (length: Int, characters: Int?)? {
        if markers { return element.markerLength().map { ($0, nil) } }
        guard case let .success(count) = element.int(kAXNumberOfCharactersAttribute) else {
            return rangedLength ? nil : fullValue().map { ($0.length, nil) }
        }
        guard rangedLength else { return (count, nil) }
        if webKit { return webKitLengths(count: count) }
        guard let ranged = element.rangedLength(), ranged >= 0 else { return nil }
        guard ranged < count else { return (count, nil) }
        // The probe for a character at that offset is a read of text. An
        // app that does not answer it in time says nothing either way.
        guard isClear() else { return nil }
        switch element.string(for: FieldRange(location: ranged, length: 1)) {
        case .success: return (count, nil)
        case let .failure(failure): return failure.isTimeout ? nil : (ranged, count)
        }
    }

    /// `lengths` for a WebKit field, measured by its markers over
    /// `FieldAccess.webKitText`. Where that is shorter than the count, the
    /// field reads as one whose ranged reads count paragraph breaks twice
    /// only when the text by markers and the ranged reads over the whole
    /// count say so run by run; see `FieldEdit.breaksCountedTwice`. A
    /// marker range that ends early reads the same by lengths alone, and a
    /// write the field ignored would then read as landed. Otherwise the
    /// field has no length this time.
    ///
    /// Measured past the field's own range, the text by markers must also
    /// end in as many line breaks as the ranged reads do. A real empty last
    /// paragraph, `<p>Alpha</p><p><br></p>`, reads "Alpha\n\n" by markers
    /// and "Alpha\n\n\n" by ranged reads, and its own range reached its
    /// end in every state probed; a last descendant's range that stopped
    /// one break short would read the same.
    ///
    /// An image with alt text is one unit by the markers, U+FFFC in their
    /// text, and nothing in the count or the ranged reads, and the field's
    /// own range ends before one in its last block. So where the text past
    /// the own range holds one, the lengths past it compare unlike things:
    /// `<p>Alpha</p><p>BravoDelta<img alt="Picture"></p>` is 16 by its own
    /// range, 17 to its last descendant and 17 by its count, which reads as
    /// a field whose reads all agree while its ranged reads hold the break
    /// twice. Such a field is measured by its own range, as it was before
    /// the reach past it was added; see `ownRangeLengths`. It still counts
    /// as read past its own range, so it takes the paste.
    ///
    /// Text by markers longer than they measure holds a list's labels,
    /// which are taken out against the ranged reads; see
    /// `FieldEdit.aligned`. What is left must be as long as the
    /// markers measure, and such a field takes the paste; see
    /// `FieldState.listLabels`.
    private func webKitLengths(count: Int) -> (length: Int, characters: Int?)? {
        guard let measured = FieldAccess.webKitText(of: element) else { return nil }
        pastOwnRange = measured.pastOwnRange
        let ranged = measured.length
        guard measured.pastOwnRange || ranged < count else { return (count, nil) }
        guard isClear(), case let .success(text) = element.string(for: measured.range) else { return nil }
        // The ranged reads over the whole count, read once and only where
        // they are needed.
        var all: String?
        func counted() -> String? {
            if all == nil, isClear(), case let .success(read) = element.string(for: FieldRange(location: 0, length: count)) { all = read }
            return all
        }
        // The two texts lined up, once and only where they are needed.
        var alignment: FieldEdit.Alignment?
        func aligned() -> FieldEdit.Alignment? {
            if alignment == nil, let counted = counted(), let found = FieldEdit.aligned(byMarkers: text, ranged: counted) {
                alignment = found
                listLabels = found.labels
            }
            return alignment
        }
        var whole = text as NSString
        // Longer than the markers measure it: a list's labels.
        if whole.length > ranged {
            guard let aligned = aligned() else { return nil }
            whole = aligned.text as NSString
        }
        guard whole.length == ranged else { return nil }
        if measured.pastOwnRange {
            if whole.substring(from: measured.ownLength).utf16.contains(0xFFFC) {
                return ownRangeLengths(measured.own, measured.ownLength, count: count)
            }
            guard ranged < count else { return (count, nil) }
        }
        // A field whose labels were taken out must end in as many breaks by
        // markers as by ranged reads, as one read past its own range must.
        // `<p>ab</p><ul><li>…</li></ul><p><br><br></p>` ends in three by
        // markers and four by ranged reads, so a marker range one break
        // short reads the same, and once it came right an ignored paste
        // would read as landed; such a list stays unreadable, as on `main`.
        // A field without labels keeps `main`'s reading by its own range,
        // and its readback must find the run that ends its text where the
        // insertion leaves it; see `FieldState.lastRun`.
        guard let counted = counted(), let aligned = aligned(), aligned.text.utf16.count == ranged,
              FieldEdit.breaksCountedTwice(byMarkers: aligned.text, ranged: counted,
                                           lastRunExact: measured.pastOwnRange || aligned.labels)
        else { return nil }
        // An image with alt text is U+FFFC and one unit of the markers'
        // lengths, and has no offset in the selection, the replace range,
        // `AXIndexForTextMarker` or the ranged reads: in
        // `<p>Start.</p><p>One<img alt="Picture">Six</p><p>End.</p>` with
        // the caret after "S" the WebKit host put the selection at 11 where
        // the markers measured 12, and a replace range at 11 wrote after
        // the "S". So the text kept leaves images out, and its length is in
        // the selection's offsets. A U+FFFC typed as text has an offset in
        // every read and stays.
        let shown = aligned.selectionText as NSString
        byMarkers = shown
        endsByOwnRange = !measured.pastOwnRange && !aligned.labels
        return (shown.length, nil)
    }

    /// A WebKit field measured by its own range alone, where the text past
    /// it holds an image. Shorter than the count, the field's text is its
    /// text by that range, which must be as long as the range says. It is
    /// not held against the ranged reads run by run: what lies between the
    /// own range's end and the image, such as the `<br>` in
    /// `<p>Alpha</p><p>BravoDelta<br><img alt="Picture"></p>`, is in the
    /// ranged reads and not in this text, so the two cannot agree to the
    /// end.
    private func ownRangeLengths(_ own: AXTextMarkerRange, _ ownLength: Int, count: Int) -> (length: Int, characters: Int?)? {
        guard ownLength < count else { return (count, nil) }
        guard isClear(), case let .success(text) = element.string(for: own) else { return nil }
        let whole = text as NSString
        guard whole.length == ownLength else { return nil }
        byMarkers = whole
        return (ownLength, nil)
    }

    func text(_ range: FieldRange) -> String? {
        if range.length == 0 { return "" }
        if let byMarkers {
            // Kept from `lengths`, so no read follows; the field is asked
            // all the same before any of it is handed on.
            guard isClear(), range.location >= 0, range.upperBound <= byMarkers.length else { return nil }
            return byMarkers.substring(with: NSRange(location: range.location, length: range.length))
        }
        // A ranged read that fails is not retried against the value, whose
        // offsets can differ from the ones the field's ranges take.
        if stringForRange { return isClear() ? try? element.string(for: range).get() : nil }
        guard !markers, let value = fullValue(), range.location >= 0, range.upperBound <= value.length else { return nil }
        return value.substring(with: NSRange(location: range.location, length: range.length))
    }

    private func fullValue() -> NSString? {
        if value == nil, isClear(), case let .success(string) = element.string(kAXValueAttribute) { value = string as NSString }
        return value
    }
}
