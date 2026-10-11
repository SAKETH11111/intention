import AppKit
@testable import Compose
import Testing

/// Telling the body of an email being written from any other field, and
/// reading it, against the scripted field, which holds "abc" with the
/// caret after "a" and belongs to Mail unless a scenario says otherwise.
/// Mail's body is a web area that is itself the editable text
/// (`document`), in a window holding Mail's To field, which the scripted
/// window holds unless a scenario says otherwise; Gmail's is a web field
/// that names itself "Message Body" on a page at mail.google.com.
@MainActor
@Suite(.serialized)
struct ComposeAccessTests {
    private let reply = "Hi,\n\nCould you make Thursday at 10?\n\nJane"

    private func reset(_ configure: (MockField) -> Void = { _ in }) {
        MockField.reset()
        MockField.shared.pasteboard = NSPasteboard(name: NSPasteboard.Name("co.intention.tests.\(UUID().uuidString)"))
        configure(MockField.shared)
    }

    private func mail(_ field: MockField) {
        field.document = true
        field.text = reply
        field.selection = FieldRange(location: 0, length: 0)
    }

    private func gmail(_ field: MockField, in browser: String = "com.google.Chrome") {
        field.bundleIdentifier = browser
        field.web = true
        field.label = "Message Body"
        field.pageURL = "https://mail.google.com/mail/u/0/#inbox?compose=new"
    }

    private func read() -> Result<ComposeTarget, EditReason> {
        ComposeAccess.focusedEmailDraft(ownPID: getpid())
    }

    private func emailBody() throws -> ComposeCapture {
        guard case let .success(.emailBody(capture)) = read() else { throw Mismatch() }
        return capture
    }

    private func isPlain() -> Bool {
        if case .success(.plain) = read() { return true }
        return false
    }

    /// The reason an email body came back without its text, or nil when
    /// the read answered anything else.
    private func unread() -> EditReason? {
        if case let .success(.emailBodyWithoutText(reason)) = read() { return reason }
        return nil
    }

    private struct Mismatch: Error {}

    // MARK: - Telling an email body

