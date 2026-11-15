import SwiftUI

/// The same cool neutrals and regular display typography used by Feather's welcome page.
enum ReachHomeStyle {
    static let background = color(light: 0xF1F3F6, dark: 0x0E1015)
    static let ink = color(light: 0x161A21, dark: 0xE9ECF1)
    static let muted = color(light: 0x474E5C, dark: 0xAEB5C1)
    static let faint = color(light: 0x5F6675, dark: 0x8B93A1)
    static let cyan = color(light: 0x398DA6, dark: 0x76C9DD)
    static let line = ink.opacity(0.10)

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

struct ReachHero: View {
    @ScaledMetric(relativeTo: .largeTitle) private var displaySize: CGFloat = 76
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ReachConnectionGlyph().frame(width: 22, height: 22)
                Text("Your desktop. Wherever you are.")
                    .font(.footnote).foregroundStyle(ReachHomeStyle.muted)
            }
            .padding(.bottom, 14)
            Text("REACH")
                .font(.system(size: displaySize, weight: .regular))
                .tracking(-displaySize * 0.01)
                .lineLimit(1).minimumScaleFactor(0.55)
                .foregroundStyle(ReachHomeStyle.ink)
                .accessibilityLabel("Reach")
                .accessibilityAddTraits(.isHeader)
            Text("Your Mac. Within reach.")
                .font(.body).foregroundStyle(ReachHomeStyle.muted)
                .padding(.top, 15)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReachConnectionGlyph: View {
    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
            let desktop = CGRect(x: 0.5, y: 2.5, width: size.width * 0.70, height: size.height * 0.51)
            context.stroke(Path(roundedRect: desktop, cornerRadius: 1.8), with: .color(ReachHomeStyle.cyan), style: stroke)
            var stand = Path()
            stand.move(to: CGPoint(x: desktop.midX, y: desktop.maxY)); stand.addLine(to: CGPoint(x: desktop.midX, y: desktop.maxY + 3.6))
            stand.move(to: CGPoint(x: desktop.midX - 3, y: desktop.maxY + 3.6)); stand.addLine(to: CGPoint(x: desktop.midX + 3, y: desktop.maxY + 3.6))
            context.stroke(stand, with: .color(ReachHomeStyle.cyan), style: stroke)
            let phone = CGRect(x: size.width * 0.65, y: size.height * 0.44, width: size.width * 0.32, height: size.height * 0.53)
            context.fill(Path(roundedRect: phone, cornerRadius: 1.8), with: .color(ReachHomeStyle.background))
            context.stroke(Path(roundedRect: phone, cornerRadius: 1.8), with: .color(ReachHomeStyle.cyan), style: stroke)
        }
        .accessibilityHidden(true)
    }
}

/// Static dots borrow Feather's hero texture without a repeating animation or rendering timer.
struct ReachHeroDotField: View {
    private static let accents: Set<Int> = [8, 17, 29, 44, 51, 68, 75, 86]
    var body: some View {
        Canvas { context, size in
            let columns = 13, rows = 8
            let gap = min(size.width / 16, 23)
            let originX = size.width - CGFloat(columns - 1) * gap - 12
            for row in 0..<rows {
                for column in 0..<columns {
                    let fade = CGFloat(column + 1) / CGFloat(columns) * (1 - CGFloat(row) / CGFloat(rows + 1))
                    let point = CGPoint(x: originX + CGFloat(column) * gap, y: 18 + CGFloat(row) * gap)
                    let rect = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
                    let accent = Self.accents.contains(row * columns + column)
                    let color = accent ? ReachHomeStyle.cyan.opacity(0.25 + fade * 0.45) : ReachHomeStyle.ink.opacity(0.045 + fade * 0.12)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .accessibilityHidden(true).allowsHitTesting(false)
    }
}
