import CoreGraphics
@testable import Intention
import Testing

struct NativeCaretContinuityTests {
    private let start = ContinuousClock.now
    private func reading(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 100, width: 0, height: 20) }

    @Test func aPlacedPositionStaysUntilANewerReadReplacesIt() {
        var evidence = NativeCaretContinuity<CGRect>()
        evidence.record(.placed, reading: reading(10), focus: 1, at: start)
        #expect(evidence.shown(at: start + .milliseconds(100)) == reading(10))
        evidence.record(.placed, reading: reading(20), focus: 1, at: start + .milliseconds(120))
        #expect(evidence.shown(at: start + .milliseconds(130)) == reading(20))
    }

    @Test func unresolvedReadsKeepTheLastPositionOnTheSameFieldBriefly() {
        var evidence = NativeCaretContinuity<CGRect>()
        evidence.record(.placed, reading: reading(10), focus: 1, at: start)
        evidence.record(.unresolved, reading: nil, focus: 1, at: start + .milliseconds(200))
        #expect(evidence.shown(at: start + .milliseconds(250)) == reading(10))
        evidence.record(.unresolved, reading: nil, focus: 1, at: start + .milliseconds(600))
        #expect(evidence.shown(at: start + .milliseconds(600)) == nil)
    }

    @Test func anotherFieldNeverInheritsAPosition() {
        var evidence = NativeCaretContinuity<CGRect>()
        evidence.record(.placed, reading: reading(10), focus: 1, at: start)
        evidence.record(.unresolved, reading: nil, focus: 2, at: start + .milliseconds(10))
        #expect(evidence.shown(at: start + .milliseconds(20)) == nil)
    }

    @Test func aReadWithNoCaretClearsImmediately() {
        var evidence = NativeCaretContinuity<CGRect>()
        evidence.record(.placed, reading: reading(10), focus: 1, at: start)
        evidence.confirmVisual(reading(12), at: start + .milliseconds(5))
        evidence.record(.absent, reading: nil, focus: 1, at: start + .milliseconds(10))
        #expect(evidence.shown(at: start + .milliseconds(20)) == nil)
        evidence.record(.unresolved, reading: nil, focus: 1, at: start + .milliseconds(30))
        #expect(evidence.shown(at: start + .milliseconds(40)) == nil)
    }

    @Test func visualConfirmationAnswersOnlyWhileAccessibilityIsUnresolved() {
        var evidence = NativeCaretContinuity<CGRect>()
        evidence.record(.unresolved, reading: nil, focus: 1, at: start)
        evidence.confirmVisual(reading(30), at: start + .milliseconds(5))
        #expect(evidence.shown(at: start + .milliseconds(10)) == reading(30))
        evidence.record(.placed, reading: reading(40), focus: 1, at: start + .milliseconds(20))
        #expect(evidence.shown(at: start + .milliseconds(30)) == reading(40))
    }

    @Test func anEstimateShowsUntilPixelsConfirmTheCaret() {
        var evidence = NativeCaretContinuity<CGRect>()
        evidence.record(.unresolved, reading: nil, hint: reading(20), focus: 1, at: start)
        #expect(evidence.shown(at: start + .milliseconds(10)) == reading(20))
        evidence.confirmVisual(reading(22), at: start + .milliseconds(90))
        #expect(evidence.shown(at: start + .milliseconds(95)) == reading(22))
        evidence.record(.absent, reading: nil, hint: reading(20), focus: 1, at: start + .milliseconds(100))
        #expect(evidence.shown(at: start + .milliseconds(110)) == nil)
    }

    @Test func visualConfirmationAgesOutInsteadOfFlickering() {
        var evidence = NativeCaretContinuity<CGRect>()
        evidence.record(.unresolved, reading: nil, focus: 1, at: start)
        evidence.confirmVisual(reading(30), at: start)
        evidence.confirmVisual(nil, at: start + .milliseconds(100))
        evidence.record(.unresolved, reading: nil, focus: 1, at: start + .milliseconds(300))
        #expect(evidence.shown(at: start + .milliseconds(400)) == reading(30))
        #expect(evidence.shown(at: start + .milliseconds(600)) == nil)
    }

    @Test func silenceExpiresEvenAPlacedPosition() {
        var evidence = NativeCaretContinuity<CGRect>()
        evidence.record(.placed, reading: reading(10), focus: 1, at: start)
        #expect(evidence.shown(at: start + .milliseconds(700)) == reading(10))
        #expect(evidence.shown(at: start + .milliseconds(800)) == nil)
    }

    @Test func aBoundaryKeepsThePositionOnlyUntilTheNextRead() {
        var evidence = NativeCaretContinuity<CGRect>()
        evidence.record(.placed, reading: reading(10), focus: 1, at: start)
        evidence.boundary(at: start + .milliseconds(10))
        #expect(evidence.shown(at: start + .milliseconds(50)) == reading(10))
        #expect(evidence.shown(at: start + .milliseconds(120)) == nil)
        evidence.record(.placed, reading: reading(30), focus: 2, at: start + .milliseconds(60))
        #expect(evidence.shown(at: start + .milliseconds(200)) == reading(30))
        evidence.boundary(at: start + .milliseconds(210))
        evidence.record(.absent, reading: nil, focus: 3, at: start + .milliseconds(215))
        #expect(evidence.shown(at: start + .milliseconds(220)) == nil)
    }

    @Test func visualConfirmationSurvivesABoundaryThatKeepsTheField() {
        var evidence = NativeCaretContinuity<CGRect>()
        evidence.record(.unresolved, reading: nil, focus: 1, at: start)
        evidence.confirmVisual(reading(30), at: start)
        evidence.boundary(at: start + .milliseconds(50))
        evidence.record(.unresolved, reading: nil, focus: 1, at: start + .milliseconds(60))
        #expect(evidence.shown(at: start + .milliseconds(70)) == reading(30))
        evidence.boundary(at: start + .milliseconds(80))
        evidence.record(.unresolved, reading: nil, focus: 2, at: start + .milliseconds(90))
        #expect(evidence.shown(at: start + .milliseconds(100)) == nil)
    }

    @Test func boundaryBarrierRejectsAlreadyQueuedObservations() {
        var evidence = NativeCaretContinuity<CGRect>()
        let queued = evidence.generation
        #expect(evidence.accepts(queued))
        evidence.boundary(at: start)
        #expect(!evidence.accepts(queued))
        evidence.clear()
        #expect(evidence.shown(at: start) == nil)
    }

    /// The caret dot hidden, or the screen locked: the dot shows nothing, and no
    /// read, one already on its way or one that arrives anyway, brings it back.
    @Test func whilePausedNothingIsShownAndNothingIsTakenIn() {
        var evidence = NativeCaretContinuity<CGRect>()
        evidence.record(.placed, reading: reading(10), focus: 1, at: start)
        let queued = evidence.generation
        evidence.pause()
        #expect(evidence.paused)
        #expect(evidence.shown(at: start + .milliseconds(10)) == nil)
        #expect(!evidence.accepts(queued))
        #expect(!evidence.accepts(evidence.generation))
        evidence.record(.placed, reading: reading(20), focus: 1, at: start + .milliseconds(20))
        evidence.confirmVisual(reading(22), at: start + .milliseconds(25))
        evidence.record(.unresolved, reading: nil, hint: reading(24), focus: 1, at: start + .milliseconds(30))
        #expect(evidence.shown(at: start + .milliseconds(35)) == nil)
        #expect(evidence.source(at: start + .milliseconds(35)) == "none")
        // A boundary while paused changes nothing either.
        evidence.boundary(at: start + .milliseconds(40))
        #expect(evidence.shown(at: start + .milliseconds(45)) == nil)
    }

    @Test func resumedEvidenceWaitsForAFreshRead() {
        var evidence = NativeCaretContinuity<CGRect>()
        evidence.record(.placed, reading: reading(10), focus: 1, at: start)
        let beforePause = evidence.generation
        evidence.pause()
        let whilePaused = evidence.generation
        evidence.resume()
        #expect(!evidence.paused)
        // Nothing from before the pause returns, and reads begun during it are refused.
        #expect(evidence.shown(at: start + .milliseconds(10)) == nil)
        #expect(!evidence.accepts(beforePause))
        #expect(!evidence.accepts(whilePaused))
        #expect(evidence.accepts(evidence.generation))
        evidence.record(.placed, reading: reading(30), focus: 1, at: start + .milliseconds(20))
        #expect(evidence.shown(at: start + .milliseconds(30)) == reading(30))
        // Resuming twice is resuming once.
        let current = evidence.generation
        evidence.resume()
        #expect(evidence.accepts(current))
    }
}
