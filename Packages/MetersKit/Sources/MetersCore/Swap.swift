import Darwin
import Foundation

/// Data source for swap space in use. The Swap module reads only through this protocol.
public protocol SwapSource: Sendable {
    /// Swap in use, in bytes, or `nil` when the read fails.
    func readSwapUsed() -> UInt64?
}

/// Documented source: `sysctl vm.swapusage`.
public struct SystemSwapSource: SwapSource {
    public init() {}

    public func readSwapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }
}

/// Turns swap readings into the Swap module's value. Each reading stands on its own.
public struct SwapMeter: ModuleMeter {
    public private(set) var bytes: UInt64?
    public private(set) var highlight = Highlight(rule: ThresholdDefaults.swap)

    private let source: any SwapSource

    public init(source: any SwapSource) {
        self.source = source
    }

    @discardableResult
    public mutating func applyThresholds(_ settings: ThresholdSettings) -> Bool {
        highlight.setRule(settings.rule(for: .swap))
    }

    @discardableResult
    public mutating func resetStates() -> Bool {
        highlight.reset()
    }

    public mutating func sample(at now: ContinuousClock.Instant) {
        bytes = source.readSwapUsed()
        // Compared as displayed, so "1.00G" is never "over 1 GB".
        highlight.record(bytes.map { RateFormat.displayedAmount(Double($0)) })
    }

    public var rows: [MeterRow] {
        [
            MeterRow(
                value: bytes.map { RateFormat.amount(Double($0)) } ?? MeterText.placeholder,
                spokenValue: bytes.map { RateFormat.spokenAmount(Double($0)) + " used" } ?? MeterText.noData,
                samples: [], hasData: bytes != nil, state: highlight.state)
        ]
    }
}

/// The Swap module's visible and spoken text.
public enum SwapModuleText {
    public static let label = "SWP"
    public static let accessibilityLabel = "Swap"
}
