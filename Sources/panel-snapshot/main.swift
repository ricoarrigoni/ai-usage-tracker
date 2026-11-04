// Development tool: renders the panel to PNG files so its layout can be checked without opening it.
// Usage: panel-snapshot <output folder>
import AppKit
import SwiftUI
import UsageCore
import UsageUI

@MainActor
func render(_ dashboard: Dashboard, scheme: ColorScheme, to url: URL) throws {
    let view = PanelView(dashboard: dashboard, onRefresh: {}, onOpenHistory: {}, onQuit: {})
        .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
        .environment(\.colorScheme, scheme)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
}

func sample() -> Dashboard {
    var d = Dashboard()
    d.menuTitle = "Week 100%"
    d.limits = [
        LimitDisplay(kind: .fiveHour, percent: 86, level: .nearLimit, detail: "Resets 16:40"),
        LimitDisplay(kind: .sevenDay, percent: 100, level: .reached, detail: "Resets Sat 19:00"),
    ]
    d.pace = PaceMessage(text: "At this pace, you'll reach your session limit around 16:10", isWarning: true)
    d.freshness = "Updated 3 min ago"
    d.costs = [
        CostPeriod(title: "Session", usd: 12.40), CostPeriod(title: "Today", usd: 48.75),
        CostPeriod(title: "7 days", usd: 312), CostPeriod(title: "30 days", usd: 1284),
    ]
    d.problem = "12 log lines couldn't be read, so totals may be low."
    return d
}

@MainActor
func renderHistory(_ history: UsageHistory, scheme: ColorScheme, to url: URL) throws {
    let view = HistoryContent(history: history, problem: nil, range: .constant(.month)).sections
        .frame(width: 620)
        .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
        .environment(\.colorScheme, scheme)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
}

let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

let engine = try DashboardEngine()
let real = try await engine.load()
let history = try await engine.history(days: 30)
var splitSample = history
splitSample.limitSplit = .ready(claudeCodePercent: 72, otherPercent: 28, points: 40)
var withSplit = real
withSplit.limitSplit = splitSample.limitSplit
var warnings = sample()
warnings.money = real.money
warnings.today = real.today
warnings.days = real.days
warnings.projects = real.projects

try await MainActor.run {
    try render(real, scheme: .light, to: folder.appendingPathComponent("real-light.png"))
    try render(real, scheme: .dark, to: folder.appendingPathComponent("real-dark.png"))
    try render(warnings, scheme: .dark, to: folder.appendingPathComponent("warnings-dark.png"))
    try render(Dashboard(), scheme: .light, to: folder.appendingPathComponent("empty-light.png"))
    try render(withSplit, scheme: .light, to: folder.appendingPathComponent("split-light.png"))
    try renderHistory(history, scheme: .dark, to: folder.appendingPathComponent("history-dark.png"))
    try renderHistory(splitSample, scheme: .light, to: folder.appendingPathComponent("history-light.png"))
}
print("menu title: \(real.menuTitle)")
