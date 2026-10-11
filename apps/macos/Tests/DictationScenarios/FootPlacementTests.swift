import AppKit
@testable import Dictation
import Foundation
import Testing

/// The three slots and their snap decision on made-up displays. Nothing
/// opens a window or changes the system's Dock preferences.
@MainActor
struct FootSlotPlacementTests {
    private static let laptop = FootMark.Screen(
        id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), usable: CGRect(x: 0, y: 80, width: 1440, height: 795))
    private static let monitor = FootMark.Screen(
        id: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), usable: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
    private static let strip = FootMark.Screen(
        id: 4, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), usable: CGRect(x: 0, y: 4, width: 1728, height: 1080))
    private static let full = FootMark.Screen(
        id: 5, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), usable: CGRect(x: 0, y: 0, width: 1440, height: 900))

    private var screens: [(screen: FootMark.Screen, dock: FootDock)] {
        [(Self.laptop, FootDock(edge: .bottom, hides: false)), (Self.monitor, FootDock(edge: .bottom, hides: true))]
    }

    @Test func slotsHaveTheSettingsTitles() {
        #expect(FootSlot.allCases == [.bottom, .left, .right])
        #expect(FootSlot.allCases.map(\.title) == ["Bottom", "Left", "Right"])
    }

    @Test func bottomCentresKeepTheExistingGeometry() {
        let examples: [(FootMark.Screen, CGPoint)] = [
            (Self.laptop, CGPoint(x: 720, y: 106)),
            (Self.monitor, CGPoint(x: 2400, y: 26)),
            (Self.strip, CGPoint(x: 864, y: 30)),
            (Self.full, CGPoint(x: 720, y: 26))
        ]
        for (screen, expected) in examples {
            let dock = FootPlacement.dock(on: screen, systemEdge: .bottom)
            #expect(FootPlacement.dotCentre(for: .bottom, on: screen, dock: dock) == expected)
            #expect(FootPlacement.dotCentre(for: .bottom, on: screen, dock: dock) == FootMark.dotCentre(on: screen))
        }
    }

    @Test func bottomFieldAndDockRulesKeepTheExistingAnswers() {
        let fields: [CGRect?] = [nil, CGRect(x: 200, y: 139, width: 900, height: 400),
                                CGRect(x: 200, y: 140, width: 900, height: 400),
                                CGRect(x: 0, y: 20, width: 500, height: 36),
                                CGRect(x: 1600, y: 0, width: 900, height: 60)]
        let pointers = [CGPoint(x: 720, y: 20), CGPoint(x: 2400, y: 20), CGPoint(x: 720, y: 129),
                        CGPoint(x: 720, y: 130), CGPoint(x: -1, y: 20)]
        for screen in [Self.laptop, Self.monitor, Self.strip, Self.full] {
            let dock = FootPlacement.dock(on: screen, systemEdge: .bottom)
            for field in fields {
                #expect(FootPlacement.isClear(of: field, slot: .bottom, on: screen, dock: dock) == FootMark.isClear(of: field, on: screen))
            }
            for pointer in pointers {
                #expect(FootPlacement.dockMayCover(slot: .bottom, on: screen, dock: dock, pointer: pointer)
                        == FootMark.dockMayCover(on: screen, pointer: pointer))
            }
        }
    }

    @Test func theLargestSideOrBottomInsetLocatesTheDockAndIgnoresTheMenuBar() {
        #expect(FootPlacement.dock(on: Self.laptop, systemEdge: .right) == FootDock(edge: .bottom, hides: false))
        let left = FootMark.Screen(id: 3, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                   usable: CGRect(x: 80, y: 4, width: 1646, height: 1013))
        #expect(FootPlacement.dock(on: left, systemEdge: .bottom) == FootDock(edge: .left, hides: false))
        let right = FootMark.Screen(id: 3, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                    usable: CGRect(x: 4, y: 2, width: 1644, height: 1015))
        #expect(FootPlacement.dock(on: right, systemEdge: .bottom) == FootDock(edge: .right, hides: false))
        #expect(FootPlacement.dock(on: Self.monitor, systemEdge: .left) == FootDock(edge: .left, hides: true))
    }

    @Test func aStripOfAtMostEightPointsMeansTheDockHides() {
        #expect(FootPlacement.dock(on: Self.strip, systemEdge: .right) == FootDock(edge: .bottom, hides: true))
        let eight = FootMark.Screen(id: 1, frame: Self.full.frame, usable: CGRect(x: 8, y: 0, width: 1432, height: 900))
        let nine = FootMark.Screen(id: 1, frame: Self.full.frame, usable: CGRect(x: 9, y: 0, width: 1431, height: 900))
        #expect(FootPlacement.dock(on: eight, systemEdge: nil) == FootDock(edge: .left, hides: true))
        #expect(FootPlacement.dock(on: nine, systemEdge: nil) == FootDock(edge: .left, hides: false))
    }

    @Test func sideSlotsKeepTwentySixPointsFromEdgesWithTheDockAtTheBottom() {
        let dock = FootDock(edge: .bottom, hides: false)
        #expect(FootPlacement.dotCentre(for: .left, on: Self.laptop, dock: dock) == CGPoint(x: 26, y: 478))
        #expect(FootPlacement.dotCentre(for: .right, on: Self.laptop, dock: dock) == CGPoint(x: 1414, y: 478))
        #expect(FootPlacement.slotCentres(on: Self.laptop, dock: dock) == [
            .bottom: CGPoint(x: 720, y: 106), .left: CGPoint(x: 26, y: 478), .right: CGPoint(x: 1414, y: 478)
        ])
    }

    @Test func aShownLeftDockPutsTheLeftSlotTwentySixPointsBesideIt() {
        let screen = FootMark.Screen(id: 3, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                     usable: CGRect(x: 80, y: 0, width: 1648, height: 1085))
        let dock = FootPlacement.dock(on: screen, systemEdge: nil)
        #expect(FootPlacement.dotCentre(for: .left, on: screen, dock: dock) == CGPoint(x: 106, y: 543))
        #expect(FootPlacement.dotCentre(for: .right, on: screen, dock: dock) == CGPoint(x: 1702, y: 543))
        #expect(FootPlacement.dotCentre(for: .bottom, on: screen, dock: dock) == CGPoint(x: 904, y: 26))
    }

    @Test func aShownRightDockPutsTheRightSlotTwentySixPointsBesideIt() {
        let screen = FootMark.Screen(id: 3, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                     usable: CGRect(x: 0, y: 0, width: 1648, height: 1085))
        let dock = FootPlacement.dock(on: screen, systemEdge: nil)
        #expect(FootPlacement.dotCentre(for: .left, on: screen, dock: dock) == CGPoint(x: 26, y: 543))
        #expect(FootPlacement.dotCentre(for: .right, on: screen, dock: dock) == CGPoint(x: 1622, y: 543))
    }

    @Test func aHiddenLeftDockKeepsTheSlotTwentySixPointsFromItsStrip() {
        let screen = FootMark.Screen(id: 3, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                     usable: CGRect(x: 4, y: 0, width: 1724, height: 1085))
        let dock = FootPlacement.dock(on: screen, systemEdge: .bottom)
        #expect(dock == FootDock(edge: .left, hides: true))
        #expect(FootPlacement.dotCentre(for: .left, on: screen, dock: dock) == CGPoint(x: 30, y: 543))
        #expect(FootPlacement.dotCentre(for: .right, on: screen, dock: dock) == CGPoint(x: 1702, y: 543))
    }

    @Test func aFullScreenSpaceUsesTheSystemDockEdgeOrBottomAndTreatsItAsHidden() {
        for (edge, expected) in [(FootSlot?.some(.left), FootSlot.left), (nil, FootSlot.bottom)] {
            let dock = FootPlacement.dock(on: Self.full, systemEdge: edge)
            #expect(dock == FootDock(edge: expected, hides: true))
            #expect(FootPlacement.slotCentres(on: Self.full, dock: dock) == [
                .bottom: CGPoint(x: 720, y: 26), .left: CGPoint(x: 26, y: 450), .right: CGPoint(x: 1414, y: 450)
            ])
        }
    }

    @Test func noFieldAndAFieldOnAnotherDisplayLeaveEverySlotClear() {
        for slot in FootSlot.allCases {
            #expect(FootPlacement.isClear(of: nil, slot: slot, on: Self.laptop, dock: screens[0].dock))
            #expect(FootPlacement.isClear(of: CGRect(x: 1500, y: 0, width: 1800, height: 1000), slot: slot,
                                          on: Self.laptop, dock: screens[0].dock))
        }
    }

    @Test func aFieldAtTheLeftEdgeHidesOnlyTheLeftSlot() {
        let field = CGRect(x: 0, y: 430, width: 700, height: 90)
        let dock = screens[0].dock
        #expect(!FootPlacement.isClear(of: field, slot: .left, on: Self.laptop, dock: dock))
        #expect(FootPlacement.isClear(of: field, slot: .bottom, on: Self.laptop, dock: dock))
        #expect(FootPlacement.isClear(of: field, slot: .right, on: Self.laptop, dock: dock))
        #expect(!FootPlacement.isClear(of: CGRect(x: 59, y: 430, width: 600, height: 90), slot: .left, on: Self.laptop, dock: dock))
        #expect(FootPlacement.isClear(of: CGRect(x: 60, y: 430, width: 600, height: 90), slot: .left, on: Self.laptop, dock: dock))
    }

    @Test func aFieldAtTheRightEdgeHidesOnlyTheRightSlot() {
        let field = CGRect(x: 1000, y: 430, width: 440, height: 90)
        let dock = screens[0].dock
        #expect(!FootPlacement.isClear(of: field, slot: .right, on: Self.laptop, dock: dock))
        #expect(FootPlacement.isClear(of: field, slot: .left, on: Self.laptop, dock: dock))
        #expect(FootPlacement.isClear(of: field, slot: .bottom, on: Self.laptop, dock: dock))
        #expect(!FootPlacement.isClear(of: CGRect(x: 1000, y: 430, width: 381, height: 90), slot: .right, on: Self.laptop, dock: dock))
        #expect(FootPlacement.isClear(of: CGRect(x: 1000, y: 430, width: 380, height: 90), slot: .right, on: Self.laptop, dock: dock))
    }

    @Test func fieldsAboveOrBelowTheSideBandLeaveSideSlotsClear() {
        for slot in [FootSlot.left, .right] {
            // The side band's boundaries are 358 and 598 on this display.
            #expect(FootPlacement.isClear(of: CGRect(x: 0, y: 598, width: 1440, height: 100), slot: slot,
                                          on: Self.laptop, dock: screens[0].dock))
            #expect(FootPlacement.isClear(of: CGRect(x: 0, y: 258, width: 1440, height: 100), slot: slot,
                                          on: Self.laptop, dock: screens[0].dock))
            #expect(!FootPlacement.isClear(of: CGRect(x: 0, y: 597, width: 1440, height: 100), slot: slot,
                                           on: Self.laptop, dock: screens[0].dock))
            #expect(!FootPlacement.isClear(of: CGRect(x: 0, y: 259, width: 1440, height: 100), slot: slot,
                                           on: Self.laptop, dock: screens[0].dock))
        }
    }

    @Test func bottomClearanceAndColumnBoundariesAreExact() {
        let dock = screens[0].dock
        #expect(!FootPlacement.isClear(of: CGRect(x: 200, y: 139, width: 900, height: 40), slot: .bottom, on: Self.laptop, dock: dock))
        #expect(FootPlacement.isClear(of: CGRect(x: 200, y: 140, width: 900, height: 40), slot: .bottom, on: Self.laptop, dock: dock))
        #expect(FootPlacement.isClear(of: CGRect(x: 0, y: 86, width: 600, height: 40), slot: .bottom, on: Self.laptop, dock: dock))
        #expect(FootPlacement.isClear(of: CGRect(x: 840, y: 86, width: 600, height: 40), slot: .bottom, on: Self.laptop, dock: dock))
        #expect(!FootPlacement.isClear(of: CGRect(x: 839, y: 86, width: 600, height: 40), slot: .bottom, on: Self.laptop, dock: dock))
    }

    @Test func aShownSideDockMeasuresFieldClearanceFromTheUsableEdge() {
        let screen = FootMark.Screen(id: 3, frame: Self.full.frame, usable: CGRect(x: 80, y: 0, width: 1360, height: 875))
        let dock = FootDock(edge: .left, hides: false)
        #expect(!FootPlacement.isClear(of: CGRect(x: 139, y: 400, width: 600, height: 80), slot: .left, on: screen, dock: dock))
        #expect(FootPlacement.isClear(of: CGRect(x: 140, y: 400, width: 600, height: 80), slot: .left, on: screen, dock: dock))
    }

    @Test func aHiddenDockCanCoverOnlyItsOwnSlot() {
        let pointers: [FootSlot: CGPoint] = [.bottom: CGPoint(x: 720, y: 20), .left: CGPoint(x: 20, y: 450),
                                           .right: CGPoint(x: 1420, y: 450)]
        for edge in FootSlot.allCases {
            for slot in FootSlot.allCases {
                #expect(FootPlacement.dockMayCover(slot: slot, on: Self.full, dock: FootDock(edge: edge, hides: true),
                                                  pointer: pointers[edge]!) == (slot == edge))
                #expect(!FootPlacement.dockMayCover(slot: slot, on: Self.full, dock: FootDock(edge: edge, hides: false),
                                                   pointer: pointers[edge]!))
            }
        }
    }

    @Test func dockRevealStopsAtOneHundredThirtyPointsAndAtAnotherDisplay() {
        let near: [FootSlot: CGPoint] = [.bottom: CGPoint(x: 720, y: 129), .left: CGPoint(x: 129, y: 450),
                                        .right: CGPoint(x: 1311, y: 450)]
        let far: [FootSlot: CGPoint] = [.bottom: CGPoint(x: 720, y: 130), .left: CGPoint(x: 130, y: 450),
                                       .right: CGPoint(x: 1310, y: 450)]
        for slot in FootSlot.allCases {
            let dock = FootDock(edge: slot, hides: true)
            #expect(FootPlacement.dockMayCover(slot: slot, on: Self.full, dock: dock, pointer: near[slot]!))
            #expect(!FootPlacement.dockMayCover(slot: slot, on: Self.full, dock: dock, pointer: far[slot]!))
            #expect(!FootPlacement.dockMayCover(slot: slot, on: Self.full, dock: dock, pointer: CGPoint(x: 2000, y: 20)))
        }
    }

    @Test func aStillReleaseChoosesTheNearestSlotInEachRegion() {
        #expect(FootPlacement.snap(release: CGPoint(x: 720, y: 150), velocity: .zero, screens: screens, from: 1)
                == FootSnap(display: 1, slot: .bottom))
        #expect(FootPlacement.snap(release: CGPoint(x: 100, y: 450), velocity: .zero, screens: screens, from: 1)
                == FootSnap(display: 1, slot: .left))
        #expect(FootPlacement.snap(release: CGPoint(x: 1350, y: 450), velocity: .zero, screens: screens, from: 1)
                == FootSnap(display: 1, slot: .right))
    }

    @Test func aFlickTowardsTheRightChoosesRightFromTheCentre() {
        #expect(FootPlacement.snap(release: CGPoint(x: 720, y: 450), velocity: .zero, screens: screens, from: 1)
                == FootSnap(display: 1, slot: .bottom))
        #expect(FootPlacement.snap(release: CGPoint(x: 720, y: 450), velocity: CGVector(dx: 6000, dy: 0), screens: screens, from: 1)
                == FootSnap(display: 1, slot: .right))
    }

    @Test func aFlickNeverChangesTheReleaseDisplay() {
        #expect(FootPlacement.snap(release: CGPoint(x: 1400, y: 450), velocity: CGVector(dx: 12000, dy: 0), screens: screens, from: 2)
                == FootSnap(display: 1, slot: .right))
        #expect(FootPlacement.snap(release: CGPoint(x: 1500, y: 450), velocity: CGVector(dx: -12000, dy: 0), screens: screens, from: 1)
                == FootSnap(display: 2, slot: .left))
    }

    @Test func aReleaseOnTheSecondDisplayChoosesThatDisplay() {
        #expect(FootPlacement.snap(release: CGPoint(x: 2400, y: 100), velocity: .zero, screens: screens, from: 1)
                == FootSnap(display: 2, slot: .bottom))
    }

    @Test func anOffScreenProjectionClampsToTheActualFramesAcrossAGap() {
        let remote = FootMark.Screen(id: 2, frame: CGRect(x: 2000, y: 1200, width: 1920, height: 1080),
                                     usable: CGRect(x: 2000, y: 1200, width: 1920, height: 1055))
        let separated = [(screen: Self.laptop, dock: screens[0].dock), (screen: remote, dock: screens[1].dock)]
        // (1600, 1000) is in the bounding rectangle but on neither screen.
        #expect(FootPlacement.snap(release: CGPoint(x: 1600, y: 1000), velocity: .zero, screens: separated, from: 2)
                == FootSnap(display: 1, slot: .right))
        #expect(FootPlacement.snap(release: CGPoint(x: 1600, y: 1000), velocity: CGVector(dx: 5000, dy: 3000),
                                  screens: separated, from: 1) == FootSnap(display: 2, slot: .left))
    }

    @Test func projectionBeyondTheOuterEdgeStillFindsADisplay() {
        #expect(FootPlacement.snap(release: CGPoint(x: 5000, y: 500), velocity: .zero, screens: screens, from: 1)
                == FootSnap(display: 2, slot: .right))
        #expect(FootPlacement.snap(release: CGPoint(x: -200, y: 450), velocity: .zero, screens: screens, from: 99)
                == FootSnap(display: 1, slot: .left))
    }

    @Test func noScreensGiveNoSnap() {
        #expect(FootPlacement.snap(release: .zero, velocity: .zero, screens: [], from: 1) == nil)
    }

    @Test func anUnknownDisplayFallsBackToItsNumericID() {
        #expect(FootPlacement.displayKey(for: UInt32.max) == "id-4294967295")
    }

    @Test func placementCanRunAwayFromTheMainActor() async {
        let result = await Task.detached {
            let screen = FootMark.Screen(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                         usable: CGRect(x: 0, y: 80, width: 1440, height: 795))
            let dock = FootPlacement.dock(on: screen, systemEdge: nil)
            return FootPlacement.dotCentre(for: .left, on: screen, dock: dock)
        }.value
        #expect(result == CGPoint(x: 26, y: 478))
    }

    @Test func slotCompletionRunsOnMainFromBackgroundAndMainThreads() async {
        var runsOnMain: [Bool] = []
        let completion = FootSlotsView.completion { runsOnMain.append(Thread.isMainThread) }
        let sentOffMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                completion()
                done.resume(returning: !Thread.isMainThread)
            }
        }
        #expect(sentOffMain)
        for _ in 0..<200 {
            if !runsOnMain.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(runsOnMain == [true])
        completion()
        #expect(runsOnMain == [true, true])
    }
}

