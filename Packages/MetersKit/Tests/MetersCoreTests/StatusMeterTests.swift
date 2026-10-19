import Foundation
import Synchronization
import Testing

@testable import MetersCore

/// A source that returns scripted readings in order, then `nil`.
final class Scripted<Reading: Sendable>: Sendable {
    private let readings: Mutex<[Reading?]>
    let reads = Atomic(0)

    init(_ readings: [Reading?]) {
        self.readings = Mutex(readings)
    }

    func next() -> Reading? {
        reads.add(1, ordering: .relaxed)
        return readings.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

extension Scripted: BatterySource where Reading == BatteryReading {
    func readBattery() -> BatteryReading? { next() }
}

extension Scripted: SwapSource where Reading == UInt64 {
    func readSwapUsed() -> UInt64? { next() }
}

struct FixedThermalSource: ThermalStateSource {
    let state: ProcessInfo.ThermalState
    func readThermalState() -> ProcessInfo.ThermalState { state }
}

final class ScriptedFreeSpaceSource: FreeSpaceSource {
    let available: Scripted<UInt64>
    let important: Scripted<UInt64>

    init(available: [UInt64?], important: [UInt64?]) {
        self.available = Scripted(available)
        self.important = Scripted(important)
    }

    func readAvailable() -> UInt64? { available.next() }
    func readAvailableForImportantUsage() -> UInt64? { important.next() }
}

@Suite("Battery")
struct BatteryTests {
    let now = ContinuousClock.now

    func sampled(_ readings: [BatteryReading?]) -> BatteryMeter {
        var meter = BatteryMeter(source: Scripted(readings))
        meter.sample(at: now)
        return meter
    }

    @Test("The charge is a whole percent, clamped to 100")
    func percent() {
        #expect(sampled([BatteryReading(charge: 0.714, milliamps: nil)]).percent == 71)
        #expect(sampled([BatteryReading(charge: 0.715, milliamps: nil)]).percent == 72)
        #expect(sampled([BatteryReading(charge: 1.02, milliamps: nil)]).percent == 100)
        #expect(sampled([BatteryReading(charge: 0, milliamps: nil)]).percent == 0)
    }

    @Test("The arrow follows the measured current, with none within 100 mA of zero")
    func direction() {
        #expect(BatteryMeter.direction(milliamps: 3_911) == .charging)
        #expect(BatteryMeter.direction(milliamps: 101) == .charging)
        #expect(BatteryMeter.direction(milliamps: 100) == .steady)
        #expect(BatteryMeter.direction(milliamps: 0) == .steady)
        #expect(BatteryMeter.direction(milliamps: -100) == .steady)
        #expect(BatteryMeter.direction(milliamps: -101) == .draining)
        #expect(BatteryMeter.direction(milliamps: nil) == .steady)
    }

    @Test("The row: the percent, the arrow as its marker, no sparkline; spoken with the direction")
    func rows() {
        let draining = sampled([BatteryReading(charge: 0.71, milliamps: -2_400)]).rows
        #expect(
            draining == [
                MeterRow(
                    value: "71%", spokenValue: "71 percent, draining", samples: [], hasData: true, valueMarker: "↓",
                    offersGauge: true, gaugeFraction: 0.71)
            ])
        let charging = sampled([BatteryReading(charge: 0.71, milliamps: 2_400)]).rows[0]
        #expect(charging.valueMarker == "↑" && charging.spokenValue == "71 percent, charging")
        let full = sampled([BatteryReading(charge: 1, milliamps: 0)]).rows[0]
        #expect(full.valueMarker == nil && full.spokenValue == "100 percent")
    }

    @Test("Before the first reading, and without a battery, the row shows the placeholder")
    func placeholder() {
        let initial = BatteryMeter(source: Scripted([BatteryReading]()))
        #expect(
            initial.rows == [
                MeterRow(value: "--", spokenValue: "no data", samples: [], hasData: false, offersGauge: true)
            ])
        var meter = BatteryMeter(source: Scripted([BatteryReading(charge: 0.5, milliamps: -500), nil]))
        meter.sample(at: now)
        meter.sample(at: now + .seconds(1))
        #expect(meter.rows == initial.rows)
        #expect(sampled([BatteryReading(charge: .nan, milliamps: nil)]).rows == initial.rows)
    }

    @Test("Labels: BATT, read as Battery; No battery in Settings")
    func text() {
        #expect(BatteryModuleText.label == "BATT")
        #expect(BatteryModuleText.accessibilityLabel == "Battery")
        #expect(BatteryModuleText.noBattery == "No battery")
    }
}

