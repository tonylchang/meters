import Foundation
import Synchronization
import Testing

@testable import MetersCore

/// A source that returns scripted per-core readings in order; `nil` entries simulate failed reads.
final class ScriptedCoreTickSource: CPUTickSource {
    private let readings: Mutex<[[CPUTicks]?]>

    init(_ readings: [[CPUTicks]?]) {
        self.readings = Mutex(readings)
    }

    func readTicks() -> CPUTicks? {
        readCoreTicks().map(CPUTicks.sum)
    }

    func readCoreTicks() -> [CPUTicks]? {
        readings.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

@Suite("CPU clusters")
struct CPUClusterTests {
    let start = ContinuousClock.now
    /// Cores 0 and 1 are Performance, 2 and 3 Super, as on the development Mac, where the higher level's
    /// cores come last.
    let clusters = [CPUCluster(name: "Super", cores: [2, 3]), CPUCluster(name: "Performance", cores: [0, 1])]

    func cores(_ busy: [UInt32], idle: UInt32 = 100) -> [CPUTicks] {
        busy.map { ticks(busy: $0, idle: idle - $0) }
    }

    @Test("Total form: one row; clusters form: the total, then one row per cluster, highest first")
    func rows() {
        let source = ScriptedCoreTickSource([cores([0, 0, 0, 0], idle: 0), cores([10, 30, 80, 100])])
        var meter = CPUMeter(source: source, clusters: clusters)
        meter.rebaseline(at: start)
        meter.sample(at: start + .seconds(1))
        #expect(meter.rows.count == 1)
        #expect(meter.rows[0].value == "55%")
        meter.form = .clusters
        #expect(meter.rows.map(\.value) == ["55%", "90%", "20%"])
        #expect(meter.rows.map(\.spokenValue) == ["55 percent", "90 percent", "20 percent"])
        #expect(meter.rows[1].samples == [0.9])
        #expect(meter.rows.allSatisfy { !$0.isUnavailable && $0.hasData })
    }

    @Test("The cluster values, weighted by core count, agree with the total within 1 point")
    func weightedAverage() throws {
        let clusters = [
            CPUCluster(name: "Super", cores: [4, 5]), CPUCluster(name: "Performance", cores: [0, 1, 2, 3]),
        ]
        let source = ScriptedCoreTickSource([cores([0, 0, 0, 0, 0, 0], idle: 0), cores([13, 7, 51, 29, 97, 88])])
        var meter = CPUMeter(source: source, form: .clusters, clusters: clusters)
        meter.rebaseline(at: start)
        meter.sample(at: start + .seconds(1))
        let total = try #require(meter.percent)
        let values = meter.clusterReadings.map { $0.percent ?? -1 }
        let weighted = Double(values[0] * 2 + values[1] * 4) / 6
        #expect(abs(weighted - Double(total)) <= 1, "\(values) against \(total)")
    }

    @Test("Unknown membership reads n/a on the cluster rows; the total is unaffected")
    func unknownMembership() {
        let clusters = [CPUCluster(name: "Super", cores: nil), CPUCluster(name: "Performance", cores: nil)]
        let source = ScriptedCoreTickSource([cores([0, 0], idle: 0), cores([50, 50])])
        var meter = CPUMeter(source: source, form: .clusters, clusters: clusters)
        #expect(meter.rows.map(\.value) == ["--", "n/a", "n/a"])
        meter.rebaseline(at: start)
        meter.sample(at: start + .seconds(1))
        #expect(meter.rows.map(\.value) == ["50%", "n/a", "n/a"])
        #expect(meter.rows.map(\.spokenValue) == ["50 percent", "unavailable", "unavailable"])
        #expect(meter.rows.map(\.isUnavailable) == [false, true, true])
    }

    @Test("A cluster naming cores this Mac does not report reads n/a")
    func coresOutOfRange() {
        let clusters = [CPUCluster(name: "Super", cores: [2, 3]), CPUCluster(name: "Performance", cores: [0, 1])]
        let source = ScriptedCoreTickSource([cores([0, 0, 0], idle: 0), cores([50, 50, 50])])
        var meter = CPUMeter(source: source, form: .clusters, clusters: clusters)
        meter.rebaseline(at: start)
        meter.sample(at: start + .seconds(1))
        #expect(meter.rows.map(\.value) == ["50%", "n/a", "50%"])
    }

    @Test("A failed read shows the placeholder and a gap on every row; switching form keeps the history")
    func failedReadAndSwitch() {
        let source = ScriptedCoreTickSource([cores([0, 0, 0, 0], idle: 0), cores([10, 10, 50, 50]), nil])
        var meter = CPUMeter(source: source, form: .clusters, clusters: clusters)
        meter.rebaseline(at: start)
        meter.sample(at: start + .seconds(1))
        meter.sample(at: start + .seconds(2))
        #expect(meter.rows.map(\.value) == ["--", "--", "--"])
        #expect(meter.rows[1].samples == [0.5, nil])
        meter.form = .total
        meter.form = .clusters
        #expect(meter.rows[2].samples == [0.1, nil])
    }

    @Test("A source without per-core figures still reads the total; cluster rows wait for data")
    func totalOnlySource() {
        let source = ScriptedTickSource([ticks(busy: 0, idle: 0), ticks(busy: 25, idle: 75)])
        var meter = CPUMeter(source: source, form: .clusters, clusters: clusters)
        meter.rebaseline(at: start)
        meter.sample(at: start + .seconds(1))
        #expect(meter.rows.map(\.value) == ["25%", "--", "--"])
    }

    @Test("Cluster rows are marked with the name's initial and read as CPU and the full name")
    func text() {
        #expect(CPUModuleText.marker(CPUCluster(name: "Super", cores: nil)) == "S")
        #expect(CPUModuleText.marker(CPUCluster(name: "efficiency", cores: nil)) == "E")
        #expect(CPUModuleText.accessibilityLabel(CPUCluster(name: "Super", cores: nil)) == "CPU Super")
        #expect(CPUForm.total.name == "Total" && CPUForm.clusters.name == "Total and clusters")
    }

    typealias Level = DeviceTreeCPUClusters.Level

    @Test("Membership: the development Mac's 6 Super cores are cluster type P, its 12 Performance cores type M")
    func matchDevelopmentMac() {
        var types: [Int: String] = [:]
        for core in 0..<12 { types[core] = "M" }
        for core in 12..<18 { types[core] = "P" }
        let clusters = DeviceTreeCPUClusters.match(
            levels: [Level(name: "Super", cores: 6), Level(name: "Performance", cores: 12)], coreTypes: types)
        #expect(
            clusters == [
                CPUCluster(name: "Super", cores: Array(12..<18)), CPUCluster(name: "Performance", cores: Array(0..<12)),
            ])
    }

    @Test("Membership: equal-sized levels pair by type rank, P before E")
    func matchEqualSizes() {
        let types = [0: "E", 1: "E", 2: "E", 3: "E", 4: "P", 5: "P", 6: "P", 7: "P"]
        let clusters = DeviceTreeCPUClusters.match(
            levels: [Level(name: "Performance", cores: 4), Level(name: "Efficiency", cores: 4)], coreTypes: types)
        #expect(
            clusters == [
                CPUCluster(name: "Performance", cores: [4, 5, 6, 7]),
                CPUCluster(name: "Efficiency", cores: [0, 1, 2, 3]),
            ])
    }

