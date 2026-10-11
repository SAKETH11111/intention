import ApplicationServices
import Foundation

/// An element's role and subrole, read in one message to the app, which is
/// all the walk around an email's body learns of most elements.
struct PageRole: Sendable {
    var role: String
    var subrole: String?
}

/// An element's description and title, read in one message. The compose
/// walk asks for its own region or dialog and text fields to find the
/// Subject header.
/// Thread reads also ask for headings, sender groups and empty static text.
/// Other controls' labels are never read.
struct PageLabels: Sendable {
    var description: String?
    var title: String?
}

/// The reads a walk of a web compose's page makes. `AXElement` answers them
/// from Chromium's and WebKit's trees; tests answer them from a made-up
/// page. Each is one message to the app, and none reads a field's value: a
/// field's value is read only through the caller's own secure check
/// (`ComposePage.read`'s `fieldText`).
protocol PageNode {
    /// Nil when the message fails or the element has no role.
    func pageRole() -> PageRole?
    func pageLabels() -> PageLabels?
    /// Nil when the message fails; an element with none has none.
    func pageChildren() -> [Self]?
    /// A static text's value, nil when it has none.
    func pageValue() -> String?
    func pageParent() -> Self?
    func isNode(_ other: Self) -> Bool
}

/// What a web compose's page shows around the body of an email being
/// written, read from its Accessibility tree as Gmail on the web gave it on
/// October 6, 2026, in Chromium and in WebKit alike: the body sits in a
/// region (`AXLandmarkRegion`), the inline reply's labelled with its
/// subject and the New Message window's with its title, inside an
/// application dialog for a window of its own; an inline reply's region
/// sits in the last message of the thread, a group in the thread's list.
/// Recipients show as text: an inline reply's as the first one's name and
/// address, "Name (address)", and a count of the rest; a New Message's as
/// names. Nothing here is logged.
struct PageSurroundings: Equatable, Sendable {
    /// Addresses shown around the body, in their order, at most
    /// `ComposePage.recipientLimit`.
    var recipients: [String] = []
    var subject = ""
    /// Whether `subject` is a visible Subject field's value, as in a New
    /// Message window, rather than a reply region's label.
    var subjectShown = false
    /// The thread's messages the page shows, most recent first, a blank
    /// line between them, each its text with a line for each block.
    var thread = ""
    /// Whether the body is an inline reply in the thread the page shows.
    var inThread = false
    /// The id of that thread, from the page, only for an inline reply.
    var threadID: String?
}

/// A Gmail thread view as the thread watch read it when the thread opened,
/// before any reply is open in it, for a reply proposal asked for then
/// (`ReplyProposalController.threadOpened`): its process and launch, the
/// thread's id from the page's address, and what `ComposePage.threadView`
/// read. Nothing here is logged.
struct GmailThreadView: Equatable, Sendable {
    var pid: pid_t
    var started: UInt64?
    var threadID: String
    var subject: String
    var thread: String
    var newestSender: String?
    var account: String?
}

/// What a thread view's page shows, read before any reply is open in it.
struct PageThread: Equatable, Sendable {
    /// The thread's subject, as the heading above its messages shows it.
    var subject = ""
    /// The thread's messages the page shows, most recent first, as an inline
    /// reply's read gives them once the reply opens (`PageSurroundings.thread`).
    var thread = ""
    /// The single address in the newest message's sender heading:
    /// who a reply goes to, unless the person sent it.
    var newestSender: String?
    /// The account the page's title names (`ComposePage.account(inTitle:)`),
    /// nil when it names none.
    var account: String?
}

enum ComposePage {
    /// Rules for the bounded walk around an admitted web body. Outlook's
    /// container and header mappings admit only qualified field shapes.
    /// No Outlook message-list or URL thread-id mapping is
    /// assumed; quoted text already inside the body still reaches the writer.
    struct Rules: Sendable {
        enum Thread: Sendable { case messageList, bodyOnly }
        var containerSubroles: Set<String>
        var subjectLabels: Set<String>
        var thread: Thread

