import AppKit
@testable import Compose
import Testing

/// The walk around an email's body in a web compose, on made-up pages
/// copied from the trees Chromium (Electron 44, Chromium 152) and WebKit
/// (macOS 27.2) gave `Fixtures/insertion-gmail-reply.html` on October 6,
/// 2026, which copies Gmail's own structure for an inline reply. Expected
/// text is written out by hand.
@Suite struct ComposePageTests {
    /// One element of a made-up page. Reads are counted, and an element can
    /// stop answering.
    final class Node: PageNode {
        let role: String
        let subrole: String?
        let description: String?
        let title: String?
        let value: String?
        private(set) var children: [Node] = []
        /// Weak, so a test holds its page's root while it reads.
        weak var parent: Node?
        var answers = true
        var childrenAnswer = true
        var textAnswers = true
        var valueReads = 0
        var labelReads = 0
        var onLabels: (() -> Void)?
        /// Every read of any element of the page, in the order the walk made
        /// them, which is the walk's own count of reads.
        var counter: Counter?

        init(_ role: String, subrole: String? = nil, description: String? = nil, title: String? = nil, value: String? = nil,
             _ children: [Node] = []) {
            self.role = role
            self.subrole = subrole
            self.description = description
            self.title = title
            self.value = value
            self.children = children
            for child in children { child.parent = self }
        }

        func pageRole() -> PageRole? {
            counter?.reads += 1
            guard answers else { return nil }
            return PageRole(role: role, subrole: subrole)
        }

        func pageLabels() -> PageLabels? {
            counter?.reads += 1
            labelReads += 1
            onLabels?()
            guard answers, textAnswers else { return nil }
            return PageLabels(description: description, title: title)
        }

        func pageChildren() -> [Node]? {
            counter?.reads += 1
            guard answers, childrenAnswer else { return nil }
            return children
        }

        func pageValue() -> String? {
            counter?.reads += 1
            valueReads += 1
            guard textAnswers else { return nil }
            return value
        }

        func pageParent() -> Node? {
            counter?.reads += 1
            return parent
        }
        func isNode(_ other: Node) -> Bool { self === other }

        /// Every element below this one, this one first.
        var all: [Node] { [self] + children.flatMap(\.all) }
    }

    final class Counter {
        var reads = 0
    }

    static func text(_ value: String) -> Node { Node(kAXStaticTextRole, value: value) }
    static func cell(_ value: String) -> Node { Node("AXCell", [text(value)]) }
    static func group(_ children: [Node]) -> Node { Node(kAXGroupRole, children) }

    /// The page as Chromium gave it, collapsed: the first message and the one
    /// before the last as headers with a snippet, the three between them as
    /// a button, the last in full with the inline reply in its list item,
    /// and a New Message window of its own beside the thread.
    struct Page {
        let page: Node
        let replyBody: Node
        let replyRegion: Node
        let newBody: Node
        let subjectField: Node
        let summary: Node
    }

    static func chromiumPage(webKitText: Bool = false, expanded: Bool = false) -> Page {
        let summary = webKitText
            ? group([group([text("Priya Raman (priya@northwind.example)1 more")])])
            : group([group([text("Priya Raman (priya@northwind.example)"), text("1 more")])])
        let replyBody = Node(kAXTextAreaRole, description: "Message Body", value: "\n", [text("Typed by the person, never read here")])
        let replyRegion = Node(kAXGroupRole, subrole: "AXLandmarkRegion", description: "Re: Venue options for the October offsite", [
            summary, replyBody,
            Node(kAXButtonRole, description: "Show trimmed content"),
            Node(kAXButtonRole, description: "Send ‪(⌘Enter)‬"),
        ])
        let heading = webKitText
            ? Node("AXHeading", title: "Priya Raman priya@northwind.example", [text("Priya Raman priya@northwind.example")])
            : Node("AXHeading", title: "Priya Raman priya@northwind.example", [text("Priya Raman"), text(" "), text("priya@northwind.example")])
        let last = group([
            Node(kAXGroupRole, title: "Priya Raman priya@northwind.example", [heading]),
            cell("Oct 4, 10:02 AM"), Node(kAXButtonRole, description: "Reply"),
            group([text("to Tomás, me")]),
            group([text("Quick update: Harbor Hall can hold the 16th and 17th for 4,650, and the deposit is due Friday.")]),
            group([text("Sam, can you confirm the headcount by "), Node("AXLink", [text("the form")]), text(" by Thursday?")]),
            group([text("Priya")]),
            replyRegion,
        ])
        var items: [Node]
        if expanded {
            items = [
                group([Node("AXHeading", [text("Priya Raman priya@northwind.example")]), cell("Oct 1, 9:12 AM"),
                       group([text("I shortlisted three venues for the offsite.")])]),
                group([Node("AXHeading", [text("Sam Lee sam@fabrikam.example")]), cell("Oct 1, 11:40 AM"),
                       group([text("Quarry Loft is out for me.")])]),
                last,
            ]
        } else {
            items = [
                group([cell("Priya Raman"), cell("Oct 1, 9:12 AM"), cell("Hi both, I shortlisted three venues for the offsite")]),
                group([Node(kAXButtonRole, description: "3 older messages")]),
                group([cell("Tomás Ortega"), cell("Oct 3, 4:51 PM"), cell("I called Harbor Hall, they have the 16th and 17th pencilled in")]),
                last,
            ]
        }
        let subjectField = Node(kAXTextFieldRole, description: "Subject", value: "Catering for the offsite")
        let newBody = Node(kAXTextAreaRole, description: "Message Body", value: "\n")
        let chip = webKitText ? Node(kAXStaticTextRole, title: "Tomás Ortega") : text("Tomás Ortega")
        let dialog = Node(kAXGroupRole, subrole: "AXApplicationDialog", description: "New Message", [
            Node("AXHeading", title: "New Message", [text("New Message")]),
            Node(kAXGroupRole, subrole: "AXLandmarkRegion", description: "New Message", [
                Node(kAXListRole, description: "Search Field", [chip, Node(kAXComboBoxRole, description: "To recipients")]),
                subjectField, newBody,
            ]),
        ])
        let page = Node("AXWebArea", [
            Node(kAXGroupRole, subrole: "AXLandmarkMain", [
                Node("AXHeading", title: "Venue options for the October offsite", [text("Venue options for the October offsite")]),
                Node(kAXListRole, subrole: "AXContentList", items),
            ]),
            dialog,
        ])
        return Page(page: page, replyBody: replyBody, replyRegion: replyRegion, newBody: newBody, subjectField: subjectField, summary: summary)
    }

