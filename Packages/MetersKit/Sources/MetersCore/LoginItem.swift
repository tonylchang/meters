import Foundation
import ServiceManagement

/// macOS's state for meters's login item.
public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case notRegistered
    /// Registered, but the user must allow it under Login Items.
    case requiresApproval
    case notFound
}

/// The login item registration. Settings changes it only through this protocol, so tests and automated checks use
/// a substitute and never touch the user's login items.
public protocol LoginItemService: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    /// Opens System Settings at Login Items.
    func openSystemSettings()
}

/// The main app's login item, through ServiceManagement.
public struct SystemLoginItemService: LoginItemService {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