        static let gmail = Rules(containerSubroles: ["AXLandmarkRegion", "AXApplicationDialog"],
                                 subjectLabels: ["Subject"], thread: .messageList)
        static let outlook = Rules(containerSubroles: ["AXLandmarkRegion", "AXApplicationDialog"],
                                   subjectLabels: ["Subject", "Add a subject"],
                                   thread: .bodyOnly)
    }

    /// How far the walk goes, in messages to the app and in time; a walk
    /// that reaches either stops and keeps what it read, the most recent
    /// messages first. The budget is checked before every read, and each
    /// read can wait up to `AccessibilityExecutor.messagingTimeout`.
    static let elementLimit = 3_000
    static let budget: Duration = .milliseconds(800)
    /// The thread is read until this many scalars, the bound the writing
    /// input puts on observed text.
    static let threadLimit = WritingInputBounds.observedThread
    /// How much text around the body is read for its addresses, in scalars.
    static let shownLimit = 8_000
    static let recipientLimit = 32
    static let ancestorLimit = 40
    /// Roles whose text and labels are never read: controls, fields and
    /// pages. A button's label, a field's value and a frame's page are not
    /// the thread's text.
    static let unread: Set<String> = [
        kAXButtonRole, kAXMenuButtonRole, kAXPopUpButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXTextFieldRole,
        kAXTextAreaRole, kAXComboBoxRole, kAXImageRole, kAXSliderRole, kAXIncrementorRole, kAXToolbarRole, kAXMenuRole,
        kAXMenuBarRole, kAXMenuItemRole, kAXTabGroupRole, "AXWebArea", "AXSearchField",
    ]
    /// Roles whose text runs on in the text around it; every other role's
    /// starts a line.
    static let inline: Set<String> = [kAXStaticTextRole, "AXLink"]

    /// What the page shows around `body`, the focused body of an email
    /// being written. Only when the body sits in a region, or in a dialog,
    /// below its page: anything else answers nothing. `fieldText` reads a
    /// Subject field's value after the caller's secure check. Every other
    /// field's value stays unread. `threadID` reads the
    /// thread's id from the page, the web area above the body, and is asked
    /// only for an inline reply. Each is asked only while the walk has reads
    /// and time left, counts as one read, and is given the walk's deadline,
    /// to check before each Accessibility call it makes.
    static func read<Node: PageNode>(body: Node, rules: Rules = .gmail, fieldText: (Node, ContinuousClock.Instant) -> String?,
                                     threadID: (Node, ContinuousClock.Instant) -> String?,
                                     budget: Duration = budget, elementLimit: Int = elementLimit) -> PageSurroundings {
        var walk = Walk(deadline: ContinuousClock.now + budget, limit: elementLimit)
        // The body's ancestors up to its page, each read once for its role.
        // A read that does not answer ends the walk, so nothing past a
        // silent element is taken for the body's surroundings.
        var ancestors: [(node: Node, role: PageRole)] = []
        var current = body
        var page: Node?
        for _ in 0..<ancestorLimit {
            guard walk.spend(), let parent = current.pageParent(), walk.spend(), let role = parent.pageRole() else { break }
            if role.role == "AXWebArea" {
                page = parent
                break
            }
            ancestors.append((parent, role))
            current = parent
        }
        guard let page, let place = ancestors.firstIndex(where: { rules.containerSubroles.contains($0.role.subrole ?? "") }) else { return PageSurroundings() }
        let container = ancestors[place]
        // The thread's list, when the container sits in one before any
        // dialog: an inline reply. A window of its own is not in the thread
        // view, even when the page behind it shows one.
        var list: Int?
        for index in (place + 1)..<ancestors.count where rules.thread == .messageList {
            if ancestors[index].role.subrole == "AXApplicationDialog" { break }
            if ancestors[index].role.role == kAXListRole {
                list = index
                break
            }
        }
        var result = PageSurroundings(inThread: list != nil)
        var subjectField: Node?
        var shown: [String] = []
        var room = shownLimit
        if walk.spend(), let children = container.node.pageChildren() {
            for child in children where !child.isNode(body) {
                collect(child, skip: body, rules: rules, walk: &walk, texts: &shown, room: &room,
                        subjectField: &subjectField)
            }
        }
        result.recipients = addresses(in: shown)
        if let subjectField, walk.spend(), let text = fieldText(subjectField, walk.deadline) {
            result.subject = text
            result.subjectShown = true
        } else if list != nil, walk.spend(), let labels = container.node.pageLabels() {
            result.subject = labels.description ?? labels.title ?? ""
        }
        if let list {
            if walk.spend() { result.threadID = threadID(page, walk.deadline) }
            if walk.spend(), let items = ancestors[list].node.pageChildren() {
                result.thread = thread(items, current: ancestors[list - 1].node, skip: container.node, walk: &walk)
            }
        }
        return result
    }

