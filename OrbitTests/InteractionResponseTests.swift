import Foundation
@testable import Orbit
import Testing

@Suite("Interaction Response Tests")
struct InteractionResponseTests {
    @Test("interactionRequestId 优先使用 elicitationId")
    func interactionRequestIdUsesElicitationIdFirst() {
        let payload = HookPayload(
            sessionId: "sess-1",
            hookEventName: "Elicitation",
            toolUseId: "tool-999",
            elicitationId: "el-123"
        )

        #expect(interactionRequestId(payload: payload) == "sess-1-el-123")
    }

    @Test("interactionRequestId 回退使用 toolUseId")
    func interactionRequestIdFallsBackToToolUseId() {
        let payload = HookPayload(
            sessionId: "sess-2",
            hookEventName: "PermissionRequest",
            toolUseId: "tool-123"
        )

        #expect(interactionRequestId(payload: payload) == "sess-2-tool-123")
    }

    @Test("interactionRequestId 最后回退到时间戳")
    func interactionRequestIdFallsBackToTimestamp() {
        let payload = HookPayload(sessionId: "sess-3", hookEventName: "PermissionRequest")
        let requestId = interactionRequestId(payload: payload)

        let prefix = "sess-3-interaction-"
        #expect(requestId.hasPrefix(prefix))
        let tsPart = String(requestId.dropFirst(prefix.count))
        #expect(Int(tsPart) != nil)
    }

    @Test("PermissionRequest allow 返回 behavior=allow")
    func permissionAllowBuildsExpectedResponse() {
        let payload = HookPayload(sessionId: "sess-a", hookEventName: "PermissionRequest")
        let response = buildInteractionResponse(payload: payload, decision: .init(decision: "allow"))

        let hookOutput = response?["hookSpecificOutput"] as? [String: Any]
        let decision = hookOutput?["decision"] as? [String: Any]
        #expect(hookOutput?["hookEventName"] as? String == "PermissionRequest")
        #expect(decision?["behavior"] as? String == "allow")
    }

    @Test("PermissionRequest deny 返回 behavior=deny")
    func permissionDenyBuildsExpectedResponse() {
        let payload = HookPayload(sessionId: "sess-b", hookEventName: "PermissionRequest")
        let response = buildInteractionResponse(payload: payload, decision: .init(decision: "deny"))

        let hookOutput = response?["hookSpecificOutput"] as? [String: Any]
        let decision = hookOutput?["decision"] as? [String: Any]
        #expect(hookOutput?["hookEventName"] as? String == "PermissionRequest")
        #expect(decision?["behavior"] as? String == "deny")
    }

    @Test("PermissionRequest allow 可携带 updatedPermissions")
    func permissionAllowBuildsUpdatedPermissions() {
        let payload = HookPayload(sessionId: "sess-b2", hookEventName: "PermissionRequest")
        let response = buildInteractionResponse(
            payload: payload,
            decision: .init(
                decision: "allow",
                updatedPermissions: [
                    PermissionUpdateEntry(
                        type: "addRules",
                        rules: [PermissionRule(toolName: "Bash", ruleContent: "git status")],
                        behavior: "allow",
                        destination: "localSettings"
                    ),
                ]
            )
        )

        let hookOutput = response?["hookSpecificOutput"] as? [String: Any]
        let decision = hookOutput?["decision"] as? [String: Any]
        let updatedPermissions = decision?["updatedPermissions"] as? [[String: Any]]
        let first = updatedPermissions?.first
        let rules = first?["rules"] as? [[String: Any]]

        #expect(decision?["behavior"] as? String == "allow")
        #expect(first?["type"] as? String == "addRules")
        #expect(first?["behavior"] as? String == "allow")
        #expect(first?["destination"] as? String == "localSettings")
        #expect(rules?.first?["toolName"] as? String == "Bash")
        #expect(rules?.first?["ruleContent"] as? String == "git status")
    }

    @Test("PermissionRequest passthrough 返回 nil")
    func permissionPassthroughReturnsNil() {
        let payload = HookPayload(sessionId: "sess-c", hookEventName: "PermissionRequest")
        let response = buildInteractionResponse(payload: payload, decision: .init(decision: "passthrough"))
        #expect(response == nil)
    }

    @Test("PermissionRequest ask 归一化为 passthrough")
    func permissionAskReturnsNil() {
        let payload = HookPayload(sessionId: "sess-d", hookEventName: "PermissionRequest")
        let response = buildInteractionResponse(payload: payload, decision: .init(decision: "ask"))
        #expect(response == nil)
    }

    @Test("AskUserQuestion allow 且带 answers 时注入 updatedInput")
    func askUserQuestionInjectsUpdatedInputAnswers() {
        let payload = HookPayload(
            sessionId: "sess-e",
            hookEventName: "PermissionRequest",
            toolName: "AskUserQuestion",
            toolInput: .object([
                "question": .string("pick"),
                "choices": .array([.string("a"), .string("b")]),
            ])
        )
        let decision = PermissionDecision(
            decision: "allow",
            content: .object([
                "answers": .array([.string("a")]),
            ])
        )

        let response = buildInteractionResponse(payload: payload, decision: decision)
        let hookOutput = response?["hookSpecificOutput"] as? [String: Any]
        let decisionObject = hookOutput?["decision"] as? [String: Any]
        let updatedInput = decisionObject?["updatedInput"] as? [String: Any]

        #expect(decisionObject?["behavior"] as? String == "allow")
        #expect(updatedInput?["question"] as? String == "pick")
        #expect(updatedInput?["answers"] as? [String] == ["a"])
    }

