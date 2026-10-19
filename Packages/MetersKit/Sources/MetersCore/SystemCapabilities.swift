import Foundation

/// What this Mac can show, which sets the modules the Settings window offers and the rows they need.
public struct SystemCapabilities: Equatable, Sendable {
    public var hasBattery: Bool
    /// CPU clusters this Mac reports; the CPU's "Total and clusters" form shows one row for each.
    public var cpuClusters: Int
    /// The clusters themselves, when read from the system, so the CPU module uses the same ones the row counts
    /// come from; `nil` in tests that give only a count.
    public var clusters: [CPUCluster]?

    public init(hasBattery: Bool, cpuClusters: Int) {
        self.hasBattery = hasBattery
        self.cpuClusters = cpuClusters
    }

    public init(hasBattery: Bool, clusters: [CPUCluster]) {
        self.hasBattery = hasBattery
        cpuClusters = clusters.count
        self.clusters = clusters
    }

    /// Reads the power sources and the device tree once; the app shares the result.
    public static func current() -> SystemCapabilities {
        SystemCapabilities(hasBattery: SystemSources.hasBattery(), clusters: SystemSources.cpuClusters())
    }

    /// Modules this Mac cannot show: Battery without a battery.
    public var unavailableModules: Set<ModuleID> {
        hasBattery ? [] : [.battery]
    }
}
