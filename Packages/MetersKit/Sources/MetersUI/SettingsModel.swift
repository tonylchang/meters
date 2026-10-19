import AppKit
import MetersCore
import Observation
import SwiftUI

/// The Settings window's state and actions. It reads and writes the
/// settings store, so every change reaches the HUD at once, and it follows changes made elsewhere.
@MainActor
@Observable
public final class SettingsModel {
    public enum Tab: String, Sendable {
        case general
        case modules
        case thresholds
        case hud
    }

    /// A note under the Launch at login checkbox.
    public enum LoginItemNote: Equatable, Sendable {
        case needsApproval
        case failed

        public var text: String {
            switch self {
            case .needsApproval: "meters needs your approval to launch at login."
            case .failed: "Couldn't change the login item. Try again, or open Login Items."
            }
        }
    }

    private var resolved: ResolvedSettings { store.state.resolved(for: capabilities) }
    public var entries: [ModuleEntry] { resolved.entries }
    public var cpuForm: CPUForm { store.state.cpuForm }
    public var networkForm: RateForm { store.state.networkForm }
    public var diskForm: RateForm { store.state.diskForm }
    /// Whether macOS starts meters at login, as macOS reports it.
    public private(set) var launchAtLogin = false
    public private(set) var loginItemNote: LoginItemNote?
    /// The tab on show; the window reopens on the last one used.
    public var tab: Tab = .modules {
        didSet {
            store.settingsTab = tab.rawValue
            onTabChange?(tab)
        }
    }
    /// Lets the window follow a tab change made in the model.
    @ObservationIgnored var onTabChange: ((Tab) -> Void)?

    @ObservationIgnored private let store: HUDSettingsStore
    @ObservationIgnored private var storeObserver: UUID?
    @ObservationIgnored private let thresholdWriteOrigin = UUID()
    /// What this Mac can show: whether Battery is offered, and how many rows the CPU clusters form needs.
    public let capabilities: SystemCapabilities
    @ObservationIgnored private let loginItem: any LoginItemService

    public init(
        store: HUDSettingsStore, capabilities: SystemCapabilities = .current(),
        loginItem: any LoginItemService = SystemLoginItemService()
    ) {
        self.store = store
        self.capabilities = capabilities
        // Read when the window is shown, not at launch, so a launch never queries the login item.
        self.loginItem = loginItem
        tab = store.settingsTab.flatMap(Tab.init(rawValue:)) ?? .modules
        storeObserver = store.addObserver { [weak self] change in
            self?.settingsChanged(change)
        }
    }

    isolated deinit {
        if let storeObserver { store.removeObserver(storeObserver) }
    }

    func reconcileSettings() { store.reload() }

    private func settingsChanged(_ change: SettingsChange) {
        guard change.origin != thresholdWriteOrigin else { return }
        for id in ThresholdEditor.modules
        where change.previous.thresholds[id] != change.current.thresholds[id] {
            resetThresholdEditor(id)
        }
    }

    public var forms: ModuleForms { resolved.forms }

    // MARK: - Modules

    /// Whether this Mac can show the module; Battery needs a battery.
    public func isAvailable(_ id: ModuleID) -> Bool {
        !capabilities.unavailableModules.contains(id)
    }

    /// The note beside a module this Mac cannot show: "No battery".
    public func unavailableNote(_ id: ModuleID) -> String? {
        isAvailable(id) ? nil : BatteryModuleText.noBattery
    }

    /// A module this Mac cannot show cannot be checked, and the last checked module it can show cannot be
    /// unchecked.
    public func canToggle(_ id: ModuleID) -> Bool {
        guard isAvailable(id) else { return false }
        let checked = entries.filter { $0.isOn && isAvailable($0.id) }
        return !(checked.count == 1 && checked[0].id == id)
    }

    public func setOn(_ id: ModuleID, _ isOn: Bool) {
        guard isAvailable(id) else { return }
        store.update { state in
            var entries = state.resolved(for: capabilities).entries
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            if !isOn, entries.filter(\.isOn).count == 1, entries[index].isOn { return }
            entries[index].isOn = isOn
            state.modules = entries
        }
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        store.update { state in
            var entries = state.resolved(for: capabilities).entries
            entries.move(fromOffsets: source, toOffset: destination)
            state.modules = entries
        }
    }

    public func moveUp(_ id: ModuleID) {
        store.reload()
        guard let index = entries.firstIndex(where: { $0.id == id }), index > 0 else { return }
        move(fromOffsets: [index], toOffset: index - 1)
    }

    public func moveDown(_ id: ModuleID) {
        store.reload()
        guard let index = entries.firstIndex(where: { $0.id == id }), index < entries.count - 1 else { return }
        move(fromOffsets: [index], toOffset: index + 2)
    }

    public func form(_ id: ModuleID) -> RateForm {
        id == .disk ? diskForm : networkForm
    }

    /// Switches a two-rate module's form; the HUD's height follows.
    public func setForm(_ id: ModuleID, _ form: RateForm) {
        guard id == .network || id == .disk else { return }
        store.update { state in
            if id == .network { state.networkForm = form } else { state.diskForm = form }
        }
    }

    public func setCPUForm(_ form: CPUForm) {
        store.cpuForm = form
    }

    // MARK: - General

