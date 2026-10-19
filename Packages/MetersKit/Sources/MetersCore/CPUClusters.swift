import Darwin
import Foundation
import IOKit

/// A CPU cluster as the system reports it: a performance level, such as "Super", "Performance", or
/// "Efficiency", and its logical cores.
public struct CPUCluster: Equatable, Sendable {
    public let name: String
    /// Logical CPU numbers, or `nil` when the system does not say which cores belong to the cluster.
    public let cores: [Int]?

    public init(name: String, cores: [Int]?) {
        self.name = name
        self.cores = cores
    }
}

extension SystemSources {
    /// This Mac's CPU clusters, highest performance first. Empty when the system reports no performance
    /// levels.
    public static func cpuClusters() -> [CPUCluster] {
        DeviceTreeCPUClusters.read()
    }
}

/// Cluster names and sizes come from the documented performance levels (`hw.perflevelN`); core membership
/// comes from each core's "cluster-type" in the device tree, an undocumented key.
enum DeviceTreeCPUClusters {
    /// A performance level: its name and logical core count, from `hw.perflevelN`.
    struct Level: Equatable {
        let name: String
        let cores: Int
    }

    static func read() -> [CPUCluster] {
        match(levels: readLevels(), coreTypes: readCoreTypes())
    }

    /// Pairs the performance levels, highest first, with the device tree's cluster types. Types rank "P",
    /// then "M", then "E", then any other letter; a pairing counts only if every level's core count
    /// matches its type's. Otherwise, levels whose core count no other level shares are paired with the
    /// one type of that size. Any level left unpaired has unknown cores.
    static func match(levels: [Level], coreTypes: [Int: String]) -> [CPUCluster] {
        var byType: [String: [Int]] = [:]
        for (core, type) in coreTypes { byType[type, default: []].append(core) }
        let rank = ["P": 0, "M": 1, "E": 2]
        let types = byType.keys.sorted { (rank[$0] ?? 3, $0) < (rank[$1] ?? 3, $1) }

        if types.count == levels.count, zip(levels, types).allSatisfy({ $0.cores == byType[$1]?.count }) {
            return zip(levels, types).map { CPUCluster(name: $0.name, cores: byType[$1]?.sorted()) }
        }
        return levels.map { level in
            let sameSizeLevels = levels.filter { $0.cores == level.cores }.count
            let sameSizeTypes = types.filter { byType[$0]?.count == level.cores }
            guard sameSizeLevels == 1, sameSizeTypes.count == 1 else { return CPUCluster(name: level.name, cores: nil) }
            return CPUCluster(name: level.name, cores: byType[sameSizeTypes[0]]?.sorted())
        }
    }

    static func readLevels() -> [Level] {
        guard let count = sysctlInt("hw.nperflevels"), count > 0 else { return [] }
        return (0..<count).compactMap { index in
            guard let name = sysctlString("hw.perflevel\(index).name"),
                let cores = sysctlInt("hw.perflevel\(index).logicalcpu")
            else { return nil }
            return Level(name: name, cores: cores)
        }
    }

    /// Each logical core's cluster type, such as "P", from the device tree's `cpus` node.
    static func readCoreTypes() -> [Int: String] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [:] }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var types: [Int: String] = [:]
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let id = (property("logical-cpu-id") as? NSNumber)?.intValue,
                let data = property("cluster-type") as? Data,
                let type = String(data: data, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters),
                !type.isEmpty
            else { continue }
            types[id] = type
        }
        return types
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}
