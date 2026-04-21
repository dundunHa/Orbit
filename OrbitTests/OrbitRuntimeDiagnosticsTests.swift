import Foundation
import Testing
@testable import Orbit

@Suite("OrbitRuntimeDiagnostics")
struct OrbitRuntimeDiagnosticsTests {
    @Test("capture summarizes current view model state")
    @MainActor
    func captureSummarizesViewModelState() {
        let viewModel = makeFixture()

        viewModel.applyTestingSnapshot(
            sessions: [
                Session(
                    id: "sess-1",
                    cwd: "/tmp/project",
                    status: .processing,
                    startedAt: Date(timeIntervalSince1970: 1_710_000_000),
                    lastEventAt: Date(timeIntervalSince1970: 1_710_000_030)
                )
            ],
            historyEntries: [
                HistoryEntry(
                    sessionId: "hist-1",
                    cwd: "/tmp/project",
                    startedAt: Date(timeIntervalSince1970: 1_709_999_000),
                    endedAt: Date(timeIntervalSince1970: 1_709_999_090),
                    toolCount: 1,
                    durationSecs: 90,
                    title: "History"
                )
            ],
            selectedSessionId: "sess-1",
            onboardingState: .driftDetected,
            pendingInteraction: PendingInteraction(
                id: "req-1",
                kind: "permission",
                sessionId: "sess-1",
                toolName: "Bash",
                toolInput: .object(["command": .string("ls")]),
                message: "Allow command?",
                requestedSchema: nil
            ),
            todayStats: TodayTokenStats(tokensIn: 12, tokensOut: 24)
        )

        let diagnostics = OrbitRuntimeDiagnostics.capture(
            viewModel: viewModel,
            overlayController: nil,
            revision: 3,
            scenario: OrbitRuntimeDiagnostics.ScenarioSummary(
                fixtureName: "pending-permission",
                schemaVersion: AppLaunchScenario.currentVersion,
                loadState: "loaded",
                error: nil
            ),
            lastDecision: OrbitRuntimeDiagnostics.DecisionSummary(
                requestId: "req-1",
                decision: "allow",
                reason: "approved in test",
                timestamp: Date(timeIntervalSince1970: 1_710_000_040)
            )
        )

        #expect(diagnostics.version == OrbitRuntimeDiagnostics.currentVersion)
        #expect(diagnostics.revision == 3)
        #expect(diagnostics.scenario?.fixtureName == "pending-permission")
        #expect(diagnostics.pendingInteraction?.id == "req-1")
        #expect(diagnostics.pendingQueueDepth == 1)
        #expect(diagnostics.counts.sessions == 1)
        #expect(diagnostics.counts.historyEntries == 1)
        #expect(diagnostics.selectedSessionId == "sess-1")
        #expect(diagnostics.activeSessionId == "sess-1")
        #expect(diagnostics.onboarding.typeName == "DriftDetected")
        #expect(diagnostics.lastDecision?.decision == "allow")
    }

    @Test("writer persists diagnostics JSON")
    @MainActor
    func writerPersistsDiagnosticsJSON() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("diagnostics.json")

        let writer = OrbitRuntimeDiagnosticsWriter(filePath: fileURL.path)
        let diagnostics = OrbitRuntimeDiagnostics(
            version: OrbitRuntimeDiagnostics.currentVersion,
            revision: 1,
            updatedAt: Date(timeIntervalSince1970: 1_710_000_000),
            scenario: OrbitRuntimeDiagnostics.ScenarioSummary(
                fixtureName: "idle",
                schemaVersion: AppLaunchScenario.currentVersion,
                loadState: "loaded",
                error: nil
            ),
            overlay: nil,
            counts: OrbitRuntimeDiagnostics.CountsSummary(sessions: 0, historyEntries: 0),
            pendingInteraction: nil,
            pendingQueueDepth: 0,
            selectedSessionId: nil,
            activeSessionId: nil,
            onboarding: makeOnboardingSummary(),
            lastDecision: nil
        )

        let didWrite = await writer.submit(diagnostics)

