import Foundation

public struct StatuslineUpdate: Decodable, Sendable, Equatable {
    public var sessionId: String
    public var tokensIn: UInt64
    public var tokensOut: UInt64
    public var costUsd: Double
    public var model: String?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case costUsd = "cost_usd"
        case model
    }

    public init(sessionId: String, tokensIn: UInt64, tokensOut: UInt64, costUsd: Double = 0, model: String? = nil) {
        self.sessionId = sessionId
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.costUsd = costUsd
        self.model = model
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.tokensIn = try container.decode(UInt64.self, forKey: .tokensIn)
        self.tokensOut = try container.decode(UInt64.self, forKey: .tokensOut)
        self.costUsd = try container.decodeIfPresent(Double.self, forKey: .costUsd) ?? 0
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
    }
}