    /// The reader as `ComposeAccess` runs it, with the page's own reads of a
    /// field's value and the thread's id stood in for, and counted.
    final class Reads {
        var fields: [Node] = []
        var pages: [Node] = []
        /// The walk's reads when each was asked.
        var fieldAt: [Int] = []
        var pageAt: [Int] = []
    }

    static func read(_ body: Node, reads: Reads = Reads(), counter: Counter? = nil, budget: Duration = ComposePage.budget,
                     elementLimit: Int = ComposePage.elementLimit) -> PageSurroundings {
        ComposePage.read(body: body, fieldText: { field, _ in
            reads.fields.append(field)
            reads.fieldAt.append(counter?.reads ?? 0)
            return field.value
        }, threadID: { page, _ in
            reads.pages.append(page)
            reads.pageAt.append(counter?.reads ?? 0)
            return "18f2a3b4c5d6e7f8"
        }, budget: budget, elementLimit: elementLimit)
    }

    /// Counts every read of `page`'s elements.
    static func counted(_ page: Node) -> Counter {
        let counter = Counter()
        for node in page.all { node.counter = counter }
        return counter
    }

    static let collapsedThread = """
        Priya Raman priya@northwind.example
        Oct 4, 10:02 AM
        to Tomás, me
        Quick update: Harbor Hall can hold the 16th and 17th for 4,650, and the deposit is due Friday.
        Sam, can you confirm the headcount by the form by Thursday?
        Priya

        Tomás Ortega
        Oct 3, 4:51 PM
        I called Harbor Hall, they have the 16th and 17th pencilled in

        Priya Raman
        Oct 1, 9:12 AM
        Hi both, I shortlisted three venues for the offsite
        """

    @Test(arguments: [false, true])
    func anInlineReplyGivesItsRecipientSubjectThreadAndThreadID(webKitText: Bool) {
        let page = Self.chromiumPage(webKitText: webKitText)
        let reads = Reads()
        let found = Self.read(page.replyBody, reads: reads)
        #expect(found.inThread)
        #expect(found.recipients == ["priya@northwind.example"])
        #expect(found.subject == "Re: Venue options for the October offsite")
        #expect(!found.subjectShown)
        #expect(found.thread == Self.collapsedThread)
        #expect(found.threadID == "18f2a3b4c5d6e7f8")
        // The id is asked of the page above the body, once, and no field's
        // value is read: an inline reply's subject field is hidden.
        #expect(reads.pages.count == 1 && reads.pages.first === page.page)
        #expect(reads.fields.isEmpty)
    }

    @Test(arguments: [false, true])
    func theBodyAndControlsAreNeverRead(newMessage: Bool) {
        let page = Self.chromiumPage()
        _ = Self.read(newMessage ? page.newBody : page.replyBody)
        let body = (newMessage ? page.newBody : page.replyBody).all
        #expect(body.allSatisfy { $0.valueReads == 0 && $0.labelReads == 0 })
        // Buttons, combo boxes and text areas give neither text nor labels;
        // a text field's labels are read only to find the Subject field.
        let controls = page.page.all.filter { [kAXButtonRole, kAXTextAreaRole, kAXComboBoxRole].contains($0.role) }
        #expect(controls.allSatisfy { $0.valueReads == 0 && $0.labelReads == 0 })
        #expect(page.subjectField.valueReads == 0)
        // Of the other elements, only the reply's own region gives its label.
        let labelled = page.page.all.filter { $0.labelReads > 0 && $0.role != kAXTextFieldRole }
        #expect(labelled.map(\.role) == (newMessage ? [] : [kAXGroupRole]))
    }

