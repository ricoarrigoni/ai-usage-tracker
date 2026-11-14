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

    /// True while the Refresh button is asking Claude Code for the current limits.
    public private(set) var isChecking = false
    /// Why the last limit check failed, until the next one.
    public private(set) var checkProblem: String?

    /// What the Refresh button does: asks Claude Code for current limits, then reloads everything.
    /// Logs and the dashboard still reload when the check fails.
    public func checkLimitsAndRefresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            try await Task.detached { try await LimitCheck.run() }.value
            checkProblem = nil
        } catch {
            checkProblem = "\(error)"
        }
        await refresh()
    }

    public func refresh() async {
        guard let engine else { return }
        do {
            dashboard = try await engine.load(takeAlerts: true)
            if !dashboard.alerts.isEmpty { onAlerts(dashboard.alerts) }
            if await engine.updateExchangeRates() {
                dashboard = try await engine.load()
            }
        } catch {
            dashboard.problem = "Couldn't read usage: \(error)"
        }
    }
}
