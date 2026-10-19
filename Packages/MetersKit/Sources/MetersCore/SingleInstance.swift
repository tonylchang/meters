import Darwin
import Foundation

/// Enforces one running instance per settings domain.
///
/// The first instance holds an exclusive lock on a per-user file for its whole life; the system releases
/// it when the process exits, even after a crash. A later instance fails to take the lock, asks the
/// running one to show its HUD, and exits. Instances launched by checks use their own settings domain, so
/// they never collide with the user's copy.
public final class InstanceLock: Sendable {
    private let descriptor: Int32

    /// Takes the lock for `domain`, or returns `nil` when another instance already holds it.
    public init?(domain: String, directory: URL = FileManager.default.temporaryDirectory) {
        let path = directory.appendingPathComponent("\(domain).instance.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// Asks the running instance for a settings domain to show its HUD.
public enum ReopenRequest {
    public static let notificationName = Notification.Name("net.1x0.meters.reopen")

    /// The settings domain an instance runs under: the isolated suite when one is set, else the app's own.
    public static func domain(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let suite = environment[AppEnvironment.settingsSuiteVariable], !suite.isEmpty { return suite }
        return Bundle.main.bundleIdentifier ?? "net.1x0.meters"
    }

    public static func post(domain: String) {
        DistributedNotificationCenter.default().postNotificationName(
            notificationName, object: domain, userInfo: nil, deliverImmediately: true)
    }
}
