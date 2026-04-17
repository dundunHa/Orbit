import Foundation
import Testing
@testable import Orbit

@Suite("TodayTokenStats Tests")
struct TodayTokenStatsTests {
    @Test("todayKey returns local YYYYMMDD")
    func testTodayKey() {
        let key = TodayTokenStats.todayKey()
        #expect(String(key).count == 8)

        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let year = UInt32(components.year ?? 0)
        let month = UInt32(components.month ?? 0)
        let day = UInt32(components.day ?? 0)
        let expected = year * 10000 + month * 100 + day
        #expect(key == expected)
    }

    @Test("resetIfNewDay clears stale counters")
    func testResetIfNewDay() {
        var stats = TodayTokenStats(
            date: todayKey(offsetByDays: -1),
            tokensIn: 12,
            tokensOut: 34,
            outRate: 56.0,
            sessionBaselines: ["session-1": [1, 2]],
            lastRateSampleTs: Date(timeIntervalSince1970: 123),
            lastRateSampleOut: 99
        )

        stats.resetIfNewDay()

        #expect(stats.date == TodayTokenStats.todayKey())
        #expect(stats.tokensIn == 0)
        #expect(stats.tokensOut == 0)
        #expect(stats.outRate == 0)
        #expect(stats.sessionBaselines.isEmpty)
        #expect(stats.lastRateSampleTs == nil)
        #expect(stats.lastRateSampleOut == 0)
    }

    @Test("sessionTodayDelta returns zero on first call and captures baseline")
    func testSessionTodayDeltaFirstCall() {
        var stats = TodayTokenStats()

        let delta = stats.sessionTodayDelta(sessionId: "session-1", totalIn: 100, totalOut: 200)

        #expect(delta.0 == 0)
        #expect(delta.1 == 0)
        #expect(stats.sessionBaselines["session-1"] == [100, 200])
    }

    @Test("sessionTodayDelta returns deltas on subsequent calls")
    func testSessionTodayDeltaSubsequentCall() {
        var stats = TodayTokenStats()

        _ = stats.sessionTodayDelta(sessionId: "session-1", totalIn: 100, totalOut: 200)
        let delta = stats.sessionTodayDelta(sessionId: "session-1", totalIn: 135, totalOut: 260)

        #expect(delta.0 == 35)
        #expect(delta.1 == 60)
    }

    @Test("updateRate primes the first sample")
    func testUpdateRateFirstCall() {
        var stats = TodayTokenStats()

        stats.updateRate(currentTotalOut: 250)

        #expect(stats.outRate == 0)
        #expect(stats.lastRateSampleOut == 250)
        #expect(stats.lastRateSampleTs != nil)
    }

    @Test("updateRate applies EMA on later sample")
    func testUpdateRateSubsequentCall() {
        var stats = TodayTokenStats()

        stats.updateRate(currentTotalOut: 100)
        stats.lastRateSampleTs = stats.lastRateSampleTs?.addingTimeInterval(-1.0)

        stats.updateRate(currentTotalOut: 250)

        let instantRate = 150.0
        let expected = 0.0 * 0.7 + instantRate * 0.3
        #expect(abs(stats.outRate - expected) < 0.0001)
        #expect(stats.lastRateSampleOut == 250)
    }

    @Test("saveToDisk and loadFromDisk round-trip data")
    func testRoundTripDisk() throws {
        let path = tempFilePath(named: "today-token-round-trip")

        let original = TodayTokenStats(
            date: TodayTokenStats.todayKey(),
            tokensIn: 123,
            tokensOut: 456,
            outRate: 78.9,
            sessionBaselines: ["session-1": [10, 20], "session-2": [30, 40]],
            lastRateSampleTs: Date(timeIntervalSince1970: 999),
            lastRateSampleOut: 88
        )

        original.saveToDisk(filePath: path)
        let loaded = TodayTokenStats.loadFromDisk(filePath: path)

        #expect(loaded.date == original.date)
        #expect(loaded.tokensIn == original.tokensIn)
        #expect(loaded.tokensOut == original.tokensOut)
        #expect(loaded.sessionBaselines == original.sessionBaselines)
        #expect(loaded.outRate == 0)
        #expect(loaded.lastRateSampleTs == nil)
        #expect(loaded.lastRateSampleOut == 0)
    }

    private func todayKey(offsetByDays days: Int) -> UInt32 {
        let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = UInt32(components.year ?? 0)
        let month = UInt32(components.month ?? 0)
        let day = UInt32(components.day ?? 0)
        return year * 10000 + month * 100 + day
    }

    private func tempFilePath(named name: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-today-token-")
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
            .path
    }
}
