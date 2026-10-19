import CoreGraphics
import Foundation

/// A display the HUD can live on. The first display in any list is the main display.
public struct DisplayInfo: Equatable, Sendable {
    /// Stable across reconnects and reboots.
    public let id: String
    public let frame: CGRect
    /// The frame minus the menu bar and the Dock, as macOS reports it.
    public let usableArea: CGRect

    public init(id: String, frame: CGRect, usableArea: CGRect) {
        self.id = id
        self.frame = frame
        self.usableArea = usableArea
    }

    /// The edge the Dock sits on: the side, other than the menu bar's top, where the usable area stops short
    /// of the frame. `nil` when the Dock is hidden or on another display.
    public var dockEdge: DockEdge? {
        if usableArea.minY > frame.minY + 1 { return .bottom }
        if usableArea.minX > frame.minX + 1 { return .left }
        if usableArea.maxX < frame.maxX - 1 { return .right }
        return nil
    }
}

public enum DockEdge: Sendable {
    case bottom
    case left
    case right
}

/// The axis along which a placement's offset is measured from the screen's edge instead of the usable area.
public enum PlacementAxis: String, Sendable {
    case horizontal
    case vertical
}

/// Where the HUD lives, as persisted: a display, the corner of
/// its usable area the HUD is anchored to, and the distance from that corner to the HUD's nearest edges.
public struct HUDPlacement: Equatable, Sendable {
    public var displayID: String
    public var corner: AnchorCorner
    /// Horizontal and vertical distance, in points, from the anchor corner to the HUD's facing edges.
    public var offset: CGSize
    /// Set when the HUD rests beside the Dock: along this axis, the offset is measured from the screen's
    /// edge rather than the usable area, so the HUD stays put when the Dock changes size.
    public var screenEdgeAxis: PlacementAxis?

    public init(displayID: String, corner: AnchorCorner, offset: CGSize, screenEdgeAxis: PlacementAxis? = nil) {
        self.displayID = displayID
        self.corner = corner
        self.offset = offset
        self.screenEdgeAxis = screenEdgeAxis
    }

    /// The first-launch placement: bottom-right corner of the main display, 4 pt from the right and 12 pt
    /// from the bottom of the usable area.
    public static func firstLaunch(on display: DisplayInfo) -> HUDPlacement {
        HUDPlacement(
            displayID: display.id, corner: .bottomRight,
            offset: CGSize(width: HUDMetrics.sideInset, height: HUDMetrics.screenInset))
    }
}

/// Where a HUD may rest on a display, and the lines it snaps to.
public struct PlacementBounds: Equatable, Sendable {
    /// A resting HUD stays inside this rectangle.
    public private(set) var limits: CGRect
    /// Lines a HUD's left, right, bottom, and top edges snap to.
    public private(set) var left: [CGFloat]
    public private(set) var right: [CGFloat]
    public private(set) var bottom: [CGFloat]
    public private(set) var top: [CGFloat]

    /// The usable area inset by 4 pt on the left and right, 12 pt at the top and bottom.
    public init(usableArea area: CGRect) {
        limits = area.insetBy(dx: HUDMetrics.sideInset, dy: HUDMetrics.screenInset)
        left = [limits.minX]
        right = [limits.maxX]
        bottom = [limits.minY]
        top = [limits.maxY]
    }

    /// As above, except on the Dock's edge, where the HUD may also rest in the Dock's strip, down to 4 pt
    /// from the screen's edge, with a second snap line there.
    public init(display: DisplayInfo) {
        self.init(usableArea: display.usableArea)
        let margin = HUDMetrics.besideDockInset
        var limits = self.limits
        var left = self.left
        var right = self.right
        var bottom = self.bottom
        switch display.dockEdge {
        case .bottom:
            let line = display.frame.minY + margin
            limits = CGRect(x: limits.minX, y: line, width: limits.width, height: limits.maxY - line)
            bottom.append(line)
        case .left:
            let line = display.frame.minX + margin
            limits = CGRect(x: line, y: limits.minY, width: limits.maxX - line, height: limits.height)
            left.append(line)
        case .right:
            let line = display.frame.maxX - margin
            limits = CGRect(x: limits.minX, y: limits.minY, width: line - limits.minX, height: limits.height)
            right.append(line)
        case nil:
            break
        }
        self.limits = limits
        self.left = left
        self.right = right
        self.bottom = bottom
    }
}

/// Placement geometry for the HUD. Coordinates follow AppKit: y grows upward.
public enum PlacementGeometry {
    /// A released HUD snaps to an edge's inset line when it is this close to it.
    public static let magnetRange: CGFloat = 24

    /// Magnetism, then containment: where a HUD released at `frame` settles in `area`.
    public static func settle(_ frame: CGRect, in area: CGRect) -> CGRect {
        settle(frame, within: PlacementBounds(usableArea: area))
    }

