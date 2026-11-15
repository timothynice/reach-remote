import Foundation
import CoreGraphics

/// All values are in zoomed scroll-content points, rather than remote desktop pixels.
enum ViewportGeometry {
    static func offsetKeepingVisible(_ point: CGPoint, current: CGPoint, viewport: CGSize, content: CGSize, minimum: CGPoint = .zero) -> CGPoint {
        guard viewport.width > 0, viewport.height > 0 else { return current }
        let horizontalMargin = min(48, viewport.width * 0.18)
        let verticalMargin = min(88, viewport.height * 0.22)
        func axis(_ value: CGFloat, offset: CGFloat, extent: CGFloat, length: CGFloat, margin: CGFloat, minimum: CGFloat) -> CGFloat {
            let maximum = max(minimum, length - extent)
            var target = offset
            if value < offset + margin { target = value - margin }
            else if value > offset + extent - margin { target = value - extent + margin }
            return min(maximum, max(minimum, target))
        }
        return CGPoint(x: axis(point.x, offset: current.x, extent: viewport.width, length: content.width, margin: horizontalMargin, minimum: minimum.x),
                       y: axis(point.y, offset: current.y, extent: viewport.height, length: content.height, margin: verticalMargin, minimum: minimum.y))
    }
}

extension ViewportGeometry {
    /// Keeps a small field visible as a whole. Large editors follow the caret and adjacent text.
    /// `safe` is local to the viewport, with the actual keyboard overlap and chrome removed.
    static func offsetForFocus(field: CGRect, caret: CGRect?, fallback: CGPoint?, current: CGPoint, safe: CGRect, minimum: CGPoint, maximum: CGPoint) -> CGPoint {
        guard safe.width > 0, safe.height > 0, !field.isNull else { return current }
        func target(fieldMin: CGFloat, fieldMax: CGFloat, caretMin: CGFloat?, caretMax: CGFloat?, fallback: CGFloat?, available: CGFloat, context: CGFloat) -> (CGFloat, CGFloat) {
            let regionMin = min(fieldMin, caretMin ?? fieldMin)
            let regionMax = max(fieldMax, caretMax ?? fieldMax)
            if regionMax - regionMin <= available { return (regionMin, regionMax) }
            let low = caretMin ?? fallback ?? (fieldMin + fieldMax) / 2
            let high = caretMax ?? low
            let padding = min(context, max(0, (available - (high - low)) / 2))
            return (max(regionMin, low - padding), min(regionMax, high + padding))
        }
        func offset(target: (CGFloat, CGFloat), current: CGFloat, safeMin: CGFloat, safeMax: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
            var result = current
            if target.0 < current + safeMin { result = target.0 - safeMin }
            else if target.1 > current + safeMax { result = target.1 - safeMax }
            return min(maximum, max(minimum, result))
        }
        let x = target(fieldMin: field.minX, fieldMax: field.maxX, caretMin: caret?.minX, caretMax: caret?.maxX, fallback: fallback?.x, available: safe.width, context: 48)
        let y = target(fieldMin: field.minY, fieldMax: field.maxY, caretMin: caret?.minY, caretMax: caret?.maxY, fallback: fallback?.y, available: safe.height, context: 28)
        return CGPoint(x: offset(target: x, current: current.x, safeMin: safe.minX, safeMax: safe.maxX, minimum: minimum.x, maximum: maximum.x),
                       y: offset(target: y, current: current.y, safeMin: safe.minY, safeMax: safe.maxY, minimum: minimum.y, maximum: maximum.y))
    }

    /// Keyboard rectangles are intersected after conversion; a SwiftUI-resized viewport has no overlap.
    static func unobscuredHeight(viewport: CGRect, keyboard: CGRect?) -> CGFloat {
        guard let keyboard else { return viewport.height }
        let intersection = viewport.intersection(keyboard)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return viewport.height }
        return max(0, min(viewport.maxY, intersection.minY) - viewport.minY)
    }
}

/// A monitor's viewport placement, independent of phone rotation and stream dimensions.
struct ViewportPlacement {
    let zoom: CGFloat
    let center: CGPoint
    init?(zoom: CGFloat, offset: CGPoint, viewport: CGSize, desktop: CGSize) {
        guard zoom.isFinite, zoom > 0, desktop.width > 0, desktop.height > 0 else { return nil }
        self.zoom = zoom
        center = CGPoint(x: (offset.x + viewport.width / 2) / (desktop.width * zoom), y: (offset.y + viewport.height / 2) / (desktop.height * zoom))
    }
    func offset(viewport: CGSize, desktop: CGSize, zoom: CGFloat) -> CGPoint {
        CGPoint(x: center.x * desktop.width * zoom - viewport.width / 2, y: center.y * desktop.height * zoom - viewport.height / 2)
    }
}
