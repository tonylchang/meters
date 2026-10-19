import Foundation

/// The HUD's modules.
public enum ModuleID: String, CaseIterable, Sendable {
    case cpu
    case memory
    case gpu
    case network
    case disk
    case battery
    case thermal
    case swap
    case freeSpace

    /// The name shown in the Settings window.
    public var name: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .network: "Network"
        case .disk: "Disk"
        case .battery: "Battery"
        case .thermal: "Thermal"
        case .swap: "Swap"
        case .freeSpace: "Free space"
        }
    }

    /// Whether the module offers forms: CPU (total, or with clusters), Network and Disk (one or two rows).
    public var hasForms: Bool { self == .cpu || self == .network || self == .disk }
}

/// The CPU module's form.
public enum CPUForm: String, CaseIterable, Sendable {
    /// One row: total CPU.
    case total
    /// The total row, then one row per CPU cluster.
    case clusters

    /// The choice as the Settings window names it.
    public var name: String { self == .total ? "Total" : "Total and clusters" }
}

/// What the percentage rows draw after their value.
public enum GraphStyle: String, CaseIterable, Sendable {
    case sparklines
    case gauges

    /// The choice as the Settings window names it.
    public var name: String { self == .sparklines ? "Sparklines" : "Gauges" }
}

/// A two-rate module's form.
public enum RateForm: String, CaseIterable, Sendable {
    /// Both rates as numbers, no sparkline.
    case oneRow
    /// Each rate in its own row, with a sparkline.
    case twoRows

    public var rows: Int { self == .oneRow ? 1 : 2 }
    /// The choice as the Settings window names it.
    public var name: String { self == .oneRow ? "One row" : "Two rows" }
}

/// Each module's current form, and the CPU clusters this Mac has.
public struct ModuleForms: Equatable, Sendable {
    public var cpu: CPUForm
    public var network: RateForm
    public var disk: RateForm
    /// CPU clusters this Mac reports; the "Total and clusters" form adds one row for each.
    public var cpuClusters: Int

    public init(cpu: CPUForm = .total, network: RateForm = .oneRow, disk: RateForm = .oneRow, cpuClusters: Int = 2) {
        self.cpu = cpu
        self.network = network
        self.disk = disk
        self.cpuClusters = cpuClusters
    }
}

/// A module in the user's list: shown or not.
public struct ModuleEntry: Equatable, Sendable {
    public var id: ModuleID
    public var isOn: Bool

    public init(_ id: ModuleID, isOn: Bool) {
        self.id = id
        self.isOn = isOn
    }
}

/// Which modules the HUD shows, and how many rows they need.
public enum ModuleSelection {
    /// First launch: CPU, Memory, and Network on, in that order, then GPU and Disk off.
    public static let defaultEntries: [ModuleEntry] = [
        ModuleEntry(.cpu, isOn: true), ModuleEntry(.memory, isOn: true), ModuleEntry(.network, isOn: true),
        ModuleEntry(.gpu, isOn: false), ModuleEntry(.disk, isOn: false), ModuleEntry(.battery, isOn: false),
        ModuleEntry(.thermal, isOn: false), ModuleEntry(.swap, isOn: false), ModuleEntry(.freeSpace, isOn: false),
    ]

    /// A stored list made whole: unknown and repeated modules dropped, missing ones appended unchecked, and,
    /// if nothing is on, the first module shown (Edge Cases). `nil` gives the defaults.
    public static func normalized(_ stored: [(id: String, isOn: Bool)]?) -> [ModuleEntry] {
        guard let stored else { return defaultEntries }
        var entries: [ModuleEntry] = []
        for item in stored {
            guard let id = ModuleID(rawValue: item.id), !entries.contains(where: { $0.id == id }) else { continue }
            entries.append(ModuleEntry(id, isOn: item.isOn))
        }
        for id in ModuleID.allCases where !entries.contains(where: { $0.id == id }) {
            entries.append(ModuleEntry(id, isOn: false))
        }
        if !entries.contains(where: \.isOn) { entries[0].isOn = true }
        return entries
    }

    /// The selection both Settings and the HUD use on this Mac: unavailable modules read as unchecked,
    /// and an unavailable-only selection checks the first available module. Reading this does not rewrite
    /// the saved selection, so moving settings between Macs preserves the user's original choices.
    public static func effective(_ entries: [ModuleEntry], unavailable: Set<ModuleID> = []) -> [ModuleEntry] {
        var entries = entries.map { ModuleEntry($0.id, isOn: $0.isOn && !unavailable.contains($0.id)) }
        if !entries.contains(where: \.isOn), let first = entries.firstIndex(where: { !unavailable.contains($0.id) }) {
            entries[first].isOn = true
        }
        return entries
    }

    /// The checked modules the HUD shows, in order; the HUD's height follows them.
    /// Modules this Mac cannot show are skipped. If no module this Mac can show is checked, the first one it can
    /// show is shown, as for a stored list with nothing checked (Edge Cases).
    public static func shown(_ entries: [ModuleEntry], unavailable: Set<ModuleID> = []) -> [ModuleID] {
        effective(entries, unavailable: unavailable).filter(\.isOn).map(\.id)
    }
}
