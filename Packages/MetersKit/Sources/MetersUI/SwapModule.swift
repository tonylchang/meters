import MetersCore

/// The Swap module: swap space in use, in one row.
public typealias SwapModule = MeterModule<SwapMeter>

extension MeterModule where Meter == SwapMeter {
    public convenience init(
        source: any SwapSource = SystemSwapSource(),
        scheduler: any SampleScheduling = RunLoopScheduler(),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.init(
            identifier: ModuleID.swap.rawValue,
            rows: [
                MeterRowLabels(
                    label: SwapModuleText.label, accessibilityLabel: SwapModuleText.accessibilityLabel,
                    showsSparkline: false)
            ],
            meter: SwapMeter(source: source), scheduler: scheduler, now: now)
    }
}