    /// What a Gmail thread view shows when it opens, read from its page,
    /// the web area itself, before any reply is open in it, within the same
    /// limits as `read`: the account the page's title names, then, breadth
    /// first by role from the page, the main landmark, and in it the first
    /// heading, the thread's subject, and the first list, the thread's
    /// messages, read as `read` reads them for an inline reply, with any
    /// region in them left out, as a reply that opened meanwhile is. Nothing
    /// of a control, field, dialog or other page is read past its role, and
    /// headings supply only the subject and the newest sender. Nil when the page
    /// shows no such list or no message in it, as while a thread loads.
    static func threadView<Node: PageNode>(page: Node, budget: Duration = budget, elementLimit: Int = elementLimit) -> PageThread? {
        var walk = Walk(deadline: ContinuousClock.now + budget, limit: elementLimit)
        var result = PageThread()
        if walk.spend(), let labels = page.pageLabels() {
            result.account = account(inTitle: labels.title) ?? account(inTitle: labels.description)
        }
        guard let main = first(below: [page], walk: &walk, where: { $0.subrole == "AXLandmarkMain" }),
              walk.spend(), let top = main.pageChildren() else { return nil }
        var heading: Node?
        var list: Node?
        var level = top
        // Breadth first through the main landmark, not into the list once
        // found: a message's own headings are inside it.
        while !level.isEmpty, list == nil || heading == nil {
            var next: [Node] = []
            for node in level {
                guard walk.spend(), let role = node.pageRole() else { continue }
                if role.role == kAXListRole, list == nil {
                    list = node
                    continue
                }
                if role.role == "AXHeading", heading == nil {
                    heading = node
                    continue
                }
                guard !unread.contains(role.role), role.subrole != "AXApplicationDialog", walk.spend(),
                      let children = node.pageChildren() else { continue }
                next += children
            }
            level = next
        }
        guard let list, walk.spend(), let items = list.pageChildren() else { return nil }
        if let heading {
            if walk.spend(), let labels = heading.pageLabels(), let title = labels.title ?? labels.description, !title.isEmpty {
                result.subject = title
            } else {
                var room = WritingInputBounds.subject
                result.subject = lines(text(of: heading, skip: nil, walk: &walk, room: &room).text)
            }
        }
        let messages = messages(items, current: nil, skip: nil, skipRegions: true, walk: &walk)
        guard !messages.isEmpty else { return nil }
        result.thread = joined(messages)
        // Gmail exposes the sender in the newest item's heading. Body
        // addresses cannot establish who wrote the message.
        if let newest = items.last { result.newestSender = sender(in: newest, walk: &walk) }
        return result
    }

