import CoreGraphics
import Foundation

/// The HUD's size and how many modules fit in it.
public struct HUDColumnLayout: Equatable, Sendable {
    public let size: CGSize
    public let visibleModuleCount: Int
}

public enum HUDLayout {
    /// Sizes the HUD to its modules' natural sizes.
    ///
    /// Height fits the modules, 4 pt apart, plus padding, capped at the usable height minus the top and
    /// bottom insets. Modules at the end of the order that do not fit entirely are left out. Width fits the
    /// widest module shown, plus padding, rounded up to a whole point.
    public static func column(moduleSizes: [CGSize], usableHeight: CGFloat) -> HUDColumnLayout {
        let maxHeight = usableHeight - 2 * HUDMetrics.screenInset
        var height = 2 * HUDMetrics.padding
        var contentWidth: CGFloat = 0
        var visibleCount = 0
        for moduleSize in moduleSizes {
            let added = visibleCount == 0 ? moduleSize.height : HUDMetrics.moduleSpacing + moduleSize.height
            guard height + added <= maxHeight else { break }
            height += added
            contentWidth = max(contentWidth, moduleSize.width)
            visibleCount += 1
        }
        let width = (contentWidth + 2 * HUDMetrics.padding).rounded(.up)
        return HUDColumnLayout(size: CGSize(width: width, height: height), visibleModuleCount: visibleCount)
    }
}

/// A corner of a display's usable area. Coordinates follow AppKit: y grows upward.
public enum AnchorCorner: String, CaseIterable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public var isTop: Bool { self == .topLeft || self == .topRight }
    public var isRight: Bool { self == .topRight || self == .bottomRight }

    /// The corner of `area` whose quadrant contains the center of `frame`.
    /// A center exactly on a quadrant boundary resolves toward the right and the top.
    public static func nearest(to frame: CGRect, in area: CGRect) -> AnchorCorner {
        let right = frame.midX >= area.midX
        let top = frame.midY >= area.midY
        switch (top, right) {
        case (true, true): return .topRight
        case (true, false): return .topLeft
        case (false, true): return .bottomRight
        case (false, false): return .bottomLeft
        }
    }
}