    /// Reads macOS's current state, as when the window is shown or becomes key. Clears a failure note.
    public func refreshLoginItem() {
        apply(loginItem.status)
    }

    /// Registers or unregisters the login item; on failure, shows the system's actual state and a note.
    public func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try loginItem.register() } else { try loginItem.unregister() }
            apply(loginItem.status)
        } catch {
            apply(loginItem.status)
            loginItemNote = .failed
        }
    }

    public func openLoginItems() {
        loginItem.openSystemSettings()
    }

    private func apply(_ status: LoginItemStatus) {
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginItemNote = status == .requiresApproval ? .needsApproval : nil
    }

    // MARK: - Graphs

    public var graphStyle: GraphStyle { store.state.graphStyle }

    public func setGraphStyle(_ style: GraphStyle) {
        store.graphStyle = style
    }

    // MARK: - Sampling interval

    /// Seconds between readings.
    public var sampleInterval: Double { store.state.sampleInterval }

    public static func intervalName(_ seconds: Double) -> String {
        "\(seconds.formatted(.number.precision(.fractionLength(0...1)))) s"
    }

    public func setSampleInterval(_ seconds: Double) {
        guard MeterTiming.intervalChoices.contains(seconds) else { return }
        store.sampleInterval = seconds
    }

    // MARK: - Thresholds

    public enum ThresholdLevel: Sendable {
        case elevated
        case critical
    }

    public var thresholds: ThresholdSettings { store.state.thresholds }
    private var thresholdEditors: [ModuleID: ThresholdEditSession] = [:]
    public var thresholdDrafts: [ModuleID: ThresholdSetting] { thresholdEditors.compactMapValues(\.draft) }
    public var thresholdProblems: [ModuleID: String] { thresholdEditors.compactMapValues(\.problem) }
    public var thresholdEditVersions: [ModuleID: Int] { thresholdEditors.mapValues(\.revision) }

    func thresholdEditVersion(_ id: ModuleID) -> Int {
        return thresholdEditors[id, default: ThresholdEditSession()].revision
    }

    /// The Thresholds tab's modules, in the Modules tab's order.
    public var thresholdModules: [ModuleID] {
        entries.map(\.id).filter { ThresholdEditor.modules.contains($0) }
    }

    /// What a module's fields show: an unsaved entry, or the saved one.
    public func threshold(_ id: ModuleID) -> ThresholdSetting {
        thresholdEditors[id]?.draft ?? thresholds[id]
    }

    /// Switches a module's highlighting at once.
    public func setHighlight(_ id: ModuleID, _ on: Bool) {
        store.reload()
        var setting = thresholds[id]
        setting.highlight = on
        save(id, setting)
        thresholdEditors[id]?.draft?.highlight = on
    }

    /// Commits one field: saved at once when the pair is valid, otherwise kept as a draft with its problem.
    public func setThreshold(_ id: ModuleID, _ level: ThresholdLevel, _ value: Double?) {
        store.reload()
        guard let fields = ThresholdEditor.fields(id) else { return }
        var setting = threshold(id)
        switch level {
        case .elevated: setting.elevated = value
        case .critical: setting.critical = value
        }
        if let problem = fields.problem(elevated: setting.elevated, critical: setting.critical) {
            thresholdEditors[id, default: ThresholdEditSession()].draft = setting
            thresholdEditors[id, default: ThresholdEditSession()].problem = problem
        } else {
            thresholdEditors[id, default: ThresholdEditSession()].commit()
            save(id, setting)
        }
    }

    /// Text that cannot be parsed uses the existing range message and never changes the saved pair.
    func invalidThresholdText(_ id: ModuleID) {
        thresholdEditors[id, default: ThresholdEditSession()].problem =
            ThresholdEditor.fields(id)?.problem(elevated: .nan, critical: nil)
        thresholdEditors[id, default: ThresholdEditSession()].hasUnreadableText = true
    }

    private func resetThresholdEditor(_ id: ModuleID) {
        thresholdEditors[id, default: ThresholdEditSession()].discard()
    }

    /// One stepper click: up or down by the field's step, kept within its range. An empty field starts from
    /// the other field's number, or from the range's low end.
    public func stepThreshold(_ id: ModuleID, _ level: ThresholdLevel, up: Bool) {
        store.reload()
        guard let fields = ThresholdEditor.fields(id) else { return }
        let setting = threshold(id)
        let current = level == .elevated ? setting.elevated : setting.critical
        let other = level == .elevated ? setting.critical : setting.elevated
        let next: Double
        if let current {
            next = min(
                max(current + (up ? fields.step : -fields.step), fields.range.lowerBound), fields.range.upperBound)
        } else {
            next = other ?? fields.range.lowerBound
        }
        setThreshold(id, level, next)
    }

    /// Every module back to the defaults, at once.
    public func restoreThresholdDefaults() {
        for id in ThresholdEditor.modules { resetThresholdEditor(id) }
        store.update(origin: thresholdWriteOrigin) { $0.thresholds = .defaults }
    }

    /// Unsaved entries are dropped when the window closes (Edge Cases).
    public func discardThresholdDrafts() {
        for id in ThresholdEditor.modules { resetThresholdEditor(id) }
    }

    private func save(_ id: ModuleID, _ setting: ThresholdSetting) {
        store.update(origin: thresholdWriteOrigin) { $0.thresholds[id] = setting }
    }
}
