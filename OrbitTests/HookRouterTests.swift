import Dispatch
import Foundation
import Testing
@testable import Orbit

@Suite("HookRouter")
struct HookRouterTests {
    @Test("full session lifecycle routes state and saves history")
    func fullSessionLifecycleRoutesStateAndSavesHistory() async throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_000))
        let fixture = makeFixture(clock: clock)
        let sessionId = "session-lifecycle"

        _ = await fixture.router.routeHookEvent(
            makePayload(sessionId: sessionId, hookEventName: "SessionStart", cwd: "/tmp/workspace")
        )
        var session = try await requireSession(fixture.sessionStore, id: sessionId)
        #expect(session.status == .waitingForInput)

        clock.advance(by: 1)
        _ = await fixture.router.routeHookEvent(
            makePayload(
                sessionId: sessionId,
                hookEventName: "UserPromptSubmit",
                cwd: "/tmp/workspace",
                message: "Build native Orbit app"
            )
        )
        session = try await requireSession(fixture.sessionStore, id: sessionId)
        #expect(session.status == .processing)
        #expect(session.title == "Build native Orbit app")
        #expect(session.titleSource == .userPrompt)

        clock.advance(by: 1)
        _ = await fixture.router.routeHookEvent(
            makePayload(
                sessionId: sessionId,
                hookEventName: "PreToolUse",
                cwd: "/tmp/workspace",
                toolName: "Bash",
                toolInput: .object(["command": .string("ls -la")])
            )
        )
        session = try await requireSession(fixture.sessionStore, id: sessionId)
        #expect(session.status == .runningTool(toolName: "Bash", description: "ls -la"))
        #expect(session.toolCount == 1)

        clock.advance(by: 1)
        _ = await fixture.router.routeHookEvent(
            makePayload(sessionId: sessionId, hookEventName: "PostToolUse", cwd: "/tmp/workspace")
        )
        session = try await requireSession(fixture.sessionStore, id: sessionId)
        #expect(session.status == .processing)

        clock.advance(by: 1)
        _ = await fixture.router.routeHookEvent(
            makePayload(sessionId: sessionId, hookEventName: "Stop", cwd: "/tmp/workspace")
        )
        session = try await requireSession(fixture.sessionStore, id: sessionId)
        #expect(session.status == .waitingForInput)

        clock.advance(by: 1)
        _ = await fixture.router.routeHookEvent(
            makePayload(sessionId: sessionId, hookEventName: "SessionEnd", cwd: "/tmp/workspace")
        )
        session = try await requireSession(fixture.sessionStore, id: sessionId)
        #expect(session.status == .ended)

        let historyEntries = await fixture.historyStore.loadAll()
        #expect(historyEntries.count == 1)
        #expect(historyEntries[0].sessionId == sessionId)
        #expect(historyEntries[0].title == "Build native Orbit app")
    }

    @Test("parent Task spawn matches child session within 10 seconds")
    func parentTaskSpawnMatchesChildSessionWithinTenSeconds() async throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 2_000))
        let fixture = makeFixture(clock: clock)

        _ = await fixture.router.routeHookEvent(
            makePayload(sessionId: "parent", hookEventName: "PreToolUse", cwd: "/repo", toolName: "Task")
        )

        clock.advance(by: 5)
        _ = await fixture.router.routeHookEvent(
            makePayload(sessionId: "child", hookEventName: "SessionStart", cwd: "/repo")
        )

        let child = try await requireSession(fixture.sessionStore, id: "child")
        #expect(child.parentSessionId == "parent")
    }

    @Test("pending spawn older than 30 seconds is cleaned")
    func pendingSpawnOlderThanThirtySecondsIsCleaned() async throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 3_000))
        let fixture = makeFixture(clock: clock)

        _ = await fixture.router.routeHookEvent(
            makePayload(sessionId: "old-parent", hookEventName: "PreToolUse", cwd: "/repo", toolName: "Task")
        )

        #if DEBUG
        #expect(await fixture.router.pendingSpawnCountForTesting() == 1)
        #endif

        clock.advance(by: 31)
        _ = await fixture.router.routeHookEvent(
            makePayload(sessionId: "new-child", hookEventName: "SessionStart", cwd: "/repo")
        )

        let child = try await requireSession(fixture.sessionStore, id: "new-child")
        #expect(child.parentSessionId == nil)

        #if DEBUG
        #expect(await fixture.router.pendingSpawnCountForTesting() == 0)
        #endif
    }

    @Test("permission request awaits and resolves by request id")
    func permissionRequestAwaitsAndResolvesByRequestId() async throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 4_000))
        let fixture = makeFixture(clock: clock)

        let result = await fixture.router.routeHookEvent(
            makePayload(
                sessionId: "perm-session",
                hookEventName: "PermissionRequest",
                cwd: "/repo",
                toolName: "Bash",
                toolUseId: "perm-1"
            )
        )
        #expect(result == .awaitPermissionDecision(requestId: "perm-1"))

        let waitTask = Task { await fixture.router.awaitPermissionDecision(requestId: "perm-1") }
        try await Task.sleep(nanoseconds: 20_000_000)

        await fixture.router.resolvePermission(
            requestId: "perm-1",
            decision: PermissionDecision(decision: "allow", reason: "approved")
        )

        let decision = await waitTask.value
        #expect(decision == PermissionDecision(decision: "allow", reason: "approved"))
    }

    @Test("elicitation routes to waitingForApproval with elicitation input")
    func elicitationRoutesToWaitingForApprovalWithElicitationInput() async throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 5_000))
        let fixture = makeFixture(clock: clock)

        let result = await fixture.router.routeHookEvent(
            makePayload(
                sessionId: "eli-session",
                hookEventName: "Elicitation",
                cwd: "/repo",
                message: "Need confirmation",
                elicitationId: "eli-1",
                mcpServerName: "notion",
                action: "prompt",
                content: .object(["field": .string("value")]),
                requestedSchema: .object(["type": .string("object")])
            )
        )

        #expect(result == .awaitPermissionDecision(requestId: "eli-1"))

        let session = try await requireSession(fixture.sessionStore, id: "eli-session")
        #expect(
            session.status == .waitingForApproval(
                toolName: "notion",
                toolInput: .object([
                    "requested_schema": .object(["type": .string("object")]),
                    "message": .string("Need confirmation"),
                    "action": .string("prompt"),
                    "content": .object(["field": .string("value")]),
                ])
            )
        )
    }

    @Test("statusline update writes tokens cost and model")
    func statuslineUpdateWritesTokensCostAndModel() async throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 6_000))
        let fixture = makeFixture(clock: clock)
        let sessionId = "statusline-session"

        _ = await fixture.router.routeHookEvent(
            makePayload(sessionId: sessionId, hookEventName: "UserPromptSubmit", cwd: "/repo", message: "hi")
        )

        await fixture.router.routeStatuslineUpdate(
            StatuslineUpdate(
                sessionId: sessionId,
                tokensIn: 120,
                tokensOut: 45,
                costUsd: 0.12,
                model: "claude-sonnet"
            )
        )

        let session = try await requireSession(fixture.sessionStore, id: sessionId)
        #expect(session.tokensIn == 120)
        #expect(session.tokensOut == 45)
        #expect(session.costUsd == 0.12)
        #expect(session.model == "claude-sonnet")
        #expect(session.status == .processing)
    }

    @Test("user prompt message sets session title")
    func userPromptMessageSetsSessionTitle() async throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 7_000))
        let fixture = makeFixture(clock: clock)

        _ = await fixture.router.routeHookEvent(
            makePayload(
                sessionId: "title-session",
                hookEventName: "UserPromptSubmit",
                cwd: "/repo",
                message: "Implement compact mode with idle monitoring"
            )
        )

        let session = try await requireSession(fixture.sessionStore, id: "title-session")
        #expect(session.title == "Implement compact mode with idle monitor")
        #expect(session.titleSource == .userPrompt)
    }

    @Test("PreCompact event switches status to compacting")
    func preCompactEventSwitchesStatusToCompacting() async throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 8_000))
        let fixture = makeFixture(clock: clock)

        _ = await fixture.router.routeHookEvent(
            makePayload(sessionId: "compact-session", hookEventName: "PreCompact", cwd: "/repo")
        )

        let session = try await requireSession(fixture.sessionStore, id: "compact-session")
        #expect(session.status == .compacting)
    }

    @Test("Notification idle_prompt switches status to waitingForInput")
    func notificationIdlePromptSwitchesStatusToWaitingForInput() async throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 9_000))
        let fixture = makeFixture(clock: clock)
        let sessionId = "notification-session"

        _ = await fixture.router.routeHookEvent(
            makePayload(
                sessionId: sessionId,
                hookEventName: "PreToolUse",
                cwd: "/repo",
                toolName: "Bash",
                toolInput: .object(["command": .string("pwd")])
            )
        )

        _ = await fixture.router.routeHookEvent(
            makePayload(
                sessionId: sessionId,
                hookEventName: "Notification",
                cwd: "/repo",
                notificationType: "idle_prompt"
            )
        )

        let session = try await requireSession(fixture.sessionStore, id: sessionId)
        #expect(session.status == .waitingForInput)
    }

    @Test("resolvePermissionFromCli resolves pending toolUseId")
    func resolvePermissionFromCliResolvesPendingToolUseId() async throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 10_000))
        let fixture = makeFixture(clock: clock)

        _ = await fixture.router.routeHookEvent(
            makePayload(
                sessionId: "cli-direct",
                hookEventName: "PermissionRequest",
                cwd: "/repo",
                toolName: "Bash",
                toolUseId: "tool-42"
            )
        )

        let waitTask = Task { await fixture.router.awaitPermissionDecision(requestId: "tool-42") }
        try await Task.sleep(nanoseconds: 20_000_000)

        await fixture.router.resolvePermissionFromCli(sessionId: "cli-direct", toolUseId: "tool-42")

        let decision = await waitTask.value
        #expect(decision.decision == "allow")
        #expect(decision.reason == "approved via CLI")
    }

    @Test("resolvePermissionFromCli falls back to session-prefixed request")
    func resolvePermissionFromCliFallsBackToSessionPrefixedRequest() async throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 11_000))
        let fixture = makeFixture(clock: clock)

        let result = await fixture.router.routeHookEvent(
            makePayload(
                sessionId: "cli-fallback",
                hookEventName: "PermissionRequest",
                cwd: "/repo",
                toolName: "Edit"
            )
        )

        let requestId: String
        switch result {
        case .awaitPermissionDecision(let id):
            requestId = id
        case .noResponse:
            Issue.record("expected awaitPermissionDecision")
            return
        }

        let waitTask = Task { await fixture.router.awaitPermissionDecision(requestId: requestId) }
        try await Task.sleep(nanoseconds: 20_000_000)

        await fixture.router.resolvePermissionFromCli(sessionId: "cli-fallback", toolUseId: "not-exist")

        let decision = await waitTask.value
        #expect(decision.decision == "allow")
        #expect(decision.reason == "approved via CLI")
    }

    @Test("resolveInteractionFromCli maps elicitation result back to waiting request")
    func resolveInteractionFromCliMapsElicitationResultBackToWaitingRequest() async throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 11_500))
        let fixture = makeFixture(clock: clock)

        _ = await fixture.router.routeHookEvent(
            makePayload(
                sessionId: "cli-elicitation",
                hookEventName: "Elicitation",
                cwd: "/repo",
                message: "Need confirmation",
                elicitationId: "eli-42",
                mcpServerName: "notion"
            )
        )

        let waitTask = Task { await fixture.router.awaitPermissionDecision(requestId: "eli-42") }
        try await Task.sleep(nanoseconds: 20_000_000)

        let resolvedRequestId = await fixture.router.resolveInteractionFromCli(
            payload: makePayload(
                sessionId: "cli-elicitation",
                hookEventName: "ElicitationResult",
                cwd: "/repo",
                elicitationId: "eli-42",
                mcpServerName: "notion",
                action: "accept",
                content: .object(["answer": .string("yes")])
            )
        )

        let decision = await waitTask.value
        #expect(resolvedRequestId == "eli-42")
        #expect(decision.decision == "accept")
        #expect(decision.reason == "answered via CLI")
        #expect(decision.content == .object(["answer": .string("yes")]))
    }

    @Test("resolveInteractionFromCli matches permission request by tool fingerprint")
    func resolveInteractionFromCliMatchesPermissionRequestByToolFingerprint() async throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 11_800))
        let fixture = makeFixture(clock: clock)
        let toolInput: AnyCodable = .object(["command": .string("git status")])

        let result = await fixture.router.routeHookEvent(
            makePayload(
                sessionId: "cli-posttool",
                hookEventName: "PermissionRequest",
                cwd: "/repo",
                toolName: "Bash",
                toolInput: toolInput
            )
        )

        let requestId: String
        switch result {
        case .awaitPermissionDecision(let id):
            requestId = id
        case .noResponse:
            Issue.record("expected awaitPermissionDecision")
            return
        }

        let waitTask = Task { await fixture.router.awaitPermissionDecision(requestId: requestId) }
        try await Task.sleep(nanoseconds: 20_000_000)

        let resolvedRequestId = await fixture.router.resolveInteractionFromCli(
            payload: makePayload(
                sessionId: "cli-posttool",
                hookEventName: "PostToolUse",
                cwd: "/repo",
                toolName: "Bash",
                toolInput: toolInput,
                toolUseId: "tool-404"
            )
        )

        let decision = await waitTask.value
        #expect(resolvedRequestId == requestId)
        #expect(decision.decision == "allow")
        #expect(decision.reason == "approved via CLI")
    }

    @Test("anomaly status is not overwritten by non-mutating normal event")
    func anomalyStatusIsNotOverwrittenByNonMutatingNormalEvent() async throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 12_000))
        let fixture = makeFixture(clock: clock)
        let sessionId = "anomaly-session"

        _ = await fixture.sessionStore.upsertSession(sessionId) { session in
            session.id = sessionId
            session.cwd = "/repo"
            session.status = .anomaly(idleSeconds: 99, previousStatus: .processing)
            session.startedAt = clock.get()
            session.lastEventAt = clock.get()
        }

        _ = await fixture.router.routeHookEvent(
            makePayload(
                sessionId: sessionId,
                hookEventName: "Notification",
                cwd: "/repo",
                notificationType: "other"
            )
        )

        let session = try await requireSession(fixture.sessionStore, id: sessionId)
        #expect(session.status == .anomaly(idleSeconds: 99, previousStatus: .processing))
    }
}

