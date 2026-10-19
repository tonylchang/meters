import AppKit
import MetersCore

/// Accessibility display settings the HUD responds to.
@MainActor
public protocol DisplayOptionsProviding: AnyObject {
    var reduceTransparency: Bool { get }
    var increaseContrast: Bool { get }
    var reduceMotion: Bool { get }
    /// Called on the main actor after any of the settings change.
    var onChange: (() -> Void)? { get set }
}

/// Reads the live system accessibility display settings.
@MainActor
public final class SystemDisplayOptions: DisplayOptionsProviding {
    public var onChange: (() -> Void)?
    private var observer: (any NSObjectProtocol)?

    public init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    isolated deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    public var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    public var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    public var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Display geometry the HUD needs.
@MainActor
public protocol ScreenProviding: AnyObject {
    /// Connected displays; the first is the main display, the one with the menu bar.
    var displays: [DisplayInfo] { get }
}

/// Reads display geometry from `NSScreen`.
@MainActor
public final class SystemScreens: ScreenProviding {
    public init() {}

    public var displays: [DisplayInfo] {
        NSScreen.screens.map { screen in
            DisplayInfo(id: Self.stableID(of: screen), frame: screen.frame, usableArea: screen.visibleFrame)
        }
    }

    /// The display's UUID, which survives reconnects and reboots, unlike its numeric display ID.
    private static func stableID(of screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let displayID = CGDirectDisplayID(number?.uint32Value ?? 0)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
            let string = CFUUIDCreateString(nil, uuid) as String?
        {
            return string
        }
        return "display-\(displayID)"
    }
}
