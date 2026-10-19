import Darwin
import Foundation

/// Cumulative CPU time, in scheduler ticks, summed across all logical cores.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// Wrapping sums, like the system-wide counters, so deltas stay right when a counter wraps.
    static func sum<Cores: Sequence<CPUTicks>>(_ cores: Cores) -> CPUTicks {
        var total = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        for core in cores {
            total.user &+= core.user
            total.system &+= core.system
            total.idle &+= core.idle
            total.nice &+= core.nice
        }
        return total
    }
}

/// Data source for total CPU time. The CPU module reads only through this protocol
///, so tests can substitute a fake.
public protocol CPUTickSource: Sendable {
    /// The current cumulative ticks, or `nil` when the read fails.
    func readTicks() -> CPUTicks?
    /// Each logical core's cumulative ticks, indexed by logical CPU number, or `nil` when the read fails or
    /// the source has no per-core figures. The cluster rows need them.
    func readCoreTicks() -> [CPUTicks]?
}

extension CPUTickSource {
    public func readCoreTicks() -> [CPUTicks]? { nil }
}

/// Documented source: per-core CPU ticks from the Mach host processor interface, summed across all logical cores
///. The system-wide total (`host_statistics`) is updated in bursts, up to
/// about a second apart (measured Sep 27, 2026), so a reading soon after another could see no change;
/// per-core counters advance about every 12 ms.
public struct MachCPUTickSource: CPUTickSource {
    private let host = MachHostPort()

    public init() {}

    public func readTicks() -> CPUTicks? {
        readCoreTicks().map(CPUTicks.sum)
    }

    public func readCoreTicks() -> [CPUTicks]? {
        var cores: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host.name, PROCESSOR_CPU_LOAD_INFO, &cores, &info, &infoCount) == KERN_SUCCESS,
            let info
        else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(cores)).map { core in
            func ticks(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[core * states + Int(state)]) }
            return CPUTicks(
                user: ticks(CPU_STATE_USER), system: ticks(CPU_STATE_SYSTEM), idle: ticks(CPU_STATE_IDLE),
                nice: ticks(CPU_STATE_NICE))
        }
    }
}

public enum CPUUtilization {
    /// The busy share (user, system, and nice) of CPU time between two readings, from 0 to 1
    ///. Counters that wrapped are handled. A counter that went backwards, or no
    /// elapsed time, gives `nil`, so a bad reading never shows as a spike.
    public static func fraction(from old: CPUTicks, to new: CPUTicks) -> Double? {
        let user = new.user &- old.user
        let system = new.system &- old.system
        let nice = new.nice &- old.nice
        let idle = new.idle &- old.idle
        // A wrapped counter yields a small delta; one that went backwards yields a delta near 2^32.
        let limit = UInt32(1) << 31
        guard user < limit, system < limit, nice < limit, idle < limit else { return nil }
        let busy = UInt64(user) + UInt64(system) + UInt64(nice)
        let total = busy + UInt64(idle)
        guard total > 0 else { return nil }
        return min(1, max(0, Double(busy) / Double(total)))
    }

    /// Whole-number percent for display, from 0 to 100.
    public static func percent(_ fraction: Double) -> Int {
        MeterText.percent(fraction)
    }
}

/// A bounded, oldest-first record of recent samples. `nil` marks a gap.
public struct SampleHistory: Equatable, Sendable {
    public let capacity: Int
    public private(set) var samples: [Double?] = []

    public init(capacity: Int) {
        self.capacity = capacity
        samples.reserveCapacity(capacity + 1)
    }

    public mutating func append(_ sample: Double?) {
        samples.append(sample)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }
}

/// Turns tick readings into the CPU module's displayed values and sparkline histories: the total and, in
/// the "Total and clusters" form, one row per cluster.
public struct CPUMeter: ModuleMeter {
    public static let historyCapacity = MeterTiming.historyCapacity
    public static let interval = MeterTiming.interval
    public static let primingDelay = MeterTiming.primingDelay
    public static let staleAfter = MeterTiming.staleAfter

    /// One cluster's row: its value, and whether the system says which cores it has.
    public struct ClusterReading: Equatable, Sendable {
        public fileprivate(set) var percent: Int?
        public fileprivate(set) var isUnavailable: Bool
        public fileprivate(set) var history = SampleHistory(capacity: historyCapacity)
        public fileprivate(set) var highlight = Highlight(rule: ThresholdDefaults.cpu)
    }

    /// The value to display; `nil` shows the placeholder.
    public private(set) var percent: Int?
    public private(set) var history = SampleHistory(capacity: historyCapacity)
    /// Each cluster's reading, in the order of `clusters`. Kept in both forms, so switching form keeps the
    /// clusters' history.
    public private(set) var clusterReadings: [ClusterReading]
    public let clusters: [CPUCluster]
    /// Which rows show; switching keeps every history.
    public var form: CPUForm
    /// The total row's highlighting; each cluster row has its own, with CPU's thresholds.
    public private(set) var highlight = Highlight(rule: ThresholdDefaults.cpu)