    /// As above, on a display, where the HUD may also rest beside the Dock.
    public static func settle(_ frame: CGRect, on display: DisplayInfo) -> CGRect {
        settle(frame, within: PlacementBounds(display: display))
    }

    /// Each axis snaps to its nearest line within 24 pt, if any; then containment applies.
    public static func settle(_ frame: CGRect, within bounds: PlacementBounds) -> CGRect {
        var settled = frame
        settled.origin.x = snap(
            low: frame.minX, high: frame.maxX, size: frame.width, lowLines: bounds.left, highLines: bounds.right)
        settled.origin.y = snap(
            low: frame.minY, high: frame.maxY, size: frame.height, lowLines: bounds.bottom, highLines: bounds.top)
        return contain(settled, within: bounds)
    }

    /// Keeps the HUD fully inside `area`, at least the inset from every edge.
    public static func contain(_ frame: CGRect, in area: CGRect) -> CGRect {
        contain(frame, within: PlacementBounds(usableArea: area))
    }

    public static func contain(_ frame: CGRect, within bounds: PlacementBounds) -> CGRect {
        var contained = frame
        contained.origin.x = clamp(frame.minX, low: bounds.limits.minX, high: bounds.limits.maxX - frame.width)
        contained.origin.y = clamp(frame.minY, low: bounds.limits.minY, high: bounds.limits.maxY - frame.height)
        return contained
    }

    /// The placement that describes a settled `frame` on `display`. A HUD resting in the Dock's strip
    /// measures its offset along the Dock's axis from the screen's edge.
    public static func placement(for frame: CGRect, on display: DisplayInfo) -> HUDPlacement {
        let area = display.usableArea
        let corner = AnchorCorner.nearest(to: frame, in: area)
        var dx = corner.isRight ? area.maxX - frame.maxX : frame.minX - area.minX
        var dy = corner.isTop ? area.maxY - frame.maxY : frame.minY - area.minY
        var screenEdgeAxis: PlacementAxis?
        switch display.dockEdge {
        case .bottom where !corner.isTop && frame.minY < area.minY:
            dy = frame.minY - display.frame.minY
            screenEdgeAxis = .vertical
        case .left where !corner.isRight && frame.minX < area.minX:
            dx = frame.minX - display.frame.minX
            screenEdgeAxis = .horizontal
        case .right where corner.isRight && frame.maxX > area.maxX:
            dx = display.frame.maxX - frame.maxX
            screenEdgeAxis = .horizontal
        default:
            break
        }
        return HUDPlacement(
            displayID: display.id, corner: corner, offset: CGSize(width: dx, height: dy),
            screenEdgeAxis: screenEdgeAxis)
    }

    /// The frame for a HUD of `size` at `placement`'s corner and offset within `area`, then contained.
    /// Resizing keeps the edges that face the anchor corner fixed.
    public static func frame(for placement: HUDPlacement, size: CGSize, in area: CGRect) -> CGRect {
        let reference = DisplayInfo(id: placement.displayID, frame: area, usableArea: area)
        return frame(for: placement, size: size, on: reference)
    }

    /// As above, on a display. An offset measured from the screen's edge stays measured from it.
    public static func frame(for placement: HUDPlacement, size: CGSize, on display: DisplayInfo) -> CGRect {
        let area = display.usableArea
        let xArea = placement.screenEdgeAxis == .horizontal ? display.frame : area
        let yArea = placement.screenEdgeAxis == .vertical ? display.frame : area
        let x =
            placement.corner.isRight
            ? xArea.maxX - placement.offset.width - size.width : xArea.minX + placement.offset.width
        let y =
            placement.corner.isTop
            ? yArea.maxY - placement.offset.height - size.height : yArea.minY + placement.offset.height
        return contain(
            CGRect(x: x, y: y, width: size.width, height: size.height), within: PlacementBounds(display: display))
    }

    /// The display a saved placement resolves to: its own display while connected, otherwise the main
    /// display at the same corner and offset. No saved placement means first launch.
    public static func display(for saved: HUDPlacement?, among displays: [DisplayInfo]) -> DisplayInfo? {
        guard let main = displays.first else { return nil }
        guard let saved else { return main }
        return displays.first { $0.id == saved.displayID } ?? main
    }

    /// The display under `point`, or the main display when no display contains it.
    public static func display(at point: CGPoint, among displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) } ?? displays.first
    }

    /// The nearest snap line within range: a low line aligns the HUD's low edge, a high line its high edge.
    /// Without one in range, the HUD stays where it was dropped.
    private static func snap(
        low: CGFloat, high: CGFloat, size: CGFloat, lowLines: [CGFloat], highLines: [CGFloat]
    ) -> CGFloat {
        let candidates =
            lowLines.map { (distance: abs(low - $0), origin: $0) }
            + highLines.map { (distance: abs($0 - high), origin: $0 - size) }
        guard let nearest = candidates.min(by: { $0.distance < $1.distance }), nearest.distance <= magnetRange
        else { return low }
        return nearest.origin
    }

    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        max(low, min(value, high))
    }
}
