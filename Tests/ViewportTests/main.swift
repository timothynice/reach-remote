import Foundation
import CoreGraphics

func equal(_ actual: CGPoint, _ expected: CGPoint, _ message: String) {
    precondition(abs(actual.x - expected.x) < 0.001 && abs(actual.y - expected.y) < 0.001, "\(message): \(actual) != \(expected)")
}
let viewport = CGSize(width: 400, height: 800)
let content = CGSize(width: 1600, height: 900)
let current = CGPoint(x: 600, y: 0)
equal(ViewportGeometry.offsetKeepingVisible(CGPoint(x: 800, y: 400), current: current, viewport: viewport, content: content), current, "A comfortably visible pointer must not move the viewport")
equal(ViewportGeometry.offsetKeepingVisible(CGPoint(x: 970, y: 400), current: current, viewport: viewport, content: content), CGPoint(x: 618, y: 0), "Approaching the right edge pans only enough to restore the margin")
equal(ViewportGeometry.offsetKeepingVisible(CGPoint(x: 610, y: 400), current: current, viewport: viewport, content: content), CGPoint(x: 562, y: 0), "Left edge follows without recentering")
equal(ViewportGeometry.offsetKeepingVisible(CGPoint(x: 1600, y: 900), current: current, viewport: viewport, content: content), CGPoint(x: 1200, y: 100), "Desktop boundaries prevent overscroll")
equal(ViewportGeometry.offsetKeepingVisible(CGPoint(x: 200, y: 120), current: CGPoint(x: 0, y: -280), viewport: viewport, content: CGSize(width: 400, height: 240), minimum: CGPoint(x: 0, y: -280)), CGPoint(x: 0, y: -280), "Letterboxed content stays centered")
equal(ViewportGeometry.offsetKeepingVisible(CGPoint(x: 20, y: 20), current: current, viewport: .zero, content: content), current, "An unlaid-out viewport stays unchanged")
print("PASS: 6 viewport edge-follow geometry cases")

let safe = CGRect(x: 18, y: 86, width: 364, height: 300)
let minimum = CGPoint(x: 0, y: -86)
let maximum = CGPoint(x: 1200, y: 1000)
equal(ViewportGeometry.offsetForFocus(field: CGRect(x: 600, y: 700, width: 200, height: 40), caret: nil, fallback: nil, current: CGPoint(x: 400, y: 0), safe: safe, minimum: minimum, maximum: maximum), CGPoint(x: 418, y: 354), "A small text field remains completely above the keyboard and within the viewport")
equal(ViewportGeometry.offsetForFocus(field: CGRect(x: 0, y: 0, width: 1600, height: 1000), caret: CGRect(x: 900, y: 800, width: 2, height: 24), fallback: nil, current: CGPoint(x: 600, y: 0), safe: safe, minimum: minimum, maximum: maximum), CGPoint(x: 600, y: 466), "A large editor follows the caret with surrounding text without horizontal jitter")
equal(ViewportGeometry.offsetForFocus(field: CGRect(x: 0, y: 0, width: 1600, height: 1000), caret: nil, fallback: CGPoint(x: 1200, y: 900), current: CGPoint(x: 600, y: 0), safe: safe, minimum: minimum, maximum: maximum), CGPoint(x: 866, y: 542), "Unavailable caret geometry falls back to the last interaction")
equal(ViewportGeometry.offsetForFocus(field: CGRect(x: 100, y: 700, width: 200, height: 80), caret: CGRect(x: 280, y: 730, width: 2, height: 24), fallback: nil, current: .zero, safe: safe, minimum: minimum, maximum: maximum), CGPoint(x: 0, y: 394), "A small field is kept whole even when only its caret would need less movement")
equal(ViewportGeometry.offsetForFocus(field: CGRect(x: 100, y: 0, width: 200, height: 40), caret: nil, fallback: nil, current: .zero, safe: safe, minimum: minimum, maximum: maximum), CGPoint(x: 0, y: -86), "Top content inset lets a field at the desktop edge clear the controls")
equal(ViewportGeometry.offsetForFocus(field: CGRect(x: 100, y: 500, width: 200, height: 40), caret: nil, fallback: nil, current: CGPoint(x: 0, y: 200), safe: CGRect(x: 18, y: 40, width: 364, height: 260), minimum: minimum, maximum: maximum), CGPoint(x: 0, y: 240), "Keyboard resizing pans only the forty points needed to reveal the field")
equal(ViewportGeometry.offsetForFocus(field: CGRect(x: 100, y: 10, width: 200, height: 20), caret: nil, fallback: nil, current: CGPoint(x: 0, y: -280), safe: safe, minimum: CGPoint(x: 0, y: -280), maximum: CGPoint(x: 0, y: -280)), CGPoint(x: 0, y: -280), "Centered letterbox content does not jump during focus updates")
let keyboard = CGRect(x: 0, y: 400, width: 400, height: 400)
precondition(ViewportGeometry.unobscuredHeight(viewport: CGRect(x: 0, y: 0, width: 400, height: 800), keyboard: keyboard) == 400)
precondition(ViewportGeometry.unobscuredHeight(viewport: CGRect(x: 0, y: 0, width: 400, height: 400), keyboard: keyboard) == 400, "SwiftUI keyboard avoidance must not subtract the keyboard twice")
precondition(ViewportGeometry.unobscuredHeight(viewport: CGRect(x: 0, y: 200, width: 400, height: 800), keyboard: CGRect(x: 0, y: 600, width: 400, height: 400)) == 400, "Keyboard conversion respects content-offset coordinate origins")
precondition(ViewportGeometry.unobscuredHeight(viewport: CGRect(x: 0, y: 0, width: 400, height: 800), keyboard: CGRect(x: 450, y: 400, width: 200, height: 200)) == 800, "A keyboard outside the viewport does not occlude it")
equal(ViewportGeometry.offsetForFocus(field: CGRect(x: 100, y: 100, width: 200, height: 40), caret: CGRect(x: 110, y: 440, width: 2, height: 24), fallback: nil, current: .zero, safe: safe, minimum: minimum, maximum: maximum), CGPoint(x: 0, y: 78), "A caret outside stale field bounds still remains visible")
print("PASS: 12 field/caret focus and actual keyboard intersection cases")