    @Test("Membership: sizes that do not pair, or a missing device tree, leave the cores unknown")
    func matchFails() {
        let levels = [Level(name: "Performance", cores: 4), Level(name: "Efficiency", cores: 4)]
        #expect(DeviceTreeCPUClusters.match(levels: levels, coreTypes: [:]).map(\.cores) == [nil, nil])
        let types = [0: "E", 1: "E", 2: "P", 3: "P", 4: "P", 5: "P", 6: "P", 7: "P"]
        #expect(DeviceTreeCPUClusters.match(levels: levels, coreTypes: types).map(\.cores) == [nil, nil])
        #expect(DeviceTreeCPUClusters.match(levels: [], coreTypes: types).isEmpty)
    }

    @Test("Membership: when rank order fails, levels with a unique size pair by size")
    func matchBySize() {
        // An unknown letter ranks last, so rank order puts the 2-core type first; sizes still pair.
        let types = [0: "X", 1: "X", 2: "X", 3: "X", 4: "E", 5: "E"]
        let clusters = DeviceTreeCPUClusters.match(
            levels: [Level(name: "Performance", cores: 4), Level(name: "Efficiency", cores: 2)], coreTypes: types)
        #expect(clusters.map(\.cores) == [[0, 1, 2, 3], [4, 5]])
    }
}
