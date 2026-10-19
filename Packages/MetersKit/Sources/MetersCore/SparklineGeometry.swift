import CoreGraphics
import Foundation

public enum SparklineGeometry {
    /// Filled-area polygons for a sparkline.
    ///
    /// Samples fill `capacity` equal slots with the newest on the right, on a fixed 0 to 1 vertical scale.
    /// Each run of consecutive samples becomes one polygon; a `nil` sample is a gap that splits runs.
    /// Coordinates use a top-left origin, as SwiftUI's `Canvas` does.
    public static func areas(samples: [Double?], capacity: Int, size: CGSize) -> [[CGPoint]] {
        guard capacity > 0, size.width > 0, size.height > 0 else { return [] }
        let slotWidth = size.width / CGFloat(capacity)
        let visible = samples.suffix(capacity)
        let firstSlot = capacity - visible.count

        func y(_ value: Double) -> CGFloat {
            size.height * (1 - CGFloat(min(1, max(0, value))))
        }

        var polygons: [[CGPoint]] = []
        var run: [(slot: Int, value: Double)] = []

        func closeRun() {
            guard let first = run.first, let last = run.last else { return }
            let left = CGFloat(first.slot) * slotWidth
            let right = CGFloat(last.slot + 1) * slotWidth
            var points = [CGPoint(x: left, y: size.height), CGPoint(x: left, y: y(first.value))]
            points += run.map { CGPoint(x: (CGFloat($0.slot) + 0.5) * slotWidth, y: y($0.value)) }
            points += [CGPoint(x: right, y: y(last.value)), CGPoint(x: right, y: size.height)]
            polygons.append(points)
            run.removeAll(keepingCapacity: true)
        }

        for (offset, sample) in visible.enumerated() {
            if let sample {
                run.append((slot: firstSlot + offset, value: sample))
            } else {
                closeRun()
            }
        }
        closeRun()
        return polygons
    }
}
