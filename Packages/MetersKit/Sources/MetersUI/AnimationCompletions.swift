import Foundation

/// Schedules window-animation fallbacks. Tests can deliver them in any order without wall-clock sleeps.
@MainActor
public protocol AnimationCompletionScheduling: AnyObject {
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void)
}

@MainActor
public final class DispatchAnimationCompletions: AnimationCompletionScheduling {
    public init() {}

    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { action() }
        }
    }
}
