import AppKit
@testable import Onboarding
import Testing

@MainActor
struct LearningNotificationTests {
    private final class Recorder {
        var asks = 0
        var posts: [String] = []
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "LearningNotificationTests.\(UUID().uuidString)")!
    }

    @Test func setupAsksForConnectedMailEvenWhenReadyOrStopped() {
        for ready in [false, true] {
            let record = Recorder()
            let voice = VoiceReady(notifier: .init(ask: { record.asks += 1 }, post: { record.posts.append($0) }),
                                   defaults: defaults(), read: {})
            let rows = [VoiceReadyTests.mailbox(state: "reconnect_required", voice: ready)]
            voice.observe(rows)
            #expect(record.asks == 0)
            voice.setupFinished(connections: rows)
            voice.setupFinished(connections: rows)
            #expect(record.asks == 1)
            #expect(record.posts.isEmpty)
        }
    }

    @Test func anotherReadyMailboxDoesNotStopTheRemainingMailbox() async {
        let record = Recorder()
        var reads = 0
        weak var observer: VoiceReady?
        let voice = VoiceReady(notifier: .init(ask: {}, post: { record.posts.append($0) }),
                               defaults: defaults(), read: {
            reads += 1
            observer?.observe([VoiceReadyTests.mailbox(1, voice: true), VoiceReadyTests.mailbox(2, voice: true)])
        }, pause: { await Task.yield() })
        observer = voice
        voice.observe([VoiceReadyTests.mailbox(1, voice: true), VoiceReadyTests.mailbox(2, voice: false)])
        #expect(voice.isWaiting)
        let deadline = ContinuousClock.now + .seconds(2)
        while voice.isWaiting, ContinuousClock.now < deadline { await Task.yield() }
        #expect(reads == 1)
        #expect(!voice.isWaiting)
        #expect(record.posts == [VoiceReady.message])
    }

    @Test func setupWithoutMailDoesNotAsk() {
        let record = Recorder()
        let voice = VoiceReady(notifier: .init(ask: { record.asks += 1 }, post: { _ in }),
                               defaults: defaults(), read: {})
        voice.setupFinished(connections: [])
        #expect(record.asks == 0)
    }

    @Test func completedBackfillKeepsReadingAndReadyNotifiesWithoutOpenWindows() async {
        let record = Recorder()
        var reads = 0
        weak var observer: VoiceReady?
        let voice = VoiceReady(notifier: .init(ask: { record.asks += 1 }, post: { record.posts.append($0) }),
                               defaults: defaults(), read: {
            reads += 1
            observer?.observe([VoiceReadyTests.mailbox(state: "ready", voice: true)])
        }, pause: { await Task.yield() })
        observer = voice
        voice.observe([VoiceReadyTests.mailbox(state: "ready", voice: false)])
        #expect(voice.isWaiting)
        let deadline = ContinuousClock.now + .seconds(2)
        while voice.isWaiting, ContinuousClock.now < deadline { await Task.yield() }
        #expect(reads == 1)
        #expect(!voice.isWaiting)
        #expect(record.posts == [VoiceReady.message])
    }
}
