import Foundation
import Synchronization
import Testing

@testable import MetersCore

final class ScriptedCounterSource: ByteCounterSource {
    private let readings: Mutex<[[String: ByteCounters]?]>

    init(_ readings: [[String: ByteCounters]?]) {
        self.readings = Mutex(readings)
    }

    func readCounters() -> [String: ByteCounters]? {
        readings.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

@Suite("Rates")
struct RateTests {
    @Test(
        "Rates show in bytes per second with 3 significant digits and K, M, or G (shared rate format)",
        arguments: [
            (0.0, "0"), (0.4, "0"), (820, "820"), (999, "999"), (999.6, "1.00K"), (1000, "1.00K"),
            (12_345, "12.3K"), (99_949, "99.9K"), (99_951, "100K"), (123_456, "123K"), (999_499, "999K"),
            (999_600, "1.00M"), (1_250_000, "1.25M"), (12_300_000, "12.3M"), (123_000_000, "123M"),
            (1_250_000_000, "1.25G"), (999_000_000_000, "999G"), (5e12, "999G"), (-5, "0"), (.nan, "0"),
        ] as [(Double, String)])
    func format(rate: Double, expected: String) {
        #expect(RateFormat.value(rate) == expected)
    }

    @Test("VoiceOver hears the displayed number with the unit spelled out (shared spoken rates)")
    func spoken() {
        #expect(RateFormat.spoken(0) == "0 bytes per second")
        #expect(RateFormat.spoken(1) == "1 byte per second")
        #expect(RateFormat.spoken(820) == "820 bytes per second")
        #expect(RateFormat.spoken(12_345) == "12.3 kilobytes per second")
        #expect(RateFormat.spoken(1_250_000) == "1.25 megabytes per second")
        #expect(RateFormat.spoken(1_250_000_000) == "1.25 gigabytes per second")
    }

    @Test("Sparklines scale to the highest recent rate, never below the floor (shared rate sparklines)")
    func sparkline() {
        #expect(RateSparkline.normalized([0, 50_000, nil], floor: 100_000) == [0, 0.5, nil])
        #expect(RateSparkline.normalized([100_000, 400_000], floor: 100_000) == [0.25, 1])
        #expect(RateSparkline.normalized([], floor: 100_000) == [])
    }

    func counters(_ items: [String: (UInt64, UInt64)]) -> [String: ByteCounters] {
        items.mapValues { ByteCounters(first: $0.0, second: $0.1) }
    }

    @Test("Rates are the bytes moved since the previous reading, divided by the time between them")
    func rates() {
        let start = ContinuousClock.now
        let source = ScriptedCounterSource([
            counters(["en0": (1_000, 500)]),
            counters(["en0": (1_251_000, 45_500)]),
        ])
        var meter = RateMeter(source: source, floor: 100_000)
        meter.rebaseline(at: start)
        meter.sample(at: start + .seconds(1))
        #expect(meter.firstRate == 1_250_000)
        #expect(meter.secondRate == 45_000)
        #expect(
            meter.rows == [
                MeterRow(
                    value: "1.25M", spokenValue: "1.25 megabytes per second", samples: [1], hasData: true),
                MeterRow(
                    value: "45.0K", spokenValue: "45.0 kilobytes per second", samples: [0.45], hasData: true),
            ])
    }

    @Test("Before the first reading both rows show the placeholder")
    func initialState() {
        let meter = RateMeter(source: ScriptedCounterSource([]), floor: 1)
        #expect(meter.rows.map(\.value) == ["--", "--"])
        #expect(meter.rows.map(\.spokenValue) == ["no data", "no data"])
    }

    @Test("A new item's first reading is only its baseline; a vanished or reset item adds nothing (edge cases)")
    func itemsComeAndGo() {
        let start = ContinuousClock.now
        let source = ScriptedCounterSource([
            counters(["en0": (0, 0), "en5": (900, 900)]),
            // en5 vanished, en7 appeared with large counters, en0 moved 1,000 bytes each way.
            counters(["en0": (1_000, 1_000), "en7": (5_000_000, 5_000_000)]),
            // en7 reset to zero.
            counters(["en0": (2_000, 2_000), "en7": (10, 10)]),
        ])
        var meter = RateMeter(source: source, floor: 1)
        meter.rebaseline(at: start)
        meter.sample(at: start + .seconds(1))
        #expect(meter.firstRate == 1_000)
        meter.sample(at: start + .seconds(2))
        #expect(meter.firstRate == 1_000)
        #expect(meter.secondRate == 1_000)
    }

    @Test("No counted items reads as 0, not the placeholder (edge case)")
    func noItems() {
        let start = ContinuousClock.now
        var meter = RateMeter(source: ScriptedCounterSource([[:], [:]]), floor: 1)
        meter.rebaseline(at: start)
        meter.sample(at: start + .seconds(1))
        #expect(meter.rows.map(\.value) == ["0", "0"])
    }

    @Test("A failed read shows the placeholder and a gap on both rows; the next reading resumes")
    func failedRead() {
        let start = ContinuousClock.now
        let source = ScriptedCounterSource([
            counters(["en0": (0, 0)]), nil, counters(["en0": (2_000, 4_000)]),
        ])
        var meter = RateMeter(source: source, floor: 1_000)
        meter.rebaseline(at: start)
        meter.sample(at: start + .seconds(1))
        #expect(meter.rows.map(\.value) == ["--", "--"])
        meter.sample(at: start + .seconds(2))
        #expect(meter.firstRate == 1_000)
        #expect(meter.secondRate == 2_000)
        #expect(meter.firstHistory.samples == [nil, 1_000])
    }

    @Test("A reading more than 3 s after its baseline starts a fresh baseline instead of a value (Behavior Details)")
    func staleBaseline() {
        let start = ContinuousClock.now
        let source = ScriptedCounterSource([
            counters(["en0": (0, 0)]), counters(["en0": (9_000_000, 0)]), counters(["en0": (9_001_000, 0)]),
        ])
        var meter = RateMeter(source: source, floor: 1)
        meter.rebaseline(at: start)
        meter.sample(at: start + .seconds(10))
        #expect(meter.firstRate == nil)
        #expect(meter.firstHistory.samples.isEmpty)
        meter.sample(at: start + .seconds(11))
        #expect(meter.firstRate == 1_000)
    }

    @Test("One-row form: both rates as numbers, no sparkline, spoken with their directions")
    func oneRowForm() {
        let start = ContinuousClock.now
        let source = ScriptedCounterSource([counters(["en0": (0, 0)]), counters(["en0": (1_250_000, 45_000)])])
        var meter = RateMeter(source: source, floor: 100_000, form: .oneRow, directionNames: ("download", "upload"))
        #expect(
            meter.rows == [
                MeterRow(value: "--", spokenValue: "no data", samples: [], hasData: false, secondValue: "--")
            ])
        meter.rebaseline(at: start)
        meter.sample(at: start + .seconds(1))
        #expect(
            meter.rows == [
                MeterRow(
                    value: "1.25M",
                    spokenValue: "download 1.25 megabytes per second, upload 45.0 kilobytes per second",
                    samples: [], hasData: true, secondValue: "45.0K")
            ])