/// Each test owns and removes its defaults domain, so no saved app choice
/// or another test's choice is read or written.
@MainActor
struct FootPositionPreferencesTests {
    private func withDefaults(_ check: (UserDefaults) -> Void) {
        let name = "FootPositionPreferencesTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        check(defaults)
    }

    @Test func aNewInstallStartsAtTheBottomWithoutDisplayChoices() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            #expect(preferences.dotPosition == .bottom)
            #expect(preferences.dotPositionsByDisplay.isEmpty)
            #expect(preferences.dotPosition(onDisplay: "laptop") == .bottom)
            #expect(defaults.object(forKey: "dotPosition") == nil)
        }
    }

    @Test func positionsRoundTripAsRawStrings() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.dotPosition = .right
            preferences.dotPositionsByDisplay = ["laptop": .left, "monitor": .bottom]
            #expect(defaults.string(forKey: "dotPosition") == "right")
            #expect(defaults.dictionary(forKey: "dotPositionsByDisplay") as? [String: String] == ["laptop": "left", "monitor": "bottom"])
            let reopened = Preferences(defaults: defaults)
            #expect(reopened.dotPosition == .right)
            #expect(reopened.dotPositionsByDisplay == ["laptop": .left, "monitor": .bottom])
        }
    }

    @Test func unknownStoredValuesFallBackAndUnknownDisplayEntriesAreDropped() {
        withDefaults { defaults in
            defaults.set("top", forKey: "dotPosition")
            defaults.set(["laptop": "left", "unknown": "top", "wrongType": 42] as [String: Any], forKey: "dotPositionsByDisplay")
            let preferences = Preferences(defaults: defaults)
            #expect(preferences.dotPosition == .bottom)
            #expect(preferences.dotPositionsByDisplay == ["laptop": .left])
            #expect(preferences.dotPosition(onDisplay: "unknown") == .bottom)
        }
    }

    @Test func eachDisplayKeepsItsOwnChoiceAndADragUpdatesTheDefault() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.chooseDotPosition(.left, onDisplay: "laptop")
            preferences.chooseDotPosition(.right, onDisplay: "monitor")
            #expect(preferences.dotPosition(onDisplay: "laptop") == .left)
            #expect(preferences.dotPosition(onDisplay: "monitor") == .right)
            #expect(preferences.dotPosition(onDisplay: "new-display") == .right)
            #expect(preferences.dotPosition == .right)
            let reopened = Preferences(defaults: defaults)
            #expect(reopened.dotPosition == .right)
            #expect(reopened.dotPositionsByDisplay == ["laptop": .left, "monitor": .right])
        }
    }

    @Test func aDragPinsConnectedDisplaysBeforeChangingTheDefaultAndPersists() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            #expect(preferences.dotPosition(onDisplay: "laptop") == .bottom)
            #expect(preferences.dotPosition(onDisplay: "monitor") == .bottom)
            #expect(preferences.dotPositionsByDisplay.isEmpty)

            preferences.chooseDotPosition(.right, onDisplay: "monitor", keeping: ["laptop", "monitor"])
            #expect(preferences.dotPosition(onDisplay: "laptop") == .bottom)
            #expect(preferences.dotPosition(onDisplay: "monitor") == .right)
            #expect(preferences.dotPosition(onDisplay: "new-display") == .right)
            #expect(preferences.dotPosition == .right)
            #expect(preferences.dotPositionsByDisplay == ["laptop": .bottom, "monitor": .right])
            #expect(defaults.dictionary(forKey: "dotPositionsByDisplay") as? [String: String]
                    == ["laptop": "bottom", "monitor": "right"])

            let reopened = Preferences(defaults: defaults)
            #expect(reopened.dotPosition == .right)
            #expect(reopened.dotPositionsByDisplay == ["laptop": .bottom, "monitor": .right])
            #expect(reopened.dotPosition(onDisplay: "laptop") == .bottom)
            #expect(reopened.dotPosition(onDisplay: "monitor") == .right)
            #expect(reopened.dotPosition(onDisplay: "new-display") == .right)
        }
    }

    @Test func pinningConnectedDisplaysPreservesAnExplicitChoiceDifferentFromTheDefault() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.dotPositionsByDisplay = ["laptop": .left]
            #expect(preferences.dotPosition == .bottom)
            preferences.chooseDotPosition(.right, onDisplay: "monitor", keeping: ["laptop", "monitor"])
            #expect(preferences.dotPosition(onDisplay: "laptop") == .left)
            #expect(preferences.dotPositionsByDisplay == ["laptop": .left, "monitor": .right])
            let reopened = Preferences(defaults: defaults)
            #expect(reopened.dotPosition == .right)
            #expect(reopened.dotPositionsByDisplay == ["laptop": .left, "monitor": .right])
        }
    }

    @Test func aSettingsChoiceClearsEveryDisplayChoiceAndPersists() {
        withDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.chooseDotPosition(.left, onDisplay: "other-display")
            preferences.chooseDotPosition(.right, onDisplay: "monitor", keeping: ["laptop", "monitor", "other-display"])
            #expect(preferences.dotPositionsByDisplay == ["laptop": .left, "monitor": .right, "other-display": .left])
            preferences.chooseDotPositionEverywhere(.bottom)
            #expect(preferences.dotPosition == .bottom)
            #expect(preferences.dotPositionsByDisplay.isEmpty)
            let reopened = Preferences(defaults: defaults)
            #expect(reopened.dotPositionsByDisplay.isEmpty)
            #expect(reopened.dotPosition(onDisplay: "laptop") == .bottom)
            #expect(reopened.dotPosition(onDisplay: "monitor") == .bottom)
            #expect(reopened.dotPosition(onDisplay: "other-display") == .bottom)
            #expect(reopened.dotPosition(onDisplay: "new-display") == .bottom)
            #expect(defaults.dictionary(forKey: "dotPositionsByDisplay")?.isEmpty == true)
        }
    }
}
