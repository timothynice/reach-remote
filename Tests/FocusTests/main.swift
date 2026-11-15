import Foundation
import CoreGraphics

@main
struct FocusGeometryTests {
    static func main() {
        func check(_ value: Bool, _ message: String) {
            guard value else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
        let leftDisplay = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
        let field = CGRect(x: -1820, y: 900, width: 600, height: 100)
        let normalized = FocusGeometry.normalize(field, within: leftDisplay)!
        check(normalized.isValid, "Normalized field validates on a display left of the main monitor")
        check(close(normalized.x, 100.0 / 1920) && close(normalized.y, 800.0 / 1080), "Account for nonzero display origins in both axes")
        let crossing = FocusGeometry.normalize(CGRect(x: -50, y: 200, width: 300, height: 100), within: leftDisplay)!
        check(close(crossing.width, 50.0 / 1920) && crossing.isValid, "Clip a field spanning two monitors")
        check(FocusGeometry.normalize(CGRect(x: 10, y: 200, width: 100, height: 30), within: leftDisplay) == nil, "Ignore fields on another display")
        check(FocusGeometry.normalize(CGRect(x: CGFloat.infinity, y: 10, width: 10, height: 10), within: leftDisplay) == nil, "Reject nonfinite geometry")
        check(FocusGeometry.normalize(field, within: .zero) == nil, "Reject empty display")
        let rightEdgeCaret = CGRect(x: field.maxX, y: field.minY, width: 0, height: 20)
        let edge = FocusGeometry.normalizeCaret(rightEdgeCaret, field: field, display: leftDisplay)
        check(edge != nil && edge!.isValid && close(edge!.width, 1.0 / 1920), "Preserve zero-width caret at field right boundary")
        let caret = RemoteRect(x: normalized.x + 0.01, y: normalized.y, width: 1.0 / 1920, height: 20.0 / 1080)
        let previous = RemoteFocus(field: normalized, caret: caret)
        var moved = caret
        moved.x += 1.0 / 1920
        check(!FocusGeometry.differs(RemoteFocus(field: normalized, caret: moved), from: previous, display: leftDisplay), "Ignore one-pixel caret jitter")
        moved.x += 3.0 / 1920
        check(FocusGeometry.differs(RemoteFocus(field: normalized, caret: moved), from: previous, display: leftDisplay), "Send meaningful caret movement")
        check(FocusGeometry.differs(RemoteFocus(field: normalized), from: previous, display: leftDisplay), "Send caret-to-field fallback")
        check(!FocusGeometry.differs(previous, from: previous, display: leftDisplay), "Suppress duplicate metadata")
        print("PASS: focus geometry origins, monitor clipping, validation, caret movement, jitter suppression, field fallback. AX app integration requires signed host and a focused text field.")
    }
}
