import Foundation

/// What an email is written from: the body of the field the person spoke
/// into, read from the app's Accessibility tree before any rule is applied
/// to it, and what the window shows around it once it is an email body
/// (`ComposeAccess.surroundings`). The person's words are the cue. Nothing
/// here is logged.
struct EmailBody: Equatable, Sendable {
    /// The app that owns the field, by bundle identifier; nil when unknown.
    var bundleIdentifier: String?
    /// The whole body, as the field holds it: text the person already typed
    /// and the quoted thread under a reply alike. Which part is which is not
    /// knowable from the field.
    var body: String
    /// The addresses the window shows the email going to, in Gmail only
    /// those it shows, usually the first one. Empty when none can be read.
    var recipients: [WritingRecipient] = []
    /// The subject as the window shows it, empty when it shows none.
    var subject = ""
    /// The messages of the thread being answered that the window shows,
    /// most recent first, a blank line between them. Gmail shows a
    /// collapsed thread's messages but the last as a line or two; the
    /// server reads the whole thread from the person's mail.
    var thread = ""
    /// Gmail's id for the thread being answered, read from the page's
    /// address for an inline reply in the thread view.
    var threadID: String?
    /// What the window says the email is, a reply or a new message, when it
    /// says: Gmail's thread view or Subject field, Mail's Subject field. Nil
    /// when it does not, and the body then decides.
    var kind: WritingInput.Mode?
    /// The compose sits in the thread's list in Gmail's thread view, an
    /// inline reply, which is where the page shows the thread.
    var inThread = false
}

/// Why an observation and the person's words cannot become a writing input.
enum ComposeInputProblem: Error, Equatable, Sendable {
    case cueBlank
    /// More was said than the input carries. The words are typed instead.
    case cueTooLong
    /// The encoded input would be larger than the route accepts.
    case tooLarge
}

/// The bounds the email writing input's schema puts on each string, in
/// Unicode scalars, from the writing input contract. The body,
/// the thread and the subject may be long and are cut to their bound from
/// the start; the person's own words are refused instead, so nothing they
/// said is quietly dropped.
enum WritingInputBounds {
    static let cue = 12_000
    static let observedThread = 16_000
    static let subject = 1_000
    static let address = 320
    static let recipients = 32
    static let threadID = 256
}

