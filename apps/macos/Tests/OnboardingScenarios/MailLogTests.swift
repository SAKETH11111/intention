import AppKit
@testable import Onboarding
import Testing

/// What a mailbox connection's log line says about a failure: a fixed name,
/// never the error's message, an address or a URL.
struct MailLogTests {
    @Test func aFailureIsNamedByItsKindAlone() {
        let name = MailAuthentication.failureName
        #expect(name(AlphaClient.MailFailure.denied) == "denied")
        #expect(name(AlphaClient.MailFailure.invalidConsent) == "invalidConsent")
        #expect(name(AlphaClient.MailFailure.couldNotOpen) == "couldNotOpen")
        #expect(name(AlphaClient.MailFailure.timedOut) == "timedOut")
        #expect(name(AlphaClient.Failure.rejected(400)) == "rejected.400")
        #expect(name(AlphaClient.Failure.tooManyRequests(retryAfter: 30)) == "tooManyRequests")
        #expect(name(URLError(.notConnectedToInternet)) == "unreachable.-1009")
        #expect(name(CancellationError()) == "cancelled")
        let described = NSError(domain: "me@example.com", code: 7,
                                userInfo: [NSLocalizedDescriptionKey: "https://accounts.google.com/?code=secret"])
        #expect(name(described) == "other")
    }
}
