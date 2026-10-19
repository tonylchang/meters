import AppKit
import MetersCore
import Testing

@testable import MetersUI

@MainActor
@Suite("Disk module")
struct DiskModuleTests {
    init() { _ = NSApplication.shared }

    @Test("Two-row form: read on top, write below, each its own VoiceOver element")
    func rows() {
        let scheduler = ManualScheduler()
        let clock = ManualClock()
        let source = ScriptedCounterSource([
            ["disk0": ByteCounters(first: 0, second: 0)],
            ["disk0": ByteCounters(first: 3_075_000, second: 205_000)],
        ])
        let module = DiskModule.disk(source: source, form: .twoRows, scheduler: scheduler, now: { clock.now })
        module.isOnScreen = { _ in true }
        #expect(module.identifier == "disk")
        #expect(module.height == 36)
        let rows = module.accessibilityElements
        #expect(rows.map { $0.accessibilityIdentifier() } == ["Disk read", "Disk write"])

        module.start()
        clock.elapsed = .milliseconds(250)
        scheduler.fire()
        #expect(module.rowModels.map(\.row.value) == ["12.3M", "820K"])
        #expect(
            rows.map { $0.accessibilityValue() as? String } == [
                "Disk read, 12.3 megabytes per second", "Disk write, 820 kilobytes per second",
            ])
    }

    @Test("One-row form: DISK with read and write as numbers, one VoiceOver element")
    func oneRow() {
        let module = DiskModule.disk(source: ScriptedCounterSource([]), scheduler: ManualScheduler())
        #expect(module.height == 18)
        #expect(module.accessibilityElements.map { $0.accessibilityIdentifier() } == ["Disk"])
    }
}
