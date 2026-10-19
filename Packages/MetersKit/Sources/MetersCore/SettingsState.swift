import Foundation

/// Committed preferences. Editing drafts and system-owned login-item state live outside this snapshot.
public struct SettingsState: Equatable, Sendable {
    public var isHUDVisible = true
    public var placement: HUDPlacement?
    public var modules = ModuleSelection.defaultEntries
    public var networkForm: RateForm = .oneRow
    public var diskForm: RateForm = .oneRow
    public var cpuForm: CPUForm = .total
    public var settingsTab: String?
    public var sampleInterval: Double = 1
    public var thresholds = ThresholdSettings.defaults
    public var graphStyle: GraphStyle = .sparklines

    public init() {}

    func normalized() -> Self {
        var result = self
        result.modules = ModuleSelection.normalized(modules.map { ($0.id.rawValue, $0.isOn) })
        if !MeterTiming.intervalChoices.contains(sampleInterval) { result.sampleInterval = 1 }
        if let placement, !placement.offset.width.isFinite || !placement.offset.height.isFinite {
            result.placement = nil
        }
        for id in ThresholdEditor.modules {
            let setting = thresholds[id]
            if let fields = ThresholdEditor.fields(id),
                fields.problem(elevated: setting.elevated, critical: setting.critical) != nil
            {
                result.thresholds[id] = ThresholdSettings.defaultSetting(id)
            }
        }
        return result
    }

    /// Both Settings and the HUD derive their selection and forms from the same inputs.
    public func resolved(for capabilities: SystemCapabilities) -> ResolvedSettings {
        ResolvedSettings(state: self, capabilities: capabilities)
    }
}

public struct ResolvedSettings: Equatable, Sendable {
    public let entries: [ModuleEntry]
    public let forms: ModuleForms
    public let shown: [ModuleID]

    init(state: SettingsState, capabilities: SystemCapabilities) {
        let unavailable = capabilities.unavailableModules
        forms = ModuleForms(
            cpu: state.cpuForm, network: state.networkForm, disk: state.diskForm,
            cpuClusters: capabilities.cpuClusters)
        entries = ModuleSelection.effective(state.modules, unavailable: unavailable)
        shown = ModuleSelection.shown(entries, unavailable: unavailable)
    }
}

/// A complete transition, delivered once for a local update, even when several preference keys change.
public struct SettingsChange: Equatable, Sendable {
    public let previous: SettingsState
    public let current: SettingsState
    /// Identifies an editor's own commit even when another observer queued it during notification delivery.
    public let origin: UUID?
}
