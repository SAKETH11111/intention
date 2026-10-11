import AppKit
@testable import Compose
import Testing

/// The email writing input as voice compose builds it: the recipients and
/// subject the window shows, the body and then the thread's messages the
/// window shows as the observed thread, the thread's id when the page gives
/// one, and the person's words as the cue, within the schema's bounds.
@Suite struct ComposeInputTests {
    private let body = "Hi,\n\nCould you make Thursday at 10?\n\nJane"

    @Test func aBodyAloneCarriesNoRecipientsSubjectOrThread() throws {
        let id = UUID()
        let input = try ComposeInput.make(EmailBody(bundleIdentifier: "com.apple.mail", body: body),
                                          cue: "Say yes and ask for the agenda.", requestID: id)
        #expect(input.requestID == id)
        #expect(input.revision == 1)
        #expect(input.version == .v1)
        #expect(input.channel == .email)
        #expect(input.mode == .reply)
        #expect(input.cue == "Say yes and ask for the agenda.")
        #expect(input.confirmedFacts.isEmpty)
        #expect(input.regeneration == nil)
        #expect(input.compose.recipients.isEmpty)
        #expect(input.compose.subject == "")
        #expect(input.compose.observedThread == body)
        #expect(input.compose.observedOrigin == .unknown)
        #expect(input.compose.threadSources.isEmpty)
        #expect(input.compose.threadID == nil)
    }

    @Test func sentWithIntentionDecodingRequiresAStrictBoolean() throws {
        let input = try ComposeInput.make(EmailBody(bundleIdentifier: nil, body: body), cue: "Say yes", requestID: UUID())
        let original = try #require(JSONSerialization.jsonObject(with: input.encoded()) as? [String: Any])
        for value in [true, false, "true", 1, NSNull()] as [Any] {
            var object = original
            var compose = try #require(object["compose"] as? [String: Any])
            compose["add_sent_with_intention"] = value
            object["compose"] = compose
            let data = try JSONSerialization.data(withJSONObject: object)
            if let boolean = value as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() {
                #expect(try JSONDecoder().decode(WritingInput.self, from: data).compose.addSentWithIntention == boolean.boolValue)
            } else {
                #expect(throws: (any Error).self) { try JSONDecoder().decode(WritingInput.self, from: data) }
            }
        }
    }

    /// A Gmail inline reply as the page reader gives it: an empty body, the
    /// first recipient, the reply's subject, the thread's messages most
    /// recent first and the thread's id.
    private let gmailReply = EmailBody(
        bundleIdentifier: "com.google.Chrome", body: "",
        recipients: [WritingRecipient(address: "priya@northwind.example", role: .to)],
        subject: "Re: Venue options for the October offsite",
        thread: "Priya Raman priya@northwind.example\nOct 4, 10:02 AM\nSam, can you confirm the headcount by Thursday?\n\nTomás Ortega\nOct 3, 4:51 PM\nI called Harbor Hall.",
        threadID: "18f2a3b4c5d6e7f8")

    @Test func aGmailReplyCarriesItsRecipientSubjectThreadAndThreadID() throws {
        let input = try ComposeInput.make(gmailReply, cue: "Confirm twelve people.", requestID: UUID())
        #expect(input.mode == .reply)
        #expect(input.compose.recipients == [WritingRecipient(address: "priya@northwind.example", role: .to)])
        #expect(input.compose.subject == "Re: Venue options for the October offsite")
        #expect(input.compose.observedThread == gmailReply.thread)
        #expect(input.compose.threadID == "18f2a3b4c5d6e7f8")
        #expect(input.compose.threadSources.isEmpty)
        let object = try #require(try JSONSerialization.jsonObject(with: input.encoded()) as? [String: Any])
        let compose = try #require(object["compose"] as? [String: Any])
        #expect(compose["thread_id"] as? String == "18f2a3b4c5d6e7f8")
        #expect((compose["recipients"] as? [[String: String]]) == [["address": "priya@northwind.example", "role": "to"]])
    }

    @Test func theBodyComesFirstThenTheThreadAndBothAreCutTogether() throws {
        var observation = gmailReply
        observation.body = "Hi Priya,"
        #expect(ComposeInput.observedThread(observation) == "Hi Priya,\n\n" + gmailReply.thread)
        observation.body = String(repeating: "b", count: WritingInputBounds.observedThread - 3)
        let cut = ComposeInput.observedThread(observation)
        #expect(cut.unicodeScalars.count == WritingInputBounds.observedThread)
        #expect(cut.hasSuffix("bbb\n\nP"))
        // The guard on the field compares the body's own part, whatever
        // follows it.
        #expect(ComposeInput.sentThread(observation.body) == observation.body)
    }

