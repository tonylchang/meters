import MetersCore

/// The GPU module: label, device utilization as a whole-number percent, and a 60-sample sparkline in
/// one row.
public typealias GPUModule = MeterModule<GPUMeter>

extension MeterModule where Meter == GPUMeter {
    public convenience init(
        source: any GPUUtilizationSource = SystemSources.gpu(),
        scheduler: any SampleScheduling = RunLoopScheduler(),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.init(
            identifier: "gpu",
            rows: [MeterRowLabels(label: GPUModuleText.label, accessibilityLabel: GPUModuleText.label)],
            meter: GPUMeter(source: source), scheduler: scheduler, now: now)
    }
}
