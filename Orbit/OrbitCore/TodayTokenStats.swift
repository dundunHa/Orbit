import Foundation

public struct TodayTokenStats: Sendable, Codable {
    public var date: UInt32
    public var tokensIn: UInt64
    public var tokensOut: UInt64
    public var outRate: Double
    public var sessionBaselines: [String: [UInt64]]
    public var lastRateSampleTs: Date?
    public var lastRateSampleOut: UInt64

    public init(
        date: UInt32 = Self.todayKey(),
        tokensIn: UInt64 = 0,
        tokensOut: UInt64 = 0,
        outRate: Double = 0,
        sessionBaselines: [String: [UInt64]] = [:],
        lastRateSampleTs: Date? = nil,
        lastRateSampleOut: UInt64 = 0
    ) {
        self.date = date
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.outRate = outRate
        self.sessionBaselines = sessionBaselines
        self.lastRateSampleTs = lastRateSampleTs
        self.lastRateSampleOut = lastRateSampleOut
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decodeIfPresent(UInt32.self, forKey: .date) ?? Self.todayKey()
        tokensIn = try container.decodeIfPresent(UInt64.self, forKey: .tokensIn) ?? 0
        tokensOut = try container.decodeIfPresent(UInt64.self, forKey: .tokensOut) ?? 0
        outRate = 0
        sessionBaselines = try container.decodeIfPresent([String: [UInt64]].self, forKey: .sessionBaselines) ?? [:]
        lastRateSampleTs = nil
        lastRateSampleOut = 0
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(tokensIn, forKey: .tokensIn)
        try container.encode(tokensOut, forKey: .tokensOut)
        try container.encode(sessionBaselines, forKey: .sessionBaselines)
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case sessionBaselines = "session_baselines"
    }

    public static func todayKey() -> UInt32 {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let year = UInt32(components.year ?? 0)
        let month = UInt32(components.month ?? 0)
        let day = UInt32(components.day ?? 0)
        return year * 10000 + month * 100 + day
    }

    public static func loadFromDisk(filePath: String? = nil) -> TodayTokenStats {
        let url = Self.baselinesURL(filePath: filePath)
        guard let data = try? Data(contentsOf: url) else {
            return Self.makeDefault()
        }

        guard var stats = try? JSONDecoder().decode(TodayTokenStats.self, from: data) else {
            return Self.makeDefault()
        }

        stats.resetIfNewDay()
        return stats
    }

    public mutating func resetIfNewDay() {
        if date != Self.todayKey() {
            self = Self.makeDefault()
        }
    }

    public mutating func sessionTodayDelta(sessionId: String, totalIn: UInt64, totalOut: UInt64) -> (UInt64, UInt64) {
        let baseline = sessionBaselines[sessionId] ?? {
            let value = [totalIn, totalOut]
            sessionBaselines[sessionId] = value
            return value
        }()

        return (
            totalIn.saturatingSub(baseline[0]),
            totalOut.saturatingSub(baseline[1])
        )
    }

    public mutating func updateRate(currentTotalOut: UInt64) {
        let now = Date()
        guard let lastSampleTs = lastRateSampleTs else {
            lastRateSampleTs = now
            lastRateSampleOut = currentTotalOut
            return
        }

        let elapsed = now.timeIntervalSince(lastSampleTs)
        guard elapsed > 0.5 else { return }

        let delta = currentTotalOut.saturatingSub(lastRateSampleOut)
        let instantRate = Double(delta) / elapsed
        outRate = outRate * 0.7 + instantRate * 0.3
        lastRateSampleTs = now
        lastRateSampleOut = currentTotalOut
    }

    public func saveToDisk(filePath: String? = nil) {
        let url = Self.baselinesURL(filePath: filePath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: url, options: [.atomic])
        } catch {
        }
    }

    public static func makeDefault() -> TodayTokenStats {
        TodayTokenStats()
    }

    private static func baselinesURL(filePath: String?) -> URL {
        if let filePath {
            return URL(fileURLWithPath: filePath)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".orbit").appendingPathComponent("token-baselines.json")
    }
}

private extension UInt64 {
    func saturatingSub(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}
