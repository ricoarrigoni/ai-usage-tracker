import Charts
import Observation
import SwiftUI
import UsageCore

@MainActor
@Observable
public final class HistoryModel {
    public enum Range: String, CaseIterable, Identifiable {
        case week = "7 days", month = "30 days", all = "All recorded"
        public var id: String { rawValue }
        var days: Int? {
            switch self {
            case .week: 7
            case .month: 30
            case .all: nil
            }
        }
    }

    public var range = Range.month
    public private(set) var history = UsageHistory()
    public private(set) var problem: String?

    @ObservationIgnored private let engine: DashboardEngine?

    public init(engine: DashboardEngine?) {
        self.engine = engine
    }

    public func refresh() async {
        guard let engine else { return }
        do {
            history = try await engine.history(days: range.days)
            problem = nil
        } catch {
            problem = "Couldn't read history: \(error)"
        }
    }
}

public struct HistoryWindow: View {
    @Bindable private var model: HistoryModel

    public init(model: HistoryModel) {
        self.model = model
    }

    public var body: some View {
        HistoryContent(history: model.history, problem: model.problem, range: $model.range)
            .frame(minWidth: 560, minHeight: 480)
            .task(id: model.range) { await model.refresh() }
    }
}

/// Separate from the model so it can also be rendered with fixed data.
public struct HistoryContent: View {
    let history: UsageHistory
    let problem: String?
    @Binding var range: HistoryModel.Range
    @State private var metric = Metric.all

    enum Metric: String, CaseIterable, Identifiable {
        case all = "All tokens", new = "Without cached reads"
        var id: String { rawValue }
    }

    public init(history: UsageHistory, problem: String?, range: Binding<HistoryModel.Range>) {
        self.history = history
        self.problem = problem
        _range = range
    }

    public var body: some View {
        ScrollView { sections }
    }

    /// Everything inside the scroll area. Image rendering can't draw scroll views, so the
    /// snapshot tool renders this directly.
    public var sections: some View {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Period", selection: $range) {
                    ForEach(HistoryModel.Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                summary
                chartSection
                if let split = history.limitSplit {
                    LimitSplitSection(status: split, scope: range.rawValue.lowercased())
                }
                HStack(alignment: .top, spacing: 24) {
                    BreakdownList(title: "By project", rows: history.projects)
                    BreakdownList(title: "By model", rows: history.models)
                }
                windowList
                footnote
            }
            .padding(20)
    }

    private var summary: some View {
        HStack(spacing: 24) {
            stat("New tokens", TokenFormat.short(history.totals.input + history.totals.output + history.totals.cacheWrite))
            stat("Cached reads", TokenFormat.short(history.totals.cacheRead))
            stat("Replies", history.totals.replies.formatted())
            if let cost = history.costUSD {
                stat(costTitle, Money.text(cost))
            }
        }
    }

    private var costTitle: String {
        guard let since = history.costTrackedSince else { return "At API prices" }
        return "At API prices, since \(since.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tokens per day").font(.headline)
                Spacer()
                Picker("Measure", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            DayChart(days: history.days, metric: metric)
                .frame(height: 180)
        }
    }

    private var windowList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("5-hour windows").font(.headline)
            if history.windows.isEmpty {
                Text("No windows recorded in this period.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(history.windows.prefix(20)) { window in
                WindowRow(window: window)
            }
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tokens are logged Claude Code use, plus any Cowork logs on this Mac. Chat, recent Cowork and some background requests aren't counted, so treat them as a lower bound.")
            if let since = history.costTrackedSince {
                Text("Costs are Claude Code's own estimates at API list prices, not what you pay, and start from \(since.formatted(date: .abbreviated, time: .shortened)).")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DayChart: View {
    let days: [UsageHistory.Day]
    let metric: HistoryContent.Metric
    @State private var selected: Date?

    private func value(_ day: UsageHistory.Day) -> Int64 {
        metric == .all ? day.totals.total : day.newTokens
    }

    private var selectedDay: UsageHistory.Day? {
        guard let selected else { return nil }
        return days.first { Calendar.current.isDate($0.date, inSameDayAs: selected) }
    }

    var body: some View {
        Chart {
            ForEach(days) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", value(day)))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
            }
            if let day = selectedDay {
                RuleMark(x: .value("Day", day.date, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(day.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2)
                            Text("\(TokenFormat.short(value(day))) tokens")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                        .padding(5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartYAxis {
            AxisMarks(position: .leading) { mark in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let number = mark.as(Int64.self) { Text(TokenFormat.short(number)) }
                }
            }
        }
        .accessibilityLabel("Tokens per day")
    }
}

private struct BreakdownList: View {
    let title: String
    let rows: [ReportRow]

    private var largest: Int64 { rows.map(\.totals.total).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(rows.prefix(8), id: \.label) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(row.label).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(TokenFormat.short(row.totals.total)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: max(3, geometry.size.width * share(row)))
                    }
                    .frame(height: 3)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func share(_ row: ReportRow) -> CGFloat {
        largest > 0 ? CGFloat(Double(row.totals.total) / Double(largest)) : 0
    }
}

private struct WindowRow: View {
    let window: WindowSplit

    private var title: String {
        let date = window.start ?? window.end ?? Date()
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.caption).monospacedDigit().frame(width: 150, alignment: .leading)
            Text("\(window.peak)%").font(.caption.weight(.semibold)).monospacedDigit().frame(width: 36, alignment: .trailing)
            if let claudeCode = window.claudeCode, let other = window.other, claudeCode + other > 0 {
                SplitBar(claudeCode: claudeCode, other: other, height: 5)
                Text("~\(Int(claudeCode.rounded())) code · ~\(Int(other.rounded())) other")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 118, alignment: .trailing)
            } else {
                Spacer()
                Text(window.measuredPoints > 0 ? "Still measuring" : "No cost data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
