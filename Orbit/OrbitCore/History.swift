import Foundation

public struct HistoryEntry: Codable, Sendable, Equatable {
    public var sessionId: String
    public var parentSessionId: String?
    public var cwd: String
    public var startedAt: Date
    public var endedAt: Date
    public var toolCount: UInt32
    public var durationSecs: Int64
    public var title: String?
    public var tokensIn: UInt64
    public var tokensOut: UInt64
    public var costUsd: Double
    public var model: String?
    public var tty: String?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case parentSessionId = "parent_session_id"
        case cwd
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case toolCount = "tool_count"
        case durationSecs = "duration_secs"
        case title
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case costUsd = "cost_usd"
        case model
        case tty
    }

    public init(
        sessionId: String,
        parentSessionId: String? = nil,
        cwd: String,
        startedAt: Date,
        endedAt: Date,
        toolCount: UInt32,
        durationSecs: Int64,
        title: String? = nil,
        tokensIn: UInt64 = 0,
        tokensOut: UInt64 = 0,
        costUsd: Double = 0,
        model: String? = nil,
        tty: String? = nil
    ) {
        self.sessionId = sessionId
        self.parentSessionId = parentSessionId
        self.cwd = cwd
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.toolCount = toolCount
        self.durationSecs = durationSecs
        self.title = title
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.costUsd = costUsd
        self.model = model
        self.tty = tty
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.parentSessionId = try container.decodeIfPresent(String.self, forKey: .parentSessionId)
        self.cwd = try container.decode(String.self, forKey: .cwd)
        self.startedAt = try OrbitDateCoding.decode(container.decode(String.self, forKey: .startedAt))
        self.endedAt = try OrbitDateCoding.decode(container.decode(String.self, forKey: .endedAt))
        self.toolCount = try container.decode(UInt32.self, forKey: .toolCount)
        self.durationSecs = try container.decode(Int64.self, forKey: .durationSecs)

        let decodedTitle = try container.decodeIfPresent(String.self, forKey: .title)
        self.title = decodedTitle?.isEmpty == true ? nil : decodedTitle

        self.tokensIn = try container.decodeIfPresent(UInt64.self, forKey: .tokensIn) ?? 0
        self.tokensOut = try container.decodeIfPresent(UInt64.self, forKey: .tokensOut) ?? 0
        self.costUsd = try container.decodeIfPresent(Double.self, forKey: .costUsd) ?? 0
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.tty = try container.decodeIfPresent(String.self, forKey: .tty)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(parentSessionId, forKey: .parentSessionId)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(OrbitDateCoding.encode(startedAt), forKey: .startedAt)
        try container.encode(OrbitDateCoding.encode(endedAt), forKey: .endedAt)
        try container.encode(toolCount, forKey: .toolCount)
        try container.encode(durationSecs, forKey: .durationSecs)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(tokensIn, forKey: .tokensIn)
        try container.encode(tokensOut, forKey: .tokensOut)
        try container.encode(costUsd, forKey: .costUsd)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(tty, forKey: .tty)
    }
}

public actor HistoryStore {
    public static let maxEntries: Int = 50

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(filePath: String = NSString(string: "~/.orbit/history.json").expandingTildeInPath) {
        self.fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func save(_ entry: HistoryEntry) async {
        var entries = await loadAll()
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries = Array(entries.suffix(Self.maxEntries))
        }

        do {
            try ensureParentDirectoryExists()
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Fail silently by design.
        }
    }

    public func loadAll() async -> [HistoryEntry] {
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([HistoryEntry].self, from: data)
        } catch {
            return []
        }
    }

    public func find(sessionId: String) async -> HistoryEntry? {
        await loadAll().first { $0.sessionId == sessionId }
    }

    private func ensureParentDirectoryExists() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}
