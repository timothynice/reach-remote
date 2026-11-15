import Foundation

/// The Mac's global top-left display coordinate space, including negative origins.
public struct DisplayFrame: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy { $0.isFinite && abs($0) < 1_000_000 } && width > 0 && height > 0
    }
}

enum DisplayDirection { case left, right, up, down }

enum DisplayNavigation {
    /// App-page order follows the Mac arrangement from left to right. Displays
    /// centered in the same column run top to bottom; IDs break geometry ties.
    /// Missing or invalid geometry comes last in deterministic ID order.
    static func ordered(displays: [RemoteDisplay]) -> [RemoteDisplay] {
        displays.sorted { lhs, rhs in
            let left = lhs.frame.flatMap { $0.isValid ? $0 : nil }
            let right = rhs.frame.flatMap { $0.isValid ? $0 : nil }
            switch (left, right) {
            case let (left?, right?):
                let leftX = left.x + left.width / 2
                let rightX = right.x + right.width / 2
                if leftX != rightX { return leftX < rightX }
                let leftY = left.y + left.height / 2
                let rightY = right.y + right.height / 2
                if leftY != rightY { return leftY < rightY }
                return lhs.id < rhs.id
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.id < rhs.id
            }
        }
    }

    /// Swipe direction moves the desktop canvas: a leftward swipe reveals the display to the right.
    static func direction(translationX x: Double, translationY y: Double) -> DisplayDirection? {
        guard x.isFinite, y.isFinite, max(abs(x), abs(y)) >= 48,
              max(abs(x), abs(y)) > min(abs(x), abs(y)) * 1.35 else { return nil }
        if abs(x) > abs(y) { return x < 0 ? .right : .left }
        return y < 0 ? .down : .up
    }

    static func swipeDirection(x: Double, y: Double, velocityX: Double, velocityY: Double) -> DisplayDirection? {
        guard velocityX.isFinite, velocityY.isFinite, hypot(velocityX, velocityY) >= 650 else { return nil }
        return direction(translationX: x, translationY: y)
    }

    static func neighbor(from id: UInt32, toward direction: DisplayDirection, displays: [RemoteDisplay]) -> RemoteDisplay? {
        guard let origin = displays.first(where: { $0.id == id })?.frame, origin.isValid else { return nil }
        let horizontal = direction == .left || direction == .right
        let positive = direction == .right || direction == .down
        let originStart = horizontal ? origin.x : origin.y
        let originLength = horizontal ? origin.width : origin.height
        let originCross = horizontal ? origin.y : origin.x
        let originCrossLength = horizontal ? origin.height : origin.width
        var best: (RemoteDisplay, Double)?
        for display in displays where display.id != id {
            guard let target = display.frame, target.isValid else { continue }
            let start = horizontal ? target.x : target.y
            let length = horizontal ? target.width : target.height
            let cross = horizontal ? target.y : target.x
            let crossLength = horizontal ? target.height : target.width
            // Mirrored displays and displays in the wrong half-plane are never swipe destinations.
            let forward = (start + length / 2 - originStart - originLength / 2) * (positive ? 1 : -1)
            guard forward > 1 else { continue }
            let overlap = min(originCross + originCrossLength, cross + crossLength) - max(originCross, cross)
            let crossDistance = abs(cross + crossLength / 2 - originCross - originCrossLength / 2)
            guard overlap > 1 || forward >= crossDistance else { continue }
            let crossGap = max(0, -overlap)
            let edgeGap = positive ? max(0, start - originStart - originLength) : max(0, originStart - start - length)
            // Favor a display directly across the shared edge over a diagonal display.
            let score = edgeGap + crossGap * 4 + crossDistance * 0.25 + forward * 0.01
            if best == nil || score < best!.1 || (score == best!.1 && display.id < best!.0.id) { best = (display, score) }
        }
        return best?.0
    }
}
