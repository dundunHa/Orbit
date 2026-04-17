import Foundation

public func interactionRequestId(payload: HookPayload) -> String {
    if let eid = payload.elicitationId, !eid.isEmpty {
        return "\(payload.sessionId)-\(eid)"
    }
    if let tuid = payload.toolUseId, !tuid.isEmpty {
        return "\(payload.sessionId)-\(tuid)"
    }
    let ts = Int(Date().timeIntervalSince1970 * 1000)
    return "\(payload.sessionId)-interaction-\(ts)"
}

public func buildInteractionResponse(payload: HookPayload, decision: PermissionDecision) -> [String: Any]? {
    switch payload.hookEventName {
    case "PermissionRequest":
        return buildPermissionRequestResponse(decision: decision, toolName: payload.toolName, toolInput: payload.toolInput)
    case "Elicitation", "ElicitationResult":
        return buildElicitationResponse(eventName: payload.hookEventName, decision: decision)
    default:
        return nil
    }
}

func buildPermissionRequestResponse(decision: PermissionDecision, toolName: String?, toolInput: AnyCodable?) -> [String: Any]? {
    switch decision.normalizedDecision() {
    case "allow":
        var response: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow"],
            ],
        ]

        if toolName == "AskUserQuestion",
           let updatedInput = buildAskUserQuestionUpdatedInput(toolInput: toolInput, content: decision.content)
        {
            var hookOutput = response["hookSpecificOutput"] as! [String: Any]
            var decisionObject = hookOutput["decision"] as! [String: Any]
            decisionObject["updatedInput"] = updatedInput
            hookOutput["decision"] = decisionObject
            response["hookSpecificOutput"] = hookOutput
        }

        return response
    case "deny":
        return [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "deny"],
            ],
        ]
    case "passthrough":
        return nil
    default:
        return nil
    }
}

func buildElicitationResponse(eventName: String, decision: PermissionDecision) -> [String: Any]? {
    switch decision.normalizedDecision() {
    case "accept":
        let content: Any = decision.content.map(anyCodableToAny) ?? [String: Any]()
        return [
            "hookSpecificOutput": [
                "hookEventName": eventName,
                "action": "accept",
                "content": content,
            ],
        ]
    case "decline":
        return [
            "hookSpecificOutput": [
                "hookEventName": eventName,
                "action": "decline",
            ],
        ]
    case "cancel":
        return [
            "hookSpecificOutput": [
                "hookEventName": eventName,
                "action": "cancel",
            ],
        ]
    case "passthrough":
        return nil
    default:
        return nil
    }
}

func buildAskUserQuestionUpdatedInput(toolInput: AnyCodable?, content: AnyCodable?) -> [String: Any]? {
    guard let toolInputObject = toolInput.map(anyCodableToAny) as? [String: Any] else {
        return nil
    }
    guard let contentObject = content.map(anyCodableToAny) as? [String: Any],
          let answers = contentObject["answers"]
    else {
        return nil
    }
    var updated = toolInputObject
    updated["answers"] = answers
    return updated
}

public func serializeInteractionResponse(_ response: [String: Any]) -> Data? {
    guard JSONSerialization.isValidJSONObject(response) else {
        return nil
    }
    return try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
}

private func anyCodableToAny(_ value: AnyCodable) -> Any {
    switch value {
    case .null:
        return NSNull()
    case .bool(let boolValue):
        return boolValue
    case .int(let intValue):
        return intValue
    case .double(let doubleValue):
        return doubleValue
    case .string(let stringValue):
        return stringValue
    case .array(let arrayValue):
        return arrayValue.map(anyCodableToAny)
    case .object(let objectValue):
        return objectValue.mapValues(anyCodableToAny)
    }
}
