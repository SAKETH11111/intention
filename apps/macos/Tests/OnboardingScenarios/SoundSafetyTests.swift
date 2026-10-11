import Testing
import Foundation
@testable import Onboarding

@MainActor
struct SoundSafetyTests {
    @Test func setupSoundsAndOutputStaySilent() {
        #expect(ProcessSafety.isSilent)
        var emitted = false
        #expect(!SoundOutput.perform { emitted = true })
        #expect(!emitted)
        #expect(!SetupSound.accepted.play())
        #expect(!SetupSound.landed.play())
        #expect(!ProcessSafety.allowsCheckInput)
        #expect(!KeyEvents.post(.paste(9), to: ProcessInfo.processInfo.processIdentifier))
    }
}
