import Foundation
import Testing

@_silgen_name("IntentionSilentTestGuardRequire")
private func requireStartupGuard()

@Test func testProcessStartsSilent() {
    requireStartupGuard()
    #expect(ProcessInfo.processInfo.environment["INTENTION_SILENT"] == "1")
}
