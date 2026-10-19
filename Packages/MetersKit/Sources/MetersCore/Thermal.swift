import Foundation

/// Data source for the system's thermal state. The Thermal module reads only through this protocol.
public protocol ThermalStateSource: Sendable {
    func readThermalState() -> ProcessInfo.ThermalState
}

/// Documented source: `ProcessInfo.thermalState`, read each second.
public struct SystemThermalSource: ThermalStateSource {
    public init() {}

    public func readThermalState() -> ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }
}

/// Turns the thermal state into the Thermal module's word.
public struct ThermalMeter: ModuleMeter {
    public private(set) var thermalState: ProcessInfo.ThermalState?
    /// Hot and Critical color the row while highlighting is on.
    public private(set) var highlight = Highlight(levels: true)

    private let source: any ThermalStateSource

    public init(source: any ThermalStateSource) {
        self.source = source
    }

    @discardableResult
    public mutating func applyThresholds(_ settings: ThresholdSettings) -> Bool {
        highlight.setFollowsLevels(settings.highlights(.thermal))
    }

    @discardableResult
    public mutating func resetStates() -> Bool {
        highlight.reset()
    }

    public mutating func sample(at now: ContinuousClock.Instant) {
        let reading = source.readThermalState()
        thermalState = reading
        highlight.record(level: Self.state(for: reading))
    }

    /// Hot is elevated and Critical critical; OK and Warm are normal. A state added in a later macOS counts as
    /// critical, as its word does.
    public static func state(for reading: ProcessInfo.ThermalState) -> ThresholdState {
        switch reading {
        case .nominal, .fair: .normal
        case .serious: .elevated
        case .critical: .critical
        @unknown default: .critical
        }
    }

    public var rows: [MeterRow] {
        [
            MeterRow(
                value: thermalState.map(ThermalModuleText.value) ?? MeterText.placeholder,
                spokenValue: thermalState.map(ThermalModuleText.spokenValue) ?? MeterText.noData,
                samples: [], hasData: thermalState != nil, state: highlight.state)
        ]
    }
}

/// The Thermal module's visible and spoken text.
public enum ThermalModuleText {
    public static let label = "HEAT"
    public static let accessibilityLabel = "Thermal state"

    /// "OK", "Warm", "Hot", or "Critical"; a state added in a later macOS reads as "Critical" (Edge Cases).
    public static func value(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "OK"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Critical"
        @unknown default: "Critical"
        }
    }

    /// "OK", "warm", "hot", or "critical".
    public static func spokenValue(_ state: ProcessInfo.ThermalState) -> String {
        state == .nominal ? "OK" : value(state).lowercased()
    }
}