    @Test func mailsMessageBodyIsAnEmailBodyReadFromTheFieldAlone() throws {
        reset(mail)
        let capture = try emailBody()
        #expect(capture.observation.body == reply)
        #expect(capture.observation.bundleIdentifier == "com.apple.mail")
        #expect(capture.field.before == "")
        #expect(capture.field.stillCurrent?() == nil)
        // Beyond the field, the walk to the To field: the window's role and
        // children, then the To field's role and identifier. Only once the
        // body has been read from the field alone, the same walk again to
        // the header fields and the To field's value, which here gives none.
        #expect(MockField.shared.readsBeyondField == 9)
        #expect(MockField.shared.windowElementReads
            == [kAXRoleAttribute, kAXIdentifierAttribute, kAXRoleAttribute, kAXIdentifierAttribute, kAXValueAttribute])
        #expect(capture.observation.recipients.isEmpty)
        #expect(capture.observation.subject.isEmpty)
        #expect(MockField.shared.textReadsWhileSecure == 0)
    }

    /// A Mail reply's header fields as the walk meets them, by the
    /// identifiers Mail's own framework gives them.
    private func mailReplyHeaders(_ field: MockField) {
        mail(field)
        typealias Element = MockField.WindowElement
        field.windowElements = [
            Element(role: kAXGroupRole, children: [
                Element(role: kAXTextFieldRole, identifier: "Mail.toField", value: "Priya Raman <priya@northwind.example>, tomas@contoso.example"),
                Element(role: kAXTextFieldRole, identifier: "Mail.ccField", value: "Ana Silva <ana@fabrikam.example>"),
                Element(role: kAXTextFieldRole, identifier: "Mail.bccField", value: ""),
                Element(role: kAXTextFieldRole, identifier: "Mail.subjectField", value: "Re: Venue options for the October offsite"),
                Element(role: kAXTextFieldRole, identifier: "Mail.searchField", value: "not a header"),
            ]),
        ]
    }

    @Test func aMailReplyCarriesItsRecipientsAndSubjectFromItsHeaderFields() throws {
        reset(mailReplyHeaders)
        let observation = try emailBody().observation
        #expect(observation.recipients == [
            WritingRecipient(address: "priya@northwind.example", role: .to),
            WritingRecipient(address: "tomas@contoso.example", role: .to),
            WritingRecipient(address: "ana@fabrikam.example", role: .cc),
        ])
        #expect(observation.subject == "Re: Venue options for the October offsite")
        #expect(observation.kind == .reply)
        // A reply's body already quotes the thread in Mail, and Mail's page
        // gives no thread id.
        #expect(observation.thread.isEmpty)
        #expect(observation.threadID == nil)
        #expect(observation.body == reply)
        // The four headers' values and none other: the search field is
        // never read.
        #expect(MockField.shared.windowElementReads.filter { $0 == kAXValueAttribute }.count == 4)
    }

    @Test func aNewMailMessageWithASignatureIsANewMessage() throws {
        reset {
            mailReplyHeaders($0)
            $0.text = "\n\nSam Lee\nNorthwind"
            typealias Element = MockField.WindowElement
            $0.windowElements = [Element(role: kAXGroupRole, children: [
                Element(role: kAXTextFieldRole, identifier: "Mail.toField", value: "priya@northwind.example"),
                Element(role: kAXTextFieldRole, identifier: "Mail.subjectField", value: "Venue options for the October offsite"),
            ])]
        }
        let observation = try emailBody().observation
        #expect(observation.kind == .new)
        let input = try ComposeInput.make(observation, cue: "Ask about venues.", requestID: UUID())
        #expect(input.mode == .new)
    }

    @Test func aMailHeaderFieldThatTurnsSecureIsNotRead() throws {
        reset {
            mailReplyHeaders($0)
            // The walk that tells the compose window reads one identifier,
            // the To field's. Once the body is read and the second walk has
            // reached the headers, the check before each header's value
            // finds a secure field.
            $0.onSecureCheck = {
                if MockField.shared.windowElementReads.filter({ $0 == kAXIdentifierAttribute }).count > 1 { MockField.shared.secure = true }
            }
        }
        let observation = try emailBody().observation
        #expect(observation.recipients.isEmpty)
        #expect(observation.subject.isEmpty)
        // A subject that was not read says nothing about what the email is.
        #expect(observation.kind == nil)
        #expect(!MockField.shared.windowElementReads.contains(kAXValueAttribute))
        #expect(MockField.shared.textReadsWhileSecure == 0)
    }

    @Test(arguments: ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser"])
    func gmailsMessageBodyInABrowserIsAnEmailBody(browser: String) throws {
        reset { gmail($0, in: browser) }
        let capture = try emailBody()
        #expect(capture.observation.body == "abc")
        #expect(capture.observation.bundleIdentifier == browser)
        #expect(capture.field.before == "a")
        // Beyond the field, none of text before the body: the element above
        // it, that it is a web area, and the page's address. Once the body
        // is read, the element above it again, and its role and subrole: it
        // is the page, with no region around the body, so nothing more is
        // read and nothing is found.
        #expect(MockField.shared.readsBeyondField == 6)
        #expect(capture.observation.recipients.isEmpty)
        #expect(capture.observation.subject.isEmpty)
        #expect(capture.observation.thread.isEmpty)
        #expect(capture.observation.threadID == nil)
    }

    @Test func anOrdinaryFieldIsPlainAndItsTextIsNotRead() {
        // A composer in Mail's own process that is not the message body,
        // and a field whose count does not answer: were its whole text
        // asked for, the read would fail rather than answer plain.
        reset { $0.countUnanswered = true }
        #expect(isPlain())
        #expect(MockField.shared.readsBeyondField == 0)
    }

    @Test func aSlackComposerIsPlain() {
        reset {
            $0.bundleIdentifier = "com.tinyspeck.slackmacgap"
            $0.web = true
            $0.label = "Message to Jane"
        }
        #expect(isPlain())
    }

    @Test func mailsOtherFieldsArePlain() {
        // The To and Subject fields are text fields, not the editable web area.
        reset { $0.label = "" }
        #expect(isPlain())
    }

    @Test func anEditableWebAreaOutsideMailIsPlain() {
        // A document editor in a browser, Mail's shape in another app.
        reset {
            $0.bundleIdentifier = "com.google.Chrome"
            $0.document = true
        }
        #expect(isPlain())
        reset {
            $0.bundleIdentifier = nil
            $0.document = true
        }
        #expect(isPlain())
    }

    /// Mail's signature editor, in Mail's Settings window: an editable web
    /// area with focus, in Mail's process, in a window with a toolbar of
    /// panes, a list of signatures and buttons, and no To field.
    private func signatureEditor(_ field: MockField) {
        mail(field)
        // Longer than the inserter reads around the caret, so only a read
        // of the body would span it.
        field.text = String(repeating: "a", count: 200)
        typealias Element = MockField.WindowElement
        field.windowElements = [
            Element(role: kAXToolbarRole, children: Array(repeating: Element(role: kAXButtonRole), count: 3)),
            Element(role: kAXScrollAreaRole, children: [Element(role: kAXTableRole, children: [Element(role: kAXRowRole), Element(role: kAXRowRole)])]),
            Element(role: kAXCheckBoxRole),
            Element(role: kAXPopUpButtonRole),
            Element(role: kAXButtonRole),
            Element(role: kAXButtonRole),
        ]
    }

    @Test func mailsSignatureEditorIsPlainAndItsTextIsNotRead() {
        reset(signatureEditor)
        #expect(isPlain())
        #expect(MockField.shared.wholeTextReads == 0)
        // Every element of the window was walked, by role and children
        // alone: no identifier, since none is a text field, and no value.
        #expect(!MockField.shared.windowElementReads.contains(kAXIdentifierAttribute))
        #expect(!MockField.shared.windowElementReads.contains(kAXValueAttribute))
        // Asked without the text, as when no email can be written now, it
        // is plain too, so the words carry no notice.
        reset(signatureEditor)
        if case .success(.plain) = ComposeAccess.focusedEmailDraft(ownPID: getpid(), text: false) {} else { Issue.record("not plain") }
    }

    @Test func aMailWindowIsAComposeWindowOnlyByATextFieldIdentifiedAsTheToField() {
        typealias Element = MockField.WindowElement
        // A reply window, its To field deeper among the headers.
        reset {
            mail($0)
            $0.windowElements = [Element(role: kAXToolbarRole, children: [Element(role: kAXButtonRole)]),
                                 Element(role: kAXGroupRole, children: [Element(role: kAXTextFieldRole, identifier: "Mail.subjectField"),
                                                                        Element(role: kAXGroupRole, children: [Element(role: kAXTextFieldRole, identifier: "Mail.toField")])])]
        }
        #expect((try? emailBody()) != nil)
        // The identifier on an element that is not a text field.
        reset {
            mail($0)
            $0.windowElements = [Element(role: kAXGroupRole, identifier: "Mail.toField")]
        }
        #expect(isPlain())
        // Another text field, such as the viewer's search field.
        reset {
            mail($0)
            $0.windowElements = [Element(role: kAXTextFieldRole, identifier: "Mail.searchField")]
        }
        #expect(isPlain())
        // A To field inside a web area is not looked for: the walk does not
        // enter a page.
        reset {
            mail($0)
            $0.windowElements = [Element(role: "AXWebArea", children: [Element(role: kAXTextFieldRole, identifier: "Mail.toField")])]
        }
        #expect(isPlain())
        #expect(MockField.shared.windowElementReads == [kAXRoleAttribute])
        // Nor inside a text area or a combo box: the walk enters no field
        // that takes text.
        for role in [kAXTextAreaRole, kAXComboBoxRole] {
            reset {
                mail($0)
                $0.windowElements = [Element(role: role, children: [Element(role: kAXTextFieldRole, identifier: "Mail.toField")])]
            }
            #expect(isPlain())
            #expect(MockField.shared.windowElementReads == [kAXRoleAttribute])
        }
    }

    @Test func aMailWindowThatDoesNotAnswerIsNotAComposeWindow() {
        typealias Element = MockField.WindowElement
        // The window's children do not answer.
        reset {
            mail($0)
            $0.windowChildrenUnanswered = true
        }
        #expect(isPlain())
        // An element before the To field does not answer for its role.
        reset {
            mail($0)
            $0.windowElements = [Element(role: kAXButtonRole, roleUnanswered: true), Element(role: kAXTextFieldRole, identifier: "Mail.toField")]
        }
        #expect(isPlain())
        // The walk reads at most 400 elements, the window first. With 398
        // buttons before it the To field is the 400th and is found.
        reset {
            mail($0)
            $0.windowElements = Array(repeating: Element(role: kAXButtonRole), count: 398)
                + [Element(role: kAXTextFieldRole, identifier: "Mail.toField")]
        }
        #expect((try? emailBody()) != nil)
        // With 399 before it the To field would be the 401st, which the
        // walk does not read.
        reset {
            mail($0)
            $0.windowElements = Array(repeating: Element(role: kAXButtonRole), count: 399)
                + [Element(role: kAXTextFieldRole, identifier: "Mail.toField")]
            $0.text = String(repeating: "a", count: 200)
        }
        #expect(isPlain())
        #expect(MockField.shared.wholeTextReads == 0)
    }

    /// The walk has half a second, checked before every read, so a slow
    /// read that uses it up is the last: the next read is not made even
    /// within the same element.
    @Test func aMailWindowWhoseReadsOutlastTheWalksTimeIsNotAComposeWindow() {
        typealias Element = MockField.WindowElement
        // The To field answers for its role only after 0.6 seconds, so its
        // identifier is not asked for.
        reset {
            mail($0)
            $0.windowElements = [Element(role: kAXTextFieldRole, identifier: "Mail.toField", readDelay: 0.6)]
        }
        #expect(isPlain())
        #expect(MockField.shared.windowElementReads == [kAXRoleAttribute])
        // A group that answers for its role as slowly is not asked for its
        // children, so the To field inside it is not reached.
        reset {
            mail($0)
            $0.windowElements = [Element(role: kAXGroupRole, children: [Element(role: kAXTextFieldRole, identifier: "Mail.toField")],
                                         readDelay: 0.6)]
        }
        #expect(isPlain())
        #expect(MockField.shared.windowElementReads == [kAXRoleAttribute])
        // Reads that take some time but finish well inside the half second still find it.
        reset {
            mail($0)
            $0.windowElements = [Element(role: kAXGroupRole, children: [Element(role: kAXTextFieldRole, identifier: "Mail.toField")],
                                         readDelay: 0.02)]
        }
        #expect((try? emailBody()) != nil)
    }

    @Test func aSecureFieldIsRefusedBeforeAnyRead() {
        reset {
            mail($0)
            $0.secure = true
        }
        if case .failure(.secureField) = read() {} else { Issue.record("\(read())") }
        #expect(MockField.shared.textReadsWhileSecure == 0)
        reset {
            gmail($0)
            $0.secure = true
        }
        if case .failure(.secureField) = read() {} else { Issue.record("\(read())") }
        #expect(MockField.shared.textReadsWhileSecure == 0)
    }

    @Test func whenThePageCannotBeToldItIsPlain() {
        // Gmail's label on a page whose address does not answer.
        reset {
            gmail($0)
            $0.pageURL = nil
        }
        #expect(isPlain())
        // The same label on another of Google's pages.
        reset {
            gmail($0)
            $0.pageURL = "https://docs.google.com/document/d/1"
        }
        #expect(isPlain())
        // A host that only ends in Gmail's.
        reset {
            gmail($0)
            $0.pageURL = "https://mail.google.com.example.net/"
        }
        #expect(isPlain())
        // A page of Gmail's, and a field that is not the body.
        reset {
            gmail($0)
            $0.label = "Subject"
        }
        #expect(isPlain())
        // A web field that answers no description at all.
        reset {
            gmail($0)
            $0.label = ""
        }
        #expect(isPlain())
    }

    @Test func aFrameWhoseWebAreaDoesNotAnswerForItsRoleIsPlain() {
        // Gmail's label on a page of an add-on, framed inside Gmail: the
        // nearest web area decides, and it is not Gmail's.
        reset {
            gmail($0)
            $0.pageURL = "https://addon.example.com/compose"
            $0.outerPageURL = "https://mail.google.com/mail/u/0/"
        }
        #expect(isPlain())
        // The frame's web area does not answer for its role: the walk ends
        // there rather than passing it over and taking the outer page's
        // address for the field's.
        reset {
            gmail($0)
            $0.pageURL = "https://addon.example.com/compose"
            $0.outerPageURL = "https://mail.google.com/mail/u/0/"
            $0.webAreaRoleUnanswered = true
        }
        #expect(isPlain())
        #expect(MockField.shared.wholeTextReads == 0)
        // The same silence with Gmail's own page right above the field.
        reset {
            gmail($0)
            $0.webAreaRoleUnanswered = true
        }
        #expect(isPlain())
    }

    @Test func aBodyWithoutItsTextIsStillAnEmailBody() {
        // Asked not to read the text, as dictation asks when no email can
        // be written now, the field is told and its text is not read:
        // admission's reads stop around the caret, and no read spans the
        // body.
        reset {
            mail($0)
            $0.text = String(repeating: "a", count: 200)
        }
        if case .success(.emailBodyWithoutText(nil)) = ComposeAccess.focusedEmailDraft(ownPID: getpid(), text: false) {} else {
            Issue.record("\(ComposeAccess.focusedEmailDraft(ownPID: getpid(), text: false))")
        }
        #expect(MockField.shared.wholeTextReads == 0)
        #expect(MockField.shared.textReads > 0)
        // Asked for the text, the same field is read once, whole.
        reset {
            mail($0)
            $0.text = String(repeating: "a", count: 200)
        }
        #expect((try? emailBody())?.observation.body.count == 200)
        #expect(MockField.shared.wholeTextReads == 1)
        reset { $0.label = "" }
        if case .success(.plain) = ComposeAccess.focusedEmailDraft(ownPID: getpid(), text: false) {} else { Issue.record("not plain") }
    }

    @Test func theHostIsReadAsItIsSpelled() {
        reset {
            gmail($0)
            $0.pageURL = "https://MAIL.google.com/mail/u/1/"
        }
        #expect((try? emailBody()) != nil)
        reset {
            gmail($0)
            $0.pageURL = "http://mail.google.com/"
        }
        #expect((try? emailBody()) != nil)
    }

    // MARK: - Reading the body

    @Test func theBodyComesFromOneSourceCheckedAgainstItsOwnLength() {
        // Mail: the markers' length does not answer. The field is still an
        // email body, so dictation can say why the words were typed.
        reset {
            mail($0)
            $0.markerLengthUnanswered = true
        }
        #expect(unread() == .unreadableField)
        // Gmail: the count answers once, for the inserter's own read, and
        // not for the body; nothing is read from another source instead.
        reset {
            gmail($0)
            $0.onLengthRead = { count in if count == 1 { MockField.shared.countUnanswered = true } }
        }
        #expect(unread() == .unreadableField)
    }

    @Test func aReadThatFailsOnceRefusesTheBodyRatherThanReadingElsewhere() {
        reset {
            mail($0)
            $0.failingRead = FieldRange(location: 0, length: reply.utf16.count)
        }
        #expect(unread() == .unreadableField)
        reset {
            mail($0)
            $0.failingRead = FieldRange(location: 0, length: reply.utf16.count)
            $0.failingReadTimesOut = true
        }
        #expect(unread() == .unreadableField)
    }

    @Test func theFieldTurningSecureBetweenTwoReadsRefusesTheBody() {
        // Secure after the first read of its length, which admission made:
        // the check right before the text is read sees it.
        reset {
            mail($0)
            $0.onLengthRead = { _ in MockField.shared.secure = true }
        }
        #expect(unread() == .secureField)
        #expect(MockField.shared.textReadsWhileSecure == 0)
        // Secure after the second, which is the body read's own length,
        // with the selection and the text around it already read: only the
        // check right before the body's text is read stands between the
        // two, in Mail and in Gmail alike.
        for browser in [nil, "com.google.Chrome"] {
            reset {
                if let browser { gmail($0, in: browser) } else { mail($0) }
                $0.onLengthRead = { count in if count == 2 { MockField.shared.secure = true } }
            }
            #expect(unread() == .secureField)
            #expect(MockField.shared.textReadsWhileSecure == 0)
        }
    }

    @Test func theFieldTurningSecureWhileItsTextIsReadRefusesTheBody() {
        // The body's own read of its text is the last read of text; the
        // field turns secure while that read is answered, which no check
        // before it can see, so the text it gave is not used.
        for browser in [nil, "com.google.Chrome"] {
            let body: (MockField) -> Void = { if let browser { self.gmail($0, in: browser) } else { self.mail($0) } }
            reset(body)
            #expect((try? emailBody()) != nil)
            let reads = MockField.shared.textReads
            reset {
                body($0)
                $0.onTextRead = { if MockField.shared.textReads == reads { MockField.shared.secure = true } }
            }
            #expect(unread() == .secureField)
            #expect(MockField.shared.textReads == reads)
        }
    }

    @Test func paragraphBreaksSurviveTheBodyRead() throws {
        reset {
            gmail($0)
            $0.blocks = true
            $0.text = "Hello Jane\nThursday works"
        }
        #expect(try emailBody().observation.body == "Hello Jane\nThursday works")
    }

    @Test func unchangedMailAndGmailBodiesCaptureAndPassTheGuard() throws {
        for variant in 0..<4 {
            reset {
                switch variant {
                case 0: mail($0)
                case 1: gmail($0)
                case 2:
                    gmail($0)
                    $0.blocks = true
                default:
                    gmail($0, in: "com.apple.Safari")
                    $0.doubles = true
                }
                $0.text = "Hello café 😀\nThursday works"
            }
            let captured = try emailBody()
            #expect(captured.field.stillCurrent?() == nil)
            #expect(captured.observation.body.contains("Thursday works"))
        }
    }

    // MARK: - The capture binds the selection and its surroundings

    private func insert(_ text: String, into capture: ComposeCapture) -> FieldAccess.DirectInsertion {
        FieldAccess.insertDirectly(text, ownPID: getpid(), ignoringFields: [], pasteOnly: false, expected: capture.field)
    }

    @Test func anUnchangedCaptureInsertsAtTheCaret() throws {
        reset(mail)
        let capture = try emailBody()
        _ = insert("DRAFT", into: capture)
        #expect(MockField.shared.text == "DRAFT" + reply)
    }

    @Test func aSelectionMadeSinceTheReadIsNotReplaced() throws {
        reset(mail)
        let capture = try emailBody()
        // The person selects the greeting after speaking; the email must
        // not take it.
        MockField.shared.selection = FieldRange(location: 0, length: 3)
        let result = insert("DRAFT", into: capture)
        #expect(MockField.shared.text == reply)
        #expect(MockField.shared.accessibilityWrites == 0)
        if case .finished(.notInserted(.fieldChanged)) = result {} else { Issue.record("\(result)") }
    }

    @Test func aCaretMovedBetweenRepeatedCharactersIsNotWrittenTo() throws {
        // One character over and over, so only the offsets can tell.
        let run = String(repeating: "a", count: 200)
        reset {
            mail($0)
            $0.text = run
            $0.selection = FieldRange(location: 80, length: 0)
        }
        let capture = try emailBody()
        MockField.shared.selection = FieldRange(location: 120, length: 0)
        let result = insert("DRAFT", into: capture)
        #expect(MockField.shared.accessibilityWrites == 0)
        #expect(MockField.shared.text == run)
        if case .finished(.notInserted(.fieldChanged)) = result {} else { Issue.record("\(result)") }
    }

    @Test func aSelectionMovedForOneReadAndBackIsCaught() throws {
        let run = String(repeating: "a", count: 200)
        reset {
            mail($0)
            $0.text = run
            $0.selection = FieldRange(location: 80, length: 0)
        }
        let capture = try emailBody()
        // Moved for the guard's read alone.
        MockField.shared.moveSelectionOnRead = FieldRange(location: 81, length: 0)
        let refused = insert("DRAFT", into: capture)
        if case .finished(.notInserted(.fieldChanged)) = refused {} else { Issue.record("\(refused)") }
        #expect(MockField.shared.accessibilityWrites == 0)
        // Back where it was, the same capture passes.
        MockField.shared.selection = FieldRange(location: 80, length: 0)
        _ = insert("DRAFT", into: capture)
        #expect(MockField.shared.text == String(repeating: "a", count: 80) + "DRAFT" + String(repeating: "a", count: 120))
    }

    // MARK: - The email binds the body it was written from

    /// A reply under a quoted thread long enough that its end lies well
    /// past the text read around the caret, 64 units on each side.
    private var longThread: String { "\n\nOn Monday, Jane wrote:\n> " + String(repeating: "Could you make Thursday at 10? ", count: 20) + "Jane" }

    @Test func anEqualLengthEditToTheQuotedThreadRefusesTheEmail() throws {
        let thread = longThread
        reset {
            mail($0)
            $0.text = thread
        }
        let capture = try emailBody()
        // "Jane" becomes "June" at the far end of the thread: the same
        // length, nowhere near the caret, so the per-write guard cannot see
        // it.
        let edited = String(thread.dropLast(4)) + "June"
        MockField.shared.text = edited
        #expect(capture.field.stillCurrent?() == nil)
        // The email was written from the old thread and does not go in.
        let result = FieldAccess.insertDirectly("DRAFT", ownPID: getpid(), ignoringFields: [], pasteOnly: false,
                                                expected: capture.emailField)
        if case .finished(.notInserted(.fieldChanged)) = result {} else { Issue.record("\(result)") }
        #expect(MockField.shared.text == edited)
        #expect(MockField.shared.accessibilityWrites == 0)
    }

    @Test(arguments: [false, true], ["none", "edit", "read", "secure"])
    func aCollapsedEmailGuardStillChecksItsWholeOriginalSelection(_ email: Bool, _ change: String) throws {
        let replacement = String(repeating: "a", count: 100)
        reset {
            mail($0)
            $0.text = "keep " + replacement + " keep"
            $0.selection = FieldRange(location: 5, length: 100)
        }
        let capture = try emailBody()
        let guarded = email ? capture.emailField : capture.field
        #expect(guarded.stillCurrent?() == nil)
        let field = MockField.shared
        let caret = FieldRange(location: 105, length: 0)
        field.selection = caret
        guarded.didConfirmCaretCollapse?(FieldRange(location: 5, length: 100), caret)
        switch change {
        case "edit": field.text = "keep b" + String(repeating: "a", count: 99) + " keep"
        case "read": field.failingRead = FieldRange(location: 5, length: 100)
        case "secure": field.onTextRead = { [field] in field.secure = true }
        default: break
        }
        #expect(guarded.stillCurrent?() == (change == "none" ? nil : .fieldChanged))
        #expect(field.accessibilityWrites == 0)
        #expect(field.keys.isEmpty)
        #expect(field.textReadsWhileSecure == 0)
    }

    @Test(arguments: [false, true], ["fresh", "guard"])
    func aLongReplacementEditedAfterCaretRecoveryRefusesTheNextEmail(_ email: Bool, _ timing: String) async throws {
        reset(mail)
        let field = MockField.shared
        let replacement = String(repeating: "a", count: 100)
        field.text = "keep old keep"
        field.selection = FieldRange(location: 5, length: 3)
        field.writes = .held
        let inserter = TextInserter(pasteboard: PasteboardOwner(pasteboard: field.pasteboard!, mayRead: { true }))
        #expect(await inserter.insert(replacement) == .unknown(.writeUnconfirmed))
        field.land()
        field.selection = FieldRange(location: 5, length: 100)
        let capture = try emailBody()
        let changed = "keep b" + String(repeating: "a", count: 99) + " keep"
        field.onSelectionWrite = { [field] in
            let reads = field.focusReads
            field.onFocusRead = { [field] in
                if field.focusReads == reads + (timing == "fresh" ? 3 : 4) { field.text = changed }
            }
        }
        #expect(await inserter.insert("email", into: email ? capture.emailField : capture.field) == .notInserted(.fieldChanged))
        #expect(field.text == changed)
        #expect(field.accessibilityWrites == 1)
        #expect(field.keys.isEmpty)
    }

    @Test func anUnchangedBodyIsReadWholeOnceMoreAndTheEmailGoesIn() throws {
        let thread = longThread
        reset {
            mail($0)
            $0.text = thread
        }
        let capture = try emailBody()
        #expect(MockField.shared.wholeTextReads == 1)
        _ = FieldAccess.insertDirectly("DRAFT", ownPID: getpid(), ignoringFields: [], pasteOnly: false, expected: capture.emailField)
        #expect(MockField.shared.text == "DRAFT" + thread)
        // Once at the start of the insertion; the checks right before the
        // write read only the selection and the text around it.
        #expect(MockField.shared.wholeTextReads == 2)
        #expect(MockField.shared.textReadsWhileSecure == 0)
    }

    @Test func anEditPastWhatWasSentDoesNotRefuseTheEmail() throws {
        // The route is sent the first 16,000 scalars of the body, and the
        // check cuts the body it reads again the same way.
        let sent = String(repeating: "a", count: 16_000)
        reset {
            mail($0)
            $0.text = sent + "Jane"
        }
        let capture = try emailBody()
        MockField.shared.text = sent + "June"
        _ = FieldAccess.insertDirectly("DRAFT", ownPID: getpid(), ignoringFields: [], pasteOnly: false, expected: capture.emailField)
        #expect(MockField.shared.text == "DRAFT" + sent + "June")
    }

    @Test func theBodyCheckRefusesAFieldThatTurnedSecureOrDoesNotAnswer() throws {
        reset(mail)
        var capture = try emailBody()
        MockField.shared.secure = true
        #expect(capture.emailField.stillCurrent?() == .secureField)
        #expect(MockField.shared.textReadsWhileSecure == 0)
        // Its length does not answer: no other source is read instead.
        let thread = longThread
        reset {
            mail($0)
            $0.text = thread
        }
        capture = try emailBody()
        let reads = MockField.shared.wholeTextReads
        MockField.shared.markerLengthUnanswered = true
        #expect(capture.emailField.stillCurrent?() == .unreadableField)
        #expect(MockField.shared.wholeTextReads == reads)
    }

    @Test func focusLeavingTheBodySinceTheReadRefusesTheWrite() throws {
        reset(mail)
        let capture = try emailBody()
        MockField.shared.focusedElement = 2
        let result = insert("DRAFT", into: capture)
        #expect(MockField.shared.accessibilityWrites == 0)
        if case .finished(.notInserted(.focusChanged)) = result {} else { Issue.record("\(result)") }
    }
    private func outlook(_ field: MockField, host: String = "outlook.office.com", label: String = "Message body") {
        field.bundleIdentifier = "com.google.Chrome"
        field.web = true
        field.label = label
        field.pageURL = "https://\(host)/mail/deeplink/compose"
        field.text = String(repeating: "a", count: 200) + "\n\nThursday at 10?"
        field.selection = FieldRange(location: 0, length: 0)
    }

    // The 12 web and six native shapes from outlook-alpha's audit. These
    // are scripted assumptions, not live Accessibility observations.
    @Test(arguments: ["com.google.Chrome", "com.google.Chrome.beta"], ["outlook.office.com", "outlook.live.com"])
    func outlookAuditWebShapesRequireTheEvidenceBackedBodyLabel(browser: String, host: String) throws {
        for label in ["Message Body", "Message body", ""] {
            reset { outlook($0, host: host, label: label); $0.bundleIdentifier = browser }
            if label == "Message body" {
                #expect(try emailBody().observation.body == String(repeating: "a", count: 200) + "\n\nThursday at 10?")
            } else {
                #expect(isPlain())
                #expect(MockField.shared.wholeTextReads == 0)
            }
        }
    }

    @Test(arguments: ["Message Body", "Message body", ""], [true, false])
    func nativeOutlookAuditShapesStayPlainUntilItsLiveTreeIsQualified(label: String, document: Bool) {
        reset {
            $0.bundleIdentifier = "com.microsoft.Outlook"
            $0.document = document
            $0.text = String(repeating: "a", count: 200)
            $0.label = label
        }
        #expect(isPlain())
        #expect(MockField.shared.wholeTextReads == 0)
    }

    @Test(arguments: ["outlook.office.com", "outlook.live.com"], ["", "Synthetic draft\nwith two lines"])
    func outlookEmptyAndPopulatedBodiesAreReadFromOneSource(host: String, body: String) throws {
        reset { outlook($0, host: host, label: "Message body, press Alt+F10 to exit"); $0.text = body }
        let capture = try emailBody()
        #expect(capture.observation.body == body)
        #expect(capture.emailField.stillCurrent?() == nil)
        #expect(MockField.shared.textReadsWhileSecure == 0)
    }

    @Test(arguments: ["To", "Cc", "Bcc", "Subject", "Add a subject", "Search", "Search mail and people"])
    func outlookHeadersAndSearchArePlainWithoutAWholeBodyRead(label: String) {
        reset { outlook($0, label: label); $0.text = String(repeating: "x", count: 200) }
        #expect(isPlain())
        #expect(MockField.shared.wholeTextReads == 0)
        #expect(!ComposeAccess.couldBeEmailBody(bundleIdentifier: "com.google.Chrome", labels: label))
    }

    @Test(arguments: ["Message body suffix", "Message body, press Alt+F10 to exit extra", "Subject\nMessage body"])
    func outlookBodyLabelsMatchTheOwnDescriptionExactly(label: String) {
        reset { outlook($0, label: label) }
        #expect(isPlain())
        #expect(MockField.shared.wholeTextReads == 0)
    }

    @Test(arguments: [kAXTextFieldRole, kAXComboBoxRole, "AXSearchField", "AXWebArea"])
    func outlookBodyLabelOnAnotherRoleIsPlain(role: String) {
        reset { outlook($0); $0.role = role }
        #expect(isPlain())
        #expect(MockField.shared.wholeTextReads == 0)
    }

    @Test(arguments: ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.kagi.kagimacOS"])
    func gmailsBodyKeepsItsExistingBrowserAdmission(browser: String) throws {
        reset { gmail($0, in: browser); $0.text = String(repeating: "a", count: 200) }
        #expect(ComposeAccess.couldBeEmailBody(bundleIdentifier: browser, labels: "Message Body"))
        #expect(try emailBody().observation.body == String(repeating: "a", count: 200))
    }

    @Test func gmailsPasteOnlyBodyKeepsItsExistingComposeAdmission() throws {
        reset { gmail($0); $0.settable = false; $0.text = String(repeating: "a", count: 200) }
        #expect(try emailBody().observation.body == String(repeating: "a", count: 200))
    }

    @Test func outlookReadingPaneWithOnlyASettableSelectionIsPlain() {
        reset { outlook($0); $0.settable = false }
        #expect(isPlain())
        #expect(MockField.shared.wholeTextReads == 0)
    }

    @Test(arguments: ["https://outlook.office.com.example.net/mail", "https://outlook.live.com.example.net/mail",
                      "https://example.net/outlook.office.com", "https://mail.google.com/mail/u/0/#inbox", ""])
    func outlookRequiresItsOwnNearestPageHost(address: String) {
        reset { outlook($0); $0.pageURL = address.isEmpty ? nil : address }
        #expect(isPlain())
        #expect(MockField.shared.wholeTextReads == 0)
    }

    @Test(arguments: [false, true])
    func outlookDoesNotBorrowTheHostOfAnOuterPage(silent: Bool) {
        reset {
            outlook($0)
            $0.pageURL = "https://addon.example.net/editor"
            $0.outerPageURL = "https://outlook.office.com/mail"
            $0.webAreaRoleUnanswered = silent
        }
        #expect(isPlain())
        #expect(MockField.shared.wholeTextReads == 0)
    }

    @Test func outlookMetadataReadDoesNotReadTheWholeBodyOrOfferGmailProposals() {
        reset { outlook($0); $0.text = String(repeating: "a", count: 200) }
        #expect(ComposeAccess.couldBeEmailBody(bundleIdentifier: "com.google.Chrome", labels: "Message body"))
        if case .success(.emailBodyWithoutText(nil)) = ComposeAccess.focusedEmailDraft(ownPID: getpid(), text: false) {} else {
            Issue.record("Outlook metadata read did not recognize the body")
        }
        #expect(MockField.shared.wholeTextReads == 0)
        if case .success(nil) = ComposeAccess.proposalCandidate(ownPID: getpid()) {} else {
            Issue.record("Outlook must not enter Gmail reply proposals")
        }
    }

    @Test func outlookBodyGuardsRefuseChangedTextAndFocus() throws {
        reset { outlook($0); $0.text = String(repeating: "a", count: 250) }
        let changed = try emailBody()
        MockField.shared.text = String(repeating: "a", count: 249) + "b"
        #expect(changed.emailField.stillCurrent?() == .fieldChanged)
        reset { outlook($0) }
        let moved = try emailBody()
        MockField.shared.focusedElement = 2
        #expect(moved.emailField.stillCurrent?() == .focusChanged)
    }

    @Test func outlookUnansweredBodyReadsNeverSwitchSources() {
        reset { outlook($0); $0.countUnanswered = true }
        #expect(unread() == .unreadableField)
        #expect(MockField.shared.wholeTextReads == 0)
    }

    @Test func outlookBodyTurningSecureIsRefusedWithoutReadingItsText() {
        reset {
            outlook($0)
            $0.onOtherRead = { MockField.shared.secure = true }
        }
        let result = read()
        if case .failure(.secureField) = result {} else if case .success(.emailBodyWithoutText(.secureField)) = result {} else {
            Issue.record("Secure Outlook field was not refused")
        }
        #expect(MockField.shared.textReadsWhileSecure == 0)
    }

}

extension ComposeAccessTests {
    @Test(arguments: ["Cuerpo del mensaje", "Corps du message", "Nachrichtentext", "邮件正文", "本文"])
    func localizedGmailBodiesUseEditorClassesWithoutEnglishLabels(label: String) throws {
        reset {
            gmail($0)
            $0.label = label
            $0.domClassList = ["Am", "Al", "editable", "LW-avf"]
        }
        #expect(try emailBody().observation.body == "abc")
        var rejection: ComposeAccess.CandidateRejection?
        let candidate = ComposeAccess.proposalCandidate(ownPID: getpid(), rejected: { rejection = $0 })
        guard case .success(.some) = candidate else { Issue.record("Localized body was rejected"); return }
        #expect(rejection == nil)
    }

    @Test(arguments: ["role", "identity", "descriptionRead", "bodyClassRead", "windowRead", "ancestryRead", "addressRead", "host"])
    func candidateRejectionsIdentifyTheFailedCheck(check: String) {
        reset {
            gmail($0)
            switch check {
            case "role": $0.role = kAXTextFieldRole
            case "identity": $0.label = "Search mail"
            case "descriptionRead": $0.descriptionUnanswered = true
            case "bodyClassRead": $0.label = "Cuerpo del mensaje"; $0.domClassListUnanswered = true
            case "windowRead": $0.windowUnanswered = true
            case "ancestryRead": $0.webAreaRoleUnanswered = true
            case "addressRead": $0.pageURL = nil
            case "host": $0.pageURL = "https://example.com/"
            default: break
            }
        }
        var rejection: ComposeAccess.CandidateRejection?
        let answer = ComposeAccess.proposalCandidate(ownPID: getpid(), rejected: { rejection = $0 })
        let expected: ComposeAccess.CandidateRejection = switch check {
        case "role": .role
        case "identity": .bodyIdentity
        case "descriptionRead": .descriptionRead
        case "bodyClassRead": .bodyClassRead
        case "windowRead": .windowRead
        case "ancestryRead": .ancestryRead
        case "addressRead": .addressRead
        default: .notGmail
        }
        #expect(rejection == expected)
        if ["descriptionRead", "bodyClassRead", "windowRead", "ancestryRead", "addressRead"].contains(check) {
            guard case .failure(.targetUnresponsive) = answer else { Issue.record("Read failure must be retryable"); return }
        } else {
            guard case .success(nil) = answer else { Issue.record("An ineligible field must not be retried"); return }
        }
        #expect(MockField.shared.wholeTextReads == 0)
    }

    @Test(arguments: [["Am"], ["editable"], ["not-Am", "editable"]])
    func localizedOtherFieldsCannotClaimGmailBodyIdentity(classes: [String]) {
        reset { gmail($0); $0.label = "Cuerpo del mensaje"; $0.domClassList = classes }
        #expect(isPlain())
        guard case .success(nil) = ComposeAccess.proposalCandidate(ownPID: getpid()) else {
            Issue.record("Missing exact editor classes must reject the field")
            return
        }
        #expect(MockField.shared.wholeTextReads == 0)
    }
}
