import Foundation

/// What one module row shows.
public struct MeterRow: Equatable, Sendable {
    /// The displayed value, such as "23%", "--", or "n/a".
    public var value: String
    /// The value as VoiceOver speaks it, such as "23 percent" or "no data".
    public var spokenValue: String
    /// Sparkline samples on a 0 to 1 scale, oldest first; `nil` marks a gap.
    public var samples: [Double?]
    /// Whether the row shows a reading, rather than a placeholder or an unavailable state.
    public var hasData: Bool
    /// Whether the source is unavailable ("n/a"), which shows the value in the secondary label color.
    public var isUnavailable: Bool
    /// A second value shown beside the first, in place of the sparkline (the one-row rate form).
    public var secondValue: String?
    /// A marker that changes with the reading, such as the battery's direction arrow; it takes the place of
    /// the row's fixed marker.
    public var valueMarker: String?
    /// The row's threshold state after the 3-reading rule.
    public var state: ThresholdState
    /// Whether the row shows a gauge when Gauges is chosen.
    public var offersGauge: Bool
    /// The gauge's fill from 0 to 1; `nil` shows the empty track.
    public var gaugeFraction: Double?
    /// Optional device names for the one-row rate form's middle label.
    public var deviceName: String?

    public init(
        value: String, spokenValue: String, samples: [Double?], hasData: Bool, isUnavailable: Bool = false,
        secondValue: String? = nil, valueMarker: String? = nil, state: ThresholdState = .normal,
        offersGauge: Bool = false, gaugeFraction: Double? = nil, deviceName: String? = nil
    ) {
        self.value = value
        self.spokenValue = spokenValue
        self.samples = samples
        self.hasData = hasData
        self.isUnavailable = isUnavailable
        self.secondValue = secondValue
        self.valueMarker = valueMarker
        self.state = state
        self.offersGauge = offersGauge
        self.gaugeFraction = gaugeFraction.map { min(1, max(0, $0)) }
        self.deviceName = deviceName
    }
}

/// Turns a data source's readings into the rows a module displays. Every module samples through this
/// protocol, so each metric supplies only its reading and its text.
public protocol ModuleMeter: Sendable {
    /// The rows to display, top to bottom. The count never changes.
    var rows: [MeterRow] { get }
    /// Records the baseline the next reading is measured against, at launch and after wake.
    mutating func rebaseline(at now: ContinuousClock.Instant)
    mutating func sample(at now: ContinuousClock.Instant)
    /// The time between readings. Meters that measure against a baseline start a
    /// fresh one when a reading comes more than 3 intervals after it.
    mutating func setInterval(_ interval: Duration)
    /// The user's thresholds. Switching a module's highlighting off returns its rows to
    /// normal at once; new numbers apply from the next reading. Returns whether a row's state changed.
    @discardableResult
    mutating func applyThresholds(_ settings: ThresholdSettings) -> Bool
    /// Forgets the recent readings' states, as after sleep: rows are normal until 3 new readings agree
    ///. Returns whether a row's state changed.
    @discardableResult
    mutating func resetStates() -> Bool
}

extension ModuleMeter {
    /// Meters whose readings stand on their own need no baseline.
    public mutating func rebaseline(at now: ContinuousClock.Instant) {}
    public mutating func setInterval(_ interval: Duration) {}
    @discardableResult
    public mutating func applyThresholds(_ settings: ThresholdSettings) -> Bool { false }
    @discardableResult
    public mutating func resetStates() -> Bool { false }
}

/// How old a baseline may be before a reading starts a fresh one instead: 3 intervals. The first reading after an
/// interval change may still be measured against a baseline taken on the old schedule, so the longer of the two
/// limits applies to it.
public struct StalenessLimit: Equatable, Sendable {
    private var current = MeterTiming.staleAfter
    private var next = MeterTiming.staleAfter

    public init() {}

    public mutating func setInterval(_ interval: Duration) {
        next = MeterTiming.staleAfter(interval: interval)
        current = max(current, next)
    }

    /// The limit for this reading; readings after it use the current interval's.
    public mutating func take() -> Duration {
        defer { current = next }
        return current
    }
}

/// Sampling timing shared by every module.
public enum MeterTiming {
    public static let historyCapacity = 60
    public static let interval: Duration = .seconds(1)
    /// The first reading follows the launch baseline this soon, so the first value appears within 1 s.
    public static let primingDelay: Duration = .milliseconds(250)
    /// A reading this long after its baseline (sleep, a stalled process) starts a fresh baseline instead, at the
    /// default interval.
    public static let staleAfter: Duration = .seconds(3)
    /// The same limit at any interval: 3 intervals.
    public static func staleAfter(interval: Duration) -> Duration { interval * 3 }
    /// The intervals the Settings window offers, in seconds.
    public static let intervalChoices: [Double] = [0.5, 1, 2, 5]
}

/// Value text shared by the percent modules.
public enum MeterText {
    public static let placeholder = "--"
    public static let noData = "no data"

    /// Whole-number percent for display, from 0 to 100. The fraction is clamped before converting, so a corrupt
    /// reading (infinite, not a number, or huge) can never trap.
    public static func percent(_ fraction: Double) -> Int {
        let clamped = fraction.isNaN ? 0 : min(1, max(0, fraction))
        return Int((clamped * 100).rounded())
    }

    public static func value(_ percent: Int?) -> String {
        percent.map { "\($0)%" } ?? placeholder
    }

    public static func spoken(_ percent: Int?) -> String {
        percent.map { "\($0) percent" } ?? noData
    }
}
