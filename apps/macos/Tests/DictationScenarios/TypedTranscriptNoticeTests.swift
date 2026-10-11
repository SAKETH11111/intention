@testable import Dictation
import Testing

struct TypedTranscriptNoticeTests {
    @Test(arguments: DraftReason.allCases)
    func eachReceiptReasonHasAnHonestNotice(_ reason: DraftReason) {
        let expected: String
        switch reason {
        case .intentionUnresolved:
            expected = "Didn't catch what the email should say, so I typed your words"
        case .costLimit:
            expected = "Intention couldn't clear this email's cost, so I typed your words"
        case .timeout, .transportUnknown, .invalidResponse, .contextPreparing,
             .qualificationUnavailable, .eligibilityChanged, .configurationRetired:
            expected = "Couldn't finish writing the email, so I typed your words"
        case .inputTooLarge:
            expected = "Too much text to write from, so I typed your words"
        case .mailPolicyUnconfigured, .productionDisabled:
            expected = "Email writing is off right now, so I typed your words"
        case .invalidInput, .bindingMismatch, .ineligibleExample, .cancelled, .excluded,
             .contextInvalidated, .superseded, .parentAccepted, .parentUnavailable,
             .expired, .nothingToAnswer, .proposalLimit, .mailImportPending, .unrecognized:
            expected = "Couldn't write it, so I typed what you said"
        }
        #expect(DictationController.Notice.typedTranscript(reason).text == expected)
        #expect(expected.count < 70)
    }

    @Test func failuresWithoutAReceiptSayWhatIsKnown() {
        #expect(DictationController.Notice.typedTranscript(for: .timedOut) == .typedTranscript(.timeout))
        #expect(DictationController.Notice.typedTranscript(for: .unavailable(.disabled)) == .typedTranscript(.productionDisabled))
        #expect(DictationController.Notice.typedTranscript(for: .unavailable(.notConfigured)) == .typedTranscript(.productionDisabled))
        #expect(DictationController.Notice.typedTranscript(for: .unavailable(.mailPolicyUnconfigured)) == .typedTranscript(.mailPolicyUnconfigured))
        #expect(DictationController.Notice.typedTranscript(for: .request(.unreachable)) == .typedTranscript(nil))
        #expect(DictationController.Notice.typedTranscript(for: .withdrawn) == .typedTranscript(nil))
        #expect(DictationController.Notice.typedTranscript(nil).text == "Couldn't write it, so I typed what you said")
    }
}