private struct HookRouterFixture {
    let router: HookRouter
    let sessionStore: SessionStore
    let historyStore: HistoryStore
}

private func makeFixture(clock: MutableNow) -> HookRouterFixture {
    let sessionStore = SessionStore()
    let historyStore = HistoryStore(filePath: tempPath(fileName: "history"))
    let debugLogger = HookDebugLogger(filePath: tempPath(fileName: "hook-debug"))

    let router = HookRouter(
        sessionStore: sessionStore,
        historyStore: historyStore,
        todayStats: TodayTokenStats(),
        debugLogger: debugLogger,
        todayStatsFilePath: tempPath(fileName: "today-stats"),
        nowProvider: { clock.get() }
    )

    return HookRouterFixture(router: router, sessionStore: sessionStore, historyStore: historyStore)
}

private func makePayload(
    sessionId: String,
    hookEventName: String,
    cwd: String,
    message: String? = nil,
    toolName: String? = nil,
    toolInput: AnyCodable? = nil,
    toolUseId: String? = nil,
    elicitationId: String? = nil,
    mcpServerName: String? = nil,
    action: String? = nil,
    content: AnyCodable? = nil,
    requestedSchema: AnyCodable? = nil,
    notificationType: String? = nil
) -> HookPayload {
    HookPayload(
        sessionId: sessionId,
        hookEventName: hookEventName,
        cwd: cwd,
        toolName: toolName,
        toolInput: toolInput,
        toolUseId: toolUseId,
        toolResponse: nil,
        mcpServerName: mcpServerName,
        notificationType: notificationType,
        message: message,
        mode: nil,
        url: nil,
        elicitationId: elicitationId,
        requestedSchema: requestedSchema,
        action: action,
        content: content,
        pid: nil,
        tty: nil,
        status: nil
    )
}

private func requireSession(_ store: SessionStore, id: String) async throws -> Session {
    let session = await store.getSession(id)
    return try #require(session)
}

private func tempPath(fileName: String) -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("orbit-hook-router-tests")
        .appendingPathComponent("\(fileName)-\(UUID().uuidString).json")
        .path
}

private final class MutableNow: @unchecked Sendable {
    private let queue = DispatchQueue(label: "orbit.hook-router.tests.now")
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func get() -> Date {
        queue.sync { value }
    }

    func advance(by seconds: TimeInterval) {
        queue.sync {
            value = value.addingTimeInterval(seconds)
        }
    }
}
