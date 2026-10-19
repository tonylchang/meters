import AppKit
import MetersCore
import SwiftUI
import Synchronization
import Testing

@testable import MetersUI

final class ScriptedTickSource: CPUTickSource {
    private let readings: Mutex<[CPUTicks?]>

    init(_ readings: [CPUTicks?]) {
        self.readings = Mutex(readings)
    }

    func readTicks() -> CPUTicks? {
        readings.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

@MainActor
final class ManualScheduler: SampleScheduling {
    private(set) var delay: Duration?
    private(set) var interval: Duration?
    private var tick: (@MainActor @Sendable () -> Void)?

    func schedule(
        after delay: Duration, every interval: Duration, _ tick: @escaping @MainActor @Sendable () -> Void
    ) -> any SampleSchedule {
        self.delay = delay
        self.interval = interval
        self.tick = tick
        return ManualSchedule()
    }

    func fire() { tick?() }
}

@MainActor
final class ManualSchedule: SampleSchedule {
    func cancel() {}
}

@MainActor
final class ManualClock {
    let start = ContinuousClock.now
    var elapsed: Duration = .zero
    var now: ContinuousClock.Instant { start + elapsed }
}

@MainActor
@Suite("CPU module")
struct CPUModuleTests {
    let scheduler = ManualScheduler()
    let clock = ManualClock()

    init() { _ = NSApplication.shared }

    func makeModule(_ readings: [CPUTicks?]) -> CPUModule {
        let clock = self.clock
        let module = CPUModule(source: ScriptedTickSource(readings), scheduler: scheduler, now: { clock.now })
        module.isOnScreen = { _ in true }
        return module
    }

    func advance(_ duration: Duration) {
        clock.elapsed += duration
        scheduler.fire()
    }

    func busy(_ busy: UInt32, idle: UInt32) -> CPUTicks {
        CPUTicks(user: busy, system: 0, idle: idle, nice: 0)
    }

    @Test("Sampling starts 0.25 s after launch and repeats every 1 s")
    func cadence() {
        let module = makeModule([busy(0, idle: 0)])
        module.start()
        #expect(scheduler.delay == .milliseconds(250))
        #expect(scheduler.interval == .seconds(1))
    }

    @Test("A fixed 18 pt row, in a fixed module slot")
    func fixedHeight() {
        let module = makeModule([])
        #expect(module.height == 18)
        #expect(module.identifier == "cpu")
    }

    @Test("Shows the placeholder, then values; a failed read shows the placeholder and a gap")
    func renderedStates() {
        let module = makeModule([busy(0, idle: 0), busy(23, idle: 77), nil, busy(123, idle: 77)])
        let row = module.rowModels[0]
        #expect(row.row.value == "--")
        module.start()
        advance(.milliseconds(250))
        #expect(row.row.value == "23%")
        advance(.seconds(1))
        #expect(row.row.value == "--")
        advance(.seconds(1))
        #expect(row.row.value == "100%")
        #expect(row.row.samples == [0.23, nil, 1])
    }

    @Test("Sampling continues while hidden; the view catches up when shown (Behavior Details)")
    func samplingWhileHidden() {
        let module = makeModule([busy(0, idle: 0), busy(10, idle: 90), busy(60, idle: 140)])
        module.start()
        module.isOnScreen = { _ in false }
        advance(.milliseconds(250))
        advance(.seconds(1))
        #expect(module.rowModels[0].row.value == "--")
        #expect(module.meter.history.samples == [0.1, 0.5])

        module.isOnScreen = { _ in true }
        module.render()
        #expect(module.rowModels[0].row.value == "50%")
        #expect(module.rowModels[0].row.samples == [0.1, 0.5])
    }

    @Test("VoiceOver reads the row as one element: CPU, then the percent or no data")
    func accessibility() {
        let module = makeModule([busy(0, idle: 0), busy(23, idle: 77)])
        #expect(module.accessibilityElements.count == 1)
        let view = module.accessibilityElements[0]
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .staticText)
        // One phrase, name first, with no separate label: VoiceOver reads a label after the value.
        #expect(view.accessibilityLabel() == nil && view.accessibilityIdentifier() == "CPU")
        #expect(view.accessibilityValue() as? String == "CPU, no data")
        #expect(view.accessibilityChildren()?.isEmpty == true)
        #expect(view.accessibilityHitTest(.zero) as? NSView === view)
        module.start()
        advance(.milliseconds(250))
        #expect(view.accessibilityValue() as? String == "CPU, 23 percent")
    }

    @Test("VoiceOver is told each time the spoken value changes, and only then")
    func announcesValueChanges() {
        let module = makeModule([busy(0, idle: 0), busy(23, idle: 77), busy(46, idle: 154), busy(146, idle: 154), nil])
        var announced: [String] = []
        module.announceValueChange = { view in announced.append(view.accessibilityValue() as? String ?? "") }
        module.start()
        advance(.milliseconds(250))
        advance(.seconds(1))
        #expect(announced == ["CPU, 23 percent"])
        advance(.seconds(1))
        advance(.seconds(1))
        #expect(announced == ["CPU, 23 percent", "CPU, 100 percent", "CPU, no data"])
    }
}

@MainActor
@Suite("CPU module clusters")
struct CPUClusterModuleTests {
    let scheduler = ManualScheduler()
    let clusters = [CPUCluster(name: "Super", cores: nil), CPUCluster(name: "Performance", cores: nil)]

    init() { _ = NSApplication.shared }

    @Test("Total and clusters: three 18 pt rows, marked S and P, read as CPU Super and CPU Performance")
    func clustersForm() {
        let module = CPUModule(
            source: ScriptedTickSource([]), form: .clusters, clusters: clusters, scheduler: scheduler)
        #expect(module.height == 54)
        #expect(
            module.accessibilityElements.map { $0.accessibilityIdentifier() } == [
                "CPU", "CPU Super", "CPU Performance",
            ])
        #expect(
            module.accessibilityElements.map { $0.accessibilityValue() as? String } == [
                "CPU, no data", "CPU Super, unavailable", "CPU Performance, unavailable",
            ])
        let labels = MeterModule<CPUMeter>.cpuLabels(form: .clusters, clusters: clusters)
        #expect(labels.map(\.label) == ["CPU", nil, nil])
        #expect(labels.map(\.marker) == [nil, "S", "P"])
    }

    @Test("Switching form resizes the module in place and tells the HUD")
    func formSwitch() {
        let module = CPUModule(source: ScriptedTickSource([]), clusters: clusters, scheduler: scheduler)
        var sizeChanges = 0
        module.onSizeChange = { sizeChanges += 1 }
        #expect(module.height == 18)
        module.setForm(.clusters)
        #expect(module.height == 54 && sizeChanges == 1)
        module.setForm(.clusters)
        #expect(sizeChanges == 1)
        module.setForm(.total)
        #expect(module.height == 18 && module.accessibilityElements.count == 1)
    }
}
