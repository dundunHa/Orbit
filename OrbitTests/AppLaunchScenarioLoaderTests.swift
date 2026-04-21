import Foundation
import Testing
@testable import Orbit

@Suite("AppLaunchScenarioLoader")
struct AppLaunchScenarioLoaderTests {
    @Test("loader decodes and applies scenario snapshot")
    @MainActor
    func loaderDecodesAndAppliesScenario() async throws {
        let scenario = AppLaunchScenario(
            schemaVersion: AppLaunchScenario.currentVersion,
            fixtureName: "pending-permission",
            description: "test fixture",
            seed: AppLaunchScenario.Seed(
                sessions: [
                    Session(
                        id: "sess-1",
                        cwd: "/tmp/project",
                        status: .waitingForApproval(
                            toolName: "Bash",
                            toolInput: .object(["command": .string("ls")])
                        ),
                        startedAt: Date(timeIntervalSince1970: 1_710_000_000),
                        lastEventAt: Date(timeIntervalSince1970: 1_710_000_060)
                    )
                ],
                historyEntries: [
                    HistoryEntry(
                        sessionId: "hist-1",
                        cwd: "/tmp/project",
                        startedAt: Date(timeIntervalSince1970: 1_709_999_000),
                        endedAt: Date(timeIntervalSince1970: 1_709_999_120),
                        toolCount: 2,
                        durationSecs: 120,
                        title: "Previous work",
                        tokensIn: 120,
                        tokensOut: 80
                    )
                ],
                selectedSessionId: "sess-1",
                onboardingState: OnboardingFixture(type: "DriftDetected", detail: nil),
                pendingInteraction: PendingInteractionFixture(
                    id: "req-1",
                    kind: "permission",
                    sessionId: "sess-1",
                    toolName: "Bash",
                    toolInput: .object(["command": .string("ls")]),
                    message: "Allow command?",
                    requestedSchema: nil,
                    permissionSuggestions: nil
                ),
                todayStats: TodayTokenStats(tokensIn: 9, tokensOut: 12),
                overlay: .init(initialIntent: .expanded)
            ),
            expected: nil
        )

        let scenarioURL = try writeScenario(scenario)
        let loader = AppLaunchScenarioLoader(filePath: scenarioURL.path)
        let loadedScenario = try loader.load()
        let fixture = makeFixture()

        let task = loader.apply(
            loadedScenario,
            sessionStore: fixture.sessionStore,
            historyStore: fixture.historyStore,
            viewModel: fixture.viewModel
        )
        await task.value

        #expect(fixture.viewModel.selectedSessionId == "sess-1")
        #expect(fixture.viewModel.onboardingState == .driftDetected)
        #expect(fixture.viewModel.pendingInteraction?.id == "req-1")
        #expect(fixture.viewModel.pendingInteraction?.toolName == "Bash")
        #expect(fixture.viewModel.todayStats.tokensIn == 9)
        #expect(fixture.viewModel.sessions["sess-1"] != nil)
        #expect(fixture.viewModel.historyEntries.count == 1)
        #expect(await fixture.sessionStore.allSessions()["sess-1"] != nil)
        #expect(await fixture.historyStore.loadAll().count == 1)
    }