    /// Gmail repeats its sender heading's title or text as an enclosing
    /// group's title inside the message item. Only that match identifies
    /// the header; depth and preceding text alone cannot exclude body headings.
    /// Walk in reading order and decide from the first non-empty heading only.
    private static func sender<Node: PageNode>(in newest: Node, walk: inout Walk) -> String? {
        let excluded = unread.union([kAXListRole, "AXApplicationDialog", "AXLandmarkRegion"])
        var pending: [(node: Node, groups: [Node])] = [(newest, [])]
        while let (node, groups) = pending.popLast(), !walk.spent {
            guard walk.spend(), let role = node.pageRole() else { return nil }
            guard !excluded.contains(role.role), !excluded.contains(role.subrole ?? "") else { continue }
            if role.role == "AXHeading" {
                // A failed label read could hide a second address, so it
                // decides nothing.
                guard walk.spend(), let labels = node.pageLabels() else { return nil }
                let values = [labels.title, labels.description].compactMap { $0 }
                // Check a bounded prefix before trimming or parsing a label.
                // Reject oversize labels whole so truncation cannot hide an address.
                guard ContinuousClock.now < walk.deadline,
                      values.allSatisfy({ $0.unicodeScalars.prefix(WritingInputBounds.subject + 1).count <= WritingInputBounds.subject })
                else { return nil }
                let names = values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                // A label with several addresses is ambiguous, even when
                // descendant text supplies only one of them.
                guard addresses(in: names).count <= 1 else { return nil }
                var room = WritingInputBounds.subject
                let heading = text(of: node, skip: nil, excluding: excluded, walk: &walk, room: &room)
                guard heading.complete, !walk.spent, room > 0 else { return nil }
                let value = heading.text
                if names.isEmpty, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                let found = addresses(in: names + [value])
                guard found.count == 1 else { return nil }
                // A description alone is not Gmail's sender label. The
                // matching title or text must itself contain the address.
                let candidates = [labels.title, value].compactMap { $0 }.filter { addresses(in: [$0]).count == 1 }
                for group in groups.reversed() {
                    guard walk.spend(), let labels = group.pageLabels(), ContinuousClock.now < walk.deadline else { return nil }
                    guard let title = labels.title else { continue }
                    guard title.unicodeScalars.prefix(WritingInputBounds.subject + 1).count <= WritingInputBounds.subject else { return nil }
                    if candidates.contains(title) { return found[0] }
                }
                return nil
            }
            if role.role == kAXStaticTextRole {
                guard let value = staticText(node, walk: &walk),
                      value.unicodeScalars.prefix(WritingInputBounds.subject + 1).count <= WritingInputBounds.subject,
                      value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                continue
            }
            guard walk.spend(), let children = node.pageChildren() else { return nil }
            // Do not use the item's own label or a group outside the item.
            let ancestors = role.role == kAXGroupRole && !node.isNode(newest) ? groups + [node] : groups
            pending.append(contentsOf: children.reversed().map { ($0, ancestors) })
        }
        return nil
    }

    /// The first element below `roots`, breadth first, whose role matches,
    /// not entering controls, fields, other pages or a dialog.
    private static func first<Node: PageNode>(below roots: [Node], walk: inout Walk, where matches: (PageRole) -> Bool) -> Node? {
        var level = roots
        while !level.isEmpty {
            var next: [Node] = []
            for node in level {
                guard walk.spend(), let children = node.pageChildren() else { continue }
                for child in children {
                    guard walk.spend(), let role = child.pageRole() else { continue }
                    if matches(role) { return child }
                    if !unread.contains(role.role), role.subrole != "AXApplicationDialog" { next.append(child) }
                }
            }
            level = next
        }
        return nil
    }

