// Development tool: renders the panel to PNG files so its layout can be checked without opening it.
// Usage: panel-snapshot <output folder>
import AppKit
import SwiftUI
import UsageCore
import UsageUI

@MainActor
func render(_ dashboard: Dashboard, scheme: ColorScheme, to url: URL) throws {
    let view = PanelView(dashboard: dashboard, onRefresh: {}, onQuit: {})
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
    d.menuTitle = "5h 86%"
    d.limits = [
        LimitDisplay(kind: .fiveHour, percent: 86, level: .nearLimit, detail: "Resets 16:40"),
        LimitDisplay(kind: .sevenDay, percent: 100, level: .reached, detail: "Resets Sat 19:00"),
    ]
    d.pace = PaceMessage(text: "At this pace: 5-hour limit 16:10", isWarning: true)
    d.freshness = "Updated 3 min ago"
    d.problem = "12 log lines couldn't be read, so totals may be low."
    return d
}

let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

let real = try await DashboardEngine().load()
var warnings = sample()
warnings.today = real.today
warnings.days = real.days
warnings.projects = real.projects

try await MainActor.run {
    try render(real, scheme: .light, to: folder.appendingPathComponent("real-light.png"))
    try render(real, scheme: .dark, to: folder.appendingPathComponent("real-dark.png"))
    try render(warnings, scheme: .dark, to: folder.appendingPathComponent("warnings-dark.png"))
    try render(Dashboard(), scheme: .light, to: folder.appendingPathComponent("empty-light.png"))
}
print("menu title: \(real.menuTitle)")
