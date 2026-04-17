import Foundation

public struct HookPayload: Codable, Sendable, Equatable {
    public var sessionId: String
    public var hookEventName: String
    public var cwd: String
    public var toolName: String?
    public var toolInput: AnyCodable?
    public var toolUseId: String?
    public var toolResponse: AnyCodable?
    public var mcpServerName: String?
    public var notificationType: String?
    public var message: String?
    public var mode: String?
    public var url: String?
    public var elicitationId: String?
    public var requestedSchema: AnyCodable?
    public var action: String?
    public var content: AnyCodable?
    public var pid: UInt32?
    public var tty: String?
    public var status: String?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case cwd
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case toolResponse = "tool_response"
        case mcpServerName = "mcp_server_name"
        case notificationType = "notification_type"
        case message
        case mode
        case url
        case elicitationId = "elicitation_id"
        case requestedSchema = "requested_schema"
        case action
        case content
        case pid
        case tty
        case status
    }

    private enum LegacyKeys: String, CodingKey {
        case sessionId
        case hookEventName
        case toolName
        case toolInput
        case toolUseId
        case toolResponse
        case mcpServerName
        case notificationType
        case elicitationId
        case requestedSchema
    }

    public init(
        sessionId: String,
        hookEventName: String,
        cwd: String = "",
        toolName: String? = nil,
        toolInput: AnyCodable? = nil,
        toolUseId: String? = nil,
        toolResponse: AnyCodable? = nil,
        mcpServerName: String? = nil,
        notificationType: String? = nil,
        message: String? = nil,
        mode: String? = nil,
        url: String? = nil,
        elicitationId: String? = nil,
        requestedSchema: AnyCodable? = nil,
        action: String? = nil,
        content: AnyCodable? = nil,
        pid: UInt32? = nil,
        tty: String? = nil,
        status: String? = nil
    ) {
        self.sessionId = sessionId
        self.hookEventName = hookEventName
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.toolResponse = toolResponse
        self.mcpServerName = mcpServerName
        self.notificationType = notificationType
        self.message = message
        self.mode = mode
        self.url = url
        self.elicitationId = elicitationId
        self.requestedSchema = requestedSchema
        self.action = action
        self.content = content
        self.pid = pid
        self.tty = tty
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)

        self.sessionId = try Self.decodeString(container, legacy, .sessionId)
        self.hookEventName = try Self.decodeString(container, legacy, .hookEventName)
        self.cwd = try Self.decodeStringOrDefault(container, .cwd, defaultValue: "")
        self.toolName = try Self.decodeOptionalString(container, legacy, .toolName, key: .toolName)
        self.toolInput = try Self.decodeOptionalAny(container, legacy, .toolInput, key: .toolInput)
        self.toolUseId = try Self.decodeOptionalString(container, legacy, .toolUseId, key: .toolUseId)
        self.toolResponse = try Self.decodeOptionalAny(container, legacy, .toolResponse, key: .toolResponse)
        self.mcpServerName = try Self.decodeOptionalString(container, legacy, .mcpServerName, key: .mcpServerName)
        self.notificationType = try Self.decodeOptionalString(container, legacy, .notificationType, key: .notificationType)
        self.message = try Self.decodeOptionalString(container, nil, nil, key: .message)
        self.mode = try Self.decodeOptionalString(container, nil, nil, key: .mode)
        self.url = try Self.decodeOptionalString(container, nil, nil, key: .url)
        self.elicitationId = try Self.decodeOptionalString(container, legacy, .elicitationId, key: .elicitationId)
        self.requestedSchema = try Self.decodeOptionalAny(container, legacy, .requestedSchema, key: .requestedSchema)
        self.action = try Self.decodeOptionalString(container, nil, nil, key: .action)
        self.content = try Self.decodeOptionalAny(container, nil, nil, key: .content)
        self.pid = try container.decodeIfPresent(UInt32.self, forKey: .pid)
        self.tty = try container.decodeIfPresent(String.self, forKey: .tty)
        self.status = try container.decodeIfPresent(String.self, forKey: .status)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(hookEventName, forKey: .hookEventName)
        try container.encode(cwd, forKey: .cwd)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        try container.encodeIfPresent(toolInput, forKey: .toolInput)
        try container.encodeIfPresent(toolUseId, forKey: .toolUseId)
        try container.encodeIfPresent(toolResponse, forKey: .toolResponse)
        try container.encodeIfPresent(mcpServerName, forKey: .mcpServerName)
        try container.encodeIfPresent(notificationType, forKey: .notificationType)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(mode, forKey: .mode)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(elicitationId, forKey: .elicitationId)
        try container.encodeIfPresent(requestedSchema, forKey: .requestedSchema)
        try container.encodeIfPresent(action, forKey: .action)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(pid, forKey: .pid)
        try container.encodeIfPresent(tty, forKey: .tty)
        try container.encodeIfPresent(status, forKey: .status)
    }

    private static func decodeString(_ container: KeyedDecodingContainer<CodingKeys>, _ legacy: KeyedDecodingContainer<LegacyKeys>, _ key: CodingKeys) throws -> String {
        if let value = try container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let legacyKey = legacyKey(for: key), let value = try legacy.decodeIfPresent(String.self, forKey: legacyKey) {
            return value
        }
        throw DecodingError.keyNotFound(key, .init(codingPath: container.codingPath, debugDescription: "Missing required key \(key.stringValue)"))
    }

    private static func decodeStringOrDefault(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, defaultValue: String) throws -> String {
        try container.decodeIfPresent(String.self, forKey: key) ?? defaultValue
    }

    private static func decodeOptionalString(_ container: KeyedDecodingContainer<CodingKeys>, _ legacy: KeyedDecodingContainer<LegacyKeys>?, _ legacyKey: LegacyKeys?, key: CodingKeys? = nil) throws -> String? {
        if let key, let value = try container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let legacy, let legacyKey, let value = try legacy.decodeIfPresent(String.self, forKey: legacyKey) {
            return value
        }
        return nil
    }

    private static func decodeOptionalAny(_ container: KeyedDecodingContainer<CodingKeys>, _ legacy: KeyedDecodingContainer<LegacyKeys>?, _ legacyKey: LegacyKeys?, key: CodingKeys? = nil) throws -> AnyCodable? {
        if let key, let value = try container.decodeIfPresent(AnyCodable.self, forKey: key) {
            return value
        }
        if let legacy, let legacyKey, let value = try legacy.decodeIfPresent(AnyCodable.self, forKey: legacyKey) {
            return value
        }
        return nil
    }

    private static func legacyKey(for key: CodingKeys) -> LegacyKeys? {
        switch key {
        case .sessionId:
            return .sessionId
        case .hookEventName:
            return .hookEventName
        case .toolName:
            return .toolName
        case .toolInput:
            return .toolInput
        case .toolUseId:
            return .toolUseId
        case .toolResponse:
            return .toolResponse
        case .mcpServerName:
            return .mcpServerName
        case .notificationType:
            return .notificationType
        case .message, .mode, .url, .elicitationId, .requestedSchema, .action, .content, .pid, .tty, .status, .cwd:
            return nil
        }
    }
}
