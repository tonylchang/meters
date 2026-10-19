import AppKit
import MetersCore
import Synchronization
import Testing

@testable import MetersUI

/// Returns scripted counter readings in order, then `nil`.
final class ScriptedCounterSource: ByteCounterSource {
    private let readings: Mutex<[[String: ByteCounters]?]>

    init(_ readings: [[String: ByteCounters]?]) {
        self.readings = Mutex(readings)
    }

    func readCounters() -> [String: ByteCounters]? {
        readings.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

@MainActor
@Suite("Network module")
struct NetworkModuleTests {
    let scheduler = ManualScheduler()
    let clock = ManualClock()

    init() { _ = NSApplication.shared }

    func makeModule() -> NetworkModule {
        let clock = self.clock
        let source = ScriptedCounterSource([
            ["en0": ByteCounters(first: 0, second: 0)],
            ["en0": ByteCounters(first: 312_500, second: 11_250)],
        ])
        let module = NetworkModule.network(source: source, form: .twoRows, scheduler: scheduler, now: { clock.now })
        module.isOnScreen = { _ in true }
        return module
    }

    @Test("Two-row form: download on top, upload below, each its own VoiceOver element")
    func rows() {
        let module = makeModule()
        #expect(module.identifier == "network")
        #expect(module.height == 36)
        let rows = module.accessibilityElements
        #expect(rows.map { $0.accessibilityIdentifier() } == ["Network download", "Network upload"])
        #expect(
            rows.map { $0.accessibilityValue() as? String } == ["Network download, no data", "Network upload, no data"])

        module.start()
        clock.elapsed = .milliseconds(250)
        scheduler.fire()
        #expect(module.rowModels.map(\.row.value) == ["1.25M", "45.0K"])
        #expect(
            rows.map { $0.accessibilityValue() as? String } == [
                "Network download, 1.25 megabytes per second", "Network upload, 45.0 kilobytes per second",
            ])

        module.view.frame = CGRect(x: 0, y: 0, width: 204, height: 36)
        module.view.layout()
        #expect(rows[0].frame == CGRect(x: 0, y: 0, width: 204, height: 18))
        #expect(rows[1].frame == CGRect(x: 0, y: 18, width: 204, height: 18))
    }

    @Test("VoiceOver's pointer reaches the row under it")
    func pointer() {
        let module = makeModule()
        let panel = HUDPanel()
        let container = HUDContainerView(frame: .zero)
        panel.contentView = container
        panel.setFrame(CGRect(x: 100, y: 100, width: 220, height: 52), display: false)
        container.setModules([module], visibleCount: 1)
        container.layout()
        module.view.layout()
        // Screen coordinates rise upward: download is 8 to 26 pt below the top, upload 26 to 44.
        let rows = module.accessibilityElements
        #expect(container.accessibilityHitTest(CGPoint(x: 150, y: 152 - 17)) as? NSView === rows[0])
        #expect(container.accessibilityHitTest(CGPoint(x: 150, y: 152 - 35)) as? NSView === rows[1])
        #expect(container.accessibilityChildren() as? [NSView] == rows)
    }

    @Test("One-row form: NET with both rates as numbers and no sparkline, one VoiceOver element")
    func oneRow() {
        let clock = self.clock
        let source = ScriptedCounterSource([
            ["en0": ByteCounters(first: 0, second: 0)],
            ["en0": ByteCounters(first: 312_500, second: 11_250)],
        ])
        let module = NetworkModule.network(source: source, scheduler: scheduler, now: { clock.now })
        module.isOnScreen = { _ in true }
        #expect(module.height == 18)
        let rows = module.accessibilityElements
        #expect(rows.map { $0.accessibilityIdentifier() } == ["Network"])
        module.start()
        clock.elapsed = .milliseconds(250)
        scheduler.fire()
        #expect(module.rowModels[0].row.value == "1.25M")
        #expect(module.rowModels[0].row.secondValue == "45.0K")
        #expect(module.rowModels[0].row.samples.isEmpty)
        #expect(
            rows[0].accessibilityValue() as? String
                == "Network, download 1.25 megabytes per second, upload 45.0 kilobytes per second")
    }
}
