import Foundation
import MetersCore

/// Calls `onReopen` when a second launch for the same settings domain asks this instance to show its
/// HUD.
@MainActor
public final class ReopenListener {
    private let center = DistributedNotificationCenter.default()
    private var token: (any NSObjectProtocol)?

    public init(domain: String, onReopen: @escaping @MainActor () -> Void) {
        token = center.addObserver(forName: ReopenRequest.notificationName, object: domain, queue: .main) { _ in
            MainActor.assumeIsolated { onReopen() }
        }
    }

    isolated deinit {
        if let token { center.removeObserver(token) }
    }
}
