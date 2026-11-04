import Observation
import ServiceManagement

/// The "Open at login" setting. macOS holds the real state, so it's read from there.
@MainActor
@Observable
final class LoginItem {
    private(set) var note: String?
    private(set) var isEnabled = false

    init() {
        update()
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            update()
        } catch {
            update()
            note = "Couldn't change this: \(error.localizedDescription)"
        }
    }

    private func update() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        note = status == .requiresApproval
            ? "Allow AI Usage Tracker in System Settings > General > Login Items."
            : nil
    }
}
