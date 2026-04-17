import Foundation
import Testing
@testable import Orbit

@Suite("History Tests")
struct HistoryTests {
    @Test("History round-trips entries")
    func testHistoryRoundTrip() async throws {
        let store = makeStore(named: "round-trip")

        let entries = [1, 2, 3].map { makeEntry($0, allowEmptyTitle: false) }
        for entry in entries {
            await store.save(entry)
        }

        let loaded = await store.loadAll()
        #expect(loaded.count == 3)
        #expect(loaded == entries)
    }

    @Test("History truncates to fifty entries")
    func testHistoryTruncation() async throws {
        let store = makeStore(named: "truncation")

        for index in 1...55 {
            await store.save(makeEntry(index))
        }

        let loaded = await store.loadAll()
        #expect(loaded.count == 50)
        #expect(loaded.first?.sessionId == "session-6")
        #expect(loaded.last?.sessionId == "session-55")
    }

    @Test("History loadAll returns empty array for missing file")
    func testHistoryMissingFile() async throws {
        let store = makeStore(named: "missing")

        let loaded = await store.loadAll()
        #expect(loaded.isEmpty)
    }

    @Test("History loadAll returns empty array for corrupted file")
    func testHistoryCorruptedFile() async throws {
        let path = storePath(named: "corrupted")
        let store = HistoryStore(filePath: path)
        try writeText("not valid json", to: path)

        let loaded = await store.loadAll()
        #expect(loaded.isEmpty)
    }

    @Test("History find returns the matching entry")
    func testFindEntry() async throws {
        let store = makeStore(named: "find")

        let entries = [1, 2, 3].map { makeEntry($0, allowEmptyTitle: false) }
        for entry in entries {
            await store.save(entry)
        }

        let found = await store.find(sessionId: "session-2")
        #expect(found == entries[1])
    }

    @Test("History title decodes empty string as nil")
    func testTitleEmptyStringBecomesNil() throws {
        let json = Data(#"{"session_id":"session-1","cwd":"/tmp","started_at":"2026-04-13T00:00:00Z","ended_at":"2026-04-13T01:00:00Z","tool_count":1,"duration_secs":3600,"title":"","tokens_in":0,"tokens_out":0,"cost_usd":0}"#.utf8)
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: json)

        #expect(entry.title == nil)
    }

    private func makeStore(named name: String) -> HistoryStore {
        HistoryStore(filePath: storePath(named: name))
    }

    private func storePath(named name: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-history-")
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
            .path
    }

    private func writeText(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)!.write(to: url)
    }

    private func makeEntry(_ index: Int, allowEmptyTitle: Bool = true) -> HistoryEntry {
        let startedAt = Date(timeIntervalSince1970: TimeInterval(index * 3600))
        let endedAt = Date(timeIntervalSince1970: TimeInterval(index * 3600 + 1800))
        return HistoryEntry(
            sessionId: "session-\(index)",
            parentSessionId: index == 1 ? nil : "parent-\(index - 1)",
            cwd: "/work/\(index)",
            startedAt: startedAt,
            endedAt: endedAt,
            toolCount: UInt32(index),
            durationSecs: Int64(index * 1800),
            title: allowEmptyTitle && index == 2 ? "" : "Title \(index)",
            tokensIn: UInt64(index * 10),
            tokensOut: UInt64(index * 20),
            costUsd: Double(index) / 10,
            model: index == 3 ? nil : "model-\(index)",
            tty: index == 1 ? nil : "ttys\(index)"
        )
    }
}
