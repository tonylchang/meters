import Foundation
import IOKit

public enum DiskSelection {
    // Keys and values from IOKit's IOStorageProtocolCharacteristics.h.
    static let protocolCharacteristicsKey = "Protocol Characteristics"
    static let interconnectKey = "Physical Interconnect"
    static let interconnectLocationKey = "Physical Interconnect Location"
    static let virtualInterconnect = "Virtual Interface"
    static let fileLocation = "File"

    /// Whether a disk is counted: physical disks only. Disk images report a
    /// virtual interconnect located in a file; their reads and writes already appear on the physical disk
    /// that stores them. A disk that reports nothing is counted.
    public static func isCounted(protocolCharacteristics: [String: Any]?) -> Bool {
        guard let characteristics = protocolCharacteristics else { return true }
        return characteristics[interconnectKey] as? String != virtualInterconnect
            && characteristics[interconnectLocationKey] as? String != fileLocation
    }
}

/// Documented source: each block storage driver's documented statistics ("Bytes (Read)" and
/// "Bytes (Write)", from IOKit's IOBlockStorageDriver.h), keyed by the driver's registry entry ID.
/// `first` is bytes read, `second` bytes written.
public struct SystemDiskSource: ByteCounterSource {
    static let statisticsKey = "Statistics"
    static let bytesReadKey = "Bytes (Read)"
    static let bytesWrittenKey = "Bytes (Write)"

    public init() {}

    public func readCounters() -> [String: ByteCounters]? {
        readSnapshot()?.counters
    }

    public func readSnapshot() -> ByteCounterSnapshot? {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
                == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var counters: [String: ByteCounters] = [:]
        var names: [String: String] = [:]
        var driver = IOIteratorNext(iterator)
        while driver != 0 {
            defer {
                IOObjectRelease(driver)
                driver = IOIteratorNext(iterator)
            }
            var provider: io_registry_entry_t = 0
            IORegistryEntryGetParentEntry(driver, kIOServicePlane, &provider)
            defer { if provider != 0 { IOObjectRelease(provider) } }
            let characteristics =
                provider == 0
                ? nil : Self.property(DiskSelection.protocolCharacteristicsKey, of: provider) as? [String: Any]
            guard DiskSelection.isCounted(protocolCharacteristics: characteristics),
                let statistics = Self.property(Self.statisticsKey, of: driver) as? [String: Any],
                let read = (statistics[Self.bytesReadKey] as? NSNumber)?.uint64Value,
                let written = (statistics[Self.bytesWrittenKey] as? NSNumber)?.uint64Value
            else { continue }
            var identifier: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(driver, &identifier)
            counters[String(identifier)] = ByteCounters(first: read, second: written)
            if let name = Self.deviceName(of: driver) {
                names[String(identifier)] = name
            }
        }
        return ByteCounterSnapshot(counters: counters, deviceNames: names)
    }

    /// A physical whole media's BSD name, rather than a partition or APFS container name. An empty
    /// card reader or missing metadata has no display name.
    static func deviceName(mediaProperties: [String: Any]?) -> String? {
        guard mediaProperties?["Whole"] as? Bool == true,
            let bsdName = mediaProperties?[kIOBSDNameKey] as? String
        else { return nil }
        let name = bsdName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func deviceName(of driver: io_object_t) -> String? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var names: [String] = []
        var child = IOIteratorNext(iterator)
        while child != 0 {
            defer {
                IOObjectRelease(child)
                child = IOIteratorNext(iterator)
            }
            // Only the driver's immediate physical media: descending recursively would include APFS
            // containers and their volumes and could label disk0's counters as disk3's.
            guard IOObjectConformsTo(child, "IOMedia") != 0,
                let name = deviceName(mediaProperties: [
                    "Whole": property("Whole", of: child) as Any,
                    kIOBSDNameKey: property(kIOBSDNameKey, of: child) as Any,
                ])
            else { continue }
            names.append(name)
        }
        return names.isEmpty ? nil : names.sorted().joined(separator: ", ")
    }

    private static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

/// The Disk module's visible and spoken text, and its sparkline floor.
public enum DiskModuleText {
    public static let label = "DISK"
    public static let readMarker = "R"
    public static let writeMarker = "W"
    public static let readAccessibilityLabel = "Disk read"
    public static let writeAccessibilityLabel = "Disk write"
    /// 1M: background activity below this stays flat.
    public static let sparklineFloor: Double = 1_000_000
}
