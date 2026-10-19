import Foundation
import Testing

@testable import MetersCore

@Suite("Gauges")
struct GaugeTests {
    let now = ContinuousClock.now

    @Test("Graphs: Sparklines by default, Gauges persists, anything else reads as Sparklines")
    @MainActor
    func setting() {
        #expect(GraphStyle.allCases.map(\.name) == ["Sparklines", "Gauges"])
        let suite = "net.1x0.meters.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HUDSettingsStore(defaults: defaults)
        #expect(store.graphStyle == .sparklines)
        store.graphStyle = .gauges
        #expect(HUDSettingsStore(defaults: defaults).graphStyle == .gauges)
        defaults.set("dials", forKey: HUDSettingsStore.graphsKey)
        #expect(HUDSettingsStore(defaults: defaults).graphStyle == .sparklines)
    }

    @Test("CPU, its clusters, Memory, GPU, and Battery fill to their displayed percent")
    func percentRows() {
        let clusters = [CPUCluster(name: "Super", cores: [1]), CPUCluster(name: "Performance", cores: nil)]
        let readings: [[CPUTicks]?] = [
            [ticks(busy: 0, idle: 0), ticks(busy: 0, idle: 0)], [ticks(busy: 25, idle: 75), ticks(busy: 60, idle: 40)],
        ]
        var cpu = CPUMeter(source: ScriptedCoreTickSource(readings), form: .clusters, clusters: clusters)
        cpu.rebaseline(at: now)
        cpu.sample(at: now + .seconds(1))
        #expect(cpu.rows.map(\.offersGauge) == [true, true, true])
        // The Performance cluster's cores are unknown: n/a shows the empty track.
        #expect(cpu.rows.map(\.gaugeFraction) == [0.43, 0.6, nil])

        var gpu = GPUMeter(source: ScriptedGPUSource([42, nil]))
        gpu.sample(at: now)
        #expect(gpu.rows[0].offersGauge && gpu.rows[0].gaugeFraction == 0.42)
        gpu.sample(at: now)
        #expect(gpu.rows[0].gaugeFraction == nil)

        let page = MemoryPages(anonymous: 2120, purgeable: 0, wired: 0, compressed: 0)
        var memory = MemoryMeter(source: ScriptedMemorySource([page]))
        memory.sample(at: now)
        #expect(memory.rows[0].offersGauge && memory.rows[0].gaugeFraction == 0.53)

        var battery = BatteryMeter(source: Scripted([BatteryReading(charge: 0.71, milliamps: -500)]))
        #expect(battery.rows[0].offersGauge && battery.rows[0].gaugeFraction == nil)
        battery.sample(at: now)
        #expect(battery.rows[0].gaugeFraction == 0.71)
    }

    @Test("Free space fills with the used share of capacity; unknown capacity shows the empty track")
    func freeSpace() {
        var meter = FreeSpaceMeter(
            source: CapacityFreeSpaceSource(capacity: 2_000_000_000_000, available: [150_000_000_000]))
        meter.sample(at: now)
        #expect(meter.rows[0].value == "150G" && meter.rows[0].offersGauge)
        #expect(meter.rows[0].gaugeFraction == 0.925)
        var unknown = FreeSpaceMeter(source: CapacityFreeSpaceSource(capacity: nil, available: [150_000_000_000]))
        unknown.sample(at: now)
        #expect(unknown.rows[0].gaugeFraction == nil)
    }

    @Test("Swap, Thermal, Network, and Disk offer no gauge")
    func noGauge() {
        #expect(!SwapMeter(source: Scripted<UInt64>([])).rows[0].offersGauge)
        #expect(!ThermalMeter(source: FixedThermalSource(state: .fair)).rows[0].offersGauge)
        #expect(RateMeter(source: ScriptedCounterSource([]), floor: 1).rows.allSatisfy { !$0.offersGauge })
    }

    @Test("A fill outside 0 to 1 stays within the track (Edge Cases)")
    func clamped() {
        #expect(MeterRow(value: "", spokenValue: "", samples: [], hasData: true, gaugeFraction: 1.4).gaugeFraction == 1)
        #expect(
            MeterRow(value: "", spokenValue: "", samples: [], hasData: true, gaugeFraction: -0.2).gaugeFraction == 0)
    }
}
