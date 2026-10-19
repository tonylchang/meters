import Foundation
import Testing

@testable import MetersCore

/// A throwaway directory for lock files, removed when the test ends.
final class TemporaryDirectory {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "net.1x0.meters.tests.\(UUID().uuidString)", isDirectory: true)

    init() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("Single instance")
struct SingleInstanceTests {
    let temporary = TemporaryDirectory()
    var directory: URL { temporary.url }

    @Test("The first instance takes the lock; a second for the same domain cannot")
    func exclusive() {
        let domain = "net.1x0.meters.tests.\(UUID().uuidString)"
        let first = InstanceLock(domain: domain, directory: directory)
        #expect(first != nil)
        #expect(InstanceLock(domain: domain, directory: directory) == nil)
        #expect(InstanceLock(domain: domain + ".other", directory: directory) != nil)
    }

    @Test("The lock frees when its holder goes away, as it does when a process exits")
    func releasedOnExit() {
        let domain = "net.1x0.meters.tests.\(UUID().uuidString)"
        var first = InstanceLock(domain: domain, directory: directory)
        #expect(first != nil)
        first = nil
        #expect(InstanceLock(domain: domain, directory: directory) != nil)
    }

    @Test("An isolated settings suite is its own instance domain")
    func domains() {
        #expect(
            ReopenRequest.domain(environment: ["METERS_SETTINGS_SUITE": "net.1x0.meters.checks"])
                == "net.1x0.meters.checks")
        #expect(!ReopenRequest.domain(environment: [:]).isEmpty)
    }
}
