import Testing
@testable import Onboarding

struct RenderArgumentsTests {
    @Test func ordinaryStartupAllowsRenderWordsInPathsAndValues() {
        #expect(!RenderArguments.requiresRenderWorker([
            "/tmp/intention-snapshots/Intention.app/Contents/MacOS/Intention",
            "--caret-permissions", "/tmp/caret-snapshot.json", "--demo",
        ], renderGuard: nil))
        #expect(!RenderArguments.requiresRenderWorker(["--home-snapshot"], renderGuard: nil))
        #expect(!RenderArguments.requiresRenderWorker(["Intention", "--home-snapshot-copy"], renderGuard: "0"))
    }

    @Test func exactRenderModesAndExplicitFlagRequireAWorker() {
        for mode in ["--home-snapshot", "--onboarding-snapshots", "--onboarding-demo", "--placement-frames"] {
            #expect(RenderArguments.requiresRenderWorker(["Intention", mode], renderGuard: nil))
        }
        #expect(RenderArguments.requiresRenderWorker(["Intention"], renderGuard: "1"))
    }
}
