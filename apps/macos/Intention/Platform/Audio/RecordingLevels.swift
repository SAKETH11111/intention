import Foundation

/// One recording's meter. Native input supplies a level when samples arrive;
/// chunk-only sources play their PCM through the same envelope at 50 Hz.
/// Audio and levels have separate lifetimes: closing this never drops tape audio.
final class RecordingLevels: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: @Sendable () -> UInt64
    private let deliver: @MainActor @Sendable (Double) -> Void
    private var follower = LevelFollower()
    private var latest = 0.0
    private var pending = false
    private var closed = false
    private var pcm = Data()
    private var timer: DispatchSourceTimer?
    private var lastTickAt: UInt64?
    private static let tickNanoseconds: UInt64 = 20_000_000
    private static let tickBytes = 640 // 20 ms at 16 kHz, 16-bit mono.

    init(clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         deliver: @escaping @MainActor @Sendable (Double) -> Void) {
        self.clock = clock
        self.deliver = deliver
    }

    /// Called off the main actor. Native input measures RMS on raw mono
    /// samples before resampling, then delivers it after that tick's conversion.
    func receive(_ level: Double, seconds: Double) {
        let schedule = lock.withLock { advance(to: level, seconds: seconds) }
        scheduleDelivery(schedule)
    }

    /// The caller holds the lock, so catch-up windows cannot interleave.
    private func advance(to level: Double, seconds: Double) -> Bool {
        guard !closed else { return false }
        latest = follower.advance(to: level, seconds: seconds)
        guard !pending else { return false }
        pending = true
        return true
    }

    private func scheduleDelivery(_ schedule: Bool) {
        if schedule {
            Task { @MainActor [self] in
                let value = lock.withLock { () -> Double? in
                    pending = false
                    return closed ? nil : latest
                }
                if let value { deliver(value) }
            }
        }
    }

    /// Compatibility for sources that only produce speech chunks. Keep at
    /// most one second so a synthetic burst cannot create a meter backlog.
    func enqueue(_ chunk: Data) {
        lock.withLock {
            guard !closed else { return }
            pcm.append(chunk)
            if pcm.count > 32_000 { pcm.removeFirst(pcm.count - 32_000) }
            guard timer == nil else { return }
            lastTickAt = clock()
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "co.intention.mac.levels"))
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
            timer.setEventHandler { @Sendable [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func tick() {
        let schedule = lock.withLock { () -> Bool in
            guard !closed, let lastTickAt else { return false }
            let now = clock()
            guard now >= lastTickAt else { return false }
            let windows = (now - lastTickAt) / Self.tickNanoseconds
            guard windows > 0 else { return false }
            // Keep sub-window time so timer jitter cannot slow the PCM clock.
            self.lastTickAt = lastTickAt + windows * Self.tickNanoseconds
            let audioWindows = min(windows, UInt64((pcm.count + Self.tickBytes - 1) / Self.tickBytes))
            var schedule = false
            for _ in 0..<audioWindows {
                let chunk = Data(pcm.prefix(Self.tickBytes))
                pcm.removeFirst(chunk.count)
                if advance(to: SpeechLevel.of(chunk), seconds: 0.020) { schedule = true }
            }
            if windows > audioWindows,
               advance(to: 0, seconds: Double(windows - audioWindows) * 0.020) { schedule = true }
            return schedule
        }
        scheduleDelivery(schedule)
    }

    /// Called on the main actor before the source stops, invalidating even
    /// a delivery already queued while that actor was busy.
    @MainActor func close() {
        lock.withLock {
            closed = true
            timer?.cancel()
            timer = nil
            pcm.removeAll()
        }
    }
}
