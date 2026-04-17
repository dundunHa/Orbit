import Foundation

public enum TitleSource: Int, Codable, Sendable, Equatable {
    case userPrompt = 1
    case historyJsonl = 2
    case sessionsMetadata = 3
}

public struct Session: Codable, Sendable, Equatable {
    public var id: String
    public var cwd: String
    public var hasSpawnedSubagent: Bool
    public var parentSessionId: String?
    public var status: SessionStatus
    public var startedAt: Date
    public var lastEventAt: Date
    public var toolCount: UInt32
    public var pid: UInt32?
    public var tty: String?
    public var title: String?
    public var titleSource: TitleSource?
    public var tokensIn: UInt64
    public var tokensOut: UInt64
    public var costUsd: Double
    public var model: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case cwd
        case hasSpawnedSubagent = "has_spawned_subagent"
        case parentSessionId = "parent_session_id"
        case status
        case startedAt = "started_at"
        case lastEventAt = "last_event_at"
        case toolCount = "tool_count"
        case pid
        case tty
        case title
        case titleSource = "title_source"
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case costUsd = "cost_usd"
        case model
    }

    public init(
        id: String,
        cwd: String,
        hasSpawnedSubagent: Bool = false,
        parentSessionId: String? = nil,
        status: SessionStatus,
        startedAt: Date,
        lastEventAt: Date,
        toolCount: UInt32 = 0,
        pid: UInt32? = nil,
        tty: String? = nil,
        title: String? = nil,
        titleSource: TitleSource? = nil,
        tokensIn: UInt64 = 0,
        tokensOut: UInt64 = 0,
        costUsd: Double = 0,
        model: String? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.hasSpawnedSubagent = hasSpawnedSubagent
        self.parentSessionId = parentSessionId
        self.status = status
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.toolCount = toolCount
        self.pid = pid
        self.tty = tty
        self.title = title
        self.titleSource = titleSource
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.costUsd = costUsd
        self.model = model
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.cwd = try container.decode(String.self, forKey: .cwd)
        self.hasSpawnedSubagent = try container.decodeIfPresent(Bool.self, forKey: .hasSpawnedSubagent) ?? false
        self.parentSessionId = try container.decodeIfPresent(String.self, forKey: .parentSessionId)
        self.status = try container.decode(SessionStatus.self, forKey: .status)
        self.startedAt = try OrbitDateCoding.decode(container.decode(String.self, forKey: .startedAt))
        self.lastEventAt = try OrbitDateCoding.decode(container.decode(String.self, forKey: .lastEventAt))
        self.toolCount = try container.decodeIfPresent(UInt32.self, forKey: .toolCount) ?? 0
        self.pid = try container.decodeIfPresent(UInt32.self, forKey: .pid)
        self.tty = try container.decodeIfPresent(String.self, forKey: .tty)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.titleSource = try container.decodeIfPresent(TitleSource.self, forKey: .titleSource)
        self.tokensIn = try container.decodeIfPresent(UInt64.self, forKey: .tokensIn) ?? 0
        self.tokensOut = try container.decodeIfPresent(UInt64.self, forKey: .tokensOut) ?? 0
        self.costUsd = try container.decodeIfPresent(Double.self, forKey: .costUsd) ?? 0
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(hasSpawnedSubagent, forKey: .hasSpawnedSubagent)
        try container.encodeIfPresent(parentSessionId, forKey: .parentSessionId)
        try container.encode(status, forKey: .status)
        try container.encode(OrbitDateCoding.encode(startedAt), forKey: .startedAt)
        try container.encode(OrbitDateCoding.encode(lastEventAt), forKey: .lastEventAt)
        try container.encode(toolCount, forKey: .toolCount)
        try container.encodeIfPresent(pid, forKey: .pid)
        try container.encodeIfPresent(tty, forKey: .tty)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(titleSource, forKey: .titleSource)
        try container.encode(tokensIn, forKey: .tokensIn)
        try container.encode(tokensOut, forKey: .tokensOut)
        try container.encode(costUsd, forKey: .costUsd)
        try container.encodeIfPresent(model, forKey: .model)
    }
}
