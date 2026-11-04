import Foundation
import Observation
import UsageCore

/// Keeps the dashboard up to date for the interface.
@MainActor
@Observable
public final class DashboardModel {
    public private(set) var dashboard = Dashboard()

    @ObservationIgnored public let engine: DashboardEngine?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let onAlerts: @MainActor ([LimitAlert]) -> Void

    public init(refreshEvery seconds: Int = 30, onAlerts: @escaping @MainActor ([LimitAlert]) -> Void = { _ in }) {
        self.onAlerts = onAlerts
        do {
            engine = try DashboardEngine()
        } catch {
            engine = nil
            dashboard.problem = "Couldn't open the usage database: \(error)"
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    public func refresh() async {
        guard let engine else { return }
        do {
            dashboard = try await engine.load(takeAlerts: true)
            if !dashboard.alerts.isEmpty { onAlerts(dashboard.alerts) }
        } catch {
            dashboard.problem = "Couldn't read usage: \(error)"
        }
    }
}
