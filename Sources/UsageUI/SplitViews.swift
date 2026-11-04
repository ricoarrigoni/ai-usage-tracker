import SwiftUI
import UsageCore

/// The two colors used for the limit split, checked for colorblind separation in light and dark.
enum SplitColor {
    static func claudeCode(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255)
            : Color(red: 0x2A / 255, green: 0x78 / 255, blue: 0xD6 / 255)
    }

    static func other(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0x19 / 255, green: 0x9E / 255, blue: 0x70 / 255)
            : Color(red: 0x1B / 255, green: 0xAF / 255, blue: 0x7A / 255)
    }
}

struct SplitBar: View {
    let claudeCode: Double
    let other: Double
    var height: CGFloat = 6
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let total = max(claudeCode + other, 0.001)
            let gap: CGFloat = claudeCode > 0 && other > 0 ? 2 : 0
            let usable = geometry.size.width - gap
            HStack(spacing: gap) {
                if claudeCode > 0 {
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(SplitColor.claudeCode(scheme))
                        .frame(width: usable * claudeCode / total)
                }
                if other > 0 {
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(SplitColor.other(scheme))
                        .frame(width: usable * other / total)
                }
            }
        }
        .frame(height: height)
    }
}

/// "Where your limit went": an estimate, or a note that it's still measuring.
struct LimitSplitSection: View {
    let status: LimitSplitStatus
    let scope: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where your limit went").font(.callout.weight(.medium))
            switch status {
            case .learning(let measurements, let needed):
                Text("Still measuring: \(measurements) of \(needed) readings. More Claude Code use will finish this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .ready(let claudeCode, let other, _):
                SplitBar(claudeCode: Double(claudeCode), other: Double(other))
                legendRow("Claude Code", value: "~\(claudeCode)%", color: SplitColor.claudeCode(scheme))
                legendRow("Chat, Cowork & other", value: "~\(other)%", color: SplitColor.other(scheme))
                Text("Estimate from your session limit, \(scope).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func legendRow(_ name: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(name).font(.caption)
            Spacer()
            Text(value).font(.caption).monospacedDigit()
        }
    }
}
