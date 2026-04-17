import Foundation
import Testing
@testable import Orbit

@Suite("HookDebugLogger")
struct HookDebugLoggerTests {
    @Test("log creates the target file")
    func testLogCreatesFile() async throws {
        let fileURL = try makeTemporaryLogURL()
        let logger = HookDebugLogger(filePath: fileURL.path)

        await logger.log(
            source: "hook",
            sessionId: "session-1",
            hookEventName: "UserPromptSubmit",
            requestId: "req-1",
            decision: "allow",
            responseJson: nil,
            payloadSummary: "summary"
        )

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("log writes a valid JSON object")
    func testLogFormat() async throws {
        let fileURL = try makeTemporaryLogURL()
        let logger = HookDebugLogger(filePath: fileURL.path)

        await logger.log(
            source: "hook",
            sessionId: "session-1",
            hookEventName: "UserPromptSubmit",
            requestId: "req-1",
            decision: "allow",
            responseJson: "{\"ok\":true}",
            payloadSummary: "summary"
        )

        let line = try String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(line.utf8)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json != nil)
        #expect(json?["timestamp"] as? String != nil)
        #expect(json?["source"] as? String == "hook")
        #expect(json?["session_id"] as? String == "session-1")
        #expect(json?["hook_event_name"] as? String == "UserPromptSubmit")
        #expect(json?["request_id"] as? String == "req-1")
        #expect(json?["decision"] as? String == "allow")
        #expect(json?["response_json"] as? String == "{\"ok\":true}")
        #expect(json?["payload_summary"] as? String == "summary")
    }

    @Test("multiple logs append separate JSONL lines")
    func testMultipleLogsAppend() async throws {
        let fileURL = try makeTemporaryLogURL()
        let logger = HookDebugLogger(filePath: fileURL.path)

        for index in 1...3 {
            await logger.log(
                source: "hook",
                sessionId: "session-\(index)",
                hookEventName: "UserPromptSubmit",
                requestId: "req-\(index)",
                decision: "allow",
                responseJson: nil,
                payloadSummary: "summary-\(index)"
            )
        }

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.split(whereSeparator: \.isNewline)

        #expect(lines.count == 3)

        for line in lines {
            let data = Data(line.utf8)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(json != nil)
            #expect(json?["source"] as? String == "hook")
            #expect(json?["decision"] as? String == "allow")
            #expect(json?["response_json"] as? String == "<none>")
        }
    }

    private func makeTemporaryLogURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("hook-debug.log")
    }
}
