import AppKit
import ApplicationServices
import Foundation

/// The body of an email being written, as an insertion will need it, and
/// its text. `field` carries a guard that refuses the insertion once the
/// field's selection or the text around it read differently from what was
/// captured, or focus has moved.
///
/// The body's text is read from the focused field alone. Once it is, the
/// window around it is read for the email's recipients, its subject and
/// the thread it answers (`ComposeAccess.surroundings`), and those go to
/// the route with the body.
struct ComposeCapture: @unchecked Sendable {
    var field: FocusedField
    var observation: EmailBody
    /// `field` for the email written from `observation`: its guard also
    /// reads the field's whole body once, on its first call, when the
    /// insertion starts, and refuses the email unless the part the route
    /// was sent reads the same, so a reply written from a thread edited
    /// since, even far from the caret and to the same length, does not go
    /// into the changed message. Every later call is `field`'s own guard.
    /// Words typed in an email's place take `field`, since they do not
    /// depend on the body.
    var emailField: FocusedField
    /// The selection when the body was read, in the field's own offsets.
    var selection: FieldRange
    /// The whole body in the same offsets as `selection`. Chromium may
    /// omit paragraph breaks that are present in `observation.body`.
    var wholeSelection: FieldRange
    /// Whether `observation.body` holds the whole body, not cut to
    /// `ComposeAccess.bodyLimit`.
    var bodyComplete: Bool
    /// Every-write exact body check for an explicitly confirmed replacement.
    /// Ordinary email insertion keeps its existing normalized body guard.
    var replacementGuard: FocusedField.Guard? = nil
    /// For a reply proposal's read of Gmail's body, what shows the body's
    /// first line in view; nil for every other read and when it did not
    /// answer.
    var visibility: BodyVisibility? = nil
    /// For a reply proposal's read of Gmail's body with a selection, the
    /// selection's bounds in Accessibility coordinates, so the card can
    /// keep clear of what a second Tab would replace; nil for every other
    /// read and when it did not answer.
    var selectionFrame: CGRect? = nil
}

/// Where a Gmail reply body is and what says its first line is in view,
/// for a proposal card placed from the body's frame when the caret cannot
/// be found: the body's frame and the frames of the nearest scroll area
/// above it and of its window, in Accessibility coordinates, sampled
/// together, with the body's frame read before and after the other two and
/// the same both times (`ComposeAccess.visibility`).
struct BodyVisibility: Equatable, Sendable {
    var body: CGRect
    var scrollArea: CGRect
    var window: CGRect

    /// Whether the body starts inside both, its top-left corner being
    /// where its first line starts. A zero-height body, as Gmail's empty
    /// one reports, is judged by that corner alone.
    var showsFirstLine: Bool {
        scrollArea.contains(body.origin) && window.contains(body.origin)
    }
}

/// A yes or no shared by guards only on the inserter's executor.
private final class Flag: @unchecked Sendable {
    var value = false
}

/// What the focused field is to voice compose.
enum ComposeTarget: @unchecked Sendable {
    /// Any field that is not the body of an email being written, and any
    /// field that cannot be told: dictation types into it as it always has.
    case plain
    /// The body of an email being written, with its text read.
    case emailBody(ComposeCapture)
    /// The body of an email being written, without its text: a read of it
    /// failed, timed out or disagreed with its length, or the field turned
    /// secure, with that reason; or, with nil, the text was not asked for,
    /// because no email could be written now. No email can come from it,
    /// so dictation types the words and tells the person.
    case emailBodyWithoutText(EditReason?)
}

