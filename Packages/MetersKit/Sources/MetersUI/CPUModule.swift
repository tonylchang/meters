import MetersCore

/// The CPU utilization module: total CPU as a whole-number percent with a 60-sample sparkline, and in the
/// "Total and clusters" form one more such row per CPU cluster.
public typealias CPUModule = MeterModule<CPUMeter>

extension MeterModule where Meter == CPUMeter {
    public convenience init(
        source: any CPUTickSource = MachCPUTickSource(), form: CPUForm = .total,
        clusters: [CPUCluster] = SystemSources.cpuClusters(),
        scheduler: any SampleScheduling = RunLoopScheduler(),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.init(
            identifier: ModuleID.cpu.rawValue, rows: Self.cpuLabels(form: form, clusters: clusters),
            meter: CPUMeter(source: source, form: form, clusters: clusters), scheduler: scheduler, now: now)
    }

    /// The total row, then in the clusters form one row per cluster, marked with its initial.
    static func cpuLabels(form: CPUForm, clusters: [CPUCluster]) -> [MeterRowLabels] {
        let total = MeterRowLabels(label: CPUModuleText.label, accessibilityLabel: CPUModuleText.label)
        guard form == .clusters else { return [total] }
        return [total]
            + clusters.map {
                MeterRowLabels(
                    label: nil, marker: CPUModuleText.marker($0),
                    accessibilityLabel: CPUModuleText.accessibilityLabel($0))
            }
    }
}

/// A module with a total form and a clusters form.
@MainActor
public protocol CPUFormSwitching: AnyObject {
    func setForm(_ form: CPUForm)
}

extension MeterModule: CPUFormSwitching where Meter == CPUMeter {
    /// Switches form in place: the total and every cluster's history carry over.
    public func setForm(_ form: CPUForm) {
        guard meter.form != form else { return }
        meter.form = form
        reconfigure(rows: Self.cpuLabels(form: form, clusters: meter.clusters))
    }
}
