import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let sourceURL = root.appendingPathComponent("Design/AppIcon.jpg")
guard let source = NSImage(contentsOf: sourceURL), source.size.width == source.size.height else {
    fatalError("Expected square app artwork at \(sourceURL.path)")
}
func render(_ size: Int, to path: URL) throws {
    let bitmap = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                           bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let context = NSGraphicsContext(cgContext: bitmap, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    context.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let destination = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(path.path)") }
}
let assets = root.appendingPathComponent("Assets.xcassets")
let icon = assets.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: icon, withIntermediateDirectories: true)
try render(1024, to: icon.appendingPathComponent("Reach.png"))
let artwork = assets.appendingPathComponent("ReachArtwork.imageset")
try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
try render(1024, to: artwork.appendingPathComponent("Reach.png"))
let artworkContents: [String: Any] = ["images": [["filename": "Reach.png", "idiom": "universal"]], "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: artworkContents, options: [.prettyPrinted, .sortedKeys]).write(to: artwork.appendingPathComponent("Contents.json"))
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
