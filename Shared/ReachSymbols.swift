import SwiftUI

/// A single-stroke monitor, matching Reach's restrained connection glyph.
struct ReachMonitorOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let screen = CGRect(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.12,
                            width: rect.width * 0.84, height: rect.height * 0.58)
        path.addRoundedRect(in: screen, cornerSize: CGSize(width: 2, height: 2))
        path.move(to: CGPoint(x: rect.midX, y: screen.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.88))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.88))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.70, y: rect.minY + rect.height * 0.88))
        return path
    }
}
