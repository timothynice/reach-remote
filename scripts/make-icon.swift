import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
func render(_ size: Int, to path: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let s = CGFloat(size) / 1024
    context.cgContext.scaleBy(x: s, y: s)
    let bg = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    NSGradient(starting: NSColor(calibratedRed: 0.04, green: 0.11, blue: 0.25, alpha: 1), ending: NSColor(calibratedRed: 0.12, green: 0.48, blue: 0.78, alpha: 1))!.draw(in: bg, angle: 40)
    let shadow = NSShadow(); shadow.shadowBlurRadius = 35; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.shadowColor = .black.withAlphaComponent(0.16); shadow.set()
    NSColor.white.withAlphaComponent(0.88).setStroke()
    let desktop = NSBezierPath(roundedRect: NSRect(x: 200, y: 310, width: 590, height: 416), xRadius: 45, yRadius: 45); desktop.lineWidth = 19; desktop.stroke()
    NSColor.white.withAlphaComponent(0.48).setStroke()
    let stand = NSBezierPath(); stand.move(to: NSPoint(x: 368, y: 236)); stand.line(to: NSPoint(x: 568, y: 236)); stand.move(to: NSPoint(x: 470, y: 310)); stand.line(to: NSPoint(x: 470, y: 238)); stand.lineWidth = 19; stand.lineCapStyle = .round; stand.stroke()
    let phone = NSBezierPath(roundedRect: NSRect(x: 554, y: 196, width: 244, height: 430), xRadius: 47, yRadius: 47)
    NSColor(calibratedRed: 0.13, green: 0.39, blue: 0.63, alpha: 1).setFill(); phone.fill(); NSColor.white.setStroke(); phone.lineWidth = 19; phone.stroke()
    let detail = NSBezierPath(); detail.move(to: NSPoint(x: 641, y: 588)); detail.line(to: NSPoint(x: 710, y: 588)); detail.move(to: NSPoint(x: 641, y: 231)); detail.line(to: NSPoint(x: 710, y: 231)); detail.lineCapStyle = .round; detail.lineWidth = 11; detail.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: path)
}
let assets = root.appendingPathComponent("Assets.xcassets")
let icon = assets.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: icon, withIntermediateDirectories: true)
try render(1024, to: icon.appendingPathComponent("Reach.png"))
var images: [[String: String]] = [["filename": "Reach.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "mac-\(size)@\(scale)x.png"
        try render(size * scale, to: icon.appendingPathComponent(filename))
        images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: icon.appendingPathComponent("Contents.json"))
try "{\"info\":{\"author\":\"xcode\",\"version\":1}}".write(to: assets.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