        // Switching form keeps the history.
        meter.form = .twoRows
        #expect(meter.rows.count == 2)
        #expect(meter.rows[0].samples == [1])
    }
}

@Suite("Network")
struct NetworkTests {
    func interface(
        _ name: String, up: Bool = true, loopback: Bool = false, pointToPoint: Bool = false, type: Int32 = 0x06
    ) -> NetworkInterface {
        NetworkInterface(
            name: name, isUp: up, isLoopback: loopback, isPointToPoint: pointToPoint, type: type,
            counters: ByteCounters(first: 0, second: 0))
    }

    @Test("Physical interfaces count; loopback, tunnels, bridges, VM links, and down interfaces do not")
    func selection() {
        #expect(NetworkInterfaces.isCounted(interface("en0")))
        #expect(NetworkInterfaces.isCounted(interface("en5")))
        #expect(NetworkInterfaces.isCounted(interface("awdl0")))
        #expect(!NetworkInterfaces.isCounted(interface("lo0", loopback: true, type: 0x18)))
        #expect(!NetworkInterfaces.isCounted(interface("utun4", pointToPoint: true, type: 0x01)))
        #expect(!NetworkInterfaces.isCounted(interface("ipsec0", pointToPoint: true)))
        #expect(!NetworkInterfaces.isCounted(interface("gif0", pointToPoint: true, type: 0x37)))
        #expect(!NetworkInterfaces.isCounted(interface("stf0", type: 0x39)))
        #expect(!NetworkInterfaces.isCounted(interface("bridge0", type: 0xD1)))
        #expect(!NetworkInterfaces.isCounted(interface("vmenet0")))
        #expect(!NetworkInterfaces.isCounted(interface("en1", up: false)))
    }

    @Test("The system source reports this Mac's interfaces and counts only the physical ones")
    func systemSource() throws {
        let interfaces = try #require(SystemNetworkSource.readInterfaces())
        #expect(interfaces.contains { $0.name == "lo0" })
        let counted = try #require(SystemNetworkSource().readCounters())
        #expect(counted["lo0"] == nil)
        #expect(!counted.keys.contains { $0.hasPrefix("utun") })
    }

    @Test("The row is labeled NET, with arrows for download and upload")
    func text() {
        #expect(NetworkModuleText.label == "NET")
        #expect(NetworkModuleText.downloadMarker == "↓")
        #expect(NetworkModuleText.uploadMarker == "↑")
        #expect(NetworkModuleText.downloadAccessibilityLabel == "Network download")
        #expect(NetworkModuleText.uploadAccessibilityLabel == "Network upload")
        #expect(NetworkModuleText.sparklineFloor == 100_000)
    }
}
