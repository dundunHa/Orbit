import Foundation
import Testing
@testable import Orbit

@Suite("Model Tests")
struct ModelTests {
    @Test("SessionStatus waitingForInput round-trips")
    func sessionStatusWaitingForInputRoundTrips() throws {
        try assertSessionStatusRoundTrips(.waitingForInput)
    }

    @Test("SessionStatus processing round-trips")
    func sessionStatusProcessingRoundTrips() throws {
        try assertSessionStatusRoundTrips(.processing)
    }

    @Test("SessionStatus runningTool round-trips")
    func sessionStatusRunningToolRoundTrips() throws {
        try assertSessionStatusRoundTrips(.runningTool(toolName: "Bash", description: "Run shell"))
    }

    @Test("SessionStatus waitingForApproval round-trips")
    func sessionStatusWaitingForApprovalRoundTrips() throws {
        try assertSessionStatusRoundTrips(.waitingForApproval(toolName: "Bash", toolInput: .object(["command": .string("ls")])) )
    }

    @Test("SessionStatus anomaly round-trips")
    func sessionStatusAnomalyRoundTrips() throws {
        try assertSessionStatusRoundTrips(.anomaly(idleSeconds: 42, previousStatus: .processing))
    }

    @Test("SessionStatus encoded JSON includes discriminator")
    func sessionStatusHasTypeDiscriminator() throws {
        let data = try JSONEncoder().encode(SessionStatus.compacting)
        let object = try jsonObject(from: data)
        #expect(object["type"] as? String == "Compacting")
    }

    @Test("HookPayload decodes snake_case JSON")
    func hookPayloadDecodesSnakeCase() throws {
        let payload = try JSONDecoder().decode(HookPayload.self, from: snakeCaseHookPayloadJSON())
        #expect(payload.sessionId == "sess-1")
        #expect(payload.hookEventName == "PreToolUse")
        #expect(payload.cwd == "/tmp")
        #expect(payload.toolName == "Bash")
        #expect(payload.toolInput == .object(["command": .string("ls")]))
        #expect(payload.toolUseId == "tool-1")
        #expect(payload.mcpServerName == "mcp")
        #expect(payload.notificationType == "info")
        #expect(payload.message == "hello")
        #expect(payload.mode == "default")
        #expect(payload.url == "https://example.com")
        #expect(payload.elicitationId == "el-1")
        #expect(payload.requestedSchema == .object(["type": .string("object")]))
        #expect(payload.action == "accept")
        #expect(payload.content == .object(["nested": .array([.int(1), .bool(true)])]))
        #expect(payload.pid == 123)
        #expect(payload.tty == "ttys001")
        #expect(payload.status == "running")
    }

    @Test("HookPayload decodes camelCase JSON")
    func hookPayloadDecodesCamelCase() throws {
        let payload = try JSONDecoder().decode(HookPayload.self, from: camelCaseHookPayloadJSON())
        #expect(payload.sessionId == "sess-2")
        #expect(payload.hookEventName == "SessionEnd")
        #expect(payload.toolName == "Edit")
        #expect(payload.toolInput == .object(["path": .string("README.md")]))
        #expect(payload.toolUseId == "tool-2")
        #expect(payload.requestedSchema == .object(["type": .string("string")]))
        #expect(payload.content == .string("done"))
    }

    @Test("normalizeTitle returns nil for empty strings")
    func normalizeTitleEmptyReturnsNil() {
        #expect(normalizeTitle("") == nil)
        #expect(normalizeTitle("   ") == nil)
    }

    @Test("normalizeTitle returns nil for bare slash commands")
    func normalizeTitleBareSlashReturnsNil() {
        #expect(normalizeTitle("/clear") == nil)
        #expect(isBareSlashCommand("/clear"))
    }

    @Test("normalizeTitle keeps commands with arguments")
    func normalizeTitleKeepsCommandWithArgs() {
        #expect(normalizeTitle("/clear with args") == "/clear with args")
        #expect(isBareSlashCommand("/clear with args") == false)
    }

    @Test("normalizeTitle truncates to forty characters")
    func normalizeTitleTruncatesToFortyCharacters() {
        let raw = String(repeating: "a", count: 50)
        #expect(normalizeTitle(raw)?.count == 40)
    }

    @Test("PermissionDecision normalizes ask to passthrough")
    func permissionDecisionAskNormalizesToPassthrough() {
        let decision = PermissionDecision(decision: "ask", reason: nil, content: nil)
        #expect(decision.normalizedDecision() == "passthrough")
    }

    @Test("PermissionDecision preserves allow")
    func permissionDecisionPassesAllowThrough() {
        let decision = PermissionDecision(decision: "allow", reason: "ok", content: .string("x"))
        #expect(decision.normalizedDecision() == "allow")
    }

    @Test("Session decodes defaults for missing counters")
    func sessionDefaultsToZeroValues() throws {
        let session = try JSONDecoder().decode(Session.self, from: sessionDefaultsJSON())
        #expect(session.hasSpawnedSubagent == false)
        #expect(session.toolCount == 0)
        #expect(session.tokensIn == 0)
        #expect(session.tokensOut == 0)
        #expect(session.costUsd == 0)
    }

    @Test("StatuslineUpdate decodes defaults")
    func statuslineUpdateDecodesDefaults() throws {
        let update = try JSONDecoder().decode(StatuslineUpdate.self, from: statuslineUpdateJSON())
        #expect(update.sessionId == "sess-3")
        #expect(update.tokensIn == 10)
        #expect(update.tokensOut == 20)
        #expect(update.costUsd == 0)
        #expect(update.model == nil)
    }

    private func assertSessionStatusRoundTrips(_ status: SessionStatus) throws {
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(SessionStatus.self, from: data)
        #expect(decoded == status)
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    private func snakeCaseHookPayloadJSON() -> Data {
        Data(#"""
        {
          "session_id": "sess-1",
          "hook_event_name": "PreToolUse",
          "cwd": "/tmp",
          "tool_name": "Bash",
          "tool_input": {"command": "ls"},
          "tool_use_id": "tool-1",
          "tool_response": {"ok": true},
          "mcp_server_name": "mcp",
          "notification_type": "info",
          "message": "hello",
          "mode": "default",
          "url": "https://example.com",
          "elicitation_id": "el-1",
          "requested_schema": {"type": "object"},
          "action": "accept",
          "content": {"nested": [1, true]},
          "pid": 123,
          "tty": "ttys001",
          "status": "running"
        }
        """#.utf8)
    }

    private func camelCaseHookPayloadJSON() -> Data {
        Data(#"""
        {
          "sessionId": "sess-2",
          "hookEventName": "SessionEnd",
          "toolName": "Edit",
          "toolInput": {"path": "README.md"},
          "toolUseId": "tool-2",
          "requestedSchema": {"type": "string"},
          "content": "done"
        }
        """#.utf8)
    }

    private func sessionDefaultsJSON() -> Data {
        Data(#"""
        {
          "id": "sess-4",
          "cwd": "/tmp",
          "status": {"type": "WaitingForInput"},
          "started_at": "2026-04-13T00:00:00Z",
          "last_event_at": "2026-04-13T00:00:00Z"
        }
        """#.utf8)
    }

    private func statuslineUpdateJSON() -> Data {
        Data(#"""
        {
          "session_id": "sess-3",
          "tokens_in": 10,
          "tokens_out": 20
        }
        """#.utf8)
    }
}
