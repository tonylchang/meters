import AppKit
import MetersCore

/// A metric module: one or more rows on the shared grid, sampled every second through a `ModuleMeter`.
///
/// Sampling continues while the HUD is hidden, so the sparklines are current when it is shown again;
/// rendering pauses whenever the module's window is not visible on screen.
@MainActor
public final class MeterModule<Meter: ModuleMeter>: HUDModule {
    public let identifier: String
    public private(set) var height: CGFloat
    public private(set) var width: CGFloat = 0
    public var onSizeChange: (() -> Void)?
    public var view: NSView { moduleView }
    public var accessibilityElements: [NSView] { moduleView.rowViews }

    private(set) var rowModels: [MeterRowModel]
    let moduleView: MeterModuleView
    /// Whether the module's view is visible on screen. Replaceable in tests.
    var isOnScreen: (NSView) -> Bool = { view in
        view.window?.occlusionState.contains(.visible) == true
    }
    /// Tells assistive apps a row's spoken value changed. VoiceOver keeps repeating the value it last
    /// read until it is told. Replaceable in tests.
    var announceValueChange: (NSView) -> Void = { view in
        NSAccessibility.post(element: view, notification: .valueChanged)
    }

    var meter: Meter
    /// The time between readings.
    public private(set) var interval: Duration = MeterTiming.interval
    /// Sparklines or gauges.
    public private(set) var graphStyle: GraphStyle = .sparklines
    private let scheduler: any SampleScheduling
    private let now: () -> ContinuousClock.Instant
    private var schedule: (any SampleSchedule)?
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    public init(
        identifier: String, rows labels: [MeterRowLabels], meter: Meter,
        scheduler: any SampleScheduling = RunLoopScheduler(),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        precondition(labels.count == meter.rows.count, "one label set per row")
        self.identifier = identifier
        self.meter = meter
        self.scheduler = scheduler
        self.now = now
        height = CGFloat(labels.count) * HUDMetrics.rowHeight
        rowModels = meter.rows.map { MeterRowModel(row: $0) }
        moduleView = MeterModuleView(
            rowViews: zip(labels, rowModels).map { MeterRowView(labels: $0, model: $1) })
        width = rowsWidth()
    }

    isolated deinit {
        schedule?.cancel()
        for observer in observers { observer.center.removeObserver(observer.token) }
    }

    /// Replaces the rows' labels to match the meter's current rows, as when a two-rate module switches
    /// form, and tells the HUD if the size changed.
    func reconfigure(rows labels: [MeterRowLabels]) {
        precondition(labels.count == meter.rows.count, "one label set per row")
        rowModels = meter.rows.map { MeterRowModel(row: $0, graphStyle: graphStyle) }
        moduleView.setRowViews(zip(labels, rowModels).map { MeterRowView(labels: $0, model: $1) })
        let newHeight = CGFloat(labels.count) * HUDMetrics.rowHeight
        let newWidth = rowsWidth()
        if newHeight != height || newWidth != width {
            height = newHeight
            width = newWidth
            onSizeChange?()
        }
        render()
    }

    /// The widest row's natural width: a gauge can widen a numbers-only row.
    private func rowsWidth() -> CGFloat {
        moduleView.rowViews.map {
            MeterRowContent.width(
                labels: $0.labels, offersGauge: $0.hostingView.rootView.model.row.offersGauge, graphStyle: graphStyle)
        }.max() ?? 0
    }

    /// Stops sampling, as when the module leaves the HUD. `start()` begins again with a fresh baseline.
    public func stop() {
        schedule?.cancel()
        schedule = nil
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers.removeAll()
    }

    /// Changes the time between readings. While sampling, the next reading comes one new interval after the
    /// change; the baseline and the history carry over.
    public func setInterval(_ newInterval: Duration) {
        guard newInterval != interval else { return }
        interval = newInterval
        meter.setInterval(newInterval)
        guard schedule != nil else { return }
        scheduleReadings(after: newInterval)
    }

    /// Switches every row that offers a gauge between its sparkline and its gauge, at once; the sparkline keeps
    /// recording either way.
    public func setGraphStyle(_ style: GraphStyle) {
        guard style != graphStyle else { return }
        graphStyle = style
        for model in rowModels { model.graphStyle = style }
        let newWidth = rowsWidth()
        if newWidth != width {
            width = newWidth
            onSizeChange?()
        }
    }

    /// Applies the user's thresholds; rows whose state changes at once, as when highlighting is switched off,
    /// are redrawn at once.
    public func applyThresholds(_ settings: ThresholdSettings) {
        if meter.applyThresholds(settings), isOnScreen(moduleView) { render() }
    }

    /// After sleep: a fresh baseline, and states that wait for 3 new readings. Readings restart as at launch, so the
    /// first one covers the 0.25 s priming delay rather than whatever was left of the interval, which could be a few
    /// milliseconds and turn a burst of wake-time traffic into a spike.
    func wake() {
        meter.rebaseline(at: now())
        if schedule != nil { scheduleReadings(after: MeterTiming.primingDelay) }
        if meter.resetStates(), isOnScreen(moduleView) { render() }
    }

    /// Takes the launch baseline and starts sampling: first reading after 0.25 s, then every interval.
    public func start() {
        guard schedule == nil else { return }
        meter.rebaseline(at: now())
        scheduleReadings(after: MeterTiming.primingDelay)
        observe(NSWindow.didChangeOcclusionStateNotification, on: .default) { module, sender in
            guard let window = module.moduleView.window, sender == ObjectIdentifier(window) else { return }
            if module.isOnScreen(module.moduleView) { module.render() }
        }
        // Time asleep must never appear as a spike or dip: start a fresh baseline on wake.
        // States restart too: the readings from before sleep are not the last 3 readings.
        observe(NSWorkspace.didWakeNotification, on: NSWorkspace.shared.notificationCenter) { module, _ in
            module.wake()
        }
    }

    /// Replaces any current schedule: the next reading after `delay`, then one every interval.
    private func scheduleReadings(after delay: Duration) {
        schedule?.cancel()
        schedule = scheduler.schedule(after: delay, every: interval) { [weak self] in self?.tick() }
    }

    func tick() {
        meter.sample(at: now())
        if isOnScreen(moduleView) { render() }
    }

    func render() {
        for (row, (model, rowView)) in zip(meter.rows, zip(rowModels, moduleView.rowViews)) {
            // An unchanged row, such as a battery percent that holds for minutes, is not redrawn.
            if model.row != row { model.row = row }
            let spoken = rowView.spokenText(row)
            if rowView.accessibilityValue() as? String != spoken {
                rowView.setAccessibilityValue(spoken)
                announceValueChange(rowView)
            }
            if row.hasData { FirstData.record() }
        }
    }

    private func observe(
        _ name: Notification.Name, on center: NotificationCenter,
        _ handler: @escaping @MainActor (MeterModule, _ sender: ObjectIdentifier?) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            let sender = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, sender)
            }
        }
        observers.append((center: center, token: token))
    }
}

/// The `first-data` marker for `make perf`: the first rendered reading from any module.
@MainActor
private enum FirstData {
    static var recorded = false

    static func record() {
        guard !recorded else { return }
        recorded = true
        AppEnvironment.recordMarker("first-data")
    }
}