    @Test("loader rejects unsupported version")
    func loaderRejectsUnsupportedVersion() throws {
        let scenario = AppLaunchScenario(
            schemaVersion: 99,
            fixtureName: "invalid-version",
            description: "invalid",
            seed: AppLaunchScenario.Seed(
                sessions: [],
                historyEntries: [],
                selectedSessionId: nil,
                onboardingState: OnboardingFixture(type: "Connected", detail: nil),
                pendingInteraction: nil,
                todayStats: nil,
                overlay: .init(initialIntent: .collapsed)
            ),
            expected: nil
        )

        let scenarioURL = try writeScenario(scenario)
        let loader = AppLaunchScenarioLoader(filePath: scenarioURL.path)

        #expect(throws: AppLaunchScenarioError.unsupportedVersion(99)) {
            try loader.load()
        }
    }

    @Test("resolution only enables scenario mode after successful load")
    func resolutionOnlyEnablesScenarioModeAfterSuccessfulLoad() throws {
        let scenario = AppLaunchScenario(
            schemaVersion: AppLaunchScenario.currentVersion,
            fixtureName: "connected",
            description: "valid",
            seed: AppLaunchScenario.Seed(
                sessions: [],
                historyEntries: [],
                selectedSessionId: nil,
                onboardingState: OnboardingFixture(type: "Connected", detail: nil),
                pendingInteraction: nil,
                todayStats: nil,
                overlay: .init(initialIntent: .collapsed)
            ),
            expected: nil
        )
        let scenarioURL = try writeScenario(scenario)

        let loaded = AppLaunchScenarioLoader.resolve(
            environment: [AppLaunchScenarioLoader.scenarioPathEnv: scenarioURL.path]
        )

        #expect(loaded.isScenarioMode)
        #expect(loaded.loader?.fileURL == scenarioURL)
        #expect(loaded.scenario?.fixtureName == "connected")
        #expect(loaded.errorDescription == nil)

        let failed = AppLaunchScenarioLoader.resolve(
            environment: [AppLaunchScenarioLoader.scenarioPathEnv: "/tmp/orbit-does-not-exist.json"]
        )

        #expect(!failed.isScenarioMode)
        #expect(failed.loader?.fileURL.path == "/tmp/orbit-does-not-exist.json")
        #expect(failed.scenario == nil)
        #expect(failed.errorDescription != nil)

        let absent = AppLaunchScenarioLoader.resolve(environment: [:])

        #expect(!absent.isScenarioMode)
        #expect(absent.loader == nil)
        #expect(absent.scenario == nil)
        #expect(absent.errorDescription == nil)
    }

    @Test("loader rejects unsupported pending interaction kind")
    func loaderRejectsUnsupportedPendingInteractionKind() throws {
        let scenario = AppLaunchScenario(
            schemaVersion: AppLaunchScenario.currentVersion,
            fixtureName: "invalid-kind",
            description: "invalid kind",
            seed: AppLaunchScenario.Seed(
                sessions: [],
                historyEntries: [],
                selectedSessionId: nil,
                onboardingState: OnboardingFixture(type: "Connected", detail: nil),
                pendingInteraction: PendingInteractionFixture(
                    id: "req-1",
                    kind: "unsupported",
                    sessionId: "sess-1",
                    toolName: "Bash",
                    toolInput: .object(["command": .string("pwd")]),
                    message: "Unsupported",
                    requestedSchema: nil,
                    permissionSuggestions: nil
                ),
                todayStats: nil,
                overlay: .init(initialIntent: .collapsed)
            ),
            expected: nil
        )

        let scenarioURL = try writeScenario(scenario)
        let loader = AppLaunchScenarioLoader(filePath: scenarioURL.path)

        #expect(throws: AppLaunchScenarioError.invalidPendingInteractionKind("unsupported")) {
            try loader.load()
        }
    }

    @Test("loader rejects unsupported onboarding state")
    func loaderRejectsUnsupportedOnboardingState() throws {
        let scenario = AppLaunchScenario(
            schemaVersion: AppLaunchScenario.currentVersion,
            fixtureName: "invalid-onboarding",
            description: "invalid onboarding state",
            seed: AppLaunchScenario.Seed(
                sessions: [],
                historyEntries: [],
                selectedSessionId: nil,
                onboardingState: OnboardingFixture(type: "MysteryState", detail: nil),
                pendingInteraction: nil,
                todayStats: nil,
                overlay: .init(initialIntent: .collapsed)
            ),
            expected: nil
        )

        let scenarioURL = try writeScenario(scenario)
        let loader = AppLaunchScenarioLoader(filePath: scenarioURL.path)

        #expect(throws: AppLaunchScenarioError.unsupportedOnboardingState("MysteryState")) {
            try loader.load()
        }
    }

    private func writeScenario(_ scenario: AppLaunchScenario) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("scenario.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(scenario).write(to: url)
        return url
    }

    @MainActor
    private func makeFixture() -> (sessionStore: SessionStore, historyStore: HistoryStore, viewModel: AppViewModel) {
        let sessionStore = SessionStore()
        let historyStore = HistoryStore(filePath: tempFilePath(prefix: "scenario-history"))
        let router = HookRouter(
            sessionStore: sessionStore,
            historyStore: historyStore,
            todayStats: TodayTokenStats(),
            debugLogger: HookDebugLogger(filePath: tempFilePath(prefix: "scenario-debug")),
            todayStatsFilePath: tempFilePath(prefix: "scenario-stats")
        )
        let viewModel = AppViewModel(
            sessionStore: sessionStore,
            historyStore: historyStore,
            hookRouter: router,
            onboardingManager: nil
        )
        return (sessionStore, historyStore, viewModel)
    }

    private func tempFilePath(prefix: String) -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
            .path
    }
}
