import Foundation

// Built into the module under test, beside the writer, in both the voice
// compose package (scripts/test-compose.sh) and the dictation package
// (scripts/test-dictation.sh), whose test targets import different modules.

/// A clock the scenario moves by hand. `advance` wakes every sleep it
/// passes; `jump` moves the time without waking any, as a timer scheduled
/// late would leave it.
final class SteppedClock: WriterClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Duration = .zero
    private var sleepers: [UUID: (until: Duration, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var cancelledEarly: Set<UUID> = []

    var now: Duration { lock.withLock { current } }

    /// The times something sleeps until, earliest first.
    var waits: [Duration] { lock.withLock { sleepers.values.map(\.until).sorted() } }

    func sleep(until: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let early: Result<Void, Error>? = lock.withLock {
                    if cancelledEarly.remove(id) != nil { return .failure(CancellationError()) }
                    if until <= current { return .success(()) }
                    sleepers[id] = (until, continuation)
                    return nil
                }
                if let early { continuation.resume(with: early) }
            }
        } onCancel: {
            let sleeper: CheckedContinuation<Void, Error>? = lock.withLock {
                guard let sleeper = sleepers.removeValue(forKey: id) else {
                    cancelledEarly.insert(id)
                    return nil
                }
                return sleeper.continuation
            }
            sleeper?.resume(throwing: CancellationError())
        }
    }

    func advance(to time: Duration) {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            current = time
            let due = sleepers.filter { $0.value.until <= time }
            due.keys.forEach { sleepers.removeValue(forKey: $0) }
            return due.values.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }

    func jump(to time: Duration) {
        lock.withLock { current = time }
    }
}
