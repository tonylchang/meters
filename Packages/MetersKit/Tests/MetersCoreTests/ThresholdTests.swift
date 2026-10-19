import Foundation
import Synchronization
import Testing

@testable import MetersCore

extension Scripted: MemoryPressureSource where Reading == MemoryPressure {
    func readPressure() -> MemoryPressure? { next() }
}

extension Scripted: ThermalStateSource where Reading == ProcessInfo.ThermalState {
    func readThermalState() -> ProcessInfo.ThermalState { next() ?? .nominal }
}

/// Free space with a fixed capacity; Finder's figure equals `df`'s, so the value is exactly `available`.
final class CapacityFreeSpaceSource: FreeSpaceSource {
    let available: Scripted<UInt64>
    let capacity: UInt64?

    init(capacity: UInt64?, available: [UInt64?]) {
        self.capacity = capacity
        self.available = Scripted(available)
    }

    func readAvailable() -> UInt64? { available.next() }
    func readAvailableForImportantUsage() -> UInt64? { nil }
    func readCapacity() -> UInt64? { capacity }
}

@Suite("Threshold states")
struct ThresholdTests {
    let now = ContinuousClock.now

    func sustained(_ readings: [ThresholdState?]) -> [ThresholdState] {
        var tracker = SustainedState()
        return readings.map {
            tracker.record($0)
            return tracker.state
        }
    }

    @Test("A state begins only after 3 readings meet it, and ends only after 3 fall short of it")
    func threeReadings() {
        let n = ThresholdState.normal
        let e = ThresholdState.elevated
        let c = ThresholdState.critical
        #expect(sustained([e, e, e]) == [n, n, e])
        // A 2-reading spike never changes the row.
        #expect(sustained([n, e, e, n, c, c, n]) == [n, n, n, n, n, n, n])
        // Leaving takes 3 readings below the current state; a dip of 2 does not.
        #expect(sustained([e, e, e, n, n, e, n, n, n]) == [n, n, e, e, e, e, e, e, n])
        // A jump across both thresholds goes straight to critical (Edge Cases).
        #expect(sustained([n, c, c, c]) == [n, n, n, c])
        // From critical, 3 readings that are only elevated step down to elevated.
        #expect(sustained([c, c, c, e, e, e, n, n, n]) == [n, n, c, c, c, e, e, e, n])
    }

    @Test("A missing reading is normal and starts the count over")
    func gaps() {
        let e = ThresholdState.elevated
        #expect(sustained([e, e, e, nil, e, e, e]) == [.normal, .normal, e, .normal, .normal, .normal, e])
        #expect(sustained([e, e, nil, e, e]) == [.normal, .normal, .normal, .normal, .normal])
    }

    @Test(
        "CPU: 70% to 80% elevated, above 80% critical",
        arguments: [(69.0, ThresholdState.normal), (70, .elevated), (80, .elevated), (81, .critical), (100, .critical)])
    func cpu(value: Double, expected: ThresholdState) {
        #expect(ThresholdDefaults.cpu.state(for: value) == expected)
    }

    @Test(
        "GPU: 90% or more elevated, never critical",
        arguments: [(89.0, ThresholdState.normal), (90, .elevated), (100, .elevated)])
    func gpu(value: Double, expected: ThresholdState) {
        #expect(ThresholdDefaults.gpu.state(for: value) == expected)
    }

    @Test(
        "Battery: 20% or below elevated, 10% or below critical",
        arguments: [(21.0, ThresholdState.normal), (20, .elevated), (11, .elevated), (10, .critical), (0, .critical)])
    func battery(value: Double, expected: ThresholdState) {
        #expect(ThresholdDefaults.battery.state(for: value) == expected)
    }

    @Test(
        "Swap, as displayed: over 1 GB elevated, over 8 GB critical; 1.00G is not over 1 GB",
        arguments: [
            (999_000_000.0, ThresholdState.normal), (1_004_000_000, .normal), (1_006_000_000, .elevated),
            (8_004_000_000, .elevated), (8_050_000_000, .critical),
        ])
    func swap(bytes: Double, expected: ThresholdState) {
        #expect(ThresholdDefaults.swap.state(for: RateFormat.displayedAmount(bytes)) == expected)
    }