/// Builds the version 1 email writing input from an observation and the
/// person's words, applying the schema's bounds. No account, source or
/// model identity is here; the server adds its own.
enum ComposeInput {
    /// A fresh request. `requestID` is new for every attempt, as the draft
    /// route asks. A dictated email has revision 1 and no regeneration; a
    /// spoken change to a reply proposal regenerates from the proposal as
    /// its parent, at revision 2; and a proposal itself carries the fixed
    /// cue with `proposal` set, so the server's prompt says no instruction
    /// was given.
    static func make(_ observation: EmailBody, cue: String, requestID: UUID, revision: Int = 1,
                     regeneration: WritingRegeneration? = nil, proposal: Bool = false, addSentWithIntention: Bool = false) throws -> WritingInput {
        // Control characters other than tab and line endings carry nothing
        // a writer can use, and the route refuses an input that holds one
        // anywhere. The body, subject and thread come from the window and
        // the cue from the dictation endpoint, so all of them lose them on
        // the way.
        let cue = withoutControls(cue)
        guard !cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ComposeInputProblem.cueBlank }
        guard cue.unicodeScalars.count <= WritingInputBounds.cue else { throw ComposeInputProblem.cueTooLong }
        let compose = WritingCompose(recipients: recipients(observation.recipients),
                                     subject: bounded(withoutControls(observation.subject), to: WritingInputBounds.subject),
                                     observedThread: observedThread(observation), observedOrigin: .unknown, threadSources: [],
                                     threadID: threadID(observation.threadID), proposal: proposal, addSentWithIntention: addSentWithIntention)
        let input = WritingInput(version: .v1, requestID: requestID, revision: revision, channel: .email,
                                 mode: mode(of: observation), cue: cue, confirmedFacts: [], compose: compose, regeneration: regeneration)
        guard (try? input.encoded()) != nil else { throw ComposeInputProblem.tooLarge }
        return input
    }

    /// The part of a body the route is sent, first in the observed thread:
    /// without the control characters it refuses, cut to the observed
    /// thread's bound. The body is checked again by this same cut right
    /// before an email written from it goes in (`ComposeCapture.emailField`).
    static func sentThread(_ body: String) -> String {
        bounded(withoutControls(body), to: WritingInputBounds.observedThread)
    }

    /// What the route is sent as the observed thread: the body, then the
    /// thread's messages the window shows, most recent first, a blank line
    /// between them, cut together to the bound. In Mail a reply's body
    /// already quotes the thread; in Gmail it is empty until the person
    /// shows the quoted text, and the thread is what the page shows.
    static func observedThread(_ observation: EmailBody) -> String {
        let parts = [sentThread(observation.body), withoutControls(observation.thread)]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return bounded(parts.joined(separator: "\n\n"), to: WritingInputBounds.observedThread)
    }

    /// The recipients the route accepts, in their order: an address of at
    /// most 320 scalars with one at sign, no space and no angle bracket,
    /// once each, at most 32.
    static func recipients(_ shown: [WritingRecipient]) -> [WritingRecipient] {
        var accepted: [WritingRecipient] = []
        for recipient in shown where accepted.count < WritingInputBounds.recipients {
            let address = recipient.address
            let parts = address.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }), address.unicodeScalars.count <= WritingInputBounds.address,
                  !address.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0 == "<" || $0 == ">" }),
                  withoutControls(address) == address,
                  !accepted.contains(where: { $0.address.caseInsensitiveCompare(address) == .orderedSame }) else { continue }
            accepted.append(recipient)
        }
        return accepted
    }

    /// A thread id the route accepts: printable ASCII with no space, at
    /// most 256 characters; anything else is no id.
    static func threadID(_ id: String?) -> String? {
        guard let id, !id.isEmpty, id.count <= WritingInputBounds.threadID,
              id.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else { return nil }
        return id
    }

    /// A forward, whose subject starts with `Fwd:` or its like, is a new
    /// message about the thread, even in Gmail's thread view. Otherwise what
    /// the window says it is, when it says, so a new message whose body holds
    /// a signature stays new. Otherwise a reply when the body already holds
    /// text, which in a compose is the quoted thread or what the person
    /// started, the window shows a thread or its id, or the subject answers
    /// one with `Re:` or its like; else a new message.
    static func mode(of observation: EmailBody) -> WritingInput.Mode {
        if observation.subject.contains(forwardPrefix) { return .new }
        if let kind = observation.kind { return kind }
        let shown = [observation.body, observation.thread].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return shown || threadID(observation.threadID) != nil || observation.subject.contains(replyPrefix) ? .reply : .new
    }

    /// What a subject a window shows says the email is: a reply when it
    /// starts with `Re:` or its like, else a new message.
    static func kind(subject: String) -> WritingInput.Mode {
        subject.contains(replyPrefix) ? .reply : .new
    }

    /// `Re:` and the words other languages' mail uses for it at the start
    /// of a subject, and the same for a forward, as the server's labels
    /// read them.
    nonisolated(unsafe) static let replyPrefix = #/^\s*(?i:re|aw|sv|antw)(?:\[\d+\])?\s*:/#
    nonisolated(unsafe) static let forwardPrefix = #/^\s*(?i:fwd?|fw|tr|wg|rv|enc|doorst)(?:\[\d+\])?\s*:/#

    /// `text` without the characters in Unicode's control category (Cc),
    /// apart from tab, line feed and carriage return, which the route
    /// accepts. Everything else, including formatting characters, stays.
    static func withoutControls(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isRefusedControl) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { !isRefusedControl($0) }))
    }

    private static func isRefusedControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control && !["\n", "\r", "\t"].contains(scalar)
    }

    /// The first `limit` scalars of `text`, whole, with nothing added.
    static func bounded(_ text: String, to limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
    }
}