    /// The account a Gmail page's title names. Gmail titles a page with
    /// what it shows, the account's address and the product's name, a
    /// spaced hyphen between them ("Venue options - sam@fabrikam.example -
    /// Gmail"), so the last part after the first that is an address is
    /// taken. Nil when no such part is one.
    static func account(inTitle title: String?) -> String? {
        guard let parts = title?.components(separatedBy: " - "), parts.count >= 3 else { return nil }
        return parts.dropFirst().reversed().map { $0.trimmingCharacters(in: .whitespaces) }.first(where: isAddress)
    }

    /// Only the Subject field is passed to the caller's secure
    /// value read. Every other control stops at its role, and the focused
    /// body is never entered. Recipients come only from static text outside
    /// controls; a recipient present only in a control stays unknown.
    private static func collect<Node: PageNode>(_ node: Node, skip body: Node, rules: Rules, walk: inout Walk,
                                                texts: inout [String], room: inout Int, subjectField: inout Node?) {
        guard room > 0, walk.spend(), let role = node.pageRole() else { return }
        if role.role == kAXTextFieldRole {
            guard subjectField == nil, walk.spend(), let labels = node.pageLabels() else { return }
            let names = [labels.description, labels.title].compactMap { $0 }
            if names.contains(where: rules.subjectLabels.contains) { subjectField = node }
            return
        }
        if role.role == kAXStaticTextRole {
            guard let text = staticText(node, walk: &walk) else { return }
            texts.append(kept(text, room: &room))
            return
        }
        guard !unread.contains(role.role),
              !(rules.thread == .bodyOnly && rules.containerSubroles.contains(role.subrole ?? "")),
              walk.spend(), let children = node.pageChildren() else { return }
        for child in children where !child.isNode(body) {
            collect(child, skip: body, rules: rules, walk: &walk, texts: &texts, room: &room,
                    subjectField: &subjectField)
        }
    }

    /// A static text's value, or its title where it gives its text there,
    /// as WebKit does for a recipient's name in Gmail's To field.
    private static func staticText<Node: PageNode>(_ node: Node, walk: inout Walk) -> String? {
        guard walk.spend() else { return nil }
        if let value = node.pageValue(), !value.isEmpty { return value }
        guard walk.spend() else { return nil }
        return node.pageLabels()?.title
    }