    @Test func anExpandedThreadGivesEveryMessageMostRecentFirst() {
        let page = Self.chromiumPage(expanded: true)
        let found = withExtendedLifetime(page.page) { Self.read(page.replyBody) }
        #expect(found.thread == """
            Priya Raman priya@northwind.example
            Oct 4, 10:02 AM
            to Tomás, me
            Quick update: Harbor Hall can hold the 16th and 17th for 4,650, and the deposit is due Friday.
            Sam, can you confirm the headcount by the form by Thursday?
            Priya

            Sam Lee sam@fabrikam.example
            Oct 1, 11:40 AM
            Quarry Loft is out for me.

            Priya Raman priya@northwind.example
            Oct 1, 9:12 AM
            I shortlisted three venues for the offsite.
            """)
    }

    @Test(arguments: [false, true])
    func aNewMessageWindowGivesItsSubjectFieldAndNoThread(webKitText: Bool) {
        let page = Self.chromiumPage(webKitText: webKitText)
        let reads = Reads()
        let found = Self.read(page.newBody, reads: reads)
        // A window of its own is not in the thread behind it, whatever the
        // page's address says, so neither the thread nor its id is read.
        #expect(!found.inThread)
        #expect(found.thread.isEmpty)
        #expect(found.threadID == nil)
        #expect(reads.pages.isEmpty)
        #expect(found.subject == "Catering for the offsite")
        #expect(found.subjectShown)
        #expect(reads.fields.count == 1 && reads.fields.first === page.subjectField)
        // A recipient Gmail knows shows as a name, which is no address.
        #expect(found.recipients.isEmpty)
    }

    @Test func aSubjectFieldThatIsNotReadGivesNoSubject() {
        let page = Self.chromiumPage()
        // The caller's secure check refused the field.
        let found = ComposePage.read(body: page.newBody, fieldText: { _, _ in nil }, threadID: { _, _ in nil })
        #expect(found.subject.isEmpty)
    }

    @Test func aBodyOutsideAnyRegionOrDialogGivesNothing() {
        let body = Node(kAXTextAreaRole, description: "Message Body")
        let page = Node("AXWebArea", [Node(kAXGroupRole, subrole: "AXLandmarkMain", [body, Self.text("priya@northwind.example")])])
        let reads = Reads()
        #expect(withExtendedLifetime(page) { Self.read(body, reads: reads) } == PageSurroundings())
        #expect(reads.pages.isEmpty)
    }

    @Test func aBodyBelowNoPageGivesNothing() {
        // Its ancestors end before a web area: not a web page's field.
        let body = Node(kAXTextAreaRole, description: "Message Body")
        let region = Node(kAXGroupRole, subrole: "AXLandmarkRegion", description: "Re: Offsite", [Self.text("priya@northwind.example"), body])
        #expect(withExtendedLifetime(region) { Self.read(body) } == PageSurroundings())
    }

    @Test func anAncestorThatDoesNotAnswerEndsTheWalkWithNothing() {
        let page = Self.chromiumPage()
        let reads = Reads()
        page.replyRegion.answers = false
        #expect(Self.read(page.replyBody, reads: reads) == PageSurroundings())
        #expect(reads.pages.isEmpty)
    }

    @Test func aMessageThatDoesNotAnswerIsLeftOutAndTheRestRead() {
        let page = Self.chromiumPage()
        let list = page.page.all.first { $0.subrole == "AXContentList" }!
        list.children[2].answers = false
        let found = Self.read(page.replyBody)
        #expect(!found.thread.contains("Tomás Ortega"))
        #expect(found.thread.hasPrefix("Priya Raman priya@northwind.example\nOct 4"))
        #expect(found.thread.hasSuffix("Hi both, I shortlisted three venues for the offsite"))
    }

    @Test func aWalkOutOfTimeReadsNothing() {
        let page = Self.chromiumPage()
        #expect(withExtendedLifetime(page.page) { Self.read(page.replyBody, budget: .zero) } == PageSurroundings())
    }

    @Test func aWalkOutOfReadsKeepsTheMostRecentMessages() {
        let body = Node(kAXTextAreaRole, description: "Message Body")
        let region = Node(kAXGroupRole, subrole: "AXLandmarkRegion", description: "Re: Offsite", [body])
        let older = (0..<500).map { Self.group([Self.text("Message \($0)")]) }
        let page = Node("AXWebArea", [Node(kAXListRole, subrole: "AXContentList", older + [Self.group([Self.text("Newest"), region])])])
        let found = withExtendedLifetime(page) { Self.read(body, elementLimit: 200) }
        let messages = found.thread.components(separatedBy: "\n\n")
        #expect(messages.first == "Newest")
        #expect(messages.dropFirst().first == "Message 499")
        #expect(messages.count > 10 && messages.count < 100)
        #expect(!found.thread.contains("Message 0\n") && !found.thread.hasSuffix("Message 0"))
        #expect(found.subject == "Re: Offsite")
    }

    @Test func theThreadStopsAtItsBoundAfterWholeMessages() {
        let body = Node(kAXTextAreaRole, description: "Message Body")
        let region = Node(kAXGroupRole, subrole: "AXLandmarkRegion", description: "Re: Offsite", [body])
        let long = String(repeating: "word ", count: 1_000).trimmingCharacters(in: .whitespaces)
        let older = (0..<10).map { Self.group([Self.text("\($0) " + long)]) }
        let page = Node("AXWebArea", [Node(kAXListRole, subrole: "AXContentList", older + [Self.group([region])])])
        let found = withExtendedLifetime(page) { Self.read(body) }
        let messages = found.thread.components(separatedBy: "\n\n")
        // 5,001 scalars each: four reach the bound, and the input cuts them.
        #expect(messages.count == 4)
        #expect(messages.first?.hasPrefix("9 word") == true)
        #expect(messages.last?.hasPrefix("6 word") == true)
    }

    @Test func oneLongMessageIsReadOnlyToTheThreadsBound() {
        // An expanded message far longer than the bound, in many paragraphs:
        // the walk stops reading inside it, and keeps nothing past the bound.
        let body = Node(kAXTextAreaRole, description: "Message Body")
        let region = Node(kAXGroupRole, subrole: "AXLandmarkRegion", description: "Re: Offsite", [body])
        let paragraph = String(repeating: "p", count: 999)
        let paragraphs = (0..<40).map { _ in Self.group([Self.text(paragraph)]) }
        let older = Self.group([Self.text("An older message")])
        let page = Node("AXWebArea", [Node(kAXListRole, subrole: "AXContentList", [older, Self.group(paragraphs + [region])])])
        let found = withExtendedLifetime(page) { Self.read(body) }
        #expect(found.thread.unicodeScalars.count == ComposePage.threadLimit)
        #expect(!found.thread.contains("An older message"))
        // 16 paragraphs and their line breaks fill the bound; the rest are
        // never read.
        let read = paragraphs.filter { $0.children[0].valueReads > 0 }.count
        #expect(read == 17)
        #expect(older.children[0].valueReads == 0)
    }

    @Test func theSubjectFieldIsNotAskedForOnceTheWalkIsOutOfReads() {
        let page = Self.chromiumPage()
        let counter = Self.counted(page.page)
        let reads = Reads()
        _ = Self.read(page.newBody, reads: reads, counter: counter)
        // With room for one more read the field is asked for; with none, it
        // is not, and nothing is read after the walk's last read.
        let needed = try! #require(reads.fieldAt.first)
        let enough = Reads()
        _ = Self.read(page.newBody, reads: enough, elementLimit: needed + 1)
        #expect(enough.fields.count == 1)
        let short = Reads()
        let found = Self.read(page.newBody, reads: short, elementLimit: needed)
        #expect(short.fields.isEmpty)
        #expect(found.subject.isEmpty)
    }

    @Test func theThreadIDIsNotAskedForOnceTheWalkIsOutOfReads() {
        let page = Self.chromiumPage()
        let counter = Self.counted(page.page)
        let reads = Reads()
        _ = Self.read(page.replyBody, reads: reads, counter: counter)
        let needed = try! #require(reads.pageAt.first)
        let short = Reads()
        let found = Self.read(page.replyBody, reads: short, elementLimit: needed)
        #expect(short.pages.isEmpty)
        #expect(found.threadID == nil)
        let enough = Reads()
        #expect(Self.read(page.replyBody, reads: enough, elementLimit: needed + 1).threadID == "18f2a3b4c5d6e7f8")
    }

    @Test func addressesAreFoundOnceEachInTheOrderShown() {
        #expect(ComposePage.addresses(in: [
            "Priya Raman (priya@northwind.example)1 more",
            "Tomás <tomas@contoso.example>, PRIYA@northwind.example",
            "Ana Silva", "o'brien+offsite@sub.fabrikam.example.", "not@an", "@nobody.example", "two@at@example.com",
        ]) == ["priya@northwind.example", "tomas@contoso.example", "o'brien+offsite@sub.fabrikam.example"])
        // An address is taken whole or not at all, in any script.
        #expect(ComposePage.addresses(in: ["Éloise (éloise@example.com)", "Zoë <zoë@fabrikam.example>"])
            == ["éloise@example.com", "zoë@fabrikam.example"])
        // Punctuation is trimmed from an address's end only; a local part may
        // start with it.
        #expect(ComposePage.addresses(in: ["Write to !alerts@example.com or ?help@example.com!", "ops@example.com.:"])
            == ["!alerts@example.com", "?help@example.com", "ops@example.com"])
        let many = (0..<40).map { "p\($0)@example.com" }
        #expect(ComposePage.addresses(in: many).count == ComposePage.recipientLimit)
    }

    // MARK: - Gmail's thread id

    /// Tokens worked out by hand for this test with Python's integers:
    /// base64 of `f:` and the id in decimal, read as a base 64 number and
    /// written in base 40 with Gmail's consonants.
    @Test(arguments: [
        ("https://mail.google.com/mail/u/0/#inbox/FMfcgzGxStwKgddWCdJhMcKqhqdxDtdG", "18f2a3b4c5d6e7f8"),
        ("https://mail.google.com/mail/u/1/#label/Work%2FTeam/FMfcgzQjhddFxMxkQxvBgVXPqKSXJMpp", "1a2b3c4d5e6f7081"),
        ("https://mail.google.com/mail/u/0/#search/offsite/LPmsdSMhcSHBsLSpZgdSgwwTBTgVdqNTLB", "fedcba9876543210"),
        ("https://mail.google.com/mail/u/0/#inbox/FMfcgzGxStwKgddWCdJhMcKqhqdxDtdG?compose=CllgCJT", "18f2a3b4c5d6e7f8"),
        // `thread-f:` and the id, as older tokens are said to hold.
        ("https://mail.google.com/mail/u/0/#inbox/NHgvNZFVxQXXXjLLhphnkPdTLMxlKzwqhCvjBZKjrJV", "18f2a3b4c5d6e7f8"),
        // The id itself, as a link to a thread gives it.
        ("https://mail.google.com/mail/u/0/#inbox/18f2a3b4c5d6e7f8", "18f2a3b4c5d6e7f8"),
    ])
    func aThreadsAddressGivesItsID(address: String, id: String) {
        #expect(GmailThreadID.id(from: URL(string: address)) == id)
    }

    @Test(arguments: [
        "https://mail.google.com/mail/u/0/#inbox",
        "https://mail.google.com/mail/u/0/#inbox?compose=new",
        "https://mail.google.com/mail/u/0/",
        // Hexadecimal, but too short for a thread: a label named so.
        "https://mail.google.com/mail/u/0/#label/fab",
        // A thread Gmail has not synced yet, and a message, not a thread.
        "https://mail.google.com/mail/u/0/#inbox/hxTnWLsSgZFtzTnCPbnHcvHmljQSrDDfZXkDZLjbFLLzr",
        "https://mail.google.com/mail/u/0/#inbox/CXKnWZngLGgsJqDVLWVhSkhXsqtTwFSSxNlQmwg",
        // A vowel is no digit of a token.
        "https://mail.google.com/mail/u/0/#inbox/FMfcgzGxStwKgddWCdJhMcKqhqdxDtdA",
    ])
    func anAddressWithoutAThreadGivesNoID(address: String) {
        #expect(GmailThreadID.id(from: URL(string: address)) == nil)
    }

    // MARK: A thread view before a reply opens

    /// The same page with no reply open: the last message without the
    /// inline reply's region, as Gmail shows it before Reply is clicked,
    /// and the page's title naming the account.
    static func threadPage(replyOpen: Bool = false, title: String? = "Venue options for the October offsite - sam@fabrikam.example - Gmail")
        -> (page: Node, replyBody: Node?) {
        let page = chromiumPage()
        // The region holds the reply; before Reply is clicked it is not there.
        let last = page.replyRegion.parent!
        let kept = Node(kAXGroupRole, last.children.filter { replyOpen || $0 !== page.replyRegion })
        let list = last.parent!
        let items = list.children.map { $0 === last ? kept : $0 }
        let main = list.parent!
        let rebuilt = Node("AXWebArea", title: title, [
            Node(kAXGroupRole, subrole: "AXLandmarkMain", [main.children[0], Node(kAXListRole, subrole: "AXContentList", items)]),
        ])
        let body = replyOpen ? kept.all.first { $0.description == "Message Body" } : nil
        return (rebuilt, body)
    }

    @Test func aThreadViewGivesItsSubjectMessagesNewestSenderAndAccount() throws {
        let (page, _) = Self.threadPage()
        let found = try #require(withExtendedLifetime(page) { ComposePage.threadView(page: page) })
        #expect(found.subject == "Venue options for the October offsite")
        #expect(found.thread == Self.collapsedThread)
        #expect(found.newestSender == "priya@northwind.example")
        #expect(found.account == "sam@fabrikam.example")
        // Only the page, subject and sender headings, and enclosing header
        // group supply labels, never a control or field.
        let labelled = page.all.filter { $0.labelReads > 0 }
        #expect(labelled.map(\.role) == ["AXWebArea", "AXHeading", kAXGroupRole, "AXHeading"])
        #expect(page.all.filter { $0.role == kAXButtonRole }.allSatisfy { $0.valueReads == 0 && $0.labelReads == 0 })
    }

    @Test(arguments: ["missing", "failed", "ambiguous", "body heading"])
    func aBodyAddressNeverBecomesTheNewestSender(header: String) throws {
        let sender = Node("AXHeading", [Self.text(header == "ambiguous"
            ? "Priya priya@northwind.example Sam sam@fabrikam.example" : "Priya Raman")])
        if header == "failed" { sender.answers = false }
        let body = Self.group([Self.text("Send the details to sam@fabrikam.example")])
        let message = Self.group(header == "body heading"
            ? [body, Self.group([Node("AXHeading", [Self.text("sam@fabrikam.example")])])]
            : [sender, body])
        let page = Node("AXWebArea", title: "Venue - sam@fabrikam.example - Gmail", [
            Node(kAXGroupRole, subrole: "AXLandmarkMain", [Node("AXHeading", [Self.text("Venue")]), Node(kAXListRole, [message])]),
        ])
        let found = try #require(ComposePage.threadView(page: page))
        #expect(found.newestSender == nil)
        #expect(found.account == "sam@fabrikam.example")
        #expect(found.thread.contains("Send the details to sam@fabrikam.example"))
    }

    /// The nested sender, empty heading sibling, time, recipient popup and
    /// separate body follow the observed Gmail shape. All text is synthetic.
    static func nestedSenderPage(sender: String = "Priya Raman PRIYA@Northwind.example", replyOpen: Bool = false, quotedHeading: Node? = nil)
        -> (page: Node, body: Node, heading: Node) {
        let heading = Node("AXHeading", title: sender, [Node("AXCell", [
            text("Priya Raman"), text(" "), text(sender == "Priya Raman PRIYA@Northwind.example" ? "PRIYA@Northwind.example" : sender),
        ])])
        var header = Node(kAXGroupRole, title: sender, [heading, Node("AXHeading", title: "")])
        header = group([group([header])])
        header = Node(kAXGroupRole, title: sender, [header])
        let body = Node(kAXTextAreaRole, description: "Message Body", value: "\n")
        let reply = Node(kAXGroupRole, subrole: "AXLandmarkRegion", description: "Re: Venue", [
            group([text("Priya Raman (priya@northwind.example)")]), body,
        ])
        let message = group([group([group([group([
            header,
            group([text("9:99 aa (99 aaaaa aaa)")]),
            group([text("to me"), Node(kAXPopUpButtonRole, description: "Message details")]),
            group([group([text("Can you confirm? Send details to events@northwind.example.")])]
                + (quotedHeading.map { [$0] } ?? [])),
        ] + (replyOpen ? [reply] : []))])])])
        let page = Node("AXWebArea", title: "Venue - sam@fabrikam.example - Gmail", [
            Node(kAXGroupRole, subrole: "AXLandmarkMain", [
                Node("AXHeading", title: "Venue", [text("Venue")]), Node(kAXListRole, [message]),
            ]),
        ])
        return (page, body, heading)
    }

    @Test func aNestedSenderHeadingMatchesTheInlineReplyRecipient() throws {
        let before = Self.nestedSenderPage()
        let after = Self.nestedSenderPage(replyOpen: true)
        let opened = try #require(ComposePage.threadView(page: before.page))
        let reply = withExtendedLifetime(after.page) { Self.read(after.body) }
        #expect(opened.newestSender == "PRIYA@Northwind.example")
        #expect(reply.recipients == ["priya@northwind.example"])
        #expect(opened.newestSender?.lowercased() == reply.recipients.first)
        #expect(reply.thread == opened.thread)
        #expect(reply.subject == "Re: " + opened.subject)
        #expect(before.page.all.filter { $0.labelReads > 0 }.map(\.role) == ["AXWebArea", "AXHeading", kAXGroupRole, "AXHeading"])
    }

    @Test(arguments: [false, true])
    func aShallowerQuotedHeadingCannotSupplyTheSender(ambiguous: Bool) throws {
        let quoted = Node("AXHeading", title: "Sam sam@fabrikam.example", [Self.text("sam@fabrikam.example")])
        let fixture = Self.nestedSenderPage(
            sender: ambiguous ? "Priya priya@northwind.example Sam sam@fabrikam.example" : "Priya priya@northwind.example",
            quotedHeading: quoted)
        let found = try #require(ComposePage.threadView(page: fixture.page))
        #expect(found.newestSender == (ambiguous ? nil : "priya@northwind.example"))
        #expect(found.account == "sam@fabrikam.example")
        #expect(found.newestSender?.lowercased() != found.account?.lowercased())
        #expect(quoted.labelReads == 0)
    }

    @Test func anEmptyHeadingBeforeTheSenderIsSkipped() throws {
        let page = Self.senderPage(Self.group([
            Node("AXHeading", title: "  "),
            Node(kAXGroupRole, title: "Priya priya@northwind.example", [Node("AXHeading", title: "Priya priya@northwind.example")]),
            Self.text("Can you confirm?"),
        ]))
        let found = try #require(ComposePage.threadView(page: page))
        #expect(found.newestSender == "priya@northwind.example")
    }

    @Test func anEmptyHeaderBeforeABodyHeadingDoesNotIdentifyTheAccountAsSender() throws {
        let content = Self.group([Node("AXHeading", title: "sam@fabrikam.example"), Self.text("Can you confirm?")])
        let header = Self.group([Node("AXHeading", title: "")])
        let page = Node("AXWebArea", title: "Venue - sam@fabrikam.example - Gmail", [
            Node(kAXGroupRole, subrole: "AXLandmarkMain", [
                Node("AXHeading", title: "Venue"), Node(kAXListRole, [Self.group([header, content])]),
            ]),
        ])
        let found = try #require(ComposePage.threadView(page: page))
        #expect(found.account == "sam@fabrikam.example")
        #expect(found.newestSender == nil)
        #expect(found.newestSender?.lowercased() != found.account?.lowercased())
    }

    @Test func aFailedHeadingLabelReadCannotHideASecondAddress() throws {
        let heading = Node("AXHeading", title: "Sam sam@fabrikam.example other@northwind.example", [Self.text("Sam sam@fabrikam.example")])
        heading.textAnswers = false
        let later = Node("AXHeading", title: "Priya priya@northwind.example")
        let page = Node("AXWebArea", title: "Venue - sam@fabrikam.example - Gmail", [
            Node(kAXGroupRole, subrole: "AXLandmarkMain", [
                Node("AXHeading", title: "Venue"), Node(kAXListRole, [Self.group([
                    Node(kAXGroupRole, title: "Sam sam@fabrikam.example", [heading]),
                    Node(kAXGroupRole, title: "Priya priya@northwind.example", [later]),
                    Self.text("Can you confirm?"),
                ])]),
            ]),
        ])
        let found = try #require(ComposePage.threadView(page: page))
        #expect(found.newestSender == nil)
        #expect(later.labelReads == 0)
    }

    @Test(arguments: ["Forwarded message", "Priya priya@northwind.example"])
    func aBodyHeadingNeedsAMatchingAncestorTitle(ancestorTitle: String) throws {
        let later = Node("AXHeading", title: "Priya priya@northwind.example")
        let page = Self.senderPage(Self.group([
            Node(kAXGroupRole, title: ancestorTitle, [Node("AXHeading", title: "sam@fabrikam.example")]),
            Node(kAXGroupRole, title: "Priya priya@northwind.example", [later]),
            Self.text("Can you confirm?"),
        ]))
        let found = try #require(ComposePage.threadView(page: page))
        #expect(found.newestSender == nil)
        #expect(later.labelReads == 0)
    }

    @Test func theLiveGmailSenderStructureHasAMatchingHeaderTitle() throws {
        let label = "Priya Raman priya@northwind.example"
        let heading = Node("AXHeading", title: label, [Node("AXCell", [
            Self.text("Priya Raman"), Self.text(" "), Self.text("priya@northwind.example"),
        ])])
        let inner = Node(kAXGroupRole, title: label, [heading, Node("AXHeading", title: "")])
        var nested = Node(kAXGroupRole, title: label, [Self.group([Self.group([inner])])])
        for _ in 0..<6 { nested = Self.group([nested]) }
        let page = Self.senderPage(Self.group([nested, Self.text("Can you confirm?")]))
        #expect(try #require(ComposePage.threadView(page: page)).newestSender == "priya@northwind.example")
    }

    @Test(arguments: ["role", "children", "text"])
    func anIncompleteHeadingCannotMatchAHeaderUsingOnlyItsReadableAddress(failure: String) throws {
        let missing = failure == "children"
            ? Self.group([Self.text("other@northwind.example")]) : Self.text("other@northwind.example")
        missing.answers = failure != "role"
        missing.childrenAnswer = failure != "children"
        missing.textAnswers = failure != "text"
        let heading = Node("AXHeading", title: "Sam", [Self.text("Sam "), Self.text("sam@fabrikam.example"), missing])
        let later = Node("AXHeading", title: "Priya priya@northwind.example")
        let page = Self.senderPage(Self.group([
            Node(kAXGroupRole, title: "Sam sam@fabrikam.example", [heading]),
            Node(kAXGroupRole, title: "Priya priya@northwind.example", [later]),
            Self.text("Can you confirm?"),
        ]))
        #expect(try #require(ComposePage.threadView(page: page)).newestSender == nil)
        #expect(later.labelReads == 0)
    }

    @Test func oversizedOrdinaryTextStopsTheSenderSearchBeforeTrimming() throws {
        let heading = Node("AXHeading", title: "Priya priya@northwind.example")
        let page = Self.senderPage(Self.group([
            Self.text(String(repeating: " ", count: WritingInputBounds.subject + 1)),
            Node(kAXGroupRole, title: "Priya priya@northwind.example", [heading]),
            Self.text("Can you confirm?"),
        ]))
        #expect(try #require(ComposePage.threadView(page: page)).newestSender == nil)
        #expect(heading.labelReads == 0)
    }

    @Test(arguments: ["item title", "group description", "heading description"])
    func onlyAHeadingTitleOrTextMatchingAGroupInsideTheItemIdentifiesTheSender(source: String) throws {
        let label = "Priya priya@northwind.example"
        let heading = Node("AXHeading", description: source == "heading description" ? label : nil,
                           title: source == "heading description" ? "Forwarded message" : label)
        let group = Node(kAXGroupRole, description: source == "group description" ? label : nil,
                         title: source == "heading description" ? label : nil, [heading])
        let page = Self.senderPage(Node(kAXGroupRole, title: source == "item title" ? label : nil, [group, Self.text("Can you confirm?")]))
        #expect(try #require(ComposePage.threadView(page: page)).newestSender == nil)
    }

    @Test func aDisplayNameTitleUsesTheSameHeadingsText() throws {
        let heading = Node("AXHeading", title: "Priya Raman", [Self.cell("Priya Raman priya@northwind.example")])
        let page = Self.senderPage(Self.group([
            Node(kAXGroupRole, title: "Priya Raman priya@northwind.example", [heading]), Self.text("Can you confirm?"),
        ]))
        let found = try #require(ComposePage.threadView(page: page))
        #expect(found.newestSender == "priya@northwind.example")
    }

    @Test func aNestedHeadingWithTwoAddressesGivesNoSender() throws {
        let fixture = Self.nestedSenderPage(sender: "Priya priya@northwind.example Sam sam@fabrikam.example")
        let found = try #require(ComposePage.threadView(page: fixture.page))
        #expect(found.newestSender == nil)
    }

    @Test func aNestedHeadingCanSupplyItsTextWhenItsTitleIsEmpty() throws {
        let heading = Node("AXHeading", title: "", [Self.cell("priya@northwind.example")])
        let message = Self.group([Node(kAXGroupRole, title: "priya@northwind.example", [heading]), Self.text("Can you confirm?")])
        let page = Self.senderPage(message)
        let found = try #require(ComposePage.threadView(page: page))
        #expect(found.newestSender == "priya@northwind.example")
    }

    static func senderPage(_ message: Node) -> Node {
        Node("AXWebArea", [Node(kAXGroupRole, subrole: "AXLandmarkMain", [
            Node("AXHeading", title: "Venue"), Node(kAXListRole, [message]),
        ])])
    }

    @Test(arguments: [kAXButtonRole, kAXTextFieldRole, kAXTextAreaRole, kAXPopUpButtonRole,
                      kAXListRole, "AXWebArea", "AXApplicationDialog", "AXLandmarkRegion"])
    func aSenderSearchDoesNotEnterExcludedContainers(boundary: String) throws {
        let heading = Node("AXHeading", title: "other@northwind.example", [Self.text("other@northwind.example")])
        let subrole = boundary.hasPrefix("AXApplication") || boundary.hasPrefix("AXLandmark") ? boundary : nil
        let hidden = Node(subrole == nil ? boundary : kAXGroupRole, subrole: subrole, [heading])
        let page = Self.senderPage(Self.group([hidden, Self.text("Can you confirm?")]))
        let found = try #require(ComposePage.threadView(page: page))
        #expect(found.newestSender == nil)
        #expect(heading.labelReads == 0)
        #expect(hidden.labelReads == 0 && hidden.valueReads == 0)
    }

    @Test(arguments: [0, 30, 100, 300, 800])
    func aDeepSenderSearchStaysWithinTheSharedReadLimit(limit: Int) throws {
        let heading = Node("AXHeading", title: "priya@northwind.example")
        var nested = Node(kAXGroupRole, title: "priya@northwind.example", [heading])
        for _ in 0..<120 { nested = Self.group([nested]) }
        let page = Self.senderPage(Self.group([nested, Self.text("Can you confirm?")]))
        let counter = Self.counted(page)
        let found = ComposePage.threadView(page: page, elementLimit: limit)
        #expect(counter.reads <= limit)
        if limit < 800 {
            #expect(found?.newestSender == nil)
        } else {
            #expect(found?.newestSender == "priya@northwind.example")
        }
    }

    @Test(arguments: ["title", "description"])
    func anOversizedSenderLabelIsRejectedBeforeParsing(label: String) throws {
        let oversized = "priya@northwind.example" + String(repeating: " ", count: WritingInputBounds.subject)
        let heading = Node("AXHeading", description: label == "description" ? oversized : nil,
                           title: label == "title" ? oversized : nil, [Self.cell("priya@northwind.example")])
        let quoted = Node("AXHeading", title: "sam@fabrikam.example")
        let page = Self.senderPage(Self.group([heading, quoted, Self.text("Can you confirm?")]))
        let found = try #require(ComposePage.threadView(page: page))
        #expect(found.newestSender == nil)
        #expect(quoted.labelReads == 0)
    }

    @Test func aDeadlineReachedInsideTheSenderSearchStopsFurtherReads() throws {
        let heading = Node("AXHeading", [Self.cell("priya@northwind.example")])
        let page = Self.senderPage(Self.group([heading, Self.text("Can you confirm?")]))
        let counter = Self.counted(page)
        var readsAtDeadline: Int?
        heading.onLabels = {
            readsAtDeadline = counter.reads
            Thread.sleep(forTimeInterval: 1.1)
        }
        let found = try #require(ComposePage.threadView(page: page, budget: .seconds(1)))
        #expect(heading.labelReads == 1)
        #expect(found.newestSender == nil)
        #expect(readsAtDeadline != nil)
        #expect(counter.reads == readsAtDeadline)
    }

    @Test func aSenderSearchMakesNoReadsAfterItsTimeBudget() {
        let fixture = Self.nestedSenderPage()
        let counter = Self.counted(fixture.page)
        #expect(ComposePage.threadView(page: fixture.page, budget: .zero) == nil)
        #expect(counter.reads == 0)
    }

    @Test(arguments: ["same", "changed", "missing"])
    func thePageAddressMustStillMatchAfterTheThreadWalk(after: String) throws {
        let (page, _) = Self.threadPage()
        let initial = URL(string: "https://mail.google.com/mail/u/0/#inbox/18c2f4a9d0e1b3a2")!
        var reads = 0
        let result = ComposeAccess.gmailThreadPage(page: page, pid: 41, started: 7, address: {
            reads += 1
            if reads == 1 || after == "same" { return initial }
            if after == "missing" { return nil }
            return URL(string: "https://mail.google.com/mail/u/0/#inbox/18c2f4a9d0e1b3b7")
        }, isNew: { _, _ in true })
        #expect(reads == 2)
        if after == "same" {
            guard case let .opened(view) = result else { Issue.record("Expected the unchanged thread"); return }
            #expect(view.threadID == "18c2f4a9d0e1b3a2")
            #expect(view.subject == "Venue options for the October offsite")
            #expect(view.thread == Self.collapsedThread)
        } else {
            guard case .unavailable(.pageChanged) = result else { Issue.record("Expected a discarded read and bounded retry"); return }
        }
    }

    @Test func aThreadReadBeforeAndAfterTheReplyOpensGivesTheSameMessages() throws {
        // Read as the thread opens, and as the inline reply's own read gives
        // them once it has: the proposal asked for at the opening is the
        // reply's only when these are the same.
        let (before, _) = Self.threadPage()
        let (after, body) = Self.threadPage(replyOpen: true)
        let opened = try #require(withExtendedLifetime(before) { ComposePage.threadView(page: before) })
        let reopened = try #require(withExtendedLifetime(after) { ComposePage.threadView(page: after) })
        let replyBody = try #require(body)
        let reply = withExtendedLifetime(after) { Self.read(replyBody) }
        #expect(opened.thread == Self.collapsedThread)
        #expect(reopened.thread == Self.collapsedThread)
        #expect(reply.thread == Self.collapsedThread)
        #expect(reply.recipients == [opened.newestSender].compactMap { $0 })
        #expect(reply.subject == "Re: " + opened.subject)
    }

    @Test func aPageWithNoThreadListGivesNothing() {
        let page = Node("AXWebArea", title: "Inbox (3) - sam@fabrikam.example - Gmail", [
            Node(kAXGroupRole, subrole: "AXLandmarkMain", [Node("AXTable", [Self.cell("Priya Raman"), Self.cell("Venue options")])]),
        ])
        #expect(withExtendedLifetime(page) { ComposePage.threadView(page: page) } == nil)
        let loading = Node("AXWebArea", [Node(kAXGroupRole, subrole: "AXLandmarkMain", [Node(kAXListRole, [])])])
        #expect(withExtendedLifetime(loading) { ComposePage.threadView(page: loading) } == nil)
    }

    @Test func aThreadViewStaysWithinTheWalksLimit() {
        let (page, _) = Self.threadPage()
        let counter = Self.counted(page)
        let found = withExtendedLifetime(page) { ComposePage.threadView(page: page, elementLimit: 12) }
        #expect(counter.reads <= 12)
        #expect(found == nil || found?.thread.isEmpty == false)
    }

    @Test(arguments: [
        ("Venue options for the October offsite - sam@fabrikam.example - Gmail", "sam@fabrikam.example"),
        ("Re: Q3 - plan - sam@fabrikam.example - Fabrikam Mail", "sam@fabrikam.example"),
        ("Inbox (3) - sam@fabrikam.example - Gmail", "sam@fabrikam.example"),
        ("Venue options for the October offsite", nil),
        ("priya@northwind.example - Gmail", nil),
    ] as [(String, String?)])
    func thePageTitleNamesTheAccount(title: String, account: String?) {
        #expect(ComposePage.account(inTitle: title) == account)
    }
    @Test(arguments: ["address", "notGmail", "noThreadID", "messages"])
    func threadPageFailuresKeepFixedReasons(reason: String) {
        let page = Node("AXWebArea", [])
        let url: URL? = switch reason {
        case "address": nil
        case "notGmail": URL(string: "https://example.test/thread")
        case "noThreadID": URL(string: "https://mail.google.com/mail/u/0/#inbox")
        default: URL(string: "https://mail.google.com/mail/u/0/#inbox/18c2f4a9d0e1b3a2")
        }
        let result = ComposeAccess.gmailThreadPage(page: page, pid: 41, started: 7, address: { url }, isNew: { _, _ in true })
        guard case let .unavailable(named) = result else { Issue.record("Expected a named refusal"); return }
        #expect(named.rawValue == reason)
    }

    @Test func gmailDoesNotReadLaterFieldLabelsOnceTheSubjectIsFound() {
        let body = Node(kAXTextAreaRole, description: "Message Body")
        let subject = Node(kAXTextFieldRole, description: "Subject", value: "Thursday")
        let unused = Node(kAXTextFieldRole, description: "Search", value: "unrelated text")
        unused.onLabels = { Issue.record("Unused Gmail labels consumed the context budget") }
        let container = Node(kAXGroupRole, subrole: "AXApplicationDialog", [subject, unused, body])
        let page = Node("AXWebArea", [container])
        let result = ComposePage.read(body: body, rules: .gmail, fieldText: { field, _ in field.pageValue() },
                                      threadID: { _, _ in nil })
        withExtendedLifetime(page) {}
        #expect(result.subject == "Thursday")
        #expect(result.subjectShown)
        #expect(unused.labelReads == 0 && unused.valueReads == 0)
        #expect(subject.valueReads == 1)
    }

    @Test func outlookReadsStaticRecipientsAndOnlyTheSubjectControlValue() {
        let body = Node(kAXTextAreaRole, description: "Message body", value: "synthetic body")
        let to = Node(kAXComboBoxRole, description: "To", value: "Maya <maya@example.test>")
        let cc = Node(kAXTextFieldRole, description: "Cc", value: "lee@example.test")
        let bcc = Node(kAXComboBoxRole, description: "Bcc", value: "sam@example.test")
        let subject = Node(kAXTextFieldRole, description: "Add a subject", value: "Re: Thursday")
        let search = Node(kAXTextFieldRole, description: "Search", value: "private search")
        let chip = Node(kAXButtonRole, description: "chip@example.test", value: "private chip")
        let recipient = Node(kAXStaticTextRole, value: "Maya <maya@example.test>")
        let container = Node(kAXGroupRole, subrole: "AXApplicationDialog", [to, cc, bcc, subject, search, chip, recipient, body])
        let outside = Node(kAXTextFieldRole, description: "To", value: "outside@example.test")
        let page = Node("AXWebArea", [outside, container])
        var fields: [Node] = []
        var threadReads = 0
        let result = ComposePage.read(body: body, rules: .outlook, fieldText: { node, _ in
            fields.append(node)
            return node.pageValue()
        }, threadID: { _, _ in threadReads += 1; return "fabricated" })
        withExtendedLifetime(page) {}
        #expect(result.recipients == ["maya@example.test"])
        #expect(to.labelReads == 0 && to.valueReads == 0)
        #expect(cc.valueReads == 0)
        #expect(bcc.labelReads == 0 && bcc.valueReads == 0)
        #expect(result.subject == "Re: Thursday")
        #expect(result.subjectShown)
        #expect(fields.count == 1)
        #expect(search.valueReads == 0)
        #expect(chip.labelReads == 0 && chip.valueReads == 0)
        #expect(recipient.valueReads == 1)
        #expect(outside.labelReads == 0 && outside.valueReads == 0)
        #expect(body.valueReads == 0)
        #expect(threadReads == 0 && result.threadID == nil && result.thread.isEmpty)
    }

    @Test func outlookRecipientsExposedOnlyByControlsStayUnknown() {
        let body = Node(kAXTextAreaRole, description: "Message body")
        let subject = Node(kAXTextFieldRole, description: "Subject", value: "Thursday")
        let to = Node(kAXComboBoxRole, description: "To", value: "maya@example.test")
        let chip = Node(kAXPopUpButtonRole, description: "Maya <maya@example.test>",
                        [Node(kAXStaticTextRole, value: "maya@example.test")])
        let cc = Node(kAXTextFieldRole, description: "Cc", value: "lee@example.test")
        let container = Node(kAXGroupRole, subrole: "AXApplicationDialog", [subject, to, chip, cc, body])
        let page = Node("AXWebArea", [container])
        let result = ComposePage.read(body: body, rules: .outlook, fieldText: { field, _ in
            #expect(field === subject)
            return field.pageValue()
        }, threadID: { _, _ in nil })
        withExtendedLifetime(page) {}
        #expect(result.recipients.isEmpty)
        #expect(to.labelReads == 0 && to.valueReads == 0)
        #expect(chip.labelReads == 0 && chip.valueReads == 0)
        #expect(cc.labelReads == 0 && cc.valueReads == 0)
    }

    @Test func outlookDoesNotTreatAnArbitraryAncestorListAsAGmailThread() {
        let body = Node(kAXTextAreaRole, description: "Message body")
        let container = Node(kAXGroupRole, subrole: "AXLandmarkRegion", [body])
        let unrelated = Node(kAXStaticTextRole, value: "Unrelated inbox message")
        let list = Node(kAXListRole, [unrelated, container])
        let page = Node("AXWebArea", [list])
        let result = ComposePage.read(body: body, rules: .outlook, fieldText: { _, _ in Issue.record("unexpected field"); return nil },
                                      threadID: { _, _ in Issue.record("unexpected thread id"); return nil })
        withExtendedLifetime(page) {}
        #expect(!result.inThread && result.thread.isEmpty && result.threadID == nil)
        #expect(unrelated.valueReads == 0)
    }

    @Test func outlookUnknownContainersReturnNoInventedContext() {
        let body = Node(kAXTextAreaRole, description: "Message body")
        let field = Node(kAXTextFieldRole, description: "Subject", value: "unread")
        let page = Node("AXWebArea", [Node(kAXGroupRole, [field, body])])
        #expect(ComposePage.read(body: body, rules: .outlook, fieldText: { _, _ in Issue.record("unscoped field"); return nil },
                                threadID: { _, _ in nil }) == PageSurroundings())
        withExtendedLifetime(page) {}
        #expect(field.valueReads == 0)
    }
    @Test func outlookFailedHeaderValuesAndNestedContainersSupplyNoContext() {
        let body = Node(kAXTextAreaRole, description: "Message body")
        let to = Node(kAXTextFieldRole, description: "To", value: "hidden@example.test")
        let subject = Node(kAXTextFieldRole, description: "Subject", value: "unread subject")
        let nestedField = Node(kAXTextFieldRole, description: "To", value: "other@example.test")
        let nested = Node(kAXGroupRole, subrole: "AXApplicationDialog", [nestedField])
        let container = Node(kAXGroupRole, subrole: "AXLandmarkRegion", [to, subject, nested, body])
        let page = Node("AXWebArea", [container])
        var asked: [Node] = []
        let result = ComposePage.read(body: body, rules: .outlook, fieldText: { node, _ in
            // The secure boundary refused or the value did not answer.
            asked.append(node)
            return nil
        }, threadID: { _, _ in nil })
        withExtendedLifetime(page) {}
        #expect(asked.count == 1)
        #expect(result == PageSurroundings())
        #expect(nestedField.labelReads == 0 && nestedField.valueReads == 0)
        #expect(to.valueReads == 0 && subject.valueReads == 0)
    }


}
