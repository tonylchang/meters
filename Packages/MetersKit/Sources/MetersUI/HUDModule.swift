import AppKit
import MetersCore

/// A metric module hosted in the HUD's column.
///
/// A module's height changes only with its layout, never with its values; otherwise the HUD would resize
/// on every sample.
@MainActor
public protocol HUDModule: AnyObject {
    var identifier: String { get }
    var height: CGFloat { get }
    /// The width the module's widest row needs, without the HUD's padding. The HUD is as wide as its widest
    /// module.
    var width: CGFloat { get }
    /// The module's content. It should be an accessibility element so VoiceOver can reach it.
    var view: NSView { get }
    /// Set by the HUD. Modules call it after their height or width changes.
    var onSizeChange: (() -> Void)? { get set }
    /// What VoiceOver sees of the module, top to bottom: one element per row, so a two-rate module reads
    /// as two elements.
    var accessibilityElements: [NSView] { get }
    /// Begins sampling, after the module is added to the HUD.
    func start()
    /// Stops sampling, after the module leaves the HUD.
    func stop()
    /// The time between readings.
    func setInterval(_ interval: Duration)
    /// The user's thresholds.
    func applyThresholds(_ settings: ThresholdSettings)
    /// Sparklines or gauges.
    func setGraphStyle(_ style: GraphStyle)
}

extension HUDModule {
    public var accessibilityElements: [NSView] { [view] }
    public func start() {}
    public func stop() {}
    public func setInterval(_ interval: Duration) {}
    public func applyThresholds(_ settings: ThresholdSettings) {}
    public func setGraphStyle(_ style: GraphStyle) {}
}

/// Keeps the HUD's modules in step with the user's settings: which show, in what order, and in which form
///. Modules that leave the HUD stop sampling; modules
/// that join it start.
@MainActor
public final class ModuleLineup {
    public private(set) var shown: [ModuleID] = []

    private let settings: HUDSettingsStore
    private let hud: HUDController
    private let capabilities: SystemCapabilities
    private let makeModule: @MainActor (ModuleID) -> any HUDModule
    private var modules: [ModuleID: any HUDModule] = [:]
    private var lastApplied: SettingsState?
    private var storeObserver: UUID?

    public init(
        settings: HUDSettingsStore, hud: HUDController, capabilities: SystemCapabilities = .current(),
        makeModule: (@MainActor (ModuleID) -> any HUDModule)? = nil
    ) {
        self.settings = settings
        self.hud = hud
        self.capabilities = capabilities
        self.makeModule = makeModule ?? { ModuleLineup.systemModule($0, capabilities: capabilities) }
    }

    /// The module for `id`, reading the system.
    public static func systemModule(_ id: ModuleID, capabilities: SystemCapabilities) -> any HUDModule {
        switch id {
        case .cpu: CPUModule(clusters: capabilities.clusters ?? SystemSources.cpuClusters())
        case .memory: MemoryModule()
        case .gpu: GPUModule()
        case .network: NetworkModule.network()
        case .disk: DiskModule.disk()
        case .battery: BatteryModule()
        case .thermal: ThermalModule()
        case .swap: SwapModule()
        case .freeSpace: FreeSpaceModule()
        }
    }

    /// Shows the selected modules, then follows every later settings change.
    public func start() {
        guard storeObserver == nil else { return }
        apply()
        storeObserver = settings.addObserver { [weak self] change in self?.apply(change.current) }
    }

    isolated deinit {
        if let storeObserver { settings.removeObserver(storeObserver) }
    }

    /// The module for `id`, once created.
    public func module(_ id: ModuleID) -> (any HUDModule)? {
        modules[id]
    }

    func apply() { apply(settings.state) }

    private func apply(_ state: SettingsState) {
        guard state != lastApplied else { return }
        let previous = lastApplied
        let resolved = state.resolved(for: capabilities)
        let ids = resolved.shown
        let joining = Set(ids.filter { modules[$0] == nil })
        for id in joining { modules[id] = makeModule(id) }
        // Configure all forms and the final column before performing one layout.
        hud.withLayoutUpdate {
            if joining.contains(.cpu) || previous?.cpuForm != state.cpuForm {
                (modules[.cpu] as? CPUFormSwitching)?.setForm(resolved.forms.cpu)
            }
            if joining.contains(.network) || previous?.networkForm != state.networkForm {
                (modules[.network] as? RateFormSwitching)?.setForm(resolved.forms.network)
            }
            if joining.contains(.disk) || previous?.diskForm != state.diskForm {
                (modules[.disk] as? RateFormSwitching)?.setForm(resolved.forms.disk)
            }
            for id in ids {
                guard let module = modules[id] else { continue }
                if joining.contains(id) || previous?.sampleInterval != state.sampleInterval {
                    module.setInterval(.seconds(state.sampleInterval))
                }
                if joining.contains(id) || previous?.thresholds[id] != state.thresholds[id] {
                    module.applyThresholds(state.thresholds)
                }
                if joining.contains(id) || previous?.graphStyle != state.graphStyle {
                    module.setGraphStyle(state.graphStyle)
                }
            }
            if ids != shown { hud.setModules(ids.compactMap { modules[$0] }) }
        }
        for id in shown where !ids.contains(id) {
            modules[id]?.stop()
            modules[id] = nil
        }
        for id in ids where !shown.contains(id) { modules[id]?.start() }
        shown = ids
        lastApplied = state
    }
}