    /// `text` cut to `room` scalars, which it then takes from `room`. Text
    /// past the room is dropped as it is read, never kept.
    private static func kept(_ text: String, room: inout Int) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > room else {
            room -= scalars.count
            return text
        }
        let cut = String(String.UnicodeScalarView(scalars.prefix(max(room, 0))))
        room = 0
        return cut
    }

    /// The messages of a thread's list, most recent first: each item's text,
    /// the current item's without the reply's container. Reads stop once
    /// `threadLimit` scalars are read, within a message too, or when the
    /// walk does, and the thread is cut to that limit.
    private static func thread<Node: PageNode>(_ items: [Node], current: Node, skip container: Node, walk: inout Walk) -> String {
        joined(messages(items, current: current, skip: container, walk: &walk))
    }

    /// Each message of a thread's list as `thread` reads it, most recent
    /// first. `skipRegions`, for a thread read before any reply is known,
    /// leaves out every region in the list, as an open reply's is, so the
    /// text reads as the same thread does once a reply opens in it.
    private static func messages<Node: PageNode>(_ items: [Node], current: Node?, skip container: Node?, skipRegions: Bool = false,
                                                 walk: inout Walk) -> [String] {
        var messages: [String] = []
        var room = threadLimit
        for item in items.reversed() {
            guard room > 0, !walk.spent else { break }
            // A reply that is an item of the list itself holds no message.
            if let container, item.isNode(container) { continue }
            let skip = current.map(item.isNode) == true ? container : nil
            let text = lines(text(of: item, skip: skip, skipRegions: skipRegions, walk: &walk, room: &room).text)
            guard !text.isEmpty else { continue }
            messages.append(text)
            room -= 2
        }
        return messages
    }

    /// The messages, a blank line between them, cut to `threadLimit`.
    private static func joined(_ messages: [String]) -> String {
        var whole = threadLimit
        return kept(messages.joined(separator: "\n\n"), room: &whole)
    }

    /// An element's text: a static text's value, or its children's text,
    /// each on its own line unless it runs on from inline text before it,
    /// up to `room` scalars, which it takes from `room`. Controls, fields and
    /// pages give none, and nothing of them is read past their role; with
    /// `skipRegions`, neither does a region. `complete` records whether every
    /// included node answered in full, so a sender cannot use partial text.
    static func text<Node: PageNode>(of node: Node, skip: Node?, skipRegions: Bool = false, excluding: Set<String> = [], walk: inout Walk,
                                     room: inout Int) -> (text: String, inline: Bool, complete: Bool) {
        guard room > 0, walk.spend(), let role = node.pageRole() else { return ("", false, false) }
        if unread.contains(role.role) || excluding.contains(role.role) || excluding.contains(role.subrole ?? "") { return ("", false, true) }
        if skipRegions, role.subrole == "AXLandmarkRegion" { return ("", false, true) }
        if role.role == kAXStaticTextRole {
            guard let value = staticText(node, walk: &walk) else { return ("", true, false) }
            let text = kept(value, room: &room)
            return (text, true, room > 0)
        }
        guard walk.spend(), let children = node.pageChildren() else { return ("", false, false) }
        var text = ""
        var lastInline = false
        var complete = true
        for child in children {
            guard room > 0 else { complete = false; break }
            if let skip, child.isNode(skip) { continue }
            let piece = self.text(of: child, skip: skip, skipRegions: skipRegions, excluding: excluding, walk: &walk, room: &room)
            complete = complete && piece.complete
            guard !piece.text.isEmpty else { continue }
            let runsOn = piece.inline && lastInline && !text.isEmpty
            text += (text.isEmpty || runsOn ? "" : "\n") + piece.text
            lastInline = piece.inline
        }
        return (text, inline.contains(role.role), complete)
    }

    /// `text` with each line trimmed and blank lines dropped.
    static func lines(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Every email address in `texts`, once each, in the order shown, at
    /// most `recipientLimit`. Text is split into words at spaces and the
    /// marks Gmail and Mail put around an address, so an address is taken
    /// whole or not at all: a word with one at sign, something before it
    /// and a dotted domain after it, once punctuation that ends a sentence
    /// is trimmed from its end. A name alone, as a New Message window shows a recipient
    /// it knows, is no address.
    static func addresses(in texts: [String]) -> [String] {
        var found: [String] = []
        for text in texts {
            for word in text.split(whereSeparator: { $0.isWhitespace || separators.contains($0) }) {
                // Only the end: a local part may start with `!` or `?`.
                var candidate = String(word)
                while let last = candidate.last, trailing.contains(last) { candidate.removeLast() }
                guard isAddress(candidate),
                      !found.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) else { continue }
                found.append(candidate)
                if found.count == recipientLimit { return found }
            }
        }
        return found
    }

    /// What separates an address from the text around it: the parentheses
    /// of Gmail's summary, the angle brackets of "Name <address>", quotes
    /// and list punctuation.
    private static let separators: Set<Character> = ["(", ")", "<", ">", "[", "]", "\"", ",", ";"]
    private static let trailing: Set<Character> = [".", ":", "!", "?"]

    /// One at sign with a local part before it and a domain of at least two
    /// nonempty labels after it, at most 320 scalars, with no control
    /// character. Any script is allowed, as the writing input allows it.
    static func isAddress(_ word: String) -> Bool {
        let parts = word.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, word.unicodeScalars.count <= 320,
              !word.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty }
    }

    /// The walk's allowance of reads, by count and by time.
    struct Walk {
        let deadline: ContinuousClock.Instant
        let limit: Int
        var reads = 0
        var spent = false

        mutating func spend() -> Bool {
            guard !spent, reads < limit, ContinuousClock.now < deadline else {
                spent = true
                return false
            }
            reads += 1
            return true
        }
    }
}