    private let source: any CPUTickSource
    private var baseline: (ticks: CPUTicks, cores: [CPUTicks]?, time: ContinuousClock.Instant)?
    private var staleness = StalenessLimit()

    public init(source: any CPUTickSource, form: CPUForm = .total, clusters: [CPUCluster] = []) {
        self.source = source
        self.form = form
        self.clusters = clusters
        clusterReadings = clusters.map { ClusterReading(isUnavailable: $0.cores == nil) }
    }

    /// Records the baseline the next reading is measured against, without producing a value.
    /// Used at launch and after wake.
    public mutating func rebaseline(at now: ContinuousClock.Instant) {
        let cores = source.readCoreTicks()
        baseline = (cores.map(CPUTicks.sum) ?? source.readTicks()).map { (ticks: $0, cores: cores, time: now) }
    }

    public mutating func sample(at now: ContinuousClock.Instant) {
        let cores = source.readCoreTicks()
        guard let ticks = cores.map(CPUTicks.sum) ?? source.readTicks() else {
            // A failed read shows the placeholder and leaves a gap; the old baseline still applies.
            record(nil, cores: nil)
            return
        }
        defer { baseline = (ticks: ticks, cores: cores, time: now) }
        let limit = staleness.take()
        guard let baseline, now - baseline.time <= limit else { return }
        record(
            CPUUtilization.fraction(from: baseline.ticks, to: ticks),
            cores: baseline.cores.flatMap { old in cores.map { (old: old, new: $0) } })
    }

    public mutating func setInterval(_ interval: Duration) {
        staleness.setInterval(interval)
    }

    /// The total and every cluster row use CPU's thresholds.
    @discardableResult
    public mutating func applyThresholds(_ settings: ThresholdSettings) -> Bool {
        let rule = settings.rule(for: .cpu)
        var changed = highlight.setRule(rule)
        for index in clusterReadings.indices { changed = clusterReadings[index].highlight.setRule(rule) || changed }
        return changed
    }

    @discardableResult
    public mutating func resetStates() -> Bool {
        var changed = highlight.reset()
        for index in clusterReadings.indices { changed = clusterReadings[index].highlight.reset() || changed }
        return changed
    }

    private mutating func record(_ fraction: Double?, cores: (old: [CPUTicks], new: [CPUTicks])?) {
        percent = fraction.map(CPUUtilization.percent)
        history.append(fraction)
        highlight.record(percent.map(Double.init))
        for (index, cluster) in clusters.enumerated() {
            var fraction: Double?
            if let members = cluster.cores, let cores {
                let count = min(cores.old.count, cores.new.count)
                if members.allSatisfy({ $0 < count }) {
                    clusterReadings[index].isUnavailable = false
                    fraction = CPUUtilization.fraction(
                        from: CPUTicks.sum(members.map { cores.old[$0] }),
                        to: CPUTicks.sum(members.map { cores.new[$0] }))
                } else {
                    // The system named cores this Mac does not report: the membership cannot be right.
                    clusterReadings[index].isUnavailable = true
                }
            }
            clusterReadings[index].percent = fraction.map(CPUUtilization.percent)
            clusterReadings[index].history.append(fraction)
            clusterReadings[index].highlight.record(clusterReadings[index].percent.map(Double.init))
        }
    }

    public var rows: [MeterRow] {
        let total = MeterRow(
            value: CPUModuleText.value(percent), spokenValue: CPUModuleText.accessibilityValue(percent),
            samples: history.samples, hasData: percent != nil, state: highlight.state, offersGauge: true,
            gaugeFraction: percent.map { Double($0) / 100 })
        guard form == .clusters else { return [total] }
        return [total]
            + clusterReadings.map { reading in
                MeterRow(
                    value: reading.isUnavailable ? CPUModuleText.unavailable : CPUModuleText.value(reading.percent),
                    spokenValue: reading.isUnavailable
                        ? CPUModuleText.spokenUnavailable : CPUModuleText.accessibilityValue(reading.percent),
                    samples: reading.history.samples, hasData: reading.percent != nil,
                    isUnavailable: reading.isUnavailable, state: reading.highlight.state, offersGauge: true,
                    gaugeFraction: reading.percent.map { Double($0) / 100 })
            }
    }
}

/// The CPU module's visible and spoken text.
public enum CPUModuleText {
    public static let label = "CPU"
    public static let unavailable = "n/a"
    public static let spokenUnavailable = "unavailable"

    /// A cluster row's marker: the first letter of the cluster's name, such as "S" for Super.
    public static func marker(_ cluster: CPUCluster) -> String {
        cluster.name.first.map { String($0).uppercased() } ?? ""
    }

    /// What VoiceOver calls a cluster row: "CPU Super".
    public static func accessibilityLabel(_ cluster: CPUCluster) -> String {
        "\(label) \(cluster.name)"
    }

    public static func value(_ percent: Int?) -> String {
        MeterText.value(percent)
    }

    public static func accessibilityValue(_ percent: Int?) -> String {
        MeterText.spoken(percent)
    }
}
