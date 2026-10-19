import Darwin
import Foundation

/// The virtual memory counters behind Activity Monitor's Memory Used, in pages.
public struct MemoryPages: Equatable, Sendable {
    /// Anonymous pages: memory apps allocated, as opposed to cached files.
    public var anonymous: UInt64
    /// Anonymous pages an app has marked as discardable.
    public var purgeable: UInt64
    public var wired: UInt64
    /// Pages occupied by the compressor.
    public var compressed: UInt64

    public init(anonymous: UInt64, purgeable: UInt64, wired: UInt64, compressed: UInt64) {
        self.anonymous = anonymous
        self.purgeable = purgeable
        self.wired = wired
        self.compressed = compressed
    }
}

/// Data source for memory use. The Memory module reads only through this protocol
///, so tests can substitute a fake.
public protocol MemorySource: Sendable {
    /// Installed memory, in bytes.
    var physicalMemory: UInt64 { get }
    /// Bytes per page.
    var pageSize: UInt64 { get }
    /// The current counters, or `nil` when the read fails.
    func readPages() -> MemoryPages?
}

/// Documented source: the Mach virtual memory statistics.
public struct MachMemorySource: MemorySource {
    private let host = MachHostPort()
    public let physicalMemory = ProcessInfo.processInfo.physicalMemory
    public let pageSize = UInt64(getpagesize())

    public init() {}

    public func readPages() -> MemoryPages? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host.name, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return MemoryPages(
            anonymous: UInt64(info.internal_page_count), purgeable: UInt64(info.purgeable_count),
            wired: UInt64(info.wire_count), compressed: UInt64(info.compressor_page_count))
    }
}

public enum MemoryUsage {
    /// Memory Used as a share of physical memory, from 0 to 1: app memory
    /// (anonymous minus purgeable, never below zero) plus wired plus compressed, as Activity Monitor
    /// defines it.
    public static func fraction(_ pages: MemoryPages, pageSize: UInt64, physicalMemory: UInt64) -> Double? {
        guard physicalMemory > 0 else { return nil }
        let app = pages.anonymous > pages.purgeable ? pages.anonymous - pages.purgeable : 0
        let used = Double(app + pages.wired + pages.compressed) * Double(pageSize)
        return min(1, max(0, used / Double(physicalMemory)))
    }
}

/// Turns memory readings into the Memory module's value and sparkline history.
/// Each reading stands on its own, so there is no baseline.
public struct MemoryMeter: ModuleMeter {
    /// The value to display; `nil` shows the placeholder.
    public private(set) var percent: Int?
    public private(set) var history = SampleHistory(capacity: MeterTiming.historyCapacity)
    /// Follows macOS memory pressure, not the percent.
    public private(set) var highlight = Highlight(levels: true)

    private let source: any MemorySource
    private let pressure: (any MemoryPressureSource)?

    /// Without a pressure source, the row never leaves the normal state.
    public init(source: any MemorySource, pressure: (any MemoryPressureSource)? = nil) {
        self.source = source
        self.pressure = pressure
    }

    @discardableResult
    public mutating func applyThresholds(_ settings: ThresholdSettings) -> Bool {
        highlight.setFollowsLevels(settings.highlights(.memory))
    }

    @discardableResult
    public mutating func resetStates() -> Bool {
        highlight.reset()
    }

    public mutating func sample(at now: ContinuousClock.Instant) {
        let fraction = source.readPages().flatMap {
            MemoryUsage.fraction($0, pageSize: source.pageSize, physicalMemory: source.physicalMemory)
        }
        percent = fraction.map(MeterText.percent)
        history.append(fraction)
        // The state follows memory pressure, not the percent. Unreadable pressure forgets the recent states,
        // so an old warning cannot remain visible and recovery needs three new readings.
        if percent == nil {
            highlight.record(nil)
        } else if let level = pressure?.readPressure()?.state {
            highlight.record(level: level)
        } else {
            highlight.record(nil)
        }
    }

    public var rows: [MeterRow] {
        [
            MeterRow(
                value: MeterText.value(percent), spokenValue: MemoryModuleText.spoken(percent),
                samples: history.samples, hasData: percent != nil, state: highlight.state, offersGauge: true,
                gaugeFraction: percent.map { Double($0) / 100 })
        ]
    }
}

/// The Memory module's visible and spoken text.
public enum MemoryModuleText {
    public static let label = "MEM"
    public static let accessibilityLabel = "Memory"

    public static func spoken(_ percent: Int?) -> String {
        percent.map { "\($0) percent used" } ?? MeterText.noData
    }
}
