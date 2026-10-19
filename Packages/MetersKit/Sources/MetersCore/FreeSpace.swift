import Darwin
import Foundation

/// Data source for the startup volume's free space. The Free space module reads only through this protocol.
public protocol FreeSpaceSource: Sendable {
    /// Bytes available to ordinary use, as `df` counts them: cheap to read.
    func readAvailable() -> UInt64?
    /// Bytes available for important usage, as Finder counts them, including purgeable space: about 20 ms of
    /// CPU to read (measured Sep 27, 2026).
    func readAvailableForImportantUsage() -> UInt64?
    /// The volume's total capacity in bytes, for the threshold percentages.
    func readCapacity() -> UInt64?
}

extension FreeSpaceSource {
    /// Without a capacity, the row never leaves the normal state.
    public func readCapacity() -> UInt64? { nil }
}

/// Documented source: `statfs` and Foundation's volume resource values for `/`.
public struct SystemFreeSpaceSource: FreeSpaceSource {
    public init() {}

    public func readAvailable() -> UInt64? {
        var info = statfs()
        guard statfs("/", &info) == 0 else { return nil }
        return UInt64(info.f_bavail) * UInt64(info.f_bsize)
    }

    public func readCapacity() -> UInt64? {
        var info = statfs()
        guard statfs("/", &info) == 0 else { return nil }
        return UInt64(info.f_blocks) * UInt64(info.f_bsize)
    }

    public func readAvailableForImportantUsage() -> UInt64? {
        var volume = URL(fileURLWithPath: "/")
        volume.removeAllCachedResourceValues()
        let capacity = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        return capacity.flatMap { $0 >= 0 ? UInt64($0) : nil }
    }
}

/// Turns free-space readings into the Free space module's value.
///
/// Finder's figure is too costly to read every second (about 2% of a core), so the meter reads the cheap
/// `df` figure each second and adds the purgeable share, refreshed from Finder's figure every 60 s. The
/// value follows writes and deletions within a second and is never below `df`'s figure.
public struct FreeSpaceMeter: ModuleMeter {
    public static let purgeableRefresh: Duration = .seconds(60)

    public private(set) var bytes: UInt64?
    /// The volume's capacity, read with Finder's figure every 60 s, since it almost never changes; `nil` when
    /// unknown.
    public private(set) var capacity: UInt64?
    /// Judged by percent of capacity.
    public private(set) var highlight = Highlight(rule: ThresholdDefaults.freeSpace)

    private let source: any FreeSpaceSource
    private var purgeable: UInt64 = 0
    /// When Finder's figure was last read, successfully or not, so a failing read is not retried every second.
    private var lastRefresh: ContinuousClock.Instant?

    public init(source: any FreeSpaceSource) {
        self.source = source
    }

    @discardableResult
    public mutating func applyThresholds(_ settings: ThresholdSettings) -> Bool {
        highlight.setRule(settings.rule(for: .freeSpace))
    }

    @discardableResult
    public mutating func resetStates() -> Bool {
        highlight.reset()
    }

    public mutating func sample(at now: ContinuousClock.Instant) {
        guard let available = source.readAvailable() else {
            bytes = nil
            highlight.record(nil)
            return
        }
        if lastRefresh.map({ now - $0 >= Self.purgeableRefresh }) ?? true {
            lastRefresh = now
            if let important = source.readAvailableForImportantUsage() {
                purgeable = important > available ? important - available : 0
            }
            capacity = source.readCapacity().flatMap { $0 > 0 ? $0 : nil }
        }
        let free = available + purgeable
        bytes = free
        if let capacity {
            highlight.record(Double(free) / Double(capacity) * 100)
        } else {
            highlight.recordNormal()
        }
    }

    public var rows: [MeterRow] {
        [
            MeterRow(
                value: bytes.map { RateFormat.amount(Double($0), allowTerabytes: true) } ?? MeterText.placeholder,
                spokenValue: bytes.map { RateFormat.spokenAmount(Double($0), allowTerabytes: true) }
                    ?? MeterText.noData,
                samples: [], hasData: bytes != nil, state: highlight.state, offersGauge: true,
                // The disk's fullness, like Finder's storage bar.
                gaugeFraction: bytes.flatMap { free in capacity.map { 1 - Double(free) / Double($0) } })
        ]
    }
}

/// The Free space module's visible and spoken text.
public enum FreeSpaceModuleText {
    public static let label = "FREE"
    public static let accessibilityLabel = "Free space"
}
