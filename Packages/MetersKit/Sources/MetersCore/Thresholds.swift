import Foundation

/// A row's threshold state.
public enum ThresholdState: Int, Comparable, Sendable {
    case normal
    case elevated
    case critical

    public static func < (lhs: ThresholdState, rhs: ThresholdState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Appended to the row's spoken phrase: "CPU, 85 percent, critical".
    public var spokenSuffix: String {
        switch self {
        case .normal: ""
        case .elevated: ", elevated"
        case .critical: ", critical"
        }
    }
}

/// When a reading is elevated or critical, for one metric.
public struct ThresholdRule: Equatable, Sendable {
    /// Which way is bad: high values (CPU) or low ones (Battery, Free space).
    public enum Direction: Equatable, Sendable {
        case high
        case low
    }

    /// One threshold, and whether a reading exactly at it counts ("70% to 80%" includes 70; "above 80%" does
    /// not include 80).
    public struct Bound: Equatable, Sendable {
        public var value: Double
        public var inclusive: Bool

        public init(_ value: Double, inclusive: Bool) {
            self.value = value
            self.inclusive = inclusive
        }
    }

    public var direction: Direction
    /// `nil` means the state is off for this metric, such as GPU's critical.
    public var elevated: Bound?
    public var critical: Bound?

    public init(direction: Direction, elevated: Bound?, critical: Bound?) {
        self.direction = direction
        self.elevated = elevated
        self.critical = critical
    }

    /// The state one reading implies on its own, before the 3-reading rule.
    public func state(for value: Double) -> ThresholdState {
        if let critical, meets(critical, value) { return .critical }
        if let elevated, meets(elevated, value) { return .elevated }
        return .normal
    }

    private func meets(_ bound: Bound, _ value: Double) -> Bool {
        switch direction {
        case .high: bound.inclusive ? value >= bound.value : value > bound.value
        case .low: bound.inclusive ? value <= bound.value : value < bound.value
        }
    }
}

/// The default thresholds, taken from the
/// Thresholds tab's defaults so the two can never disagree. Memory and Thermal follow macOS's own levels instead.
public enum ThresholdDefaults {
    /// Percent: 70% to 80% elevated, above 80% critical. Also each CPU cluster row.
    public static let cpu = rule(.cpu)
    /// Percent: 90% or more elevated; no critical.
    public static let gpu = rule(.gpu)
    /// Percent, while draining: 20% or below elevated, 10% or below critical.
    public static let battery = rule(.battery)
    /// Bytes: over 1 GB elevated, over 8 GB critical.
    public static let swap = rule(.swap)
    /// Percent of the startup volume's capacity: under 10% elevated, under 5% critical.
    public static let freeSpace = rule(.freeSpace)

    private static func rule(_ id: ModuleID) -> ThresholdRule {
        guard let rule = ThresholdSettings.defaults.rule(for: id) else {
            preconditionFailure("\(id) has default thresholds")
        }
        return rule
    }
}

/// One row's highlighting: how a reading becomes a state, and the 3-reading rule over the readings. Every meter
/// keeps its rows' highlighting in this one type, so switching it off, sleep, and missing readings behave the
/// same everywhere.
public struct Highlight: Equatable, Sendable {
    /// Numbers that make a reading elevated or critical; `nil` when highlighting is off, or for a row that
    /// follows macOS's own levels.
    public private(set) var rule: ThresholdRule?
    /// For a row that follows macOS's own levels (Memory pressure, Thermal): whether highlighting is on.
    public private(set) var followsLevels: Bool
    private var sustained = SustainedState()

    /// The row's state after the 3-reading rule.
    public var state: ThresholdState { sustained.state }

    /// A row judged by numbers.
    public init(rule: ThresholdRule?) {
        self.rule = rule
        followsLevels = false
    }

    /// A row that follows macOS's own levels, highlighted or not.
    public init(levels isOn: Bool) {
        rule = nil
        followsLevels = isOn
    }

    /// A reading judged by the numbers, or `nil` for a missing one.
    public mutating func record(_ value: Double?) {
        sustained.record(value.map { rule?.state(for: $0) ?? .normal })
    }

    /// A level macOS reports; normal while highlighting is off.
    public mutating func record(level: ThresholdState) {
        sustained.record(followsLevels ? level : .normal)
    }

    /// A reading that cannot be past a threshold, such as a battery that is not draining.
    public mutating func recordNormal() {
        sustained.record(.normal)
    }

    /// New numbers, from the Thresholds tab. Switching highlighting off returns the row to normal at once; new
    /// numbers apply from the next reading. Returns whether the state changed.
    @discardableResult
    public mutating func setRule(_ newRule: ThresholdRule?) -> Bool {
        guard newRule != rule else { return false }
        rule = newRule
        return newRule == nil ? reset() : false
    }

    /// Switches a level-following row on or off, as `setRule` does. Returns whether the state changed.
    @discardableResult
    public mutating func setFollowsLevels(_ isOn: Bool) -> Bool {
        guard isOn != followsLevels else { return false }
        followsLevels = isOn
        return isOn ? false : reset()
    }

    /// Forgets the recent readings, as after sleep or a restart: the row is normal until 3 new readings agree
    ///. Returns whether the state changed.
    @discardableResult
    public mutating func reset() -> Bool {
        let wasNormal = sustained.state == .normal
        sustained = SustainedState()
        return !wasNormal
    }
}

/// Applies the 3-reading rule: a row enters a higher state only when its last
/// 3 readings all meet it, and drops only when its last 3 readings all fall short of its current state. A
/// missing reading shows as normal and starts the count over.
public struct SustainedState: Equatable, Sendable {
    public static let readings = 3

    public private(set) var state: ThresholdState = .normal
    private var recent: [ThresholdState] = []

    public init() {}

    /// Records one reading's own state, or `nil` for a missing reading.
    public mutating func record(_ instant: ThresholdState?) {
        guard let instant else {
            state = .normal
            recent.removeAll()
            return
        }
        recent.append(instant)
        if recent.count > Self.readings { recent.removeFirst(recent.count - Self.readings) }
        guard recent.count == Self.readings, let lowest = recent.min(), let highest = recent.max() else { return }
        if lowest > state {
            state = lowest
        } else if highest < state {
            state = highest
        }
    }
}
