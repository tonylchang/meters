import Darwin
import Foundation

/// macOS's memory pressure level, as Activity Monitor's Memory Pressure graph shows it.
public enum MemoryPressure: Equatable, Sendable {
    case normal
    case warning
    case critical

    /// The Memory row's state at this level.
    public var state: ThresholdState {
        switch self {
        case .normal: .normal
        case .warning: .elevated
        case .critical: .critical
        }
    }
}

/// Data source for memory pressure. The Memory module reads it only through this protocol.
public protocol MemoryPressureSource: Sendable {
    /// The current level, or `nil` when it cannot be read.
    func readPressure() -> MemoryPressure?
}

extension SystemSources {
    public static func memoryPressure() -> any MemoryPressureSource {
        SysctlMemoryPressureSource()
    }
}

/// Undocumented source: the kernel's current pressure level, `kern.memorystatus_vm_pressure_level` (1 normal,
/// 2 warning, 4 critical, the values of the documented dispatch memory pressure flags). The sysctl is not in
/// the SDK headers; the documented dispatch source reports only changes, so it cannot give the level at
/// launch. Any other value reads as unavailable.
struct SysctlMemoryPressureSource: MemoryPressureSource {
    func readPressure() -> MemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return nil
        }
    }
}
