import AppKit
@testable import Dictation
import os
import Testing

extension DictationScenarioTests {
    @Test func caretVisibilityCoversEveryPhaseAndFootState() {
        for email in [false, true] {
            for phase in [DictationController.Phase.idle, .recording, .processing, .writingEmail] {
                for proposal in [ProposalPresentation.idle, .pending, .shown] {
                    for red in [false, true] {
                        for paints in [false, true] {
                            for caption in [false, true] {
                                for wordsAtFoot in [false, true] {
                                    let result = DictationIndicators.caretPresentation(isEmailBody: email, phase: phase,
                                        proposal: proposal, footCarriesRed: red, footPaints: paints, captionDue: caption,
                                        wordsAtFoot: wordsAtFoot)
                                    let expected: Bool
                                    switch phase {
                                    case .idle: expected = email
                                    case .recording: expected = email || !red
                                    case .processing, .writingEmail: expected = email || !paints
                                    }
                                    #expect(result.dot == expected)
                                    #expect(result.caption == (caption && !wordsAtFoot))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func hiddenDotKeepsCaptionsNoticesAndPopupAtTheCaret() {
        let dot = DotPlacement.dot(aboveCaret: CGRect(x: 250, y: 300, width: 1, height: 18))
        let anchor = DotPlacement.anchor(for: dot)
        let result = DictationIndicators.caretPresentation(isEmailBody: false, phase: .idle,
            proposal: .idle, footCarriesRed: true, footPaints: false, captionDue: true)
        #expect(!result.dot && result.caption)
        var caption: String?
        var fallback: FootState?
        DictationIndicators.sayOnDot("Copied text was replaced", caretAnchor: anchor,
            caption: { caption = $0 }, panel: { state, _ in fallback = state })
        #expect(caption == "Copied text was replaced")
        #expect(fallback == nil)
        if case let .dot(frame) = DictationIndicators.popupAnchor(caretAnchor: anchor) {
            #expect(frame == anchor)
        } else { Issue.record("Popup lost a known caret") }
        if case .screenFoot = DictationIndicators.popupAnchor(caretAnchor: nil) {} else {
            Issue.record("Unknown caret must use the foot")
        }
        DictationIndicators.sayOnDot("No caret", caretAnchor: nil,
            caption: { caption = $0 }, panel: { state, _ in fallback = state })
        #expect(caption == nil)
        #expect(fallback == .notice("No caret"))
    }

    @Test func wordsUseExactlyOneSurfaceForEveryFocusFootAndIndicator() {
        let anchor = CGRect(x: 250, y: 300, width: 12, height: 12)
        let examples: [(String, Bool, Bool)] = [
            ("Pasted it, which replaced what you'd copied", false, false),
            ("Couldn't write it, so I typed what you said", false, false),
            ("Intention heard no words", true, false),
            ("Reconnecting microphone…", false, true),
            ("Hold fn to write this email", true, false)]
        for style in [IndicatorStyle.dot, .foot] {
            for email in [false, true] {
                for paints in [false, true] {
                    for hasCaret in [false, true] {
                        for (words, timed, issue) in examples {
                            let foot = FootPlacementTests.foot()
                            foot.enabled = paints
                            var route = NoticeWordRoute()
                            let atFoot = route.choose(words, style: style, isEmailBody: email,
                                                      footHasRoom: foot.canShowWords(words))
                            #expect(atFoot == (style == .foot || (!email && paints)))
                            foot.saysWords = atFoot
                            let state: FootState = issue ? .listening : timed ? .resting : .notice(words)
                            var timedWords: String?
                            if issue { foot.recordingIssue = words }
                            let displayedAtFoot = DictationIndicators.follow(state, words: words, atFoot: atFoot, timed: timed,
                                allowCaretFallback: style == .dot, foot: foot, timedWords: &timedWords)
                            #expect(displayedAtFoot == atFoot)
                            var caption: String? = "old caption"
                            var panel: FootState? = .notice("old panel")
                            DictationIndicators.sayOnDot(words, caretAnchor: hasCaret ? anchor : nil,
                                recordingIssue: issue ? words : nil, throughFoot: atFoot,
                                caption: { caption = $0 }, panel: { value, _ in panel = value })
                            #expect(foot.showsNotice == (atFoot && !issue))
                            #expect(caption == (!atFoot && hasCaret ? words : nil))
                            #expect(panel == (!atFoot && !hasCaret ? .notice(words) : nil))
                            let footHasWords = foot.mark.slip?.text == words && foot.painting
                            #expect((atFoot ? 1 : 0) + (caption == nil ? 0 : 1) + (panel == nil ? 0 : 1) == 1)
                            if paints {
                                #expect(footHasWords == atFoot)
                                #expect((footHasWords ? 1 : 0) + (caption == nil ? 0 : 1) + (panel == nil ? 0 : 1) == 1)
                            }
                            if issue {
                                foot.recordingIssue = nil
                                DictationIndicators.sayRecordingIssue(nil, throughFoot: atFoot,
                                    caretAnchor: hasCaret ? anchor : nil,
                                    caption: { caption = $0 }, panel: { panel = $0 })
                                #expect(caption == nil && panel == nil)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func aNoticeKeepsItsSurfaceUntilTheFootLosesRoom() {
        for startsInEmail in [false, true] {
            let foot = FootPlacementTests.foot()
            let words = "Couldn't write it, so I typed what you said"
            var route = NoticeWordRoute()
            var timedWords: String?
            for email in [startsInEmail, !startsInEmail, startsInEmail] {
                let atFoot = route.choose(words, style: .dot, isEmailBody: email, footHasRoom: true)
                #expect(atFoot == !startsInEmail)
                foot.saysWords = atFoot
                DictationIndicators.follow(.notice(words), words: words, atFoot: atFoot, timed: false,
                                           foot: foot, timedWords: &timedWords)
                #expect(foot.showsNotice == !startsInEmail)
            }
            let transferred = route.choose(words, style: .dot, isEmailBody: false, footHasRoom: false)
            #expect(!transferred)
            foot.saysWords = transferred
            DictationIndicators.follow(.notice(words), words: words, atFoot: transferred, timed: false,
                                       foot: foot, timedWords: &timedWords)
            #expect(!foot.showsNotice)
            // A mutating call cannot run inside #expect.
            let repeated = route.choose(words, style: .dot, isEmailBody: false, footHasRoom: true)
            #expect(!repeated)
            _ = route.choose(nil, style: .dot, isEmailBody: false, footHasRoom: true)
            let afresh = route.choose(words, style: .dot, isEmailBody: false, footHasRoom: true)
            #expect(afresh)
        }
    }

    @Test func aGeometryRefreshWithNoWordsKeepsThePracticeEmailWarm() {
        let foot = FootPlacementTests.foot()
        foot.follow(.writing)
        var timedWords: String?
        DictationIndicators.follow(nil, words: nil, atFoot: false, timed: false,
                                   foot: foot, timedWords: &timedWords)
        #expect(foot.state == .writing)
        #expect(!foot.showsNotice)
        // An actual dictation phase change still takes ownership.
        DictationIndicators.follow(.listening, words: nil, atFoot: false, timed: false,
                                   foot: foot, timedWords: &timedWords)
        #expect(foot.state == .listening)
    }

    @Test func aTimedFootNoticeStartsOnlyOnceAndACaretNoticeClearsIt() {
        let foot = FootPlacementTests.foot()
        var timedWords: String?
        let words = "Intention heard no words"
        DictationIndicators.follow(.resting, words: words, atFoot: true, timed: true,
                                   foot: foot, timedWords: &timedWords)
        let task = foot.noticeEnds
        DictationIndicators.follow(.writing, words: words, atFoot: true, timed: true,
                                   foot: foot, timedWords: &timedWords)
        #expect(foot.noticeEnds == task)
        #expect(foot.state == .notice(words))
        foot.saysWords = false
        DictationIndicators.follow(.notice(words), words: words, atFoot: false, timed: false,
                                   foot: foot, timedWords: &timedWords)
        #expect(!foot.showsNotice)
        #expect(timedWords == nil)
    }

    @Test func aPaintingFootWithACollidingSlipUsesTheCaretWithoutHoldingANotice() {
        let words = "Pasted it, which replaced what you'd copied"
        for slot in FootSlot.allCases {
            let choices = FootDragTests.Choices()
            choices.everywhere = slot
            let foot = FootDragTests.foot(choices)
            foot.saysWords = true
            foot.show(.notice(words))
            let slip = foot.slipFrame!.offsetBy(dx: foot.panel.frame.minX, dy: foot.panel.frame.minY)
            // A small field touches only the far shadow, clear of the sun.
            let field: CGRect
            switch slot {
            case .bottom, .left: field = CGRect(x: slip.maxX + 8, y: slip.midY - 10, width: 12, height: 20)
            case .right: field = CGRect(x: slip.minX - 20, y: slip.midY - 10, width: 12, height: 20)
            }
            foot.state = .resting
            foot.focusedField = field
            #expect(foot.painting)
            #expect(!foot.canShowWords(words))
            var route = NoticeWordRoute()
            let atFoot = route.choose(words, style: .dot, isEmailBody: false, footHasRoom: foot.canShowWords(words))
            foot.saysWords = atFoot
            var timedWords: String?
            DictationIndicators.follow(.notice(words), words: words, atFoot: atFoot, timed: false,
                                       foot: foot, timedWords: &timedWords)
            #expect(!foot.showsNotice)
            #expect(foot.slipFrame == nil)
            var caption: String?
            DictationIndicators.sayOnDot(words, caretAnchor: CGRect(x: 500, y: 500, width: 12, height: 12),
                throughFoot: atFoot, caption: { caption = $0 }, panel: { _, _ in })
            #expect(caption == words)
        }
    }

    @Test func aNoticeRechecksTheSlipAfterChoosingAnotherDisplay() {
        let desk = FootPlacementTests.Desk()
        let foot = FootPlacementTests.foot(desk)
        let words = "Pasted it, which replaced what you'd copied"
        // This field touches only the notice's shadow on the other display.
        foot.focusedField = CGRect(x: 2568, y: 16, width: 12, height: 20)
        #expect(foot.canShowWords(words))
        desk.pointer = CGPoint(x: 2400, y: 500)
        var timedWords: String?
        let atFoot = DictationIndicators.follow(.notice(words), words: words, atFoot: true, timed: false,
                                               foot: foot, timedWords: &timedWords)
        #expect(foot.painting)
        #expect(!atFoot)
        #expect(!foot.showsNotice)
        #expect(foot.slipFrame == nil)
    }

    /// A change of the focused field moves where the foot may say words,
    /// and the callback comes once, on the main actor, after the placement.
    /// Driven through this foot alone: posting the system's display
    /// notification would reach every foot in the tests running beside it
    /// and end their drags.
    @Test func wordSpaceCallbackRunsOnMainAfterThePlacementChanges() async {
        let foot = FootPlacementTests.foot()
        var callbacks = 0
        foot.wordSpaceChanged = {
            MainActor.assertIsolated()
            #expect(Thread.isMainThread)
            callbacks += 1
        }
        await until { callbacks > 0 }
        callbacks = 0
        foot.focusedField = CGRect(x: 100, y: 600, width: 400, height: 40)
        await until { callbacks > 0 }
        #expect(callbacks == 1)
        #expect(foot.painting)
    }

    private func classify(_ classifier: CaretEmailBody, focus: CaretEmailBody.Focus,
                          on executor: AccessibilityExecutor) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            executor.submit { @Sendable _ in
                let element = try? AXElement.application(focus.pid).element(kAXFocusedUIElementAttribute).get()
                classifier.observe(focus, element: element)
                done.resume()
            }
        }
    }

    @Test(arguments: [false, true])
    func emailClassificationCachesTheFlatGmailBodyWithoutReadingText(pasteOnly: Bool) async {
        MockField.reset()
        field.web = true
        field.bundleIdentifier = "com.google.Chrome"
        field.label = "Message Body"
        field.pageURL = "https://mail.google.com/mail/u/0/#inbox"
        field.settable = !pasteOnly
        field.frameWidth = 944
        field.frameHeight = 0
        let reports = OSAllocatedUnfairLock<[(CaretEmailBody.Focus, Bool)]>(initialState: [])
        let classifier = CaretEmailBody { focus, body in reports.withLock { $0.append((focus, body)) } }
        let executor = AccessibilityExecutor()
        let focus = CaretEmailBody.Focus(serial: 1, pid: getppid())
        #expect(!classifier.result(for: focus))
        await classify(classifier, focus: focus, on: executor)
        await until { reports.withLock { $0.count == 1 } }
        #expect(classifier.result(for: focus))
        let reads = field.readsBeyondField
        for _ in 0..<30 { await classify(classifier, focus: focus, on: executor) }
        #expect(reports.withLock { $0.count } == 1)
        #expect(field.readsBeyondField == reads)
        #expect(field.textReads == 0)
        #expect(field.rangeBoundsReads == 0)
    }

    @Test func aFailedMailReadRetriesTheSameFocusAfterBackoffWithoutReadingText() async {
        MockField.reset()
        field.web = true
        field.document = true
        field.windowChildrenUnanswered = true
        let time = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let reports = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let classifier = CaretEmailBody(now: { time.withLock { $0 } }) { _, body in
            reports.withLock { $0.append(body) }
        }
        let executor = AccessibilityExecutor()
        let focus = CaretEmailBody.Focus(serial: 1, pid: getppid())
        await classify(classifier, focus: focus, on: executor)
        await until { reports.withLock { $0 == [false] } }
        #expect(!classifier.result(for: focus))
        let reads = field.readsBeyondField
        field.windowChildrenUnanswered = false
        for _ in 0..<20 { await classify(classifier, focus: focus, on: executor) }
        #expect(field.readsBeyondField == reads)
        time.withLock { $0 += .milliseconds(100) }
        await classify(classifier, focus: focus, on: executor)
        await until { reports.withLock { $0 == [false, true] } }
        #expect(classifier.result(for: focus))
        #expect(field.textReads == 0)
        #expect(field.rangeBoundsReads == 0)
    }

    @Test func unansweredMailClassificationStopsAfterThreeAttemptsAndNewFocusGetsAFreshBudget() async {
        MockField.reset()
        field.web = true
        field.document = true
        field.windowChildrenUnanswered = true
        let time = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let reports = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let classifier = CaretEmailBody(now: { time.withLock { $0 } }) { _, body in
            reports.withLock { $0.append(body) }
        }
        let executor = AccessibilityExecutor()
        let focus = CaretEmailBody.Focus(serial: 1, pid: getppid())
        for count in 1...3 {
            await classify(classifier, focus: focus, on: executor)
            await until { reports.withLock { $0.count == count } }
            time.withLock { $0 += .seconds(1) }
        }
        let reads = field.readsBeyondField
        for _ in 0..<20 { await classify(classifier, focus: focus, on: executor) }
        #expect(reports.withLock { $0 == [false, false, false] })
        #expect(field.readsBeyondField == reads)
        field.windowChildrenUnanswered = false
        let next = CaretEmailBody.Focus(serial: 2, pid: getppid())
        await classify(classifier, focus: next, on: executor)
        await until { reports.withLock { $0.last == true } }
        #expect(classifier.result(for: next))
        #expect(field.textReads == 0)
    }

    @Test func aCompleteNegativeClassificationDoesNotRetry() async {
        MockField.reset()
        field.web = true
        field.document = true
        field.windowElements = []
        let time = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let reports = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let classifier = CaretEmailBody(now: { time.withLock { $0 } }) { _, body in
            reports.withLock { $0.append(body) }
        }
        let executor = AccessibilityExecutor()
        let focus = CaretEmailBody.Focus(serial: 1, pid: getppid())
        await classify(classifier, focus: focus, on: executor)
        await until { reports.withLock { $0 == [false] } }
        let reads = field.readsBeyondField
        time.withLock { $0 += .seconds(10) }
        for _ in 0..<20 { await classify(classifier, focus: focus, on: executor) }
        #expect(reports.withLock { $0 == [false] })
        #expect(field.readsBeyondField == reads)
        #expect(field.textReads == 0)
    }

    /// The page's address does not answer at first, then does: the same
    /// focused body becomes an email body on a retry, without focus moving,
    /// and the dot rule then draws its dot. The mock gives the tracker no
    /// caret bounds, so placement itself is not what this checks.
    @Test func aSameFocusRetryTurnsTheTrackedFieldIntoAnEmailBody() async {
        MockField.reset()
        field.web = true
        field.bundleIdentifier = "com.google.Chrome"
        field.label = "Message Body"
        field.pageURL = nil
        field.rangeBounds = CGRect(x: 100, y: 100, width: 1, height: 18)
        let reports = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let readings = OSAllocatedUnfairLock<[CaretTracker.Observation]>(initialState: [])
        let tracker = CaretTracker(onEmailBody: { _, body in reports.withLock { $0.append(body) } },
                                   onChange: { value in readings.withLock { $0.append(value) } })
        defer { tracker.pause() }
        tracker.refresh(frontmost: getppid(), generation: 0)
        await until { reports.withLock { $0 == [false] } && readings.withLock { !$0.isEmpty } }
        let focus = readings.withLock { $0.last?.focus }
        #expect(readings.withLock { $0.last?.fieldFocused == true && $0.last?.isEmailBody == false })
        field.pageURL = "https://mail.google.com/mail/u/0/#inbox"
        try? await Task.sleep(for: .milliseconds(120))
        tracker.refresh(frontmost: getppid(), generation: 0)
        await until { reports.withLock { $0.last == true } }
        tracker.refresh(frontmost: getppid(), generation: 0)
        await until { readings.withLock { $0.last?.isEmailBody == true } }
        let observation = readings.withLock { $0.last! }
        #expect(observation.focus == focus)
        #expect(observation.fieldFocused)
        #expect(DictationIndicators.caretPresentation(isEmailBody: observation.isEmailBody, phase: .idle,
            proposal: .idle, footCarriesRed: false, footPaints: true, captionDue: false).dot)
        #expect(field.textReads == 0)
    }

    @Test(arguments: [false, true])
    func lateMailClassificationCannotApplyToANewFocus(newObservation: Bool) async {
        MockField.reset()
        field.web = true
        field.document = true
        field.windowElements[0].readDelay = 0.15
        let reports = OSAllocatedUnfairLock<[(CaretEmailBody.Focus, Bool)]>(initialState: [])
        let classifier = CaretEmailBody { focus, body in reports.withLock { $0.append((focus, body)) } }
        let executor = AccessibilityExecutor()
        let old = CaretEmailBody.Focus(serial: 1, pid: getppid())
        let next = CaretEmailBody.Focus(serial: 2, pid: getppid())
        await classify(classifier, focus: old, on: executor)
        await until { !self.field.windowElementReads.isEmpty }
        field.focusedElement = 9
        field.secure = true
        if newObservation { await classify(classifier, focus: next, on: executor) }
        #expect(!classifier.result(for: old))
        #expect(!classifier.result(for: next))
        await until { reports.withLock { !$0.isEmpty } }
        let expected = newObservation ? next : old
        #expect(reports.withLock { $0.count == 1 && $0[0].0 == expected && !$0[0].1 })
        #expect(field.textReads == 0)
    }

    @Test func trackerKeepsPlacingWhileMailClassificationRuns() async {
        MockField.reset()
        field.web = true
        field.document = true
        field.rangeBounds = CGRect(x: 100, y: 100, width: 1, height: 18)
        field.windowElements[0].readDelay = 0.3
        let readings = OSAllocatedUnfairLock<[CaretTracker.Observation]>(initialState: [])
        let reports = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let tracker = CaretTracker(onEmailBody: { _, body in reports.withLock { $0.append(body) } },
                                   onChange: { value in readings.withLock { $0.append(value) } })
        defer { tracker.pause() }
        tracker.refresh(frontmost: getppid(), generation: 0)
        await until { !self.field.windowElementReads.isEmpty }
        tracker.refresh(frontmost: getppid(), generation: 0)
        await until { readings.withLock { $0.count >= 2 } }
        #expect(reports.withLock { $0.isEmpty })
        #expect(readings.withLock { $0.allSatisfy { !$0.isEmailBody } })
        await until { reports.withLock { $0 == [true] } }
        tracker.refresh(frontmost: getppid(), generation: 0)
        await until { readings.withLock { $0.last?.isEmailBody == true } }
        let classifiedFocus = readings.withLock { $0.last?.focus }
        // A field turning secure in place overrides the cached body answer.
        field.secure = true
        tracker.refresh(frontmost: getppid(), generation: 0)
        await until { readings.withLock { $0.last?.fieldFocused == false } }
        #expect(readings.withLock { $0.last?.isEmailBody == false })
        #expect(readings.withLock { $0.last?.focus } == classifiedFocus)
    }

    @Test func intentionsOwnProcessIsNeverClassified() async {
        MockField.reset()
        let reports = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let classifier = CaretEmailBody { _, body in reports.withLock { $0.append(body) } }
        await classify(classifier, focus: .init(serial: 1, pid: getpid()), on: AccessibilityExecutor())
        await until { reports.withLock { $0 == [false] } }
        #expect(field.fieldReads.isEmpty)
        #expect(field.textReads == 0)
    }

    @Test func classificationReporterHopsFromBackgroundToMainActor() async {
        var received: (CaretEmailBody.Focus, Bool)?
        var onMain = false
        let foot = FootPlacementTests.foot(saysWords: true)
        let dictation = controller(nil)
        let report = CaretEmailBody.reporter { focus, body in
            DictationIndicators.select(.dot, dictation: dictation, foot: foot, isEmailBody: body)
            received = (focus, body)
            onMain = Thread.isMainThread
        }
        let focus = CaretEmailBody.Focus(serial: 2, pid: getppid())
        let offMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                report(focus, true)
                done.resume(returning: !Thread.isMainThread)
            }
        }
        await until { received != nil }
        #expect(offMain && onMain)
        #expect(!foot.saysWords)
        #expect(received?.0 == focus && received?.1 == true)
    }
}
