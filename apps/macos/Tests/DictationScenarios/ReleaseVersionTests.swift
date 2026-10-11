@testable import Dictation
import Testing

struct ReleaseVersionTests {
    @Test func showsOnlyTheMarketingVersion() {
        #expect(ReleaseVersion.label(version: "0.0.1") == "Intention 0.0.1")
    }
}