@Suite("Thermal")
struct ThermalTests {
    @Test(
        "Each state reads as one word, spoken in lower case",
        arguments: [
            (ProcessInfo.ThermalState.nominal, "OK", "OK"), (.fair, "Warm", "warm"), (.serious, "Hot", "hot"),
            (.critical, "Critical", "critical"),
        ] as [(ProcessInfo.ThermalState, String, String)])
    func words(state: ProcessInfo.ThermalState, value: String, spoken: String) {
        var meter = ThermalMeter(source: FixedThermalSource(state: state))
        meter.sample(at: .now)
        #expect(meter.rows == [MeterRow(value: value, spokenValue: spoken, samples: [], hasData: true)])
    }

    @Test("Before the first reading the row shows the placeholder; labels HEAT and Thermal state")
    func placeholder() {
        let meter = ThermalMeter(source: FixedThermalSource(state: .nominal))
        #expect(meter.rows == [MeterRow(value: "--", spokenValue: "no data", samples: [], hasData: false)])
        #expect(ThermalModuleText.label == "HEAT")
        #expect(ThermalModuleText.accessibilityLabel == "Thermal state")
    }
}

@Suite("Swap")
struct SwapTests {
    @Test("Swap in use, in the shared format without a rate, spoken with used")
    func rows() {
        var meter = SwapMeter(source: Scripted<UInt64>([0, 512_000_000, 1_250_000_000, nil]))
        #expect(meter.rows == [MeterRow(value: "--", spokenValue: "no data", samples: [], hasData: false)])
        meter.sample(at: .now)
        #expect(meter.rows == [MeterRow(value: "0", spokenValue: "0 bytes used", samples: [], hasData: true)])
        meter.sample(at: .now)
        #expect(meter.rows[0].value == "512M")
        meter.sample(at: .now)
        #expect(meter.rows[0].value == "1.25G" && meter.rows[0].spokenValue == "1.25 gigabytes used")
        meter.sample(at: .now)
        #expect(meter.rows[0].value == "--")
        #expect(SwapModuleText.label == "SWP" && SwapModuleText.accessibilityLabel == "Swap")
    }
}

@Suite("Free space")
struct FreeSpaceTests {
    let start = ContinuousClock.now

    @Test("Free space in the shared format, with T for terabytes")
    func format() {
        #expect(RateFormat.amount(675_000_000_000, allowTerabytes: true) == "675G")
        #expect(RateFormat.amount(999_000_000_000, allowTerabytes: true) == "999G")
        #expect(RateFormat.amount(999_600_000_000, allowTerabytes: true) == "1.00T")
        #expect(RateFormat.amount(1_204_000_000_000, allowTerabytes: true) == "1.20T")
        #expect(RateFormat.amount(5e15, allowTerabytes: true) == "999T")
        #expect(RateFormat.amount(5e12) == "999G")
        #expect(RateFormat.spokenAmount(675_000_000_000, allowTerabytes: true) == "675 gigabytes")
        #expect(RateFormat.spokenAmount(1_204_000_000_000, allowTerabytes: true) == "1.20 terabytes")
        #expect(FreeSpaceModuleText.label == "FREE" && FreeSpaceModuleText.accessibilityLabel == "Free space")
    }

    @Test("Finder's figure sets the purgeable share once a minute; df's figure follows each second (Behavior Details)")
    func purgeableRefresh() {
        let source = ScriptedFreeSpaceSource(
            available: [600_000_000_000, 599_000_000_000, 598_000_000_000, 598_000_000_000],
            important: [675_000_000_000, 700_000_000_000])
        var meter = FreeSpaceMeter(source: source)
        #expect(meter.rows[0].value == "--")
        meter.sample(at: start)
        #expect(meter.bytes == 675_000_000_000)
        // A 1 GB write shows at once, without reading Finder's figure again.
        meter.sample(at: start + .seconds(1))
        #expect(meter.bytes == 674_000_000_000)
        meter.sample(at: start + .seconds(59))
        #expect(source.important.reads.load(ordering: .relaxed) == 1)
        meter.sample(at: start + .seconds(60))
        #expect(source.important.reads.load(ordering: .relaxed) == 2)
        #expect(meter.bytes == 700_000_000_000)
        // No capacity from this source, so the gauge shows only its track.
        #expect(
            meter.rows == [
                MeterRow(value: "700G", spokenValue: "700 gigabytes", samples: [], hasData: true, offersGauge: true)
            ])
    }

    @Test("Never below df's figure; a failed Finder read is retried a minute later, not every second")
    func failedImportantRead() {
        let source = ScriptedFreeSpaceSource(
            available: [600_000_000_000, 600_000_000_000, 600_000_000_000, nil],
            important: [nil, 500_000_000_000])
        var meter = FreeSpaceMeter(source: source)
        meter.sample(at: start)
        #expect(meter.bytes == 600_000_000_000)
        meter.sample(at: start + .seconds(1))
        #expect(source.important.reads.load(ordering: .relaxed) == 1)
        meter.sample(at: start + .seconds(60))
        #expect(meter.bytes == 600_000_000_000)
        meter.sample(at: start + .seconds(61))
        #expect(meter.rows[0].value == "--" && meter.rows[0].spokenValue == "no data")
    }
}
