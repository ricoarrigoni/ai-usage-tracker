import SwiftUI
import UsageUI

@main
struct AIUsageTrackerApp: App {
    @State private var model: DashboardModel
    @State private var history: HistoryModel
    @State private var loginItem = LoginItem()
    private let notifier: AlertNotifier

    init() {
        let notifier = AlertNotifier()
        notifier.start()
        self.notifier = notifier

        // A way to check that notifications get through, without waiting to reach a limit.
        if CommandLine.arguments.contains("--test-alert") {
            notifier.send(
                id: "test-\(UUID().uuidString)",
                title: "Session limit at 80%",
                body: "This is a test from AI Usage Tracker."
            )
        }

        let dashboard = DashboardModel(onAlerts: { notifier.send($0) })
        _model = State(initialValue: dashboard)
        _history = State(initialValue: HistoryModel(engine: dashboard.engine))
    }

    var body: some Scene {
        MenuBarExtra {
            PanelContainer(model: model, loginItem: loginItem)
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
    let loginItem: LoginItem
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PanelView(
            dashboard: model.dashboard,
            openAtLogin: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }),
            loginNote: loginItem.note,
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
