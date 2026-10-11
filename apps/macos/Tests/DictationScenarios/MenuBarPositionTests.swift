import Foundation
import Testing
@testable import Dictation

struct MenuBarPositionTests {
    @Test func firstLaunchSeedsTheSwiftUIStatusItemBeforeCreation() {
        let suite = "co.intention.tests.menu-position.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(defaults.object(forKey: "NSStatusItem Preferred Position Item-0") == nil)
        MenuBarPosition.seedIfNeeded(defaults: defaults)
        #expect(defaults.integer(forKey: "NSStatusItem Preferred Position Item-0") == 1)
        MenuBarPosition.seedIfNeeded(defaults: defaults)
        #expect(defaults.integer(forKey: "NSStatusItem Preferred Position Item-0") == 1)
    }

    @Test(arguments: [0, 1, 250, 900])
    func savedPositionSurvivesAnUpgradeOrRelaunch(position: Int) {
        let suite = "co.intention.tests.menu-position.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(position, forKey: "NSStatusItem Preferred Position Item-0")
        MenuBarPosition.seedIfNeeded(defaults: defaults)
        #expect(defaults.integer(forKey: "NSStatusItem Preferred Position Item-0") == position)
    }
}
