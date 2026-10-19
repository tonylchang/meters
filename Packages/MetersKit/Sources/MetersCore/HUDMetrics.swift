import CoreGraphics
import Foundation

/// Fixed HUD measurements, in points.
public enum HUDMetrics {
    /// Padding between the HUD's edge and its module column.
    public static let padding: CGFloat = 8
    /// Space between module rows.
    public static let moduleSpacing: CGFloat = 4
    /// Height of one module row.
    public static let rowHeight: CGFloat = 18
    /// Corner radius of the HUD container.
    public static let cornerRadius: CGFloat = 12
    /// Minimum distance between the HUD and the top and bottom edges of the display's usable area.
    public static let screenInset: CGFloat = 12
    /// Minimum distance between the HUD and the left and right edges of the usable area.
    public static let sideInset: CGFloat = 4
    /// Distance from the screen's edge for a HUD resting beside the Dock.
    public static let besideDockInset: CGFloat = 4
    /// The HUD's faint edge in place of a window shadow: one pixel on a Retina display.
    public static let hairlineBorderWidth: CGFloat = 0.5
    /// Border width shown while Increase Contrast is on.
    public static let contrastBorderWidth: CGFloat = 1
}

/// HUD animation timing.
public enum HUDMotion {
    public static let resizeDuration: TimeInterval = 0.2
    public static let fadeDuration: TimeInterval = 0.2
    /// Shorter than a resize, so a dropped HUD snaps into place.
    public static let settleDuration: TimeInterval = 0.12

    /// Resizes are instant with Reduce Motion on.
    public static func resizeDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : resizeDuration
    }

    /// Settles after a drag are instant with Reduce Motion on.
    public static func settleDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : settleDuration
    }

    /// Fades are permitted under Reduce Motion, so the duration never changes.
    public static func fadeDuration(reduceMotion: Bool) -> TimeInterval {
        fadeDuration
    }
}

/// How the HUD background renders for the current accessibility display settings.
public struct HUDBackgroundStyle: Equatable, Sendable {
    public enum Fill: Equatable, Sendable {
        case translucentMaterial
        case opaque
    }

    public let fill: Fill
    public let borderWidth: CGFloat

    public init(reduceTransparency: Bool, increaseContrast: Bool) {
        fill = reduceTransparency ? .opaque : .translucentMaterial
        borderWidth = increaseContrast ? HUDMetrics.contrastBorderWidth : HUDMetrics.hairlineBorderWidth
    }
}

/// The app's user-visible name.
public enum AppIdentity {
    public static let displayName = "meters"
}
