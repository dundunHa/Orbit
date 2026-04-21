import Foundation

struct AppLaunchScenarioResolution {
    let loader: AppLaunchScenarioLoader?
    let scenario: AppLaunchScenario?
    let errorDescription: String?

    var isScenarioMode: Bool {
        scenario != nil
    }
}

struct AppLaunchScenarioLoader {
    static let scenarioPathEnv = "ORBIT_TEST_SCENARIO_PATH"
    static let diagnosticsPathEnv = "ORBIT_TEST_DIAGNOSTICS_PATH"

    let fileURL: URL

    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let path = Self.scenarioPath(in: environment) else {
            return nil
        }
        self.init(filePath: path)
    }

    init(filePath: String) {
        self.fileURL = URL(fileURLWithPath: filePath)
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppLaunchScenarioResolution {
        guard let loader = AppLaunchScenarioLoader(environment: environment) else {
            return AppLaunchScenarioResolution(
                loader: nil,
                scenario: nil,
                errorDescription: nil
            )
        }

        do {
            return AppLaunchScenarioResolution(
                loader: loader,
                scenario: try loader.load(),
                errorDescription: nil
            )
        } catch {
            return AppLaunchScenarioResolution(
                loader: loader,
                scenario: nil,
                errorDescription: String(describing: error)
            )
        }
    }

    func load() throws -> AppLaunchScenario {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppLaunchScenario.self, from: data).validated()
    }

    @MainActor
    @discardableResult
    func apply(
        _ scenario: AppLaunchScenario,
        sessionStore: SessionStore,
        historyStore: HistoryStore,
        viewModel: AppViewModel
    ) -> Task<Void, Never> {
        viewModel.applyTestingSnapshot(
            sessions: scenario.sessions,
            historyEntries: scenario.historyEntries,
            selectedSessionId: scenario.selectedSessionId,
            onboardingState: (try? scenario.onboarding.makeState()) ?? .welcome,
            pendingInteraction: scenario.pendingInteraction?.makePendingInteraction(),
            todayStats: scenario.todayStats ?? TodayTokenStats()
        )

        if scenario.pendingInteraction != nil {
            viewModel.permissionDecisionResolver = { _, _ in }
        }

        return Task {
            await sessionStore.replaceAll(scenario.sessions)
            await historyStore.replaceAll(scenario.historyEntries)
        }
    }

    static func scenarioPath(in environment: [String: String]) -> String? {
        guard let path = environment[scenarioPathEnv], !path.isEmpty else {
            return nil
        }
        return path
    }

    static func diagnosticsPath(in environment: [String: String]) -> String? {
        guard let path = environment[diagnosticsPathEnv], !path.isEmpty else {
            return nil
        }
        return path
    }
}
