import AppKit
@testable import Dictation
import Testing

@MainActor
struct ReleaseHoldTests {
    @Test func escapeThenSpaceAndAMissedReleaseCannotBlockTheNextHold() async throws {
        let hold = HoldKey(key: .function, holdDelay: 0, watchInterval: 0.01, unseenReleaseWait: 0.03)
        let fn = NSEvent.ModifierFlags.function
        var keyboard = fn.rawValue
        hold.keyboardFlags = { [keyboard] }
        hold.keyboardShowsKeyDown = { _ in false }
        var starts = 0
        hold.onPress = { starts += 1; hold.recording = true }
        hold.onEscape = { hold.recording = false }
        hold.modifiersChanged(.init(keyCode: 63, flags: fn.rawValue, keyboard: fn.rawValue, fromKeyboard: true, generation: 1))
        #expect(starts == 1)
        var claims = KeyClaims()
        claims.trigger = .function
        claims.takesSpace = hold.takesSpace
        claims.escapeCancels = hold.takesEscape
        claims.modifiersChanged(keyCode: 63, flags: fn)
        let escape = try #require(claims.key(KeyClaims.escape, down: true, flags: fn).claim)
        let space = claims.key(KeyClaims.space, down: true, flags: fn)
        #expect(!space.take)
        #expect(space.claim == nil)
        DispatchQueue.global().sync {
            hold.tapClaimed(escape, generation: 1)
            hold.tapInput(.init(kind: .keyDown, keyCode: KeyClaims.space, flags: fn.rawValue))
            hold.tapInput(.init(kind: .keyUp, keyCode: KeyClaims.space, flags: fn.rawValue))
        }
        keyboard = 0 // The Fn-up event is lost; only hardware shows the release.
        let deadline = ContinuousClock.now + .seconds(2)
        while hold.watch != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!hold.recording)
        #expect(hold.watch == nil)
        keyboard = fn.rawValue
        hold.modifiersChanged(.init(keyCode: 63, flags: fn.rawValue, keyboard: fn.rawValue, fromKeyboard: true, generation: 2))
        #expect(starts == 2)
        #expect(hold.recording)
        hold.modifiersChanged(.init(keyCode: 63, flags: 0, keyboard: 0, fromKeyboard: true, generation: 2))
    }

    @Test func newHandsFreeGesturesAreDisabledWhileHoldsStillRecord() throws {
        let hold = HoldKey(key: .function)
        hold.now = { 1 }
        hold.keyboardFlags = { [] }
        var starts = 0, ends = 0, handsFree = 0
        hold.onPress = { starts += 1; hold.recording = true }
        hold.onRelease = { ends += 1; hold.recording = false }
        hold.onHandsFree = { handsFree += 1 }
        #expect(!hold.handsFreeEnabled)
        #expect(!hold.takesSpace)
        for time in [1.0, 1.15] {
            hold.modifiersChanged(.init(keyCode: 63, flags: NSEvent.ModifierFlags.function.rawValue, time: time))
            hold.modifiersChanged(.init(keyCode: 63, flags: 0, time: time + 0.05))
        }
        #expect(starts == 0)
        #expect(handsFree == 0)
        hold.modifiersChanged(keyCode: 63, flags: [.function])
        hold.claimed(.handsFree)
        #expect(handsFree == 0)
        try #require(hold.gestureTimer).fire()
        #expect(starts == 1)
        hold.modifiersChanged(keyCode: 63, flags: [])
        #expect(ends == 1)
        #expect(!HoldKey.instructions(for: .function).contains("Double-tap"))
    }
}