    @Test(
        "Free space: under 10% of capacity elevated, under 5% critical; exactly 10% is not under",
        arguments: [(10.0, ThresholdState.normal), (9.99, .elevated), (5, .elevated), (4.99, .critical)])
    func freeSpace(percent: Double, expected: ThresholdState) {
        #expect(ThresholdDefaults.freeSpace.state(for: percent) == expected)
    }

    @Test("Displayed amounts round like the row: 3 significant digits in K, M, G, or T")
    func displayedAmount() {
        #expect(RateFormat.displayedAmount(1_004_000_000) == 1e9)
        #expect(RateFormat.displayedAmount(1_006_000_000) == 1.01e9)
        #expect(RateFormat.displayedAmount(820) == 820)
        #expect(RateFormat.displayedAmount(1_204_000_000_000, allowTerabytes: true) == 1.2e12)
    }

    @Test("VoiceOver hears the state after the value")
    func spoken() {
        #expect(ThresholdState.normal.spokenSuffix == "")
        #expect(ThresholdState.elevated.spokenSuffix == ", elevated")
        #expect(ThresholdState.critical.spokenSuffix == ", critical")
    }

    // MARK: - Meters

    func sampleCPU(_ meter: inout CPUMeter, seconds: Int) {
        for second in 1...seconds { meter.sample(at: now + .seconds(second)) }
    }

    @Test("CPU total and cluster rows take states from their own percents; off with no threshold")
    func cpuMeter() {
        // Each reading adds 100 ticks per core: cores 0 and 1 (Performance) 60 busy, cores 2 and 3 (Super) 90.
        let readings: [[CPUTicks]?] = (0...4).map { step in
            let t = UInt32(step * 100)
            return [
                ticks(busy: t * 6 / 10, idle: t * 4 / 10), ticks(busy: t * 6 / 10, idle: t * 4 / 10),
                ticks(busy: t * 9 / 10, idle: t / 10), ticks(busy: t * 9 / 10, idle: t / 10),
            ]
        }
        let clusters = [CPUCluster(name: "Super", cores: [2, 3]), CPUCluster(name: "Performance", cores: [0, 1])]
        var meter = CPUMeter(source: ScriptedCoreTickSource(readings), form: .clusters, clusters: clusters)
        meter.rebaseline(at: now)
        sampleCPU(&meter, seconds: 3)
        #expect(meter.rows.map(\.value) == ["75%", "90%", "60%"])
        #expect(meter.rows.map(\.state) == [.elevated, .critical, .normal])
        // Switching form keeps the cluster states (Edge Cases).
        meter.form = .total
        meter.form = .clusters
        #expect(meter.rows[1].state == .critical)

        var off = CPUMeter(source: ScriptedCoreTickSource(readings), clusters: clusters)
        var settings = ThresholdSettings()
        settings[.cpu] = ThresholdSetting(highlight: false, elevated: 70, critical: 80)
        off.applyThresholds(settings)
        off.rebaseline(at: now)
        sampleCPU(&off, seconds: 3)
        #expect(off.rows[0].state == .normal)
    }

    @Test("GPU: saturated is elevated; n/a is normal and starts over")
    func gpuMeter() {
        var meter = GPUMeter(source: ScriptedGPUSource([95, 99, 100, nil, 100, 100]))
        for _ in 0..<3 { meter.sample(at: now) }
        #expect(meter.rows[0].state == .elevated)
        meter.sample(at: now)
        #expect(meter.rows[0].state == .normal && meter.rows[0].value == "n/a")
        meter.sample(at: now)
        meter.sample(at: now)
        #expect(meter.rows[0].state == .normal)
    }

