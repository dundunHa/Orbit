import Foundation

public struct PermissionDecision: Codable, Sendable, Equatable {
    public var decision: String
    public var reason: String?
    public var content: AnyCodable?

    public init(decision: String, reason: String? = nil, content: AnyCodable? = nil) {
        self.decision = decision
        self.reason = reason
        self.content = content
    }

    public func normalizedDecision() -> String {
        decision == "ask" ? "passthrough" : decision
    }
}