/// A read of the focused field handed to the inserter's executor, awaited
/// later.
final class ComposeRead: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Result<ComposeTarget, EditReason>?
    private var waiting: CheckedContinuation<Result<ComposeTarget, EditReason>, Never>?

    func finish(_ result: Result<ComposeTarget, EditReason>) {
        lock.lock()
        guard let waiting else {
            answer = result
            lock.unlock()
            return
        }
        self.waiting = nil
        lock.unlock()
        waiting.resume(returning: result)
    }

    var value: Result<ComposeTarget, EditReason> {
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

/// The field focus landed in, when it could be Gmail's reply body: its
/// process and launch and the element itself, read on the inserter's
/// executor at the cost of the focused element and its description, and
/// its frame, in Accessibility coordinates, and, for a card placed from the
/// body when the caret cannot be found, where the body is and what shows
/// its first line in view; each nil when it did not answer.
struct ProposalCandidate: @unchecked Sendable {
    let pid: pid_t
    let started: UInt64?
    let element: AXElement
    let frame: CGRect?
    var visibility: BodyVisibility? = nil
    /// Whether the body held only line breaks, or nothing, when this read
    /// was made, asked only by a read made with `blank`; nil when not
    /// asked or when it did not answer. A reply proposal takes it as the
    /// body being empty before the person's first key in it, the evidence
    /// a reply already typed into needs before it takes the draft held for
    /// its thread (`ReplyProposalController`).
    var blank: Bool? = nil

    /// This field, as a later read must find it focused.
    var expectation: ExpectedFocus { ExpectedFocus(pid: pid, started: started, element: element) }
}

/// A candidate read handed to the inserter's executor, awaited later; nil
/// means the field is not one.
final class ProposalCandidateRead: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Result<ProposalCandidate?, EditReason>?
    private var waiting: CheckedContinuation<Result<ProposalCandidate?, EditReason>, Never>?
    private var rejected: ComposeAccess.CandidateRejection?
    private var identified: ExpectedFocus?

    var focus: ExpectedFocus? {
        lock.lock()
        defer { lock.unlock() }
        return identified
    }

    func identify(_ focus: ExpectedFocus) {
        lock.lock()
        identified = focus
        lock.unlock()
    }

    var rejection: ComposeAccess.CandidateRejection? {
        lock.lock()
        defer { lock.unlock() }
        return rejected
    }

    func reject(_ reason: ComposeAccess.CandidateRejection) {
        lock.lock()
        rejected = reason
        lock.unlock()
    }

    func finish(_ result: Result<ProposalCandidate?, EditReason>) {
        lock.lock()
        guard answer == nil else { lock.unlock(); return }
        answer = result
        let waiting = waiting
        self.waiting = nil
        lock.unlock()
        waiting?.resume(returning: result)
    }

    var value: Result<ProposalCandidate?, EditReason> {
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

extension TextInserter {
    /// Start on the notice's path, on a read-only executor independent of
    /// insertion. Compare again after the surroundings walk so a mixed read
    /// cannot authorize replacing a different selection.
    func readProposalSnapshot(expecting: ExpectedFocus, visibility: Bool = false) -> ComposeRead {
        let read = ComposeRead()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let queued = proposalSnapshotExecutor.submit(deadline: .now + .milliseconds(250)) { expired in
            guard !expired else { read.finish(.failure(.busy)); return }
            let answer = ComposeAccess.focusedEmailDraft(ownPID: ownPID, text: true, expecting: expecting, visibility: visibility)
            guard case let .success(.emailBody(capture)) = answer else { read.finish(answer); return }
            // Compare exact text, including controls and line breaks, after
            // the surroundings walk. The write guard normalizes email text.
            guard case let .success(target) = FieldAccess.focusedTarget(ownPID: ownPID, expecting: expecting),
                  target.state?.selection == capture.selection,
                  case let .success(body) = ComposeAccess.bodyText(of: target), body == capture.observation.body,
                  capture.field.stillCurrent?() == nil else { read.finish(.failure(.fieldChanged)); return }
            read.finish(answer)
        }
        if !queued { read.finish(.failure(.busy)) }
        return read
    }

    /// Starts reading, on the inserter's executor, whether the focused
    /// field could be Gmail's reply body: in a Chromium browser, a field
    /// whose own description is "Message Body" on a page at
    /// mail.google.com. Any other field costs the focused element and its
    /// description and nothing more; no text is read. For that body it also
    /// reads its frame and what shows it in view (`ComposeAccess.visibility`).
    /// With `expecting`, as a proposal's own reread of its body's geometry
    /// asks, the read is made only while that field has focus, and refuses
    /// with `focusChanged` before it reads anything of another field.
    /// `blank` also asks, of that body alone, whether it holds only line
    /// breaks (`ProposalCandidate.blank`).
    func readProposalCandidate(expecting: ExpectedFocus? = nil, blank: Bool = false) -> ProposalCandidateRead {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let read = ProposalCandidateRead()
        let queued = submit {
            read.finish(ComposeAccess.proposalCandidate(ownPID: ownPID, expecting: expecting, blank: blank,
                                                       rejected: read.reject, identified: read.identify))
        }
        if !queued { read.finish(.failure(.busy)) }
        return read
    }

    /// Starts reading, on the inserter's executor, whether the focused
    /// field is the body of an email being written and, only when it is
    /// and `text` asks for it, its selection and the text around it and
    /// its whole text, of which `ComposeAccess.bodyLimit` scalars are
    /// kept, then what the window shows around it: recipients, subject and
    /// the thread it answers. Dictation asks once, when the person's words
    /// have come back, and asks for the text only when an email can be
    /// written now; the text is kept in memory for that request and never
    /// logged. An email body whose text
    /// cannot be read, or was not asked for, answers
    /// `emailBodyWithoutText`; any other field answers `plain` without a
    /// read of its text, and the read fails when the field cannot be told
    /// at all, as when no field has focus. With `expecting`, the read is
    /// made only while that field has focus, and refuses with
    /// `focusChanged` before it reads anything of another field.
    /// `visibility`, which only a reply proposal asks for, also reads what
    /// shows a Gmail body's first line in view (`ComposeAccess.visibility`)
    /// and, with a selection, its bounds.
    func readFocusedEmailDraft(text: Bool, expecting: ExpectedFocus? = nil, visibility: Bool = false) -> ComposeRead {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let read = ComposeRead()
        let queued = submit {
            read.finish(ComposeAccess.focusedEmailDraft(ownPID: ownPID, text: text, expecting: expecting, visibility: visibility))
        }
        if !queued { read.finish(.failure(.busy)) }
        return read
    }
}

/// Accessibility reads of the focused field for an email, and of the
/// window around it once it is an email body, run only on Accessibility
/// executors. Text read here is handed to the request that asked for it and
/// dropped; nothing is logged. The check that the field and its
/// ancestors are not secure is the statement right before each read of
/// text, and is asked once more after the body's; a check that cannot be
/// made ends the read. Once the field is known to be an email body, a read
/// that fails leaves it that, without its text, so dictation can say why
/// the words were typed.
enum ComposeAccess {
    /// The most of the body that is kept, in Unicode scalars: the input's
    /// own bound for the observed thread, twice over, since the input cuts
    /// to its bound itself. The body is read whole and cut to this once
    /// it has passed the length check (`bodyText`).
    static let bodyLimit = 32_000
    static let mailBundleIdentifier = "com.apple.mail"
    /// The identifier of the To field of a Mail window for writing a
    /// message, on a text field: how the `mail` insertion scene tells the
    /// new message it opened from Mail's other windows
    /// (`InsertionChecks.mail`), in every run recorded on October 3 and 4,
    /// 2026.
    static let mailToFieldIdentifier = "Mail.toField"
    /// The most elements of a Mail window read to find its To field, and
    /// how long that walk may take. Not yet measured in a real compose
    /// window; a walk that reaches either is not a compose window.
    static let mailWindowLimit = 400
    static let mailWindowBudget: Duration = .milliseconds(500)
    /// The page Gmail's compose lives on, and how its body names itself.
    static let gmailHost = GmailBodyIdentity.host
    static let gmailBodyDescription = GmailBodyIdentity.description

    /// Provider metadata stays here so admission, the hint and context reads
    /// agree. A new provider supplies its field identity and bounded reading
    /// rules; the controller never reads an app's compose controls.
    struct Provider: Sendable {
        enum Location: Sendable {
            case native(bundleIdentifier: String, toField: String, headers: [String: WritingRecipient.Role?])
            case web(hosts: Set<String>, surroundings: ComposePage.Rules)
        }
        var location: Location
        var bodyRoles: Set<String>
        var bodyDescriptions: Set<String>
        var requiresBrowser = false
        var requiresSettableText = false
        var requiresMarkers = false
        var threadID: @Sendable (URL?) -> String? = { _ in nil }
        var provisional = false

        func couldMatch(bundleIdentifier: String?, description: String) -> Bool {
            switch location {
            case let .native(identifier, _, _):
                return bundleIdentifier == identifier && (bodyDescriptions.isEmpty || bodyDescriptions.contains(description))
            case .web:
                return (!requiresBrowser || WritingSurfacePolicy.isChromiumBrowser(bundleIdentifier: bundleIdentifier)
                        || bundleIdentifier == "com.apple.Safari" || bundleIdentifier == "com.apple.SafariTechnologyPreview")
                    && bodyDescriptions.contains(description)
            }
        }
    }

    static let providers: [Provider] = [
        Provider(location: .native(bundleIdentifier: mailBundleIdentifier, toField: mailToFieldIdentifier, headers: mailHeaderFields),
                 bodyRoles: ["AXWebArea"], bodyDescriptions: [], requiresMarkers: true),
        Provider(location: .web(hosts: [gmailHost], surroundings: .gmail),
                 bodyRoles: [kAXTextAreaRole], bodyDescriptions: [gmailBodyDescription], threadID: GmailThreadID.id),
        // Provisional DOM/screen-reader evidence, not a recorded live Mac AX
        // tree. Microsoft documents "Message body"; its published compose
        // markup also has the Alt+F10 label. Issue #454 tracks qualification.
        // https://support.microsoft.com/en-us/accessibility/outlook/use-a-screen-reader-to-format-text-in-your-email-in-outlook
        // https://learn.microsoft.com/en-us/answers/questions/4583816/images-in-signature-getting-replaced-with-alt-text?page=2
        Provider(location: .web(hosts: OutlookBodyIdentity.hosts, surroundings: .outlook),
                 bodyRoles: [kAXTextAreaRole],
                 bodyDescriptions: OutlookBodyIdentity.descriptions,
                 requiresBrowser: true, requiresSettableText: true, provisional: true),
    ]

    /// Whether the focused field could be Gmail's reply body, at the cost
    /// of the focused element, its process, its description and, only then,
    /// its window, the page's host and its frame. Nil for every other field.
    /// With `expecting`, focus on anything but that element of that launch
    /// of that app refuses with `focusChanged` before its description is
    /// read, and focus is asked again before and after the walk for what
    /// shows the body, so evidence is returned only for a body that kept
    /// focus throughout. Without it, as the scan on each focus change reads,
    /// the field is whichever has focus.
    ///
    /// `blank`, for that body alone, reads whether it is blank as an
    /// insertion reads a field (`FieldAccess.focusedTarget`, bound to the
    /// body): its selection and the text around it, up to
    /// `FieldEdit.contextLength` units either side, with the secure check
    /// before each read of text, compared and dropped. A read that does not
    /// answer leaves it nil.
    enum CandidateRejection: String, Sendable {
        case accessibility, focusRead, processRead, ownApp, focusChanged, browser, roleRead, role
        case descriptionRead, bodyClassRead, bodyIdentity, windowRead, ancestryRead, addressRead, notGmail
    }

    static func proposalCandidate(ownPID: pid_t, expecting: ExpectedFocus? = nil,
                                  blank: Bool = false,
                                  rejected: (CandidateRejection) -> Void = { _ in },
                                  identified: (ExpectedFocus) -> Void = { _ in }) -> Result<ProposalCandidate?, EditReason> {
        guard AXIsProcessTrusted() else { rejected(.accessibility); return .failure(.permissionMissing) }
        let none: Result<ProposalCandidate?, EditReason> = expecting == nil ? .success(nil) : .failure(.focusChanged)
        func reject(_ reason: CandidateRejection, transient: Bool = false) -> Result<ProposalCandidate?, EditReason> {
            rejected(reason)
            return transient ? .failure(.targetUnresponsive) : none
        }
        let focus = AXElement(ref: AXUIElementCreateSystemWide()).element(kAXFocusedUIElementAttribute)
        guard case let .success(element) = focus else { return reject(.focusRead, transient: true) }
        guard let pid = element.pid() else { return reject(.processRead, transient: true) }
        guard pid != ownPID else { return reject(.ownApp) }
        if let expecting, !FieldAccess.isExpected(element, pid: pid, expecting) { return reject(.focusChanged) }
        let expected = ExpectedFocus(pid: pid, started: FieldAccess.processStart(pid), element: element)
        identified(expected)
        let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        guard WritingSurfacePolicy.isChromiumBrowser(bundleIdentifier: bundleIdentifier) else { return reject(.browser) }
        guard case let .success(role) = element.string(kAXRoleAttribute) else { return reject(.roleRead, transient: true) }
        guard role == kAXTextAreaRole else { return reject(.role) }
        guard case let .success(description) = element.string(kAXDescriptionAttribute) else { return reject(.descriptionRead, transient: true) }
        switch gmailBodyIdentity(element, description: description) {
        case .success(true): break
        case .success(false): return reject(.bodyIdentity)
        case .failure: return reject(.bodyClassRead, transient: true)
        }
        guard case let .success(window) = element.element(kAXWindowAttribute) else { return reject(.windowRead, transient: true) }
        guard let page = webArea(atOrAbove: element) else { return reject(.ancestryRead, transient: true) }
        guard let address = address(of: page) else { return reject(.addressRead, transient: true) }
        guard address.host?.lowercased() == gmailHost else { return reject(.notGmail) }
        guard FieldAccess.hasFocus(expected) else { return reject(.focusChanged) }
        let frame = try? element.frame().get()
        let shown = visibility(of: element, window: window)
        guard FieldAccess.hasFocus(expected) else { return reject(.focusChanged) }
        let started = FieldAccess.processStart(pid)
        var empty: Bool?
        if blank, case let .success(target) = FieldAccess.focusedTarget(ownPID: ownPID, expecting: ExpectedFocus(pid: pid, started: started, element: element)) {
            empty = target.state?.blank
        }
        return .success(ProposalCandidate(pid: pid, started: started, element: element, frame: frame, visibility: shown, blank: empty))
    }

    /// Gmail's DOM classes remain stable when its accessible label is localized.
    /// This is metadata only; the caller must still establish role and host.
    private static func gmailBodyIdentity(_ element: AXElement, description: String) -> Result<Bool, AXFailure> {
        if GmailBodyIdentity.matches(description: description, classes: nil) { return .success(true) }
        switch element.value("AXDOMClassList") {
        case let .success(value):
            return .success(GmailBodyIdentity.matches(description: description, classes: (value as? [String]).map(Set.init)))
        case let .failure(error) where error.code == .attributeUnsupported || error.code == .noValue:
            return .success(false)
        case let .failure(error): return .failure(error)
        }
    }

    /// What a read of the focused page found for the thread watch
    /// (`gmailThread`).
    enum ThreadRead: @unchecked Sendable {
        /// Focus is on nothing this read follows, or a read on the way did
        /// not answer: nothing is said of what the page shows.
        case unknown
        case unavailable(ThreadReadReason)
        /// The focused page shows no Gmail thread.
        case elsewhere
        /// The thread `isNew` said was read already while it stayed open.
        case same
        /// A Gmail thread's address with no thread on the page yet, as while
        /// the thread loads.
        case notReady
        case opened(GmailThreadView)
    }

    enum ThreadReadReason: String, Sendable {
        case accessibility, focus, ownApp, browser, webArea, address, notGmail, noThreadID, messages, pageChanged
    }

    /// Whether the page that has focus in a Chromium browser shows a Gmail
    /// thread and, for one `isNew` says was not read while it stayed open,
    /// what it shows (`ComposePage.threadView`). It reads the focused
    /// element, its process, the role of it and each ancestor up to the
    /// nearest web area, and that web area's address; only for a page at
    /// mail.google.com whose address ends in a thread's token or id does
    /// it read more. No field's value is read, and nothing of another app.
    static func gmailThread(ownPID: pid_t, isNew: (pid_t, String) -> Bool) -> ThreadRead {
        guard AXIsProcessTrusted() else { return .unavailable(.accessibility) }
        guard case let .success(focused) = AXElement(ref: AXUIElementCreateSystemWide()).element(kAXFocusedUIElementAttribute),
              let pid = focused.pid() else { return .unavailable(.focus) }
        guard pid != ownPID else { return .unavailable(.ownApp) }
        guard WritingSurfacePolicy.isChromiumBrowser(bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
            else { return .unavailable(.browser) }
        guard let page = webArea(atOrAbove: focused) else { return .unavailable(.webArea) }
        return gmailThreadPage(page: page, pid: pid, started: FieldAccess.processStart(pid),
                               address: { address(of: page) }, isNew: isNew)
    }

    /// Recheck the same page after its bounded walk, so a thread change
    /// cannot attach one thread's messages to another thread's id.
    static func gmailThreadPage<Node: PageNode>(page: Node, pid: pid_t, started: UInt64?,
                                                address readAddress: () -> URL?, isNew: (pid_t, String) -> Bool) -> ThreadRead {
        guard let address = readAddress() else { return .unavailable(.address) }
        guard address.host?.lowercased() == gmailHost else { return .unavailable(.notGmail) }
        guard let threadID = GmailThreadID.id(from: address) else { return .unavailable(.noThreadID) }
        guard isNew(pid, threadID) else { return .same }
        guard let shown = ComposePage.threadView(page: page) else { return .unavailable(.messages) }
        guard readAddress() == address else { return .unavailable(.pageChanged) }
        return .opened(GmailThreadView(pid: pid, started: started, threadID: threadID, subject: shown.subject,
                                       thread: shown.thread, newestSender: shown.newestSender, account: shown.account))
    }

    /// The nearest web area at or above `element`, by the role of each
    /// element on the way; nil past a window, after 40 ancestors, or when a
    /// read on the way does not answer.
    private static func webArea(atOrAbove element: AXElement) -> AXElement? {
        var current = element
        for _ in 0..<40 {
            guard case let .success(role) = current.string(kAXRoleAttribute), role != kAXWindowRole else { return nil }
            if role == "AXWebArea" { return current }
            guard case let .success(parent) = current.element(kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    /// How many times the body's position is sampled with its scroll
    /// area's and window's frames before a body that keeps moving is given
    /// no evidence.
    static let visibilitySamples = 3

    /// Where a Gmail body is and what shows its first line in view: the
    /// nearest scroll area above the body, found by the role of each
    /// ancestor on the way, then the body's frame, that area's frame, the
    /// window's frame and the body's frame once more. A body whose two
    /// frames differ moved while the others were read, as one scrolled
    /// meanwhile does, and is sampled again, up to `visibilitySamples`
    /// times. Nothing else is read, and no text. Nil when no scroll area
    /// comes before the window, after 40 ancestors, when a read on the way
    /// does not answer, or when the body never held still for a sample, so
    /// a card placed from the body's frame then does not show.
    static func visibility(of element: AXElement, window: AXElement) -> BodyVisibility? {
        var current = element
        var scrollArea: AXElement?
        for _ in 0..<40 {
            guard case let .success(parent) = current.element(kAXParentAttribute), !parent.sameElement(as: window),
                  case let .success(role) = parent.string(kAXRoleAttribute) else { return nil }
            if role == kAXScrollAreaRole {
                scrollArea = parent
                break
            }
            current = parent
        }
        guard let scrollArea else { return nil }
        for _ in 0..<visibilitySamples {
            guard case let .success(body) = element.frame(), case let .success(area) = scrollArea.frame(),
                  case let .success(frame) = window.frame(), case let .success(after) = element.frame() else { return nil }
            if after == body { return BodyVisibility(body: body, scrollArea: area, window: frame) }
        }
        return nil
    }

    /// `text` false tells the field without reading its text, for a
    /// dictation that will type the words whatever the field is, because
    /// no email can be written now; an email body then answers
    /// `emailBodyWithoutText(nil)`. `expecting` binds the read to one field
    /// (`FieldAccess.focusedTarget`).
    static func focusedEmailDraft(ownPID: pid_t, text: Bool = true, expecting: ExpectedFocus? = nil,
                                  visibility seen: Bool = false) -> Result<ComposeTarget, EditReason> {
        let target: FieldTarget
        switch FieldAccess.focusedTarget(ownPID: ownPID, expecting: expecting) {
        case let .success(found): target = found
        case let .failure(reason): return .failure(reason)
        }
        let bundleIdentifier = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier
        guard let provider = provider(target.element, window: target.window, labels: target.labels, markers: target.markers,
                                      bundleIdentifier: bundleIdentifier) else { return .success(.plain) }
        guard text else { return .success(.emailBodyWithoutText(nil)) }
        // From here the field is an email body, and a read that does not
        // answer is that body without its text, never another field.
        // The selection and the text around it, as the insertion will
        // compare them again right before each write. Without them the
        // field turned secure while they were read, or did not answer.
        guard let state = target.state else {
            if case let .failure(reason) = clear(target.element, window: target.window) { return .success(.emailBodyWithoutText(reason)) }
            return .success(.emailBodyWithoutText(.unreadableField))
        }
        guard case let .success(frame) = target.element.frame() else { return .success(.emailBodyWithoutText(.targetUnresponsive)) }
        let whole: String
        switch wholeBodyText(of: target) {
        case let .success(text): whole = text
        case let .failure(reason): return .success(.emailBodyWithoutText(reason))
        }
        let body = ComposeInput.bounded(whole, to: bodyLimit)
        var field = FocusedField(pid: target.pid, started: target.started, element: target.element, window: target.window,
                                 frame: frame, before: state.before, bundleIdentifier: bundleIdentifier, labels: target.labels,
                                 gmailBody: target.gmailBody)
        // Only the inserter's confirmed collapse can permit this selection
        // change. Keep the captured text unchanged and derive its expected
        // caret context for each comparison; the flag holds no field text.
        let caretCollapsed = Flag()
        field.didConfirmCaretCollapse = { from, to in
            if target.method == .textOperation, state.selection.length > 0, from == state.selection,
               to == FieldRange(location: state.selection.upperBound, length: 0) {
                caretCollapsed.value = true
            }
        }
        // Asked by the inserter on its executor when the insertion starts
        // and right before each write or paste key; see
        // `FocusedField.stillCurrent`. The same launch of the app must
        // still have this element focused, not secure, with the selection
        // and the text around it as captured. A read that does not answer
        // is a reason, never a pass. The state read checks for a secure
        // field again right before each read of text; the check before it
        // names a field that turned secure as that, not as changed.
        field.stillCurrent = { () -> EditReason? in
            if let reason = FieldAccess.focusMoved(target) { return reason }
            switch AXWritingSurface.secureAncestry(target.element, window: target.window) {
            case true?: return .secureField
            case nil: return .targetUnresponsive
            case false?: break
            }
            let expected = caretCollapsed.value ? FieldEdit.afterCollapsing(state) : state
            guard let now = FieldAccess.currentState(of: target), FieldEdit.sameState(now, expected) else { return .fieldChanged }
            if caretCollapsed.value {
                // Collapsing a long selection puts its beginning outside
                // the caret's 64-unit context. Keep comparing the original
                // selected span, already captured for this request, and
                // drop each read at once. The whole-body email check ran
                // before the collapse and cannot authorize a later edit.
                let none = FieldRange(location: state.selection.location, length: 0)
                guard let selected = FieldAccess.readback(target, text: state.selection, before: none, after: none),
                      selected.length == state.length,
                      FieldEdit.comparable(selected.text) == FieldEdit.comparable(state.selectedText)
                else { return .fieldChanged }
            }
            return nil
        }
        // The whole body is read once more as it was read above, from one
        // source checked against its own length with the secure check
        // right before and after, never from another source in its place,
        // and cut as the route's input cuts it. A read that does not
        // answer is a reason, and a body that differs is a field that
        // changed. The first call is the one at the start of the
        // insertion, on the inserter's executor like every call, so the
        // flag needs no lock.
        let perWrite = field.stillCurrent
        let sent = ComposeInput.sentThread(body)
        let bodyChecked = Flag()
        var emailField = field
        emailField.stillCurrent = { () -> EditReason? in
            if !bodyChecked.value {
                bodyChecked.value = true
                if let reason = FieldAccess.focusMoved(target) { return reason }
                switch bodyText(of: target) {
                case let .success(now) where ComposeInput.sentThread(now) == sent: break
                case .success: return .fieldChanged
                case let .failure(reason): return reason
                }
            }
            return perWrite?()
        }
        var observation = EmailBody(bundleIdentifier: bundleIdentifier, body: body)
        surroundings(of: target, provider: provider, into: &observation)
        // Only Gmail's body is placed from its frame, so Mail's is never
        // read for it. Read last, after the body's text and its
        // surroundings, which can take hundreds of milliseconds, with the
        // body's own frame sampled again in it: `frame` above is from before
        // those reads and says nothing of where the body is now.
        let shown = seen && bundleIdentifier != mailBundleIdentifier ? visibility(of: target.element, window: target.window) : nil
        // With them, a selection's bounds, a frame and never its text.
        let selectionFrame = seen && bundleIdentifier != mailBundleIdentifier && state.selection.length > 0
            ? try? target.element.bounds(for: state.selection, timeout: 0.1).get() : nil
        return .success(.emailBody(ComposeCapture(field: field, observation: observation, emailField: emailField,
                                                  selection: state.selection, wholeSelection: FieldRange(location: 0, length: state.length),
                                                  bodyComplete: body.unicodeScalars.count == whole.unicodeScalars.count,
                                                  replacementGuard: {
                                                      if let reason = perWrite?() { return reason }
                                                      switch bodyText(of: target) {
                                                      case let .success(now) where now.utf8.elementsEqual(body.utf8): return nil
                                                      case .success: return .fieldChanged
                                                      case let .failure(reason): return reason
                                                      }
                                                  },
                                                  visibility: shown, selectionFrame: selectionFrame)))
    }

    /// What the window shows around the body once the body is read: its
    /// recipients and subject and, in a Gmail reply in the thread view,
    /// the thread's messages the page shows and the thread's id. In Mail
    /// the To, Cc, Bcc and Subject fields' values; a reply's body there
    /// already holds the message it answers. Read only for an email that
    /// can be written now, kept for its request and never logged. Whatever
    /// does not answer is left out, and the email is written without it.
    static func surroundings(of target: FieldTarget, provider: Provider, into observation: inout EmailBody) {
        if case let .native(_, _, fields) = provider.location {
            let headers = nativeHeaders(target.window, fields: fields)
            observation.recipients = headers.recipients
            observation.subject = headers.subject ?? ""
            // Mail's own subject says whether this is a reply: Mail starts a
            // reply's with `Re:`, and a new message's is what the person typed.
            if let subject = headers.subject { observation.kind = ComposeInput.kind(subject: subject) }
            return
        }
        guard case let .web(_, rules) = provider.location else { return }
        let page = ComposePage.read(body: target.element, rules: rules,
                                    fieldText: { fieldText($0, window: target.window, until: $1) },
                                    threadID: { page, deadline in
                                        ContinuousClock.now < deadline ? provider.threadID(address(of: page)) : nil
                                    })
        observation.recipients = page.recipients.map { WritingRecipient(address: $0, role: .to) }
        observation.subject = page.subject
        observation.thread = page.thread
        observation.threadID = page.threadID
        observation.inThread = page.inThread
        // An inline reply in the thread view is a reply; a window with its own
        // Subject field is a new message unless that subject answers one.
        if page.inThread {
            observation.kind = .reply
        } else if page.subjectShown {
            observation.kind = ComposeInput.kind(subject: page.subject)
        }
    }

    /// A text field's value, with the secure check right before the read.
    /// Nil for a secure field, a check that cannot be made, a value that is
    /// not text, or `deadline` passed before the check or the read.
    static func fieldText(_ field: AXElement, window: AXElement, until deadline: ContinuousClock.Instant) -> String? {
        guard ContinuousClock.now < deadline, case .success = clear(field, window: window), ContinuousClock.now < deadline else { return nil }
        return try? field.string(kAXValueAttribute).get()
    }

    /// The identifiers of a Mail compose window's header fields, found in
    /// Mail's own framework on macOS 27.2, and the recipient role each
    /// holds; the subject field holds none.
    static let mailHeaderFields: [String: WritingRecipient.Role?] = [
        mailToFieldIdentifier: .to, "Mail.ccField": .cc, "Mail.ccBccMultiField": .cc, "Mail.bccField": .bcc,
        "Mail.subjectField": nil,
    ]

    /// The recipients and subject of a Mail compose window, from its header
    /// fields' values, each read after the secure check. The fields are
    /// found by the walk `isNativeCompose` makes, by role, children and a text
    /// field's identifier, within the same limits, without stopping at the
    /// To field. A recipient field gives the addresses its value shows; the
    /// subject is nil when its field was not found or did not answer.
    static func nativeHeaders(_ window: AXElement, fields: [String: WritingRecipient.Role?]) -> (recipients: [WritingRecipient], subject: String?) {
        let deadline = ContinuousClock.now + mailWindowBudget
        var inTime: Bool { ContinuousClock.now < deadline }
        var found: [(AXElement, String)] = []
        var pending = [window]
        var next = 0
        while next < pending.count, next < mailWindowLimit, inTime, found.count < fields.count {
            let element = pending[next]
            next += 1
            guard case let .success(role) = element.string(kAXRoleAttribute) else { continue }
            if role == "AXWebArea" || role == kAXTextAreaRole || role == kAXComboBoxRole { continue }
            if role == kAXTextFieldRole {
                guard inTime, case let .success(identifier) = element.string(kAXIdentifierAttribute),
                      fields[identifier] != nil, !found.contains(where: { $0.1 == identifier }) else { continue }
                found.append((element, identifier))
                continue
            }
            guard inTime, case let .success(children) = element.children() else { continue }
            pending += children
        }
        var recipients: [WritingRecipient] = []
        var subject: String?
        for (field, identifier) in found {
            guard let value = fieldText(field, window: window, until: deadline), let role = fields[identifier] else { continue }
            guard let role else {
                subject = value
                continue
            }
            for address in ComposePage.addresses(in: [value])
            where recipients.count < ComposePage.recipientLimit && !recipients.contains(where: { $0.address.caseInsensitiveCompare(address) == .orderedSame }) {
                recipients.append(WritingRecipient(address: address, role: role))
            }
        }
        return (recipients, subject)
    }

    /// Whether the focused field matches a provider's body identity and
    /// location, without reading its text. Native providers declare marker
    /// requirements and a compose header identifier. Web providers declare
    /// a body role, exact own description, nearest page host and any extra
    /// browser or editability requirements.
    static func isEmailBody(_ target: FieldTarget, bundleIdentifier: String?) -> Bool {
        isEmailBody(target.element, window: target.window, labels: target.labels, markers: target.markers,
                    bundleIdentifier: bundleIdentifier)
    }

    /// The same decision from the field's parts, for a reader that has no
    /// `FieldTarget`, as `EmailBodyWatch` has none: `labels` is the field's
    /// own description first (`FieldAccess.labels`), and `markers` whether
    /// it is a web area edited through text markers, asked only in Mail.
    static func isEmailBody(_ element: AXElement, window: AXElement, labels: String, markers: @autoclosure () -> Bool,
                            bundleIdentifier: String?) -> Bool {
        provider(element, window: window, labels: labels, markers: markers(), bundleIdentifier: bundleIdentifier) != nil
    }

    /// Nil means metadata did not answer. The caret classifier may retry;
    /// dictation still treats that answer as an ordinary field for this request.
    static func emailBodyClassification(_ element: AXElement, window: AXElement, labels: String,
                                        markers: @autoclosure () -> Bool?, bundleIdentifier: String?) -> Bool? {
        switch providerClassification(element, window: window, labels: labels, markers: markers(), bundleIdentifier: bundleIdentifier) {
        case .matched: true
        case .other: false
        case .indeterminate: nil
        }
    }

    private enum ProviderClassification {
        case matched(Provider), other, indeterminate
    }

    private static func provider(_ element: AXElement, window: AXElement, labels: String, markers: @autoclosure () -> Bool,
                                 bundleIdentifier: String?) -> Provider? {
        if case let .matched(provider) = providerClassification(element, window: window, labels: labels,
                                                               markers: markers(), bundleIdentifier: bundleIdentifier) {
            return provider
        }
        return nil
    }

    private static func providerClassification(_ element: AXElement, window: AXElement, labels: String,
                                               markers: @autoclosure () -> Bool?, bundleIdentifier: String?) -> ProviderClassification {
        let candidates = providers.filter {
            if case let .web(hosts, _) = $0.location, hosts == [gmailHost],
               WritingSurfacePolicy.isChromiumBrowser(bundleIdentifier: bundleIdentifier),
               case .success(true) = gmailBodyIdentity(element, description: description(in: labels)) { return true }
            return $0.couldMatch(bundleIdentifier: bundleIdentifier, description: description(in: labels))
        }
        guard !candidates.isEmpty else { return .other }
        guard case let .success(role) = element.string(kAXRoleAttribute) else { return .indeterminate }
        // Every candidate is still tried as before, so dictation's answer
        // is unchanged; a read that did not answer only makes "no match"
        // indeterminate, for the caret classifier to retry.
        var unanswered = false
        for provider in candidates where provider.bodyRoles.contains(role) {
            switch provider.location {
            case let .native(_, toField, _):
                if provider.requiresMarkers {
                    guard let editable = markers() else { unanswered = true; continue }
                    if !editable { continue }
                }
                switch nativeComposeClassification(window, toField: toField) {
                case true?: return .matched(provider)
                case nil: unanswered = true
                case false?: break
                }
            case let .web(hosts, _):
                // Outlook's reading pane can share its body label. Its
                // provisional definition requires editable text; Gmail
                // retains its qualified paste-only body path. A negative
                // editability answer can also be a failed read.
                if provider.requiresSettableText,
                   !(element.isSettable(kAXValueAttribute) || element.isSettable(kAXSelectedTextAttribute)) {
                    unanswered = true
                    continue
                }
                guard let host = pageHost(of: element, window: window) else { unanswered = true; continue }
                if hosts.contains(host) { return .matched(provider) }
            }
        }
        return unanswered ? .indeterminate : .other
    }

    /// Whether a Mail window is one for writing a message: it holds a text
    /// field identified as Mail's To field. The walk goes breadth first
    /// from the window and reads each element's role, its children, and a
    /// text field's identifier, never a value. It does not enter a text
    /// field, text area or combo box, so a recipient's token is not
    /// reached, or a web area, so the message body and a quoted thread are
    /// not walked, and it stops at the To field. An element that does not
    /// answer for its role or its children, more than `mailWindowLimit`
    /// elements, or a walk longer than `mailWindowBudget` is not a compose
    /// window, and dictation then types the words as anywhere else. The
    /// budget is checked before every read, and each read can wait up to
    /// `AccessibilityExecutor.messagingTimeout`, so a walk of slow reads
    /// ends at most one read past it.
    static func isNativeCompose(_ window: AXElement, toField: String) -> Bool {
        nativeComposeClassification(window, toField: toField) == true
    }

    private static func nativeComposeClassification(_ window: AXElement, toField: String) -> Bool? {
        let deadline = ContinuousClock.now + mailWindowBudget
        var inTime: Bool { ContinuousClock.now < deadline }
        var pending = [window]
        var next = 0
        var skipped = false
        while next < pending.count {
            guard next < mailWindowLimit, inTime else { return nil }
            let element = pending[next]
            next += 1
            guard case let .success(role) = element.string(kAXRoleAttribute) else { return nil }
            if role == "AXWebArea" || role == kAXTextAreaRole || role == kAXComboBoxRole { continue }
            if role == kAXTextFieldRole {
                guard inTime else { return nil }
                // A text field whose identifier does not answer is passed
                // over, as it always was, so the walk can still reach the
                // To field; only a walk that ends without it, having passed
                // one over, is unanswered rather than "not a compose window".
                switch element.string(kAXIdentifierAttribute) {
                case let .success(identifier): if identifier == toField { return true }
                case let .failure(error) where error.code == .noValue || error.code == .attributeUnsupported: break
                case .failure: skipped = true
                }
                continue
            }
            guard inTime else { return nil }
            switch element.children() {
            case let .success(children): pending += children
            case let .failure(failure) where failure.code == .noValue || failure.code == .attributeUnsupported: break
            case .failure: return nil
            }
        }
        return skipped ? nil : false
    }

    /// Metadata-only prefilter shared by dictation and the body classifier.
    /// Only matching native apps, browser descriptions or a confirmed Gmail body trigger a
    /// compose read after the spoken words return.
    static func couldBeEmailBody(bundleIdentifier: String?, labels: String, gmailBody: Bool = false) -> Bool {
        gmailBody || providers.contains { $0.couldMatch(bundleIdentifier: bundleIdentifier, description: description(in: labels)) }
    }

    /// The field's own description, the first of its labels
    /// (`FieldAccess.labels`).
    static func description(in labels: String) -> String {
        labels.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// The host of the page the field is in: the nearest web area above
    /// the field, found by the same walk of its ancestors admission made,
    /// and that web area's address. Nil when there is no web area before
    /// the window, when it does not answer for its address, or when any
    /// ancestor on the way does not answer for its role: a frame's web area
    /// that stays silent would otherwise be passed over, and an outer
    /// page's address taken for the field's.
    static func pageHost(of element: AXElement, window: AXElement) -> String? {
        FieldAccess.pageHost(of: element, window: window)
    }

    static func address(of webArea: AXElement) -> URL? {
        FieldAccess.address(of: webArea)
    }

    /// The field's whole text, from one source and checked against that
    /// source's own length, then cut to `bodyLimit`: a web area addressed
    /// by markers gives its text and length through them, every other
    /// field through its value and character count, which hold paragraph
    /// breaks the same way. A read that fails for any reason, a timeout
    /// included, or a text and length that disagree, refuses the capture,
    /// and nothing is read from another source in its place; the words are
    /// typed instead. The read is not bounded by a range: a read of the
    /// first part answers as many units as it asks for even when the
    /// source's text and length disagree further on, and a field read by
    /// its value has no ranged read from the same source, since Chromium's
    /// ranged reads leave out the breaks its value holds.
    static func bodyText(of target: FieldTarget) -> Result<String, EditReason> {
        wholeBodyText(of: target).map { ComposeInput.bounded($0, to: bodyLimit) }
    }

    /// The field's whole text as `bodyText` reads it, before the cut.
    private static func wholeBodyText(of target: FieldTarget) -> Result<String, EditReason> {
        let element = target.element
        let text: String
        if target.markers {
            guard let length = element.markerLength() else { return .failure(.unreadableField) }
            switch clear(element, window: target.window) {
            case .failure(let reason): return .failure(reason)
            case .success: break
            }
            guard case let .success(whole) = element.string(for: FieldRange(location: 0, length: length)),
                  whole.utf16.count == length else { return .failure(.unreadableField) }
            text = whole
        } else {
            guard case let .success(count) = element.int(kAXNumberOfCharactersAttribute) else { return .failure(.unreadableField) }
            switch clear(element, window: target.window) {
            case .failure(let reason): return .failure(reason)
            case .success: break
            }
            guard case let .success(value) = element.string(kAXValueAttribute), value.utf16.count == count else {
                return .failure(.unreadableField)
            }
            text = value
        }
        // Asked once more after the read, as the inserter asks after its
        // last read of a field: one that turned secure while its text was
        // answered gives no body.
        if case let .failure(reason) = clear(element, window: target.window) { return .failure(reason) }
        return .success(text)
    }

    /// Whether `element` and its ancestors up to `window` answer that they
    /// are not secure. The statement right before every read of text, and
    /// after the body's.
    private static func clear(_ element: AXElement, window: AXElement) -> Result<Void, EditReason> {
        switch AXWritingSurface.secureAncestry(element, window: window) {
        case false?: .success(())
        case true?: .failure(.secureField)
        case nil: .failure(.unreadableField)
        }
    }
}