let placement = ViewportPlacement(zoom: 2, offset: CGPoint(x: 700, y: 300), viewport: viewport, desktop: content)!
equal(placement.offset(viewport: viewport, desktop: content, zoom: 2), CGPoint(x: 700, y: 300), "Returning to a monitor restores its exact zoomed position")
precondition(placement.zoom == 2)
equal(placement.offset(viewport: CGSize(width: 800, height: 400), desktop: content, zoom: 2), CGPoint(x: 500, y: 500), "Rotation preserves the same remote center")
equal(placement.offset(viewport: viewport, desktop: CGSize(width: 800, height: 450), zoom: 4), CGPoint(x: 700, y: 300), "Normalized placement survives a changed stream resolution")
let letterbox = ViewportPlacement(zoom: 0.25, offset: CGPoint(x: 0, y: -287.5), viewport: viewport, desktop: content)!
equal(letterbox.offset(viewport: viewport, desktop: content, zoom: 0.25), CGPoint(x: 0, y: -287.5), "Fit preview letterboxing restores without shifting")
precondition(ViewportPlacement(zoom: 0, offset: .zero, viewport: viewport, desktop: content) == nil)
print("PASS: 5 saved monitor placement and rotation cases")


// iPad portrait/landscape and narrow multitasking windows must preserve the remote center.
let tabletDesktop = CGSize(width: 1920, height: 1080)
let tabletPlacement = ViewportPlacement(zoom: 1.5, offset: CGPoint(x: 900, y: 400), viewport: CGSize(width: 1024, height: 1366), desktop: tabletDesktop)!
for size in [CGSize(width: 1366, height: 1024), CGSize(width: 320, height: 1024), CGSize(width: 844, height: 600)] {
    let offset = tabletPlacement.offset(viewport: size, desktop: tabletDesktop, zoom: tabletPlacement.zoom)
    let restored = ViewportPlacement(zoom: tabletPlacement.zoom, offset: offset, viewport: size, desktop: tabletDesktop)!
    equal(restored.center, tabletPlacement.center, "iPad rotation and window resize preserve remote center")
}
precondition(ViewportGeometry.unobscuredHeight(viewport: CGRect(x: 0, y: 0, width: 1024, height: 1366), keyboard: CGRect(x: 0, y: 1000, width: 1024, height: 366)) == 1000, "iPad docked keyboard leaves the typing area above it")
print("PASS: iPad landscape, narrow multitasking, resizable window and docked keyboard geometry")
