// AppKit rather than Foundation: the Command Line Tools cannot load the
// overlay that importing Foundation beside Testing asks for.
import AppKit
@testable import Onboarding
import Testing

/// The one notification, when a mailbox's voice turns ready: from made-up
/// mailbox lists, a recorded notifier and a scripted pause.
@MainActor
struct VoiceReadyTests {
    @MainActor private final class Told {
        var asks = 0
        var posts: [String] = []
        var notifier: VoiceReady.Notifier {
            VoiceReady.Notifier(ask: { self.asks += 1 }, post: { self.posts.append($0) })
        }
    }

    private func defaults() -> UserDefaults {
        let name = "VoiceReadyTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// One mailbox as the server lists it; `voice` nil leaves the field
    /// out, as an older server does.
    static func mailbox(_ id: Int = 3, state: String = "syncing", voice: Bool?, error: String? = nil) -> AlphaClient.MailConnection {
        let voiceField = voice.map { #","voice_ready":\#($0),"voice_examples":\#($0 ? 4 : 1)"# } ?? ""
        let errorField = error.map { #""\#($0)""# } ?? "null"
        let json = #"{"id":"33333333-3333-4333-8333-33333333333\#(id)","provider":"gmail","address":"synthetic@example.com","state":"\#(state)","stored_messages":10,"backfill_done":false,"blocked_messages":0,"reconciling":false,"last_synced_at":null,"error_code":\#(errorField),"connected_at":"2026-10-03T10:00:00Z"\#(voiceField)}"#
        return try! JSONDecoder().decode(AlphaClient.MailConnection.self, from: Data(json.utf8))
    }

    private func voice(_ told: Told, _ store: UserDefaults) -> VoiceReady {
        VoiceReady(notifier: told.notifier, defaults: store, read: {}, pause: { try? await Task.sleep(for: .seconds(3600)) })
    }

    @Test func aMailboxThatTurnsReadyIsAnnouncedOnceWithTheApprovedWords() {
        let told = Told()
        let voice = voice(told, defaults())
        voice.observe([Self.mailbox(voice: false)])
        // Asked as mail first comes in, and only then.
        #expect(told.asks == 1)
        #expect(told.posts.isEmpty)
        voice.observe([Self.mailbox(voice: false)])
        #expect(told.asks == 1)
        voice.observe([Self.mailbox(voice: true)])
        #expect(told.posts == ["Intention has read your mail. Emails sound like you now."])
        // Going back to false, as during a reconnect, and true again says nothing.
        voice.observe([Self.mailbox(state: "reconnect_required", voice: false)])
        voice.observe([Self.mailbox(voice: true)])
        #expect(told.posts.count == 1)
    }

    @Test func aMailboxFirstSeenReadyIsNeverAnnounced() {
        let told = Told()
        let voice = voice(told, defaults())
        voice.observe([Self.mailbox(state: "ready", voice: true)])
        voice.observe([Self.mailbox(state: "ready", voice: true)])
        #expect(told.posts.isEmpty)
        #expect(told.asks == 0)
    }

    @Test func whatWasSeenSurvivesARelaunch() {
        let store = defaults()
        let told = Told()
        voice(told, store).observe([Self.mailbox(voice: false)])
        let relaunched = voice(told, store)
        relaunched.observe([Self.mailbox(state: "ready", voice: true)])
        #expect(told.posts.count == 1)
        voice(told, store).observe([Self.mailbox(state: "ready", voice: true)])
        #expect(told.posts.count == 1)
    }

    @Test func onlyTheServersSignalIsReady() {
        // An older server's mailbox that is up to date is not announced,
        // and neither is a mailbox with too little sent mail.
        let told = Told()
        let voice = voice(told, defaults())
        voice.observe([Self.mailbox(voice: nil)])
        voice.observe([Self.mailbox(state: "ready", voice: nil)])
        #expect(!VoiceReady.isReady(Self.mailbox(state: "ready", voice: nil)))
        #expect(!VoiceReady.isReady(Self.mailbox(state: "ready", voice: false)))
        #expect(told.posts.isEmpty)
        // Keep checking after import; later sent mail can supply the examples.
        #expect(voice.isWaiting)
    }

    @Test func twoMailboxesTurningReadyTogetherSayItOnce() {
        let told = Told()
        let voice = voice(told, defaults())
        voice.observe([Self.mailbox(1, voice: false), Self.mailbox(2, voice: false)])
        voice.observe([Self.mailbox(1, voice: true), Self.mailbox(2, voice: true)])
        #expect(told.posts.count == 1)
    }

    @Test func aStoppedMailboxIsNotWaitedOn() {
        let told = Told()
        let voice = voice(told, defaults())
        voice.observe([Self.mailbox(voice: false, error: "sync_paused")])
        #expect(!voice.isWaiting)
        #expect(told.asks == 0)
        // A pass the server retries by itself is still waited on.
        voice.observe([Self.mailbox(voice: false, error: "sync_failed")])
        #expect(voice.isWaiting)
    }

    /// A mailbox first seen stopped and then importing is still asked
    /// about, before the notification goes.
    @Test func permissionIsAskedOnceMailComesInWhateverWasSeenFirst() {
        final class Order { var events: [String] = [] }
        let order = Order()
        let voice = VoiceReady(notifier: .init(ask: { order.events.append("ask") }, post: { _ in order.events.append("post") }),
                               defaults: defaults(), read: {}, pause: { try? await Task.sleep(for: .seconds(3600)) })
        voice.observe([Self.mailbox(state: "reconnect_required", voice: false)])
        #expect(order.events.isEmpty)
        voice.observe([Self.mailbox(voice: false)])
        voice.observe([Self.mailbox(voice: true)])
        #expect(order.events == ["ask", "post"])
    }

    /// A launch with a mailbox remembered from before keeps reading while
    /// the reads fail, as offline, and announces it once one succeeds.
    @Test func aLaunchWhoseFirstReadFailsKeepsReading() async throws {
        @MainActor final class Script {
            var reads = 0
            weak var voice: VoiceReady?
        }
        let store = defaults()
        let told = Told()
        voice(told, store).observe([Self.mailbox(voice: false)])
        let script = Script()
        let relaunched = VoiceReady(notifier: told.notifier, defaults: store, read: {
            script.reads += 1
            // The first three reads fail and call nothing.
            if script.reads > 3 { script.voice?.observe([Self.mailbox(voice: true)]) }
        }, pause: { await Task.yield() })
        script.voice = relaunched
        relaunched.check()
        let deadline = ContinuousClock.now + .seconds(5)
        while told.posts.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(told.posts.count == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!relaunched.isWaiting)
        let reads = script.reads
        try await Task.sleep(for: .milliseconds(50))
        #expect(script.reads == reads)
    }

    /// A wait that ends during the pause, as when Settings reads the
    /// mailbox stopped, makes no further read.
    @Test func aWaitEndedDuringThePauseReadsNothingMore() async throws {
        @MainActor final class Script {
            var reads = 0
            var release: CheckedContinuation<Void, Never>?
        }
        let script = Script()
        let voice = VoiceReady(notifier: Told().notifier, defaults: defaults(), read: { script.reads += 1 },
                               pause: { await withCheckedContinuation { done in Task { @MainActor in script.release = done } } })
        voice.observe([Self.mailbox(voice: false)])
        let deadline = ContinuousClock.now + .seconds(5)
        while script.release == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        voice.observe([Self.mailbox(voice: false, error: "sync_paused")])
        script.release?.resume()
        try await Task.sleep(for: .milliseconds(50))
        #expect(script.reads == 0)
    }

    /// A change of account drops a notification still waiting for
    /// permission and stops reading the earlier account's mailboxes.
    @Test func anAccountChangeDropsWhatIsPending() {
        final class Cancels { var count = 0 }
        let cancels = Cancels()
        let told = Told()
        let voice = VoiceReady(notifier: .init(ask: {}, post: { told.posts.append($0) }, cancel: { cancels.count += 1 }),
                               defaults: defaults(), read: {}, pause: { try? await Task.sleep(for: .seconds(3600)) })
        voice.observe([Self.mailbox(voice: false)])
        #expect(voice.isWaiting)
        voice.accountChanged()
        #expect(cancels.count == 1)
        #expect(!voice.isWaiting)
    }

    /// While an import runs the list is read again after each pause, until
    /// the voice turns ready, and then the reading stops.
    @Test func theListIsReadAgainUntilTheVoiceIsReady() async throws {
        @MainActor final class Script {
            var lists: [[AlphaClient.MailConnection]] = []
            var reads = 0
            weak var voice: VoiceReady?
        }
        let told = Told()
        let script = Script()
        script.lists = [[Self.mailbox(voice: false)], [Self.mailbox(voice: false)], [Self.mailbox(voice: true)]]
        let voice = VoiceReady(notifier: told.notifier, defaults: defaults(), read: {
            script.reads += 1
            script.voice?.observe(script.lists.removeFirst())
        }, pause: { await Task.yield() })
        script.voice = voice
        voice.observe([Self.mailbox(voice: false)])
        let deadline = ContinuousClock.now + .seconds(5)
        while voice.isWaiting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!voice.isWaiting)
        #expect(script.reads == 3)
        #expect(told.posts.count == 1)
        // Nothing reads after the voice is ready.
        try await Task.sleep(for: .milliseconds(50))
        #expect(script.reads == 3)
    }
}
