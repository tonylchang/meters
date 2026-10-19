import Foundation
import MetersCore

/// A cancellable repeating sample schedule.
@MainActor
public protocol SampleSchedule: AnyObject {
    func cancel()
}

/// Schedules periodic sampling on the main actor. Tests substitute a manual scheduler.
@MainActor
public protocol SampleScheduling: AnyObject {
    /// Calls `tick` after `delay`, then every `interval`, until the returned schedule is cancelled.
    func schedule(
        after delay: Duration, every interval: Duration, _ tick: @escaping @MainActor @Sendable () -> Void
    ) -> any SampleSchedule
}

/// Schedules sampling with a main run loop timer. The timer runs in common modes, so sampling continues
/// while a menu is open, and allows 10% tolerance so the system can coalesce wakeups.
@MainActor
public final class RunLoopScheduler: SampleScheduling {
    public init() {}

    public func schedule(
        after delay: Duration, every interval: Duration, _ tick: @escaping @MainActor @Sendable () -> Void
    ) -> any SampleSchedule {
        let timer = Timer(
            fire: Date(timeIntervalSinceNow: delay.timeInterval), interval: interval.timeInterval, repeats: true
        ) { _ in
            MainActor.assumeIsolated { tick() }
        }
        timer.tolerance = interval.timeInterval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        return TimerSchedule(timer: timer)
    }
}

@MainActor
private final class TimerSchedule: SampleSchedule {
    private let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer.invalidate()
    }
}
