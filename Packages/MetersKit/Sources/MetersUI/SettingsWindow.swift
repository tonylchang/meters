import AppKit
import MetersCore
import SwiftUI

/// The Settings window: a window meters owns, hosting SwiftUI content, so the AppKit menu can open it and
/// bring it forward.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    public static let title = "meters Settings"

    public let model: SettingsModel
    public private(set) var window: NSWindow?

    public init(
        settings: HUDSettingsStore, capabilities: SystemCapabilities = .current(),
        loginItem: any LoginItemService = SystemLoginItemService()
    ) {
        model = SettingsModel(store: settings, capabilities: capabilities, loginItem: loginItem)
    }

    /// Opens the window, or brings it forward if it is open, and makes meters the active app.
    public func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        model.refreshLoginItem()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // macOS can decline to activate meters, for example when Settings is opened with ⌘, from the menu bar
        // item; the window would then open behind the app in use (measured Sep 27, 2026). Keep it in front.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: SettingsTabViewController(model: model))
        window.title = Self.title
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    // meters has no Dock icon, so hand focus back to the app in use when Settings closes.
    public func windowWillClose(_ notification: Notification) {
        window?.endEditing(for: nil)
        model.discardThresholdDrafts()
        NSApp.deactivate()
    }

    // Login Items may have changed in System Settings while the window was in the background.
    public func windowDidBecomeKey(_ notification: Notification) {
        model.refreshLoginItem()
    }
}

/// The Settings tabs as buttons in the window's toolbar, the standard macOS Settings layout. Moving VoiceOver
/// across toolbar buttons does not switch tabs, so each tab's content is reachable; with a tab bar, moving
/// across the tabs switched them, and only the last tab's content could be reached.
@MainActor
final class SettingsTabViewController: NSTabViewController {
    static let tabs: [(tab: SettingsModel.Tab, label: String, symbol: String)] = [
        (.general, "General", "gearshape"), (.modules, "Modules", "square.grid.2x2"),
        (.thresholds, "Thresholds", "gauge.with.dots.needle.67percent"), (.hud, "HUD", "macwindow"),
    ]
    /// Every tab's content size, so switching tabs never resizes the window.
    static let paneSize = CGSize(width: 440, height: 340)

    let model: SettingsModel
    /// Adding the tabs and loading the view select the first tab; that must not overwrite the tab the window
    /// reopens on.
    private var isSettingUp = true
    private let reopenOn: SettingsModel.Tab

    init(model: SettingsModel) {
        self.model = model
        reopenOn = model.tab
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        // The window keeps its title, "meters Settings", rather than taking the tab's.
        canPropagateSelectedChildViewControllerTitle = false
        for entry in Self.tabs {
            let item = NSTabViewItem(viewController: Self.pane(entry.tab, model: model))
            item.identifier = entry.tab.rawValue
            item.label = entry.label
            item.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
            addTabViewItem(item)
        }
        model.onTabChange = { [weak self] tab in self?.select(tab) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        isSettingUp = false
        select(reopenOn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func select(_ tab: SettingsModel.Tab) {
        guard let index = Self.tabs.firstIndex(where: { $0.tab == tab }), selectedTabViewItemIndex != index else {
            return
        }
        selectedTabViewItemIndex = index
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard !isSettingUp, let identifier = tabViewItem?.identifier as? String,
            let tab = SettingsModel.Tab(rawValue: identifier),
            model.tab != tab
        else { return }
        model.tab = tab
    }

    private static func pane(_ tab: SettingsModel.Tab, model: SettingsModel) -> NSViewController {
        func host(_ content: some View) -> NSViewController {
            let controller = NSHostingController(
                rootView: content.padding(20).frame(width: paneSize.width, height: paneSize.height, alignment: .top))
            controller.sizingOptions = .preferredContentSize
            return controller
        }
        switch tab {
        case .general: return host(GeneralTab(model: model))
        case .modules: return host(ModulesTab(model: model))
        case .thresholds: return host(ThresholdsTab(model: model))
        case .hud: return host(HUDTab(model: model))
        }
    }
}

/// General: Launch at login, with a note when macOS needs approval or a change fails.
struct GeneralTab: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Toggle(
                "Launch at login",
                isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })
            )
            // A checkbox: a grouped form would otherwise draw a switch.
            .toggleStyle(.checkbox)
            if let note = model.loginItemNote {
                HStack {
                    Label(note.text, systemImage: "info.circle")
                    Spacer()
                    Button("Open Login Items") { model.openLoginItems() }
                }
                .font(.callout)
            }
            // How often every module takes a reading.
            Picker(
                "Update every",
                selection: Binding(get: { model.sampleInterval }, set: { model.setSampleInterval($0) })
            ) {
                ForEach(MeterTiming.intervalChoices, id: \.self) { Text(SettingsModel.intervalName($0)).tag($0) }
            }
            .pickerStyle(.menu)
        }
        .formStyle(.grouped)
        // VoiceOver reads the note when it shows.
        .onChange(of: model.loginItemNote) { _, note in
            if let note { AccessibilityNotification.Announcement(note.text).post() }
        }
    }
}

