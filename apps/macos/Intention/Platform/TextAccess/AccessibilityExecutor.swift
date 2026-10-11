import ApplicationServices
import Foundation
import os

/// Runs Accessibility calls on one dedicated thread with its own run loop,
/// off the main actor and off Swift's cooperative pool. The main actor never
/// waits on it; results return through callbacks.
///
/// Every AX message has a timeout, so a hung app delays this thread by a
/// bounded amount instead of freezing Intention. The queue is bounded: work that
/// cannot be queued is reported busy rather than waiting.
final class AccessibilityExecutor: @unchecked Sendable {
    /// Seconds before an AX message to another app gives up. Applies to every
    /// call this process makes.
    static let messagingTimeout: Float = 1.0

    private let capacity: Int
    private let pending = OSAllocatedUnfairLock(initialState: 0)
    private let thread: Thread
    private let runLoop: RunLoopHandle

    init(capacity: Int = 4) {
        self.capacity = capacity
        let started = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock<RunLoopHandle?>(initialState: nil)
        thread = Thread {
            // A port keeps the run loop alive between jobs; observers added
            // later attach their sources to this same run loop.
            let port = NSMachPort()
            RunLoop.current.add(port, forMode: .default)
            box.withLock { $0 = RunLoopHandle(runLoop: CFRunLoopGetCurrent()) }
            started.signal()
            while true {
                CFRunLoopRun()
            }
        }
        thread.name = "co.intention.mac.accessibility"
        thread.qualityOfService = .userInitiated
        thread.start()
        started.wait()
        runLoop = box.withLock { $0! }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
    }

    /// True on the executor thread. The caret tracker asserts it before
    /// touching native objects, which are confined to this thread.
    var isCurrent: Bool { Thread.current == thread }

    /// Queues `work`. Returns false without queueing when the bounded queue is
    /// full. `deadline` expires work that waited too long; the work receives
    /// `expired == true` and must return without calling Accessibility.
    @discardableResult
    func submit(deadline: ContinuousClock.Instant? = nil, _ work: @escaping @Sendable (_ expired: Bool) -> Void) -> Bool {
        let accepted = pending.withLock { count in
            guard count < capacity else { return false }
            count += 1
            return true
        }
        guard accepted else { return false }
        perform {
            let expired = deadline.map { ContinuousClock.now > $0 } ?? false
            work(expired)
            self.pending.withLock { $0 -= 1 }
        }
        return true
    }

    /// Queues cleanup that must not be dropped, such as releasing a native
    /// target. It does not count against the bounded queue and must not
    /// message other apps.
    func submitCleanup(_ work: @escaping @Sendable () -> Void) {
        perform(work)
    }

    private func perform(_ block: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop.runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop.runLoop)
    }
}

/// Other threads only call CFRunLoopPerformBlock and CFRunLoopWakeUp on this
/// run loop; both are documented as thread-safe.
private struct RunLoopHandle: @unchecked Sendable {
    let runLoop: CFRunLoop
}
