import Foundation

/// What setup's reply page needs to have a real email written: whether the
/// writer can be asked now, and the ask itself. The page shows one of the
/// person's own threads that waits on their reply, or a made-up message
/// from Maya when none is ready, and an empty reply; the person dictates
/// into it as anywhere else, and the words go to the same writer dictation
/// uses in Gmail and Mail, with that thread as the one being answered. The
/// email that comes back goes into the page's own field, so the inserter
/// and the dot panel keep refusing Intention's windows, and nothing is sent.
///
/// The server writes only for an account with a mailbox, so the page asks
/// only once one is connected; before that it shows the example instead,
/// marked as one.
struct PracticeReply {
    /// Why no email came, as a fixed name safe to log, such as
    /// "abstained.timeout" or "unavailable.disabled".
    struct Failure: Error, Equatable {
        let name: String
    }

    /// Why the writer cannot be asked, for the page to say.
    enum Unavailable: Equatable {
        case writingOff, signedOut, noWriter
    }

    /// Whether the writer can be asked: it has a route, this Mac is signed
    /// in and "Write emails for me" is on. Asked each time, since all three
    /// can change while setup is open.
    var isAvailable: @MainActor () -> Bool
    /// Which of the three is missing when it cannot be asked.
    var unavailable: @MainActor () -> Unavailable? = { nil }
    /// Asks for the email from the words and the person's thread, or Maya's
    /// message when it is nil, and waits for it within the writer's own
    /// limit.
    var write: @MainActor (String, AlphaClient.ReplyThread?, Date) async -> Result<String, Failure>
    /// The timestamp identifies the originating dictation, including late callbacks.
    var inserted: @MainActor (String, Date) -> Void = { _, _ in }

    /// The message the person answers when none of their own is ready. Made
    /// up, and the same for everyone.
    enum Message {
        static let sender = "Maya Chen"
        static let time = "10:12"
        static let text = "Are we still on for lunch Thursday? I can do 12:30 or 1."
        static let subject = "Lunch Thursday?"
        /// Reserved for documentation, so no mail can ever reach it.
        static let address = "maya@example.com"
        /// What the writer is sent as the thread being answered: who wrote,
        /// then what they wrote, as a reply quotes it.
        static let thread = "\(sender) wrote:\n\(text)"
    }

    /// The two ways of speaking the page offers, both of which the writer
    /// takes: an instruction, and the reply itself.
    static let instructionCue = "tell her 1 works"
    static let directCue = "yeah 1 works, see you there"
    /// What the page suggests saying to one of the person's own threads:
    /// the cue that sold a tester on the writer.
    static let ownCue = "answer how I would"
    /// What the page shows when the writer cannot be asked: the reply the
    /// example's words would become. Marked as an example on the page.
    static let exampleEmail = "Hey Maya, 1 works for me. See you Thursday!"
    /// What the page says when the words were typed because no email came.
    /// The same words the dot's caption and the foot mark say after a real
    /// dictation (`DictationController.Notice.typedTranscript`), checked
    /// equal by the dictation tests.
    static let typedNotice = "Couldn't write it, so I typed what you said"

    /// The reply page's lead once the words were typed because no email
    /// came: why, then what to do. Mail still being read, as for a new
    /// account, is said in one sentence of its own.
    static func typedLead(for name: String?, key: String) -> String {
        if name == "abstained.mail_import_pending" {
            // The dot's slip has no full stop; a lead is a sentence.
            return "Still reading your email, try again in a few minutes."
        }
        if name == "abstained.context_preparing" {
            return "Your mail is still being read, so Intention typed your words instead. Try again in a few minutes, or continue."
        }
        let reason = name.map(reason(for:)) ?? "Intention couldn't write it this time."
        return "\(reason) Intention typed your words instead. Hold \(key) to try again, or continue."
    }

    /// Why no email came, from the writer's fixed failure name, said as
    /// exactly as the name allows, under the typed notice.
    static func reason(for name: String) -> String {
        switch name {
        // A reason this build doesn't know says nothing about mail, so it
        // falls to the default below.
        case "abstained.mail_import_pending": return "Still reading your email, try again in a few minutes"
        case "abstained.context_preparing": return "Your mail is still being read. Try again in a few minutes."
        case "timedOut", "abstained.timeout": return "The writer took too long."
        case "request.unreachable", "unavailable.unreachable", "abstained.transport_unknown": return "Intention couldn't reach its server."
        case "signedOut", "request.unauthorized", "request.signedOut": return "The server didn't accept this Mac's sign-in."
        default:
            if name.hasPrefix("unavailable.") || name == "abstained.production_disabled" || name == "request.disabled" {
                return "Email writing isn't on for your account yet."
            }
            return "The writer sent nothing back."
        }
    }
}
