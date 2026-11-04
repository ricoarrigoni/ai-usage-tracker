import SwiftUI
import UsageCore

/// The panel that opens from the menu bar.
public struct PanelView: View {
    private let dashboard: Dashboard
    private let onRefresh: () -> Void
    private let onQuit: () -> Void

    public init(dashboard: Dashboard, onRefresh: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.dashboard = dashboard
        self.onRefresh = onRefresh
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            limitsSection
            Divider()
            usageSection
            if let problem = dashboard.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder private var limitsSection: some View {
        if dashboard.limits.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No limit readings yet").font(.headline)
                Text("Limits appear after your next Claude Code reply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(dashboard.limits) { LimitRow(limit: $0) }
                if let pace = dashboard.pace {
                    Label(pace.text, systemImage: pace.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(pace.isWarning ? Color.orange : Color.secondary)
                }
                if let freshness = dashboard.freshness {
                    Label(
                        dashboard.isStale ? "\(freshness). Refreshes when Claude Code replies" : freshness,
                        systemImage: "clock"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today").font(.headline)
                Text("\(TokenFormat.short(dashboard.todayNew)) new · \(TokenFormat.short(dashboard.today.cacheRead)) cached tokens")
                    .font(.callout)
                    .monospacedDigit()
            }
            if !dashboard.days.isEmpty { DayBars(days: dashboard.days) }
            if !dashboard.projects.isEmpty { ProjectRows(projects: dashboard.projects) }
            Text("Logged Claude Code use only. Chat, recent Cowork and some background requests aren't counted.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Refresh", action: onRefresh)
                .help("Reads new logs and limit readings. Doesn't send anything to Claude.")
                .keyboardShortcut("r")
            Spacer()
            Button("Quit", action: onQuit)
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct LimitRow: View {
    let limit: LimitDisplay

    private var color: Color {
        switch limit.level {
        case .normal: .accentColor
        case .nearLimit: .orange
        case .reached: .red
        }
    }

    private var status: String? {
        switch limit.level {
        case .normal: nil
        case .nearLimit: "Near limit"
        case .reached: "Limit reached"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.kind.title).font(.callout.weight(.medium))
                if let status {
                    Label(status, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(color)
                }
                Spacer()
                Text("\(limit.percent)%").font(.callout.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(color)
                        .frame(width: max(limit.percent > 0 ? 6 : 0, geometry.size.width * min(Double(limit.percent), 100) / 100))
                }
            }
            .frame(height: 6)
            Text(limit.detail).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limit.kind.title) limit, \(limit.percent) percent used. \(status ?? "") \(limit.detail)")
    }
}

/// Tokens per day for the last 7 days. One series, so one color, with only the peak labeled.
private struct DayBars: View {
    let days: [DayUsage]
    private let plotHeight: CGFloat = 44

    private var peak: Int64 { days.map(\.total).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(days) { day in
                    VStack(spacing: 3) {
                        Spacer(minLength: 0)
                        if day.total > 0 && day.total == peak {
                            Text(TokenFormat.short(day.total))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                            .fill(day.total > 0 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                            .frame(height: barHeight(day.total))
                        Text(day.weekdayLetter)
                            .font(.caption2.weight(day.isToday ? .bold : .regular))
                            .foregroundStyle(day.isToday ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .help("\(day.day.formatted(date: .abbreviated, time: .omitted)): \(TokenFormat.short(day.total)) tokens")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day.day.formatted(date: .complete, time: .omitted)), \(TokenFormat.short(day.total)) tokens")
                }
            }
            .frame(height: plotHeight + 32)
        }
    }

    private func barHeight(_ total: Int64) -> CGFloat {
        guard peak > 0, total > 0 else { return 2 }
        return max(3, plotHeight * CGFloat(Double(total) / Double(peak)))
    }
}

private struct ProjectRows: View {
    let projects: [ReportRow]

    private var largest: Int64 { projects.map(\.totals.total).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(projects, id: \.label) { project in
                HStack(spacing: 8) {
                    Text(project.label)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 124, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: max(4, geometry.size.width * share(project)))
                        }
                    }
                    .frame(height: 4)
                    Text(TokenFormat.short(project.totals.total))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(project.label), \(TokenFormat.short(project.totals.total)) tokens today")
            }
        }
    }

    private func share(_ project: ReportRow) -> CGFloat {
        largest > 0 ? CGFloat(Double(project.totals.total) / Double(largest)) : 0
    }
}
