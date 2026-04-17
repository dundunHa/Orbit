import Foundation

public struct PermissionRule: Codable, Sendable, Equatable {
    public var toolName: String
    public var ruleContent: String?

    public init(toolName: String, ruleContent: String? = nil) {
        self.toolName = toolName
        self.ruleContent = ruleContent
    }
}

public struct PermissionUpdateEntry: Codable, Sendable, Equatable {
    public var type: String
    public var rules: [PermissionRule]?
    public var behavior: String?
    public var destination: String?
    public var mode: String?
    public var directories: [String]?

    public init(
        type: String,
        rules: [PermissionRule]? = nil,
        behavior: String? = nil,
        destination: String? = nil,
        mode: String? = nil,
        directories: [String]? = nil
    ) {
        self.type = type
        self.rules = rules
        self.behavior = behavior
        self.destination = destination
        self.mode = mode
        self.directories = directories
    }
}

public struct PermissionDecision: Codable, Sendable, Equatable {
    public var decision: String
    public var reason: String?
    public var content: AnyCodable?
    public var updatedPermissions: [PermissionUpdateEntry]?

    public init(
        decision: String,
        reason: String? = nil,
        content: AnyCodable? = nil,
        updatedPermissions: [PermissionUpdateEntry]? = nil
    ) {
        self.decision = decision
        self.reason = reason
        self.content = content
        self.updatedPermissions = updatedPermissions
    }

    public func normalizedDecision() -> String {
        decision == "ask" ? "passthrough" : decision
    }
}
