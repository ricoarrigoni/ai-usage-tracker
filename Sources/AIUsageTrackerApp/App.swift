import SwiftUI
import UsageUI

@main
struct AIUsageTrackerApp: App {
    @State private var model = DashboardModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(
                dashboard: model.dashboard,
                onRefresh: { Task { await model.refresh() } },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            .task { await model.refresh() }
        } label: {
            Text(model.dashboard.menuTitle).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
