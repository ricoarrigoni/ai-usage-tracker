import SwiftUI
import UsageCore

/// The panel that opens from the menu bar.
public struct PanelView: View {
    private let dashboard: Dashboard
    private let onRefresh: () -> Void
    private let onOpenHistory: () -> Void
    private let onQuit: () -> Void
    private let openAtLogin: Binding<Bool>?
    private let loginNote: String?

    public init(
        dashboard: Dashboard,
        openAtLogin: Binding<Bool>? = nil,
        loginNote: String? = nil,
        onRefresh: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.dashboard = dashboard
        self.openAtLogin = openAtLogin
        self.loginNote = loginNote
        self.onRefresh = onRefresh
        self.onOpenHistory = onOpenHistory
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            limitsSection
            if let split = dashboard.limitSplit {
                Divider()
                LimitSplitSection(status: split, scope: "this week")
            }
            if !dashboard.costs.isEmpty {
                Divider()
                CostSection(costs: dashboard.costs, unpricedReplies: dashboard.unpricedReplies, money: dashboard.money)
            }
            Divider()
            usageSection
            if let problem = dashboard.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            if let openAtLogin {
                Toggle("Open at login", isOn: openAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
            if let loginNote {
                Text(loginNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(14)
        .frame(width: 340)
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
            Text("Costs and tokens cover logged Claude Code use only. Chat, recent Cowork and some background requests aren't counted.")
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
            Button("History…", action: onOpenHistory)
                .keyboardShortcut("h")
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
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(limit.kind.title).font(.callout.weight(.medium))
                Text(limit.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 124, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(color)
                        .frame(width: max(limit.percent > 0 ? 6 : 0, geometry.size.width * min(Double(limit.percent), 100) / 100))
                }
            }
            .frame(height: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(limit.percent)% used")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(status == nil ? Color.secondary : color)
                if let status {
                    Label(status, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(color)
                }
            }
            .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limit.kind.title), \(limit.percent) percent of the limit used. \(status ?? "") \(limit.detail)")
    }
}

/// What the same use would cost on the API, over four periods.
private struct CostSection: View {
    let costs: [CostPeriod]
    let unpricedReplies: Int64
    let money: MoneyFormat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Estimated cost at API prices").font(.callout.weight(.medium))
            HStack(alignment: .top, spacing: 8) {
                ForEach(costs) { period in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(period.title).font(.caption).foregroundStyle(.secondary)
                        Text(period.usd.map(money.plain) ?? "–")
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Your plan's price doesn't change with this. It shows what the same use would cost on the API.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = money.conversionNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if unpricedReplies > 0 {
                Text("\(unpricedReplies) replies in the last 30 days used a model with no known price and aren't included.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
