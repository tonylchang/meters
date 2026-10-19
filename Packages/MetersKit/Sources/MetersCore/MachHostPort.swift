import Darwin

/// Owns one host send-right reference. Source structs may be copied, so ownership is shared until their
/// last copy is released rather than acquiring a new reference or releasing one twice.
final class MachHostPort: Sendable {
    let name = mach_host_self()

    deinit {
        mach_port_deallocate(mach_task_self_, name)
    }
}
