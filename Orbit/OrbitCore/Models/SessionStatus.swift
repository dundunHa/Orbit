import Foundation

public indirect enum SessionStatus: Codable, Sendable, Equatable {
    case waitingForInput
    case processing
    case runningTool(toolName: String, description: String?)
    case waitingForApproval(toolName: String, toolInput: AnyCodable)
    case anomaly(idleSeconds: UInt64, previousStatus: SessionStatus)
    case compacting
    case ended

    private enum CodingKeys: String, CodingKey {
        case type
        case toolName = "tool_name"
        case description
        case toolInput = "tool_input"
        case idleSeconds = "idle_seconds"
        case previousStatus = "previous_status"
    }

    private enum TypeDiscriminator: String, Codable {
        case waitingForInput = "WaitingForInput"
        case processing = "Processing"
        case runningTool = "RunningTool"
        case waitingForApproval = "WaitingForApproval"
        case anomaly = "Anomaly"
        case compacting = "Compacting"
        case ended = "Ended"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TypeDiscriminator.self, forKey: .type)

        switch type {
        case .waitingForInput:
            self = .waitingForInput
        case .processing:
            self = .processing
        case .runningTool:
            self = .runningTool(
                toolName: try container.decode(String.self, forKey: .toolName),
                description: try container.decodeIfPresent(String.self, forKey: .description)
            )
        case .waitingForApproval:
            self = .waitingForApproval(
                toolName: try container.decode(String.self, forKey: .toolName),
                toolInput: try container.decode(AnyCodable.self, forKey: .toolInput)
            )
        case .anomaly:
            self = .anomaly(
                idleSeconds: try container.decode(UInt64.self, forKey: .idleSeconds),
                previousStatus: try container.decode(SessionStatus.self, forKey: .previousStatus)
            )
        case .compacting:
            self = .compacting
        case .ended:
            self = .ended
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .waitingForInput:
            try container.encode(TypeDiscriminator.waitingForInput, forKey: .type)
        case .processing:
            try container.encode(TypeDiscriminator.processing, forKey: .type)
        case .runningTool(let toolName, let description):
            try container.encode(TypeDiscriminator.runningTool, forKey: .type)
            try container.encode(toolName, forKey: .toolName)
            try container.encodeIfPresent(description, forKey: .description)
        case .waitingForApproval(let toolName, let toolInput):
            try container.encode(TypeDiscriminator.waitingForApproval, forKey: .type)
            try container.encode(toolName, forKey: .toolName)
            try container.encode(toolInput, forKey: .toolInput)
        case .anomaly(let idleSeconds, let previousStatus):
            try container.encode(TypeDiscriminator.anomaly, forKey: .type)
            try container.encode(idleSeconds, forKey: .idleSeconds)
            try container.encode(previousStatus, forKey: .previousStatus)
        case .compacting:
            try container.encode(TypeDiscriminator.compacting, forKey: .type)
        case .ended:
            try container.encode(TypeDiscriminator.ended, forKey: .type)
        }
    }
}
