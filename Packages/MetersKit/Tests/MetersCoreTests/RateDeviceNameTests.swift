import Foundation
import Synchronization
import Testing

@testable import MetersCore

private final class ScriptedSnapshotSource: ByteCounterSource {
    private let readings: Mutex<[ByteCounterSnapshot?]>

    init(_ readings: [ByteCounterSnapshot?]) { self.readings = Mutex(readings) }

    func readCounters() -> [String: ByteCounters]? { readSnapshot()?.counters }

    func readSnapshot() -> ByteCounterSnapshot? {
        readings.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

@Suite("Rate device names")
struct RateDeviceNameTests {
    @Test("Names belong to counted devices, sort stably, and preserve distinct devices with the same name")
    func countedNames() {
        let counters = ["a", "b", "c"].reduce(into: [String: ByteCounters]()) {
            $0[$1] = ByteCounters(first: 0, second: 0)
        }
        let reading = ByteCounterSnapshot(
            counters: counters, deviceNames: ["a": " Wi-Fi ", "b": "Wi-Fi", "c": " \n", "tunnel": "VPN"])
        #expect(reading.deviceName == "Wi-Fi, Wi-Fi")
        #expect(ByteCounterSnapshot(counters: counters).deviceName == nil)
        #expect(ByteCounterSnapshot(counters: [:], deviceNames: ["a": "Wi-Fi"]).deviceName == nil)
    }

    @Test("Names follow device arrival, removal, failed reads, and recovery without changing rates or history")
    func topologyAndFailure() {
        func reading(_ counters: [String: (UInt64, UInt64)], _ names: [String: String]) -> ByteCounterSnapshot {
            ByteCounterSnapshot(
                counters: counters.mapValues { ByteCounters(first: $0.0, second: $0.1) }, deviceNames: names)
        }
        let source = ScriptedSnapshotSource([
            reading(["en0": (0, 0)], ["en0": "Wi-Fi"]),
            reading(["en0": (1_000, 2_000), "en5": (500_000, 300_000)], ["en0": "Wi-Fi", "en5": "Ethernet"]),
            reading(["en5": (501_000, 302_000)], ["en5": "Ethernet"]),
            nil,
            reading(["en5": (505_000, 306_000)], ["en5": "USB Ethernet"]),
        ])
        let start = ContinuousClock.now
        var meter = RateMeter(source: source, floor: 1_000, form: .oneRow)
        meter.rebaseline(at: start)
        #expect(meter.rows[0].deviceName == "Wi-Fi")
        meter.sample(at: start + .seconds(1))
        #expect(meter.rows[0].deviceName == "Wi-Fi, Ethernet")
        #expect(meter.firstRate == 1_000 && meter.secondRate == 2_000)
        meter.sample(at: start + .seconds(2))
        #expect(meter.rows[0].deviceName == "Ethernet")
        #expect(meter.firstRate == 1_000 && meter.secondRate == 2_000)
        meter.sample(at: start + .seconds(3))
        #expect(meter.rows[0].deviceName == nil && meter.rows[0].value == "--")
        meter.sample(at: start + .seconds(4))
        #expect(meter.rows[0].deviceName == "USB Ethernet")
        #expect(meter.firstRate == 2_000 && meter.secondRate == 2_000)
        #expect(meter.firstHistory.samples == [1_000, 1_000, nil, 2_000])
        meter.form = .twoRows
        #expect(meter.rows.allSatisfy { $0.deviceName == nil })
        meter.form = .oneRow
        #expect(meter.rows[0].deviceName == "USB Ethernet")
    }

    @Test("Absent name metadata never drops counters from the aggregate")
    func missingMetadata() {
        let source = ScriptedSnapshotSource([
            ByteCounterSnapshot(counters: [
                "known": ByteCounters(first: 0, second: 0), "unknown": ByteCounters(first: 0, second: 0),
            ]),
            ByteCounterSnapshot(
                counters: [
                    "known": ByteCounters(first: 1_000, second: 2_000),
                    "unknown": ByteCounters(first: 4_000, second: 8_000),
                ],
                deviceNames: ["known": "disk0"]),
        ])
        let start = ContinuousClock.now
        var meter = RateMeter(source: source, floor: 1, form: .oneRow)
        meter.rebaseline(at: start)
        meter.sample(at: start + .seconds(1))
        #expect(meter.firstRate == 5_000 && meter.secondRate == 10_000)
        #expect(meter.rows[0].deviceName == "disk0")
    }

    @Test("Disk names require a valid whole-media BSD name")
    func diskMetadata() {
        #expect(SystemDiskSource.deviceName(mediaProperties: ["Whole": true, "BSD Name": " disk0 "]) == "disk0")
        #expect(SystemDiskSource.deviceName(mediaProperties: ["Whole": false, "BSD Name": "disk0s1"]) == nil)
        #expect(SystemDiskSource.deviceName(mediaProperties: ["Whole": "true", "BSD Name": "disk0"]) == nil)
        #expect(SystemDiskSource.deviceName(mediaProperties: ["Whole": true, "BSD Name": 42]) == nil)
        #expect(SystemDiskSource.deviceName(mediaProperties: ["Whole": true, "BSD Name": " "]) == nil)
        #expect(SystemDiskSource.deviceName(mediaProperties: nil) == nil)
    }

    @Test("Network labels show only counted Wi-Fi once, without narrowing the aggregate")
    func wiFiLabel() {
        let counters = [
            "en2": ByteCounters(first: 1_000, second: 2_000),
            "en5": ByteCounters(first: 3_000, second: 4_000),
            "en8": ByteCounters(first: 5_000, second: 6_000),
        ]
        let reading = SystemNetworkSource.snapshot(counters: counters, wiFiInterfaces: ["en2", "en8", "en9"])
        #expect(reading.counters == counters)
        #expect(reading.deviceNames == ["en2": "Wi-Fi"])
        #expect(reading.deviceName == "Wi-Fi")
        let absent = SystemNetworkSource.snapshot(counters: counters, wiFiInterfaces: ["en9"])
        #expect(absent.counters == counters && absent.deviceName == nil)
        #expect(SystemNetworkSource.snapshot(counters: counters, wiFiInterfaces: []).deviceName == nil)
        #expect(SystemNetworkSource.snapshot(counters: [:], wiFiInterfaces: ["en2"]).deviceName == nil)
    }

    @Test("Live network labels include only Wi-Fi and keep all counted interfaces")
    func networkNames() throws {
        let reading = try #require(SystemNetworkSource().readSnapshot())
        let interfaces = try #require(SystemNetworkSource.readInterfaces())
        #expect(Set(reading.counters.keys) == Set(interfaces.filter(NetworkInterfaces.isCounted).map(\.name)))
        #expect(Set(reading.deviceNames.keys).isSubset(of: reading.counters.keys))
        #expect(reading.deviceNames.count <= 1)
        #expect(reading.deviceNames.values.allSatisfy { $0 == "Wi-Fi" })
        print("Network device names: \(reading.deviceNames)")
    }

    @Test("Live disk names match physical disks, excluding APFS containers and mounted images")
    func physicalDiskNames() throws {
        let reading = try #require(SystemDiskSource().readSnapshot())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["list", "-plist", "physical"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let disks = try #require(plist["AllDisksAndPartitions"] as? [[String: Any]])
        let physical = Set(disks.compactMap { $0["DeviceIdentifier"] as? String })
        #expect(!reading.deviceNames.isEmpty)
        #expect(Set(reading.deviceNames.values).isSubset(of: physical))
        print("Disk device names: \(reading.deviceNames)")
    }
}
