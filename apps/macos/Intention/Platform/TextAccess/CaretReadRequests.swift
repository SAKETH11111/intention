/// Coalesces queued reads while preserving a request received during an
/// active read. The tracker protects this value with its request lock.
struct CaretReadRequests: Sendable {
    private var revision: UInt64 = 0
    private var scheduled = false
    /// While paused nothing is read: every request is refused, and a read
    /// queued before the pause sees this as it begins and is skipped.
    private(set) var paused = false

    /// True when this stopped reads that were allowed until now.
    mutating func pause() -> Bool {
        defer { paused = true }
        return !paused
    }

    mutating func resume() { paused = false }

    mutating func request() -> Bool {
        guard !paused else { return false }
        revision &+= 1
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func begin() -> UInt64 { revision }

    /// Called after the executor has released the completed read's slot.
    /// A true result reserves the next read without admitting duplicates.
    mutating func finish(_ handled: UInt64) -> Bool {
        if revision != handled { return true }
        scheduled = false
        return false
    }

    mutating func rejected() { scheduled = false }
}
