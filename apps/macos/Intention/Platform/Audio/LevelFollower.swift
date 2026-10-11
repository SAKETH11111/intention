import Foundation

/// A time-based envelope, independent of the audio and presentation queues.
struct LevelFollower {
    private(set) var value = 0.0
    let attack = 0.030
    let release = 0.200

    mutating func advance(to level: Double, seconds: Double) -> Double {
        let target = level.isFinite ? min(1, max(0, level)) : 0
        guard seconds.isFinite, seconds > 0 else { return value }
        let constant = target > value ? attack : release
        value += (target - value) * (1 - exp(-seconds / constant))
        if target == 0, value < 0.001 { value = 0 }
        return value
    }
}
