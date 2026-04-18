import Foundation

public actor HookDebugLogger {
    private let filePath: String

    public init(filePath: String = HookDebugLogger.defaultFilePath()) {
        self.filePath = (filePath as NSString).expandingTildeInPath
    }

    public func log(
        source: String,
        sessionId: String?,
        hookEventName: String?,
        requestId: String?,
        decision: String,
        responseJson: String?,
        payloadSummary: String?,
        payloadDetails: [String: String]? = nil
    ) async {
        let line = makeJSONLine(
            source: source,
            sessionId: sessionId,
            hookEventName: hookEventName,
            requestId: requestId,
            decision: decision,
            responseJson: responseJson,
            payloadSummary: payloadSummary,
            payloadDetails: payloadDetails
        )

        guard let data = (line + "\n").data(using: .utf8) else {
            return
        }

        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: filePath)

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            return
        }

        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else {
            return
        }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
        }
    }

    public static func defaultFilePath() -> String {
        let environment = ProcessInfo.processInfo.environment["ORBIT_HOOK_DEBUG_LOG_PATH"]
        if let environment, !environment.isEmpty {
            return (environment as NSString).expandingTildeInPath
        }

        return NSHomeDirectory()
            .appending("/.orbit/hook-debug.log")
    }

    private func makeJSONLine(
        source: String,
        sessionId: String?,
        hookEventName: String?,
        requestId: String?,
        decision: String,
        responseJson: String?,
        payloadSummary: String?,
        payloadDetails: [String: String]?
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var payload: [String: Any] = [
            "timestamp": formatter.string(from: Date()),
            "source": source,
            "decision": decision,
            "response_json": responseJson ?? "<none>",
        ]

        if let sessionId {
            payload["session_id"] = sessionId
        }

        if let hookEventName {
            payload["hook_event_name"] = hookEventName
        }

        if let requestId {
            payload["request_id"] = requestId
        }

        if let payloadSummary {
            payload["payload_summary"] = payloadSummary
        }

        if let payloadDetails, !payloadDetails.isEmpty {
            payload["payload_details"] = payloadDetails
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let line = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return line
    }
}
