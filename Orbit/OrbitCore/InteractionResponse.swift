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
        var decisionObject: [String: Any] = ["behavior": "allow"]

        if toolName == "AskUserQuestion",
           let updatedInput = buildAskUserQuestionUpdatedInput(toolInput: toolInput, content: decision.content) {
            decisionObject["updatedInput"] = updatedInput
        }

        if let updatedPermissions = permissionUpdatesToJSONObject(decision.updatedPermissions) {
            decisionObject["updatedPermissions"] = updatedPermissions
        }

        return [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decisionObject,
            ],
        ]
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
    guard let contentObject = content.map(anyCodableToAny) as? [String: Any] else {
        return nil
    }
    var updated = toolInputObject
    if let answers = contentObject["answers"] {
        updated["answers"] = answers
    }
    if let responses = contentObject["responses"] {
        updated["responses"] = responses
    }
    guard updated["answers"] != nil || updated["responses"] != nil else {
        return nil
    }
    return updated
}

func permissionUpdatesToJSONObject(_ updates: [PermissionUpdateEntry]?) -> [[String: Any]]? {
    guard let updates, !updates.isEmpty else {
        return nil
    }
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(updates),
          let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return nil
    }
    return json
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