/// Modules: checkboxes, drag to reorder, and the CPU, Network, and Disk forms.
struct ModulesTab: View {
    let model: SettingsModel

    var body: some View {
        List {
            ForEach(model.entries, id: \.id) { entry in
                HStack {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Toggle(
                        entry.id.name,
                        // A module this Mac cannot show reads as unchecked, whatever is stored.
                        isOn: Binding(
                            get: { entry.isOn && model.isAvailable(entry.id) }, set: { model.setOn(entry.id, $0) })
                    )
                    .toggleStyle(.checkbox)
                    .disabled(!model.canToggle(entry.id))
                    Spacer()
                    if let note = model.unavailableNote(entry.id) {
                        Text(note)
                            .foregroundStyle(.secondary)
                    } else if entry.id == .cpu {
                        Picker(
                            "\(entry.id.name) form",
                            selection: Binding(get: { model.cpuForm }, set: { model.setCPUForm($0) })
                        ) {
                            ForEach(CPUForm.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    } else if entry.id.hasForms {
                        Picker(
                            "\(entry.id.name) form",
                            selection: Binding(get: { model.form(entry.id) }, set: { model.setForm(entry.id, $0) })
                        ) {
                            ForEach(RateForm.allCases, id: \.self) { Text($0.name).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .accessibilityAction(named: "Move Up") { model.moveUp(entry.id) }
                .accessibilityAction(named: "Move Down") { model.moveDown(entry.id) }
            }
            .onMove { model.move(fromOffsets: $0, toOffset: $1) }
        }
    }
}

/// HUD: the Graphs picker. The HUD's size follows the modules, so it has no size control.
struct HUDTab: View {
    let model: SettingsModel

    var body: some View {
        Form {
            // Sparklines or gauges for every module that offers a gauge.
            Picker(
                "Graphs", selection: Binding(get: { model.graphStyle }, set: { model.setGraphStyle($0) })
            ) {
                ForEach(GraphStyle.allCases, id: \.self) { Text($0.name).tag($0) }
            }
        }
        .formStyle(.grouped)
    }
}

/// Thresholds: each module's highlighting, with its numbers or a note, and Restore Defaults.
struct ThresholdsTab: View {
    let model: SettingsModel

    var body: some View {
        VStack(spacing: 10) {
            Form {
                ForEach(model.thresholdModules, id: \.self) { id in
                    Section(id.name) {
                        ThresholdEditorRows(model: model, id: id)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Restore Defaults") { model.restoreThresholdDefaults() }
            }
        }
    }
}

/// One module's switch and fields, or its note.
struct ThresholdEditorRows: View {
    let model: SettingsModel
    let id: ModuleID

    var body: some View {
        let setting = model.threshold(id)
        // On a Mac without a battery, Battery keeps its switch and fields, greyed out, with the note.
        let available = model.isAvailable(id)
        Toggle("Highlight", isOn: Binding(get: { setting.highlight }, set: { model.setHighlight(id, $0) }))
            .accessibilityLabel("Highlight \(id.name)")
            .disabled(!available)
        if let fields = ThresholdEditor.fields(id) {
            field(fields.elevatedLabel, unit: fields.unit, level: .elevated, name: "amber")
                .disabled(!available || !setting.highlight)
            field(fields.criticalLabel, unit: fields.unit, level: .critical, name: "red")
                .disabled(!available || !setting.highlight)
            if let problem = model.thresholdProblems[id] {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    // VoiceOver reads each message when it appears or changes.
                    .onChange(of: problem, initial: true) { _, text in
                        AccessibilityNotification.Announcement(text).post()
                    }
            }
        } else if let note = ThresholdEditor.note(id) {
            Text(note)
                .foregroundStyle(.secondary)
        }
        if let note = model.unavailableNote(id) {
            Text(note)
                .foregroundStyle(.secondary)
        }
    }

    private func field(
        _ label: String, unit: String, level: SettingsModel.ThresholdLevel, name: String
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                // Named for VoiceOver ("CPU amber threshold"); "None" is only the empty field's placeholder.
                ThresholdNumberField(
                    name: "\(id.name) \(name) threshold",
                    value: Binding(
                        get: {
                            let setting = model.threshold(id)
                            return level == .elevated ? setting.elevated : setting.critical
                        },
                        set: { model.setThreshold(id, level, $0) }),
                    resetVersion: model.thresholdEditVersions[id, default: 0],
                    currentResetVersion: { model.thresholdEditVersion(id) },
                    invalidText: { model.invalidThresholdText(id) },
                    prepareCommit: { model.reconcileSettings() }
                )
                .frame(width: 56)
                Stepper(
                    "\(id.name) \(name) threshold", onIncrement: { model.stepThreshold(id, level, up: true) },
                    onDecrement: { model.stepThreshold(id, level, up: false) }
                )
                .labelsHidden()
                Text(unit)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
