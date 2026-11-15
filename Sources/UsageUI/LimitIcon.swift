import AppKit
import SwiftUI
import UsageCore

/// The icon for each limit: a clock with a dotted tail for the session, a calendar for the week.
public struct LimitIcon: View {
    let kind: LimitKind

    public init(_ kind: LimitKind) { self.kind = kind }

    public var body: some View {
        switch kind {
        case .fiveHour: SessionClock()
        case .sevenDay: Image(systemName: "calendar")
        }
    }
}

/// The icon for a single model's weekly limit, such as Fable.
public struct ModelLimitIcon: View {
    public init() {}
    public var body: some View { Image(systemName: "sparkle") }
}

/// A clock whose rim turns into dots on the lower left, like time running out of a window.
/// Sized from its frame, so it follows the font it sits next to.
struct SessionClock: View {
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let line = side * 0.11
            let radius = side / 2 - line
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // Angles in degrees, clockwise from 3 o'clock (y points down).
            func point(_ degrees: Double, _ distance: CGFloat) -> CGPoint {
                let radians = degrees * .pi / 180
                return CGPoint(x: center.x + distance * cos(radians), y: center.y + distance * sin(radians))
            }

            var outline = Path()
            outline.addArc(center: center, radius: radius,
                           startAngle: .degrees(205), endAngle: .degrees(60), clockwise: false)
            outline.move(to: point(270, radius * 0.62))
            outline.addLine(to: center)
            outline.addLine(to: point(0, radius * 0.45))
            let style = StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)
            context.stroke(outline, with: .foreground, style: style)

            let dot = line * 1.15
            for index in 0..<4 {
                let at = point(180 - Double(index) * 28, radius)
                let rect = CGRect(x: at.x - dot / 2, y: at.y - dot / 2, width: dot, height: dot)
                context.fill(Path(ellipseIn: rect), with: .foreground)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The menu bar title drawn as one template image, since a menu bar label shows only a single
/// image or line of text. Template images follow the menu bar's light and dark appearance.
@MainActor
public enum MenuBarTitle {
    public static func image(for dashboard: Dashboard, scale: CGFloat) -> NSImage? {
        guard !dashboard.limits.isEmpty else { return nil }
        let byKind = Dictionary(dashboard.limits.map { ($0.kind, $0.percent) }, uniquingKeysWith: { a, _ in a })
        let font = NSFont.menuBarFont(ofSize: 0).pointSize

        func item(_ icon: some View, _ value: String) -> some View {
            HStack(spacing: 3) {
                icon
                    .font(.system(size: font * 0.92))
                    .frame(width: font * 1.05, height: font * 1.05)
                Text(value)
                    .font(.system(size: font))
                    .monospacedDigit()
            }
        }

        let content = HStack(spacing: 7) {
            ForEach(LimitKind.allCases, id: \.self) { kind in
                item(LimitIcon(kind), byKind[kind].map { "\($0)%" } ?? "–")
            }
            ForEach(dashboard.modelLimits) { model in
                item(ModelLimitIcon(), "\(model.percent)%")
            }
        }
        .foregroundStyle(.black)
        .padding(.vertical, 1)

        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}
