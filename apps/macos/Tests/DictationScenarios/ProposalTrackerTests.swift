import AppKit
@testable import Dictation
import os
import Testing

extension DictationScenarioTests {
    @Test(arguments: [false, true])
    func trackerSelectionKeepsConfirmationThroughAPauseAndSecondTab(paste: Bool) async throws {
        let (p, outcomes) = await shownProposal(configure: { if paste { $0.writes = .refuse } })
        MockField.shared.text = "My reply\n"
        MockField.shared.selection = FieldRange(location: 4, length: 0)
        let readings = OSAllocatedUnfairLock<[CaretTracker.Observation]>(initialState: [])
        let tracker = CaretTracker(onChange: { reading in readings.withLock { $0.append(reading) } })
        defer { tracker.pause() }
        // Establish the tracker's element identity before first Tab. This
        // fixture exposes no caret bounds even when the range is collapsed.
        tracker.refresh(frontmost: p.pid, generation: 0)
        await until { readings.withLock { !$0.isEmpty } }
        let first = try #require(readings.withLock { $0.last })
        #expect(first.focus == 1)
        p.controller.observe(ProposalObservation(first))
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { p.card.confirmingReplacement }
        let anchor = try #require(p.card.shown.last?.anchor)
        let tab = try #require(p.tab)
        for index in 1...8 {
            try await Task.sleep(for: .milliseconds(400))
            tracker.refresh(frontmost: p.pid, generation: 0)
            await until { readings.withLock { $0.count > index } }
            let selected = try #require(readings.withLock { $0.last })
            #expect(selected.reading == nil)
            #expect(selected.hint == nil)
            #expect(selected.status == .absent)
            #expect(selected.fieldFocused)
            #expect(selected.selection == FieldRange(location: 0, length: 9))
            let observation = ProposalObservation(selected)
            #expect(observation.focused)
            p.controller.observe(observation)
            #expect(p.card.isShown)
            #expect(p.card.confirmingReplacement)
            #expect(p.card.shown.last?.anchor == anchor)
            #expect(p.tab == tab)
        }
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { outcomes.list == [.inserted] }
        #expect(MockField.shared.text == proposalDraft)
        #expect(p.route.accepted.count == 1)
    }

    @Test func aSelectedBodyFrameChangeFromTheTrackerEndsConfirmation() async throws {
        let (p, _) = await shownProposal()
        MockField.shared.text = "My reply\n"
        MockField.shared.selection = FieldRange(location: 4, length: 0)
        let readings = OSAllocatedUnfairLock<[CaretTracker.Observation]>(initialState: [])
        let tracker = CaretTracker(onChange: { reading in readings.withLock { $0.append(reading) } })
        defer { tracker.pause() }
        tracker.refresh(frontmost: p.pid, generation: 0)
        await until { readings.withLock { !$0.isEmpty } }
        p.controller.observe(ProposalObservation(try #require(readings.withLock { $0.last })))
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { p.card.confirmingReplacement }
        let tab = try #require(p.tab)
        let boundsReads = MockField.shared.rangeBoundsReads
        MockField.shared.fieldTop += 100
        // No observer exists in the fixture. Let the tracker's existing
        // frame cache expire; this adds no geometry polling or bounds read.
        try await Task.sleep(for: CaretTracker.framesLifetime + .milliseconds(10))
        tracker.refresh(frontmost: p.pid, generation: 0)
        await until { readings.withLock { $0.count == 2 } }
        let moved = try #require(readings.withLock { $0.last })
        #expect(moved.reading == nil)
        #expect(moved.fieldFrame?.minY == MockField.shared.fieldTop)
        p.controller.observe(ProposalObservation(moved))
        #expect(!p.card.confirmingReplacement)
        #expect(p.tab != tab)
        #expect(MockField.shared.rangeBoundsReads == boundsReads)
        #expect(MockField.shared.selection == FieldRange(location: 0, length: 9))
        p.controller.tabTaken(generation: tab)
        #expect(p.route.accepted.isEmpty)
        p.controller.reset()
    }

    @Test(arguments: ["element", "application", "unfocused"])
    func trackerFocusLossCancelsTheSelectedReply(change: String) async throws {
        let (p, outcomes) = await shownProposal()
        MockField.shared.text = "My reply\n"
        MockField.shared.selection = FieldRange(location: 4, length: 0)
        let readings = OSAllocatedUnfairLock<[CaretTracker.Observation]>(initialState: [])
        let tracker = CaretTracker(onChange: { reading in readings.withLock { $0.append(reading) } })
        defer { tracker.pause() }
        tracker.refresh(frontmost: p.pid, generation: 0)
        await until { readings.withLock { !$0.isEmpty } }
        p.controller.observe(ProposalObservation(try #require(readings.withLock { $0.last })))
        p.controller.tabTaken(generation: try #require(p.tab))
        await until { p.card.confirmingReplacement }
        tracker.refresh(frontmost: p.pid, generation: 0)
        await until { readings.withLock { $0.count == 2 } }
        let selected = try #require(readings.withLock { $0.last })
        #expect(selected.reading == nil)
        p.controller.observe(ProposalObservation(selected))
        #expect(p.card.confirmingReplacement)
        switch change {
        case "element":
            MockField.shared.focusedElement = 9
            MockField.shared.label = "Search mail"
        case "unfocused": MockField.shared.focused = false
        case "application": break
        default: Issue.record("Unexpected focus change")
        }
        tracker.refresh(frontmost: change == "application" ? getpid() : p.pid, generation: 0)
        await until { readings.withLock { $0.count == 3 } }
        p.controller.observe(ProposalObservation(try #require(readings.withLock { $0.last })))
        #expect(!p.card.isShown)
        #expect(!p.card.confirmingReplacement)
        #expect(p.tab == nil)
        #expect(MockField.shared.text == "My reply\n")
        #expect(MockField.shared.selection == FieldRange(location: 0, length: 9))
        #expect(p.route.accepted.isEmpty)
        #expect(outcomes.list.isEmpty)
    }
}