/// Gmail's id for a thread, from the address of a page that shows it.
/// Gmail's thread view puts a token for the thread last in the address's
/// fragment (`#inbox/FMfcgz…`, `#label/Work/FMfcgz…`, `#search/…/FMfcgz…`),
/// or the id itself in hexadecimal when a link gave it. The token is
/// `f:` and the thread's id in decimal, encoded in base64 and then written
/// as a number in base 40 with consonants for digits; the id in
/// hexadecimal is the thread id Gmail's API gives, which mail imported from
/// Gmail keeps as its conversation. Measured on October 6, 2026 against
/// the `data-legacy-thread-id` of the thread a real Gmail page showed.
enum GmailThreadID {
    static let consonants = Array("BCDFGHJKLMNPQRSTVWXZbcdfghjklmnpqrstvwxz")
    static let base64 = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    /// The thread id in lowercase hexadecimal, or nil when the address's
    /// fragment does not end in a thread's token or id.
    static func id(from address: URL?) -> String? {
        guard let fragment = address?.fragment else { return nil }
        let path = fragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard let last = path.split(separator: "/").last.map(String.init) else { return nil }
        if last.count >= 12, last.count <= 16, last.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) { return last }
        guard last.count >= 20, last.count <= 64, let decoded = decode(last) else { return nil }
        for prefix in ["f:", "thread-f:"] where decoded.hasPrefix(prefix) {
            let digits = decoded.dropFirst(prefix.count)
            guard !digits.isEmpty, digits.count <= 20, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
                  let number = UInt64(digits), number > 0 else { return nil }
            return String(number, radix: 16)
        }
        return nil
    }

    /// The text a token encodes, or nil when it is not one.
    static func decode(_ token: String) -> String? {
        var digits: [Int] = []
        for character in token {
            guard let digit = consonants.firstIndex(of: character) else { return nil }
            digits.append(digit)
        }
        let converted = convert(digits, from: consonants.count, to: base64.count)
        var encoded = String(converted.map { base64[$0] })
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .ascii)
    }

    /// `digits`, most significant first, from one base to another, by long
    /// division, since a token is longer than any machine integer.
    static func convert(_ digits: [Int], from: Int, to: Int) -> [Int] {
        var number = Array(digits.drop { $0 == 0 })
        var result: [Int] = []
        while !number.isEmpty {
            var remainder = 0
            var quotient: [Int] = []
            for digit in number {
                let value = remainder * from + digit
                remainder = value % to
                if !quotient.isEmpty || value / to != 0 { quotient.append(value / to) }
            }
            result.append(remainder)
            number = quotient
        }
        return result.reversed()
    }
}

extension AXElement: PageNode {
    func pageRole() -> PageRole? {
        guard case let .success(answers) = values([kAXRoleAttribute, kAXSubroleAttribute]),
              let role = text(answers[0]) else { return nil }
        return PageRole(role: role, subrole: text(answers[1]))
    }

    func pageLabels() -> PageLabels? {
        guard case let .success(answers) = values([kAXDescriptionAttribute, kAXTitleAttribute]) else { return nil }
        return PageLabels(description: text(answers[0]), title: text(answers[1]))
    }

    func pageChildren() -> [AXElement]? {
        switch children() {
        case let .success(found): found
        case let .failure(failure) where failure.code == .noValue || failure.code == .attributeUnsupported: []
        case .failure: nil
        }
    }

    func pageValue() -> String? { try? string(kAXValueAttribute).get() }

    func pageParent() -> AXElement? { try? element(kAXParentAttribute).get() }

    func isNode(_ other: AXElement) -> Bool { sameElement(as: other) }

    private func text(_ answer: Result<CFTypeRef, AXFailure>) -> String? {
        guard case let .success(value) = answer, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }
}