        #expect(didWrite)
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder.withISO8601.decode(OrbitRuntimeDiagnostics.self, from: data)
        #expect(decoded.version == diagnostics.version)
        #expect(decoded.revision == diagnostics.revision)
        #expect(decoded.scenario == diagnostics.scenario)
        #expect(decoded.counts == diagnostics.counts)
        #expect(decoded.onboarding == diagnostics.onboarding)
    }

    @Test("writer ignores stale submissions once a newer revision has landed")
    @MainActor
    func writerIgnoresStaleSubmissions() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("diagnostics.json")

        let writer = OrbitRuntimeDiagnosticsWriter(filePath: fileURL.path)
        let newer = makeDiagnostics(revision: 2, fixtureName: "newer")
        let older = makeDiagnostics(revision: 1, fixtureName: "older")

        #expect(await writer.submit(newer))
        #expect(!(await writer.submit(older)))

        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder.withISO8601.decode(OrbitRuntimeDiagnostics.self, from: data)
        #expect(decoded.revision == 2)
        #expect(decoded.scenario?.fixtureName == "newer")
    }

    @Test("writer is a safe no-op when diagnostics are disabled")
    func writerNoOpsWhenDisabled() async {
        let writer = OrbitRuntimeDiagnosticsWriter(filePath: nil)

        #expect(!(await writer.submit(makeDiagnostics(revision: 1, fixtureName: "disabled"))))
    }

    @Test("writer recovers after a temporary write failure")
    func writerRecoversAfterTemporaryWriteFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("diagnostics.json")
        let writer = OrbitRuntimeDiagnosticsWriter(filePath: fileURL.path)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        let failed = await writer.submit(makeDiagnostics(revision: 1, fixtureName: "failed"))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let recovered = await writer.submit(makeDiagnostics(revision: 2, fixtureName: "recovered"))

        #expect(!failed)
        #expect(recovered)

        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder.withISO8601.decode(OrbitRuntimeDiagnostics.self, from: data)
        #expect(decoded.revision == 2)
        #expect(decoded.scenario?.fixtureName == "recovered")
    }

    @MainActor
    private func makeFixture() -> AppViewModel {
        let sessionStore = SessionStore()
        let historyStore = HistoryStore(filePath: tempFilePath(prefix: "runtime-history"))
        let router = HookRouter(
            sessionStore: sessionStore,
            historyStore: historyStore,
            todayStats: TodayTokenStats(),
            debugLogger: HookDebugLogger(filePath: tempFilePath(prefix: "runtime-debug")),
            todayStatsFilePath: tempFilePath(prefix: "runtime-stats")
        )
        let viewModel = AppViewModel(
            sessionStore: sessionStore,
            historyStore: historyStore,
            hookRouter: router,
            onboardingManager: nil
        )
        return viewModel
    }

    private func tempFilePath(prefix: String) -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
            .path
    }

    private func makeDiagnostics(revision: Int, fixtureName: String) -> OrbitRuntimeDiagnostics {
        OrbitRuntimeDiagnostics(
            version: OrbitRuntimeDiagnostics.currentVersion,
            revision: revision,
            updatedAt: Date(timeIntervalSince1970: 1_710_000_000 + Double(revision)),
            scenario: OrbitRuntimeDiagnostics.ScenarioSummary(
                fixtureName: fixtureName,
                schemaVersion: AppLaunchScenario.currentVersion,
                loadState: "loaded",
                error: nil
            ),
            overlay: nil,
            counts: OrbitRuntimeDiagnostics.CountsSummary(sessions: revision, historyEntries: 0),
            pendingInteraction: nil,
            pendingQueueDepth: 0,
            selectedSessionId: nil,
            activeSessionId: nil,
            onboarding: makeOnboardingSummary(),
            lastDecision: nil
        )
    }

    private func makeOnboardingSummary() -> OrbitRuntimeDiagnostics.OnboardingSummary {
        OrbitRuntimeDiagnostics.OnboardingSummary(
            typeName: "Welcome",
            statusText: "Welcome to Orbit! Click Start to begin setup.",
            trayStatus: "connecting",
            trayEmoji: "🟡",
            needsAttention: false,
            isComplete: false,
            canRetry: false
        )
    }
}

private extension JSONDecoder {
    static var withISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
