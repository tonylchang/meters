import Foundation
import Synchronization
import Testing

@testable import MetersCore

final class ScriptedGPUSource: GPUUtilizationSource {
    private let readings: Mutex<[Double?]>

    init(_ readings: [Double?]) {
        self.readings = Mutex(readings)
    }

    func readUtilization() -> Double? {
        readings.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

@Suite("GPU")
struct GPUTests {
    @Test("Before the first sample the row shows the placeholder")
    func initialState() {
        let meter = GPUMeter(source: ScriptedGPUSource([]))
        #expect(
            meter.rows == [
                MeterRow(value: "--", spokenValue: "no data", samples: [], hasData: false, offersGauge: true)
            ])
    }

    @Test("Readings show as a whole percent; readable numbers outside 0 to 100 are clamped")
    func readings() {
        var meter = GPUMeter(source: ScriptedGPUSource([42.4, 120, -5]))
        meter.sample(at: .now)
        #expect(
            meter.rows == [
                MeterRow(
                    value: "42%", spokenValue: "42 percent", samples: [0.424], hasData: true, offersGauge: true,
                    gaugeFraction: 0.42)
            ])
        meter.sample(at: .now)
        #expect(meter.percent == 100)
        meter.sample(at: .now)
        #expect(meter.percent == 0)
        #expect(meter.history.samples == [0.424, 1, 0])
    }

    @Test("A missing or unreadable figure shows n/a and a gap; readings resume when it returns")
    func unavailable() {
        var meter = GPUMeter(source: ScriptedGPUSource([nil, .nan, 30]))
        meter.sample(at: .now)
        #expect(
            meter.rows == [
                MeterRow(
                    value: "n/a", spokenValue: "unavailable", samples: [nil], hasData: false, isUnavailable: true,
                    offersGauge: true)
            ])
        meter.sample(at: .now)
        #expect(meter.isUnavailable)
        meter.sample(at: .now)
        #expect(
            meter.rows == [
                MeterRow(
                    value: "30%", spokenValue: "30 percent", samples: [nil, nil, 0.3], hasData: true, offersGauge: true,
                    gaugeFraction: 0.3)
            ])
    }

    @Test("The history keeps the last 60 samples")
    func history() {
        var meter = GPUMeter(source: ScriptedGPUSource(Array(repeating: 50, count: 61)))
        for _ in 1...61 { meter.sample(at: .now) }
        #expect(meter.history.samples.count == 60)
    }

    @Test("The row is labeled GPU")
    func text() {
        #expect(GPUModuleText.label == "GPU")
        #expect(GPUModuleText.unavailable == "n/a")
        #expect(GPUModuleText.spokenUnavailable == "unavailable")
    }

    @Test("This Mac's GPU reports a figure from 0 to 100", .physicalMacOnly)
    func systemSource() throws {
        let utilization = try #require(SystemSources.gpu().readUtilization())
        #expect((0...100).contains(utilization))
    }
}
