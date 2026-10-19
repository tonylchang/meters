import MetersCore

/// The Free space module: the startup volume's free space, as Finder counts it, in one row.
public typealias FreeSpaceModule = MeterModule<FreeSpaceMeter>

extension MeterModule where Meter == FreeSpaceMeter {
    public convenience init(
        source: any FreeSpaceSource = SystemFreeSpaceSource(),
        scheduler: any SampleScheduling = RunLoopScheduler(),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.init(
            identifier: ModuleID.freeSpace.rawValue,
            rows: [
                MeterRowLabels(
                    label: FreeSpaceModuleText.label, accessibilityLabel: FreeSpaceModuleText.accessibilityLabel,
                    showsSparkline: false)
            ],
            meter: FreeSpaceMeter(source: source), scheduler: scheduler, now: now)
    }
}
