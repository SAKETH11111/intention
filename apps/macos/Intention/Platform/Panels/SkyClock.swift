import AppKit

/// Whether the foot mark is the sun or the moon: the sun from 6:00 to
/// 19:00 by the Mac's own clock and time zone, the moon the rest of the
/// night. Nothing asks for the person's location. Light and Dark appearance
/// do not change it; they only colour what is around it.
///
/// It wakes once, at the next 6:00 or 19:00, never on a running tick, and
/// looks again whenever the clock is set, the time zone changes or the Mac
/// wakes, since a timer does not count time asleep. Whoever shows the sky
/// decides when to switch: the foot mark waits until it rests.
@MainActor
final class SkyClock {
    /// The hours the sun rises and sets, in local time.
    nonisolated static let dawn = 6
    nonisolated static let dusk = 19

    /// The sky now.
    private(set) var sky: SunDotView.Sky
    /// Runs when the sky turns.
    var changed: (SunDotView.Sky) -> Void = { _ in }

    private let now: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(now: @escaping @Sendable () -> Date = { Date() }, calendar: @escaping @Sendable () -> Calendar = { Calendar.autoupdatingCurrent }) {
        self.now = now
        self.calendar = calendar
        sky = Self.sky(at: now(), in: calendar())
    }

    /// The sun from `dawn` up to `dusk`, the moon otherwise.
    nonisolated static func sky(at date: Date, in calendar: Calendar) -> SunDotView.Sky {
        let hour = calendar.component(.hour, from: date)
        return (dawn..<dusk).contains(hour) ? .sun : .moon
    }

    /// The first 6:00 or 19:00 after `date`. A boundary a clock change
    /// skips, as when summer time starts, falls to the next valid time.
    nonisolated static func nextChange(after date: Date, in calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: date)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? date.addingTimeInterval(86_400)
        let candidates = [today, tomorrow].flatMap { day in
            [dawn, dusk].compactMap { calendar.date(bySettingHour: $0, minute: 0, second: 0, of: day) }
        }
        return candidates.filter { $0 > date }.min() ?? date.addingTimeInterval(3_600)
    }

    /// Starts watching the clock, the time zone and wake, and schedules the
    /// first wake.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        for (source, name) in [(center, Notification.Name.NSSystemClockDidChange), (center, .NSSystemTimeZoneDidChange),
                               (workspace, NSWorkspace.didWakeNotification)] {
            observers.append((source, source.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.clockMayHaveChanged()
            }))
        }
        schedule()
    }

    /// The clock, the time zone or the hour may have changed. Safe to call
    /// from any queue: it reaches the main actor itself, at once on the main
    /// thread and through the main queue anywhere else.
    nonisolated func clockMayHaveChanged() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { recheck() }
        } else {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.recheck() }
            }
        }
    }

    private func recheck() {
        NSTimeZone.resetSystemTimeZone()
        let next = Self.sky(at: now(), in: calendar())
        if next != sky {
            sky = next
            changed(next)
        }
        if !observers.isEmpty { schedule() }
    }

    /// One wake at the next boundary, allowed to come up to half a minute
    /// late so the system can batch it.
    private func schedule() {
        timer?.invalidate()
        let timer = Timer(fire: Self.nextChange(after: now(), in: calendar()), interval: 0, repeats: false) { [weak self] _ in
            self?.clockMayHaveChanged()
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// When the next wake is due, for the checks.
    var nextWake: Date? { timer?.fireDate }
}
