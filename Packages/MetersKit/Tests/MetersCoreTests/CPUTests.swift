import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import MetersCore

/// A source that returns scripted readings in order; `nil` entries simulate failed reads.
final class ScriptedTickSource: CPUTickSource {
    private let readings: Mutex<[CPUTicks?]>

    init(_ readings: [CPUTicks?]) {
        self.readings = Mutex(readings)
    }

    func readTicks() -> CPUTicks? {
        readings.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

func ticks(busy: UInt32, idle: UInt32) -> CPUTicks {
    CPUTicks(user: busy, system: 0, idle: idle, nice: 0)
}

@Suite("CPU utilization")
struct CPUUtilizationTests {
    @Test("Busy share counts user, system, and nice time against idle")
    func busyShare() throws {
        let old = CPUTicks(user: 100, system: 100, idle: 100, nice: 100)
        let new = CPUTicks(user: 110, system: 105, idle: 180, nice: 105)
        #expect(try #require(CPUUtilization.fraction(from: old, to: new)) == 0.2)
    }

    @Test("A wrapped counter still yields the right share")
    func wraparound() throws {
        let old = CPUTicks(user: UInt32.max - 9, system: 0, idle: UInt32.max - 29, nice: 0)
        let new = CPUTicks(user: 10, system: 0, idle: 30, nice: 0)
        #expect(try #require(CPUUtilization.fraction(from: old, to: new)) == 0.25)
    }

    @Test("A counter that went backwards, or no elapsed time, gives no value")
    func invalidReadings() {
        #expect(CPUUtilization.fraction(from: ticks(busy: 100, idle: 100), to: ticks(busy: 90, idle: 120)) == nil)
        #expect(CPUUtilization.fraction(from: ticks(busy: 100, idle: 100), to: ticks(busy: 100, idle: 100)) == nil)
    }

    @Test("Percent is a whole number from 0 to 100")
    func percent() {
        #expect(CPUUtilization.percent(0) == 0)
        #expect(CPUUtilization.percent(0.225) == 23)
        #expect(CPUUtilization.percent(0.994) == 99)
        #expect(CPUUtilization.percent(1) == 100)
        #expect(CPUUtilization.percent(1.2) == 100)
        #expect(CPUUtilization.percent(-0.1) == 0)
    }
}

@Suite("Sample history")
struct SampleHistoryTests {
    @Test("Keeps the newest 60 samples, oldest first, including gaps")
    func boundedHistory() {
        var history = SampleHistory(capacity: CPUMeter.historyCapacity)
        for index in 0..<75 { history.append(index == 70 ? nil : Double(index)) }
        #expect(history.samples.count == 60)
        #expect(history.samples.first == 15)
        #expect(history.samples.last == 74)
        #expect(history.samples[55] == nil)
    }
}

@Suite("CPU meter")
struct CPUMeterTests {
    let start = ContinuousClock.now

    @Test("Timing: first reading 0.25 s after the baseline, then every 1 s")
    func timing() {
        #expect(CPUMeter.primingDelay == .milliseconds(250))
        #expect(CPUMeter.interval == .seconds(1))
        #expect(CPUMeter.historyCapacity == 60)
    }

    @Test("Before the first reading there is no value and no history")
    func initialState() {
        var meter = CPUMeter(source: ScriptedTickSource([ticks(busy: 0, idle: 0)]))
        #expect(meter.percent == nil)
        meter.rebaseline(at: start)
        #expect(meter.percent == nil)
        #expect(meter.history.samples.isEmpty)
    }

    @Test("Each reading measures against the previous one")
    func consecutiveReadings() {
        let source = ScriptedTickSource([
            ticks(busy: 0, idle: 0), ticks(busy: 25, idle: 75), ticks(busy: 125, idle: 75),
        ])
        var meter = CPUMeter(source: source)
        meter.rebaseline(at: start)
        meter.sample(at: start + .milliseconds(250))
        #expect(meter.percent == 25)
        meter.sample(at: start + .milliseconds(1250))
        #expect(meter.percent == 100)
        #expect(meter.history.samples == [0.25, 1])
    }

    @Test("A failed read shows the placeholder and leaves a gap; the next reading resumes")
    func failedRead() {
        let source = ScriptedTickSource([
            ticks(busy: 0, idle: 0), ticks(busy: 50, idle: 50), nil, ticks(busy: 60, idle: 140),
        ])
        var meter = CPUMeter(source: source)
        meter.rebaseline(at: start)
        meter.sample(at: start + .seconds(1))
        meter.sample(at: start + .seconds(2))
        #expect(meter.percent == nil)
        meter.sample(at: start + .seconds(3))
        #expect(meter.percent == 10)
        #expect(meter.history.samples == [0.5, nil, 0.1])
    }

    @Test("A reading long after its baseline, as after sleep, starts a fresh baseline instead (edge case)")
    func staleBaseline() {
        let source = ScriptedTickSource([
            ticks(busy: 0, idle: 0), ticks(busy: 50, idle: 50), ticks(busy: 5000, idle: 50),
            ticks(busy: 5010, idle: 140),
        ])
        var meter = CPUMeter(source: source)
        meter.rebaseline(at: start)
        meter.sample(at: start + .seconds(1))
        meter.sample(at: start + .seconds(3600))
        #expect(meter.percent == 50)
        #expect(meter.history.samples == [0.5])
        meter.sample(at: start + .seconds(3601))
        #expect(meter.percent == 10)
    }

    @Test("Rebaselining on wake discards the time since the last reading (edge case)")
    func rebaselineOnWake() {
        let source = ScriptedTickSource([
            ticks(busy: 0, idle: 0), ticks(busy: 900, idle: 100), ticks(busy: 910, idle: 190),
        ])
        var meter = CPUMeter(source: source)
        meter.rebaseline(at: start)
        meter.rebaseline(at: start + .milliseconds(500))
        meter.sample(at: start + .milliseconds(1500))
        #expect(meter.percent == 10)
    }

    @Test("Placeholder, value, and spoken text")
    func text() {
        #expect(CPUModuleText.label == "CPU")
        #expect(CPUModuleText.value(nil) == "--")
        #expect(CPUModuleText.value(23) == "23%")
        #expect(CPUModuleText.value(100) == "100%")
        #expect(CPUModuleText.accessibilityValue(23) == "23 percent")
        #expect(CPUModuleText.accessibilityValue(nil) == "no data")
    }
}

@Suite("Sparkline geometry")
struct SparklineGeometryTests {
    let size = CGSize(width: 120, height: 12)

    @Test("Samples fill from the right on a fixed 0 to 100% scale")
    func rightAlignedFixedScale() throws {
        let polygon = try #require(SparklineGeometry.areas(samples: [0.5, 1], capacity: 60, size: size).first)
        // 60 slots of 2 pt: the two samples occupy the last two slots, x 116 to 120.
        #expect(polygon.first == CGPoint(x: 116, y: 12))
        #expect(polygon.last == CGPoint(x: 120, y: 12))
        #expect(polygon.contains(CGPoint(x: 117, y: 6)))
        #expect(polygon.contains(CGPoint(x: 119, y: 0)))
        #expect(polygon.map(\.y).allSatisfy { (0...12).contains($0) })
    }

    @Test("A gap splits the area into separate shapes")
    func gapsSplitRuns() {
        let polygons = SparklineGeometry.areas(samples: [0.2, 0.4, nil, 0.6], capacity: 60, size: size)
        #expect(polygons.count == 2)
        #expect(SparklineGeometry.areas(samples: [nil, nil], capacity: 60, size: size).isEmpty)
    }

    @Test("Only the newest 60 samples are drawn, whatever the width", arguments: [144.0, 204.0, 284.0])
    func capacityAtEveryWidth(width: Double) throws {
        let samples = (0..<70).map { Double($0) / 70 }
        let polygon = try #require(
            SparklineGeometry.areas(samples: samples, capacity: 60, size: CGSize(width: width, height: 12)).first)
        #expect(polygon.first?.x == 0)
        #expect(polygon.last?.x == CGFloat(width))
        #expect(polygon.count == 60 + 4)
    }
}
