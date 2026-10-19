import Foundation
import Synchronization
import Testing

@testable import MetersCore

/// Free space whose capacity reads are counted.
final class CountingCapacitySource: FreeSpaceSource {
    let capacityReads = Atomic(0)
    func readAvailable() -> UInt64? { 150_000_000_000 }
    func readAvailableForImportantUsage() -> UInt64? { nil }
    func readCapacity() -> UInt64? {
        capacityReads.add(1, ordering: .relaxed)
        return 2_000_000_000_000
    }
}

/// Regression tests for the Sep 28, 2026 code review.
@Suite("Code review fixes")
struct ReviewFixTests {
    let start = ContinuousClock.now

    @Test("A corrupt reading can never trap the percent conversion")
    func percentClamps() {
        #expect(MeterText.percent(1e17) == 100)
        #expect(MeterText.percent(.infinity) == 100)
        #expect(MeterText.percent(-.infinity) == 0)
        #expect(MeterText.percent(.nan) == 0)
        var battery = BatteryMeter(source: Scripted([BatteryReading(charge: 1e17, milliamps: nil)]))
        battery.sample(at: start)
        #expect(battery.percent == 100)
    }

    @Test("After a shorter interval, the next reading still counts against the old schedule's baseline")
    func shorterInterval() {
        let readings = (0...3).map { ticks(busy: UInt32($0 * 40), idle: UInt32($0 * 60)) }
        var cpu = CPUMeter(source: ScriptedTickSource(readings))
        cpu.setInterval(.seconds(5))
        cpu.rebaseline(at: start)
        cpu.sample(at: start + .seconds(5))
        // 0.5 s chosen 3 s after the last reading: the next comes 3.5 s after its baseline, over the new 1.5 s
        // limit, but within the old 15 s one.
        cpu.setInterval(.milliseconds(500))
        cpu.sample(at: start + .seconds(8) + .milliseconds(500))
        #expect(cpu.history.samples.count == 2)
        // From then on the new limit applies: a reading 2 s later starts a fresh baseline.
        cpu.sample(at: start + .seconds(10) + .milliseconds(500))
        #expect(cpu.history.samples.count == 2)

        var rates = RateMeter(
            source: ScriptedCounterSource([
                ["en0": ByteCounters(first: 0, second: 0)], ["en0": ByteCounters(first: 3_500, second: 0)],
            ]), floor: 1)
        rates.setInterval(.seconds(5))
        rates.rebaseline(at: start)
        rates.setInterval(.milliseconds(500))
        rates.sample(at: start + .seconds(3) + .milliseconds(500))
        #expect(rates.firstRate == 1_000)
    }

    @Test("Resetting states, as after sleep, returns a red row to normal until 3 new readings agree")
    func resetStates() {
        var gpu = GPUMeter(source: ScriptedGPUSource([95, 95, 95, 95, 95, 95]))
        for _ in 0..<3 { gpu.sample(at: start) }
        #expect(gpu.rows[0].state == .elevated)
        let reset = gpu.resetStates()
        #expect(reset && gpu.rows[0].state == .normal)
        gpu.sample(at: start)
        gpu.sample(at: start)
        #expect(gpu.rows[0].state == .normal)
        gpu.sample(at: start)
        #expect(gpu.rows[0].state == .elevated)
        var swap = SwapMeter(source: Scripted<UInt64>([]))
        let swapReset = swap.resetStates()
        #expect(!swapReset)
    }

    @Test("Applying thresholds reports whether a state changed, so the HUD redraws only then")
    func applyReportsChanges() {
        var gpu = GPUMeter(source: ScriptedGPUSource([95, 95, 95]))
        for _ in 0..<3 { gpu.sample(at: start) }
        var settings = ThresholdSettings()
        settings[.gpu] = ThresholdSetting(elevated: 80, critical: 90)
        let newNumbers = gpu.applyThresholds(settings)
        #expect(!newNumbers)
        settings[.gpu] = ThresholdSetting(highlight: false, elevated: 80, critical: 90)
        let switchedOff = gpu.applyThresholds(settings)
        #expect(switchedOff && gpu.rows[0].state == .normal)
        let again = gpu.applyThresholds(settings)
        #expect(!again)
        var rates = RateMeter(source: ScriptedCounterSource([]), floor: 1)
        let ratesChanged = rates.applyThresholds(settings)
        #expect(!ratesChanged)
    }

    @Test("Percent thresholds take whole numbers; gigabytes may be fractional")
    func wholeNumbers() throws {
        let cpu = try #require(ThresholdEditor.fields(.cpu))
        #expect(cpu.problem(elevated: 70.5, critical: 80) == "Enter a whole number.")
        #expect(cpu.problem(elevated: 70, critical: 80) == nil)
        #expect(try #require(ThresholdEditor.fields(.freeSpace)).problem(elevated: 9.5, critical: nil) != nil)
        #expect(try #require(ThresholdEditor.fields(.swap)).problem(elevated: 1.25, critical: nil) == nil)
    }

    @Test("Free space reads the capacity with Finder's figure, once a minute, not every reading")
    func capacityOncePerRefresh() {
        let source = CountingCapacitySource()
        var meter = FreeSpaceMeter(source: source)
        for second in 0..<59 { meter.sample(at: start + .seconds(second)) }
        #expect(source.capacityReads.load(ordering: .relaxed) == 1)
        #expect(meter.rows[0].gaugeFraction == 0.925)
        meter.sample(at: start + .seconds(60))
        #expect(source.capacityReads.load(ordering: .relaxed) == 2)
    }

    @Test("The default thresholds come from the Thresholds tab's defaults, a single table")
    func singleDefaults() {
        #expect(ThresholdDefaults.cpu == ThresholdEditor.fields(.cpu)?.rule(elevated: 70, critical: 80))
        #expect(
            SystemCapabilities(hasBattery: true, clusters: [CPUCluster(name: "Super", cores: [0])]).cpuClusters == 1)
    }
}