    @Test func aThreadOrItsIDOrAReplySubjectMakesAReply() {
        #expect(ComposeInput.mode(of: EmailBody(bundleIdentifier: nil, body: "", thread: "Tomás Ortega\nI called.")) == .reply)
        #expect(ComposeInput.mode(of: EmailBody(bundleIdentifier: nil, body: "", threadID: "18f2a3b4c5d6e7f8")) == .reply)
        for subject in ["Re: Offsite", "RE:Offsite", "  re : offsite", "AW: Offsite", "Re[2]: Offsite", "SV: Offsite"] {
            #expect(ComposeInput.mode(of: EmailBody(bundleIdentifier: nil, body: "", subject: subject)) == .reply)
        }
        for subject in ["Offsite", "Regarding the offsite", "Fwd: Offsite", ""] {
            #expect(ComposeInput.mode(of: EmailBody(bundleIdentifier: nil, body: "", subject: subject)) == .new)
        }
        // A forward in Gmail's thread view knows its thread and is still a new
        // message about it; a reply to a forward is a reply.
        for subject in ["Fwd: Offsite", "FW: Offsite", "WG: Offsite", "Fwd: Re: Offsite"] {
            #expect(ComposeInput.mode(of: EmailBody(bundleIdentifier: nil, body: "", subject: subject, thread: "Tomás Ortega",
                                                    threadID: "18f2a3b4c5d6e7f8")) == .new)
        }
        #expect(ComposeInput.mode(of: EmailBody(bundleIdentifier: nil, body: "", subject: "Re: Fwd: Offsite")) == .reply)
    }

    @Test func whatTheWindowSaysItIsComesBeforeTheBody() {
        // A New Message window whose body holds a signature stays a new message.
        #expect(ComposeInput.mode(of: EmailBody(bundleIdentifier: nil, body: "Sam Lee\nNorthwind", subject: "Venue options",
                                                kind: .new)) == .new)
        // A reply the window names stays one with an empty body.
        #expect(ComposeInput.mode(of: EmailBody(bundleIdentifier: nil, body: "", kind: .reply)) == .reply)
        // A forward is new whatever the window says.
        #expect(ComposeInput.mode(of: EmailBody(bundleIdentifier: nil, body: "", subject: "Fwd: Venue", kind: .reply)) == .new)
        #expect(ComposeInput.kind(subject: "Re: Venue") == .reply)
        #expect(ComposeInput.kind(subject: "") == .new)
        // An id the route would refuse is no id.
        #expect(ComposeInput.mode(of: EmailBody(bundleIdentifier: nil, body: "", threadID: "has space")) == .new)
    }

    @Test func onlyAddressesTheRouteAcceptsAreSentOnceEachUpToThirtyTwo() throws {
        let shown = [
            WritingRecipient(address: "priya@northwind.example", role: .to),
            WritingRecipient(address: "PRIYA@northwind.example", role: .cc),
            WritingRecipient(address: "Priya Raman", role: .to),
            WritingRecipient(address: "a b@example.com", role: .to),
            WritingRecipient(address: "<x@example.com>", role: .to),
            WritingRecipient(address: "two@at@example.com", role: .to),
            WritingRecipient(address: String(repeating: "l", count: 310) + "@example.com", role: .to),
            WritingRecipient(address: "tomas@contoso.example", role: .cc),
        ] + (0..<40).map { WritingRecipient(address: "person\($0)@example.com", role: .bcc) }
        let sent = ComposeInput.recipients(shown)
        #expect(sent.count == WritingInputBounds.recipients)
        #expect(Array(sent.prefix(2)) == [WritingRecipient(address: "priya@northwind.example", role: .to),
                                          WritingRecipient(address: "tomas@contoso.example", role: .cc)])
        #expect(sent.last == WritingRecipient(address: "person29@example.com", role: .bcc))
    }

    @Test func aThreadIDTheRouteWouldRefuseIsLeftOut() {
        #expect(ComposeInput.threadID("18f2a3b4c5d6e7f8") == "18f2a3b4c5d6e7f8")
        #expect(ComposeInput.threadID(String(repeating: "a", count: 256)) != nil)
        for refused in ["", "has space", "tab\t", "é", String(repeating: "a", count: 257)] {
            #expect(ComposeInput.threadID(refused) == nil)
        }
    }

    @Test func theSubjectIsCutToItsBoundAndLosesControls() throws {
        let subject = "Re:\u{0007} " + String(repeating: "s", count: WritingInputBounds.subject + 10)
        let input = try ComposeInput.make(EmailBody(bundleIdentifier: nil, body: "", subject: subject), cue: "Yes", requestID: UUID())
        #expect(input.compose.subject.unicodeScalars.count == WritingInputBounds.subject)
        #expect(input.compose.subject.hasPrefix("Re: sss"))
    }

    @Test func theEncodedInputIsTheRoutesShape() throws {
        let input = try ComposeInput.make(EmailBody(bundleIdentifier: nil, body: ""), cue: "Hello", requestID: UUID())
        let object = try #require(try JSONSerialization.jsonObject(with: input.encoded()) as? [String: Any])
        // `regeneration` and `compose.thread_id` are the fields the schema
        // lets a request leave out, and this compose has neither.
        #expect(Set(object.keys) == ["version", "request_id", "revision", "channel", "mode", "cue", "confirmed_facts", "compose"])
        #expect(object["revision"] as? Int == 1)
        #expect(object["mode"] as? String == "new")
        let compose = try #require(object["compose"] as? [String: Any])
        #expect((compose["recipients"] as? [Any])?.isEmpty == true)
        #expect(compose["subject"] as? String == "")
        #expect(compose["observed_thread"] as? String == "")
        #expect(compose["observed_origin"] as? String == "unknown")
        #expect((compose["thread_sources"] as? [Any])?.isEmpty == true)
        #expect(compose["thread_id"] == nil)
    }

    @Test func aBodyMakesAReplyAndAnEmptyOneANewMessage() {
        #expect(ComposeInput.mode(of: EmailBody(bundleIdentifier: nil, body: body)) == .reply)
        #expect(ComposeInput.mode(of: EmailBody(bundleIdentifier: nil, body: "")) == .new)
        // Line breaks alone, as an empty rich editor holds, are no thread.
        #expect(ComposeInput.mode(of: EmailBody(bundleIdentifier: nil, body: "\n\n")) == .new)
    }

    @Test func theBodyIsCutToItsBoundByScalar() throws {
        // Two-unit scalars, so a cut by UTF-16 units would split one.
        let long = String(repeating: "😀", count: WritingInputBounds.observedThread + 5)
        let input = try ComposeInput.make(EmailBody(bundleIdentifier: nil, body: long), cue: "Hello", requestID: UUID())
        #expect(input.compose.observedThread.unicodeScalars.count == WritingInputBounds.observedThread)
        #expect(input.compose.observedThread.allSatisfy { $0 == "😀" })
    }

    @Test func thePersonsOwnWordsAreRefusedRatherThanCut() {
        let observation = EmailBody(bundleIdentifier: nil, body: body)
        #expect(throws: ComposeInputProblem.cueTooLong) {
            try ComposeInput.make(observation, cue: String(repeating: "a", count: WritingInputBounds.cue + 1), requestID: UUID())
        }
        #expect(throws: ComposeInputProblem.cueBlank) {
            try ComposeInput.make(observation, cue: " \n", requestID: UUID())
        }
        // Exactly the bound is carried whole.
        let whole = try? ComposeInput.make(observation, cue: String(repeating: "a", count: WritingInputBounds.cue), requestID: UUID())
        #expect(whole?.cue.unicodeScalars.count == WritingInputBounds.cue)
    }

    @Test func controlCharactersTheRouteRefusesLeaveTheBodyAndTheWords() throws {
        let input = try ComposeInput.make(EmailBody(bundleIdentifier: nil, body: "Hi\u{0001} Jane\tand\r\nall\u{000B}"),
                                          cue: "Say\u{0000} yes\u{2028}", requestID: UUID())
        // Tab and line endings stay; a line separator is formatting, not a control.
        #expect(input.compose.observedThread == "Hi Jane\tand\r\nall")
        #expect(input.cue == "Say yes\u{2028}")
    }

    @Test func anInputOverTheByteCapIsRefused() {
        // Within every scalar bound, over the route's byte cap once encoded.
        let body = String(repeating: "😀", count: WritingInputBounds.observedThread)
        let cue = String(repeating: "a", count: WritingInputBounds.cue)
        #expect(throws: ComposeInputProblem.tooLarge) {
            try ComposeInput.make(EmailBody(bundleIdentifier: nil, body: body), cue: cue, requestID: UUID())
        }
    }
}