    @Test("Memory follows memory pressure, not the percent; unreadable or switched off stays normal")
    func memoryMeter() {
        let page = MemoryPages(anonymous: 3600, purgeable: 0, wired: 0, compressed: 0)
        let source = ScriptedMemorySource(Array(repeating: page, count: 9))
        var meter = MemoryMeter(
            source: source,
            pressure: Scripted<MemoryPressure>([.warning, .warning, .warning, .critical, .critical, .critical, nil]))
        for _ in 0..<3 { meter.sample(at: now) }
        #expect(meter.rows[0].value == "90%" && meter.rows[0].state == .elevated)
        for _ in 0..<3 { meter.sample(at: now) }
        #expect(meter.rows[0].state == .critical)

        var normal = MemoryMeter(source: ScriptedMemorySource(Array(repeating: page, count: 3)))
        for _ in 0..<3 { normal.sample(at: now) }
        #expect(normal.rows[0].value == "90%" && normal.rows[0].state == .normal)

        var off = MemoryMeter(
            source: ScriptedMemorySource(Array(repeating: page, count: 3)),
            pressure: Scripted<MemoryPressure>([.critical, .critical, .critical]))
        var settings = ThresholdSettings()
        settings[.memory] = ThresholdSetting(highlight: false)
        off.applyThresholds(settings)
        for _ in 0..<3 { off.sample(at: now) }
        #expect(off.rows[0].state == .normal)
    }

    @Test("Battery: low charge counts only while draining")
    func batteryMeter() {
        let draining = BatteryReading(charge: 0.15, milliamps: -2_000)
        let charging = BatteryReading(charge: 0.15, milliamps: 2_000)
        let low = BatteryReading(charge: 0.08, milliamps: -2_000)
        var meter = BatteryMeter(
            source: Scripted([draining, draining, draining, charging, charging, charging, low, low, low]))
        for _ in 0..<3 { meter.sample(at: now) }
        #expect(meter.rows[0].state == .elevated)
        for _ in 0..<3 { meter.sample(at: now) }
        #expect(meter.rows[0].state == .normal)
        for _ in 0..<3 { meter.sample(at: now) }
        #expect(meter.rows[0].state == .critical)
    }

    @Test("Thermal: Hot is elevated, Critical critical, OK and Warm normal")
    func thermalMeter() {
        #expect(ThermalMeter.state(for: .nominal) == .normal)
        #expect(ThermalMeter.state(for: .fair) == .normal)
        #expect(ThermalMeter.state(for: .serious) == .elevated)
        #expect(ThermalMeter.state(for: .critical) == .critical)
        var meter = ThermalMeter(source: Scripted<ProcessInfo.ThermalState>([.serious, .serious, .serious]))
        for _ in 0..<3 { meter.sample(at: now) }
        #expect(meter.rows[0].value == "Hot" && meter.rows[0].state == .elevated)
    }

    @Test("Swap and Free space take states from their displayed amounts")
    func amounts() {
        var swap = SwapMeter(source: Scripted<UInt64>([1_500_000_000, 1_500_000_000, 1_500_000_000]))
        for _ in 0..<3 { swap.sample(at: .now) }
        #expect(swap.rows[0].state == .elevated)

        let source = CapacityFreeSpaceSource(
            capacity: 2_000_000_000_000, available: Array(repeating: 150_000_000_000, count: 3) + [80_000_000_000])
        var free = FreeSpaceMeter(source: source)
        for second in 0..<3 { free.sample(at: now + .seconds(second)) }
        #expect(free.rows[0].value == "150G" && free.rows[0].state == .elevated)
        free.sample(at: now + .seconds(3))
        #expect(free.rows[0].state == .elevated)

        let noCapacity = CapacityFreeSpaceSource(capacity: nil, available: Array(repeating: 1_000_000, count: 3))
        var unknown = FreeSpaceMeter(source: noCapacity)
        for second in 0..<3 { unknown.sample(at: now + .seconds(second)) }
        #expect(unknown.rows[0].state == .normal)
    }
}