@MainActor
extension DictationScenarioTests {
    @Test(arguments: [(false, false, false), (false, false, true), (false, true, false), (false, true, true),
                      (true, false, false), (true, false, true), (true, true, false), (true, true, true)])
    func switchingIndicatorsKeepsTheCurrentRecoveryWarning(hasCaret: Bool, isEmailBody: Bool, footPaints: Bool) async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let source = ScriptedSource()
        let dictation = controller(server.endpoint, source: source)
        let foot = FootMark(desktop: .init(screens: { [] }, pointer: { .zero }, showsWindow: false))
        let panel = DotNotice(showsWindow: false)
        var style = IndicatorStyle.foot
        var caption: String?
        DictationIndicators.connect(dictation, foot: foot, phase: { _ in }, notice: { _ in },
            silence: { _ in }, nothing: { _ in }, recordingIssue: { words in
                DictationIndicators.sayRecordingIssue(words,
                    throughFoot: DictationIndicators.wordsThroughFoot(style: style, isEmailBody: isEmailBody, footHasRoom: footPaints),
                    caretAnchor: hasCaret ? CGRect(x: 100, y: 100, width: 10, height: 10) : nil,
                    caption: { caption = $0 }, panel: { notice in
                        if let notice { panel.show(notice, beside: nil, for: nil) } else { panel.hide() }
                    })
            })
        dictation.toggle()
        source.interrupt()
        #expect(caption == nil)
        #expect(!panel.isShown)
        style = .dot
        DictationIndicators.select(style, dictation: dictation, foot: foot, isEmailBody: isEmailBody)
        let atFoot = !isEmailBody && footPaints
        #expect(foot.saysWords == !isEmailBody)
        #expect(caption == (!atFoot && hasCaret ? "Reconnecting microphone…" : nil))
        #expect(panel.isShown == (!atFoot && !hasCaret))
        style = .foot
        DictationIndicators.select(style, dictation: dictation, foot: foot, isEmailBody: isEmailBody)
        #expect(foot.saysWords)
        #expect(foot.recordingIssue == "Reconnecting microphone…")
        #expect(caption == nil)
        #expect(!panel.isShown)
        dictation.cancel()
        await idle(dictation)
    }

    @Test func disabledSpaceCannotFinishAReplacementRecording() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let source = ScriptedSource()
        let dictation = controller(server.endpoint, source: source)
        let hold = HoldKey(key: .function)
        hold.onHandsFree = { dictation.holdBecameHandsFree() }
        dictation.phaseChanged = { hold.recording = $0 == .recording }
        dictation.toggle()
        DispatchQueue.global().sync { hold.tapClaimed(.handsFree, generation: 1) }
        dictation.cancel()
        dictation.toggle()
        try await Task.sleep(for: .milliseconds(40))
        #expect(dictation.phase == .recording)
        #expect(source.running)
        dictation.cancel()
        await idle(dictation)
    }

    @Test func initialRecoverySurvivesClearingAnEarlierNotice() async throws {
        let server = try await ScriptedEndpoint([.answer(transcript: "hello", text: "Hello.")])
        defer { server.stop() }
        let hardware = StandInHardware(MadeUpInputs.inputs([MadeUpInputs.builtIn], default: MadeUpInputs.builtIn))
        let source = Microphone(preference: { .builtIn }, hardware: hardware)
        let dictation = controller(server.endpoint, source: source)
        let foot = FootMark(desktop: .init(screens: { [] }, pointer: { .zero }, showsWindow: false))
        var caption: String?
        let mark = CGRect(x: 100, y: 100, width: 10, height: 10)
        DictationIndicators.connect(dictation, foot: foot, phase: { _ in }, notice: { notice in
            DictationIndicators.sayOnDot(notice?.text, caretAnchor: mark,
                caption: { caption = $0 }, panel: { _, _ in })
        }, silence: { _ in }, nothing: { _ in }, recordingIssue: { words in
            DictationIndicators.sayRecordingIssue(words, throughFoot: false, caretAnchor: mark,
                caption: { caption = $0 }, panel: { _ in })
        })
        dictation.recordingLimit = .milliseconds(15)
        dictation.toggle()
        let deadline = ContinuousClock.now + .seconds(5)
        while dictation.notice != .recordingLimit, ContinuousClock.now < deadline { await Task.yield() }
        #expect(dictation.notice == .recordingLimit)
        dictation.recordingLimit = .seconds(60)
        hardware.now.lidClosed = true
        dictation.toggle()
        #expect(dictation.phase == .recording)
        #expect(dictation.problem == .microphoneUnavailable)
        #expect(dictation.recordingIssue == "Reconnecting microphone…")
        #expect(foot.recordingIssue == "Reconnecting microphone…")
        #expect(caption == "Reconnecting microphone…")
        dictation.cancel()
        await idle(dictation)
    }
}

@MainActor
struct PersistentRecoveryNoticeTests {
    @Test func recoveryTransferredFromCaretKeepsItsPersistentLifetime() async throws {
        let panel = DotNotice(showsWindow: false)
        let words = "Reconnecting microphone…"
        var caption: String?
        DictationIndicators.sayRecordingIssue(words, throughFoot: false,
            caretAnchor: CGRect(x: 100, y: 100, width: 10, height: 10),
            caption: { caption = $0 }, panel: { _ in })
        #expect(caption == words)
        DictationIndicators.sayOnDot(words, caretAnchor: nil, recordingIssue: words,
            caption: { caption = $0 }, panel: { notice, duration in
                #expect(duration == nil)
                if let notice { panel.show(notice, beside: nil, for: duration) } else { panel.hide() }
            })
        #expect(panel.isShown)
        try await Task.sleep(for: .milliseconds(4100))
        #expect(panel.isShown)
        panel.hide()
    }
}
