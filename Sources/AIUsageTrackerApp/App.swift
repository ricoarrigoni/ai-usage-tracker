import SwiftUI
import UsageUI

@main
struct AIUsageTrackerApp: App {
    @State private var model: DashboardModel
    @State private var history: HistoryModel

    init() {
        let dashboard = DashboardModel()
        _model = State(initialValue: dashboard)
        _history = State(initialValue: HistoryModel(engine: dashboard.engine))
    }

    var body: some Scene {
        MenuBarExtra {
            PanelContainer(model: model)
        } label: {
            Text(model.dashboard.menuTitle).monospacedDigit()
        }
        .menuBarExtraStyle(.window)

        Window("Usage History", id: "history") {
            HistoryWindow(model: history)
        }
        .defaultSize(width: 640, height: 760)
        .defaultLaunchBehavior(.suppressed)
    }
}

private struct PanelContainer: View {
    let model: DashboardModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PanelView(
            dashboard: model.dashboard,
            onRefresh: { Task { await model.refresh() } },
            onOpenHistory: {
                openWindow(id: "history")
                NSApplication.shared.activate()
            },
            onQuit: { NSApplication.shared.terminate(nil) }
        )
        .task { await model.refresh() }
    }
}