    @Test("AskUserQuestion allow 且带 responses 时注入 structured responses")
    func askUserQuestionInjectsStructuredResponses() {
        let payload = HookPayload(
            sessionId: "sess-e2",
            hookEventName: "PermissionRequest",
            toolName: "AskUserQuestion",
            toolInput: .object([
                "questions": .array([
                    .object([
                        "id": .string("q1"),
                        "question": .string("pick one"),
                    ]),
                    .object([
                        "id": .string("q2"),
                        "question": .string("pick many"),
                    ]),
                ]),
            ])
        )
        let decision = PermissionDecision(
            decision: "allow",
            content: .object([
                "responses": .array([
                    .object([
                        "id": .string("q1"),
                        "answers": .array([.string("a")]),
                    ]),
                    .object([
                        "id": .string("q2"),
                        "answers": .array([.string("b"), .string("c")]),
                    ]),
                ]),
            ])
        )

        let response = buildInteractionResponse(payload: payload, decision: decision)
        let hookOutput = response?["hookSpecificOutput"] as? [String: Any]
        let decisionObject = hookOutput?["decision"] as? [String: Any]
        let updatedInput = decisionObject?["updatedInput"] as? [String: Any]
        let responses = updatedInput?["responses"] as? [[String: Any]]

        #expect(decisionObject?["behavior"] as? String == "allow")
        #expect(responses?.count == 2)
        #expect(responses?.first?["id"] as? String == "q1")
        #expect(responses?.first?["answers"] as? [String] == ["a"])
        #expect(responses?.last?["id"] as? String == "q2")
        #expect(responses?.last?["answers"] as? [String] == ["b", "c"])
    }

    @Test("Elicitation accept 带 content")
    func elicitationAcceptWithContent() {
        let payload = HookPayload(sessionId: "sess-f", hookEventName: "Elicitation")
        let decision = PermissionDecision(
            decision: "accept",
            content: .object([
                "value": .string("ok"),
                "count": .int(1),
            ])
        )

        let response = buildInteractionResponse(payload: payload, decision: decision)
        let hookOutput = response?["hookSpecificOutput"] as? [String: Any]
        let content = hookOutput?["content"] as? [String: Any]

        #expect(hookOutput?["hookEventName"] as? String == "Elicitation")
        #expect(hookOutput?["action"] as? String == "accept")
        #expect(content?["value"] as? String == "ok")
        #expect(content?["count"] as? Int == 1)
    }

    @Test("Elicitation decline")
    func elicitationDecline() {
        let payload = HookPayload(sessionId: "sess-g", hookEventName: "Elicitation")
        let response = buildInteractionResponse(payload: payload, decision: .init(decision: "decline"))
        let hookOutput = response?["hookSpecificOutput"] as? [String: Any]

        #expect(hookOutput?["action"] as? String == "decline")
    }

    @Test("Elicitation cancel")
    func elicitationCancel() {
        let payload = HookPayload(sessionId: "sess-h", hookEventName: "Elicitation")
        let response = buildInteractionResponse(payload: payload, decision: .init(decision: "cancel"))
        let hookOutput = response?["hookSpecificOutput"] as? [String: Any]

        #expect(hookOutput?["action"] as? String == "cancel")
    }

    @Test("Elicitation 响应使用真实 eventName")
    func elicitationUsesOriginalEventName() {
        let payload = HookPayload(sessionId: "sess-i", hookEventName: "ElicitationResult")
        let response = buildInteractionResponse(payload: payload, decision: .init(decision: "decline"))
        let hookOutput = response?["hookSpecificOutput"] as? [String: Any]

        #expect(hookOutput?["hookEventName"] as? String == "ElicitationResult")
    }

    @Test("buildInteractionResponse 按事件分发")
    func buildInteractionResponseDispatchesByEventName() {
        let permissionPayload = HookPayload(sessionId: "sess-j", hookEventName: "PermissionRequest")
        let permissionResponse = buildInteractionResponse(payload: permissionPayload, decision: .init(decision: "allow"))
        let permissionDecision = (permissionResponse?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]

        let elicitationPayload = HookPayload(sessionId: "sess-j", hookEventName: "Elicitation")
        let elicitationResponse = buildInteractionResponse(payload: elicitationPayload, decision: .init(decision: "decline"))
        let elicitationAction = (elicitationResponse?["hookSpecificOutput"] as? [String: Any])?["action"] as? String

        #expect(permissionDecision?["behavior"] as? String == "allow")
        #expect(elicitationAction == "decline")
    }

    @Test("非 Permission/Elicitation 事件返回 nil")
    func nonSupportedEventReturnsNil() {
        let payload = HookPayload(sessionId: "sess-k", hookEventName: "SessionStart")
        let response = buildInteractionResponse(payload: payload, decision: .init(decision: "allow"))
        #expect(response == nil)
    }
}
