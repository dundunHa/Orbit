import Darwin
import Foundation
import Testing
@testable import Orbit

@Suite("CLI Tests")
struct CLITests {

    // MARK: - Response Mode Detection

    @Test("PermissionRequest event expects response")
    func permissionRequestExpectsResponse() {
        let input = #"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/"}"#
        #expect(expectedResponseMode(for: input) == .permissionRequest)
    }

    @Test("Elicitation event expects response")
    func elicitationExpectsResponse() {
        let input = #"{"hook_event_name":"Elicitation","session_id":"s1","cwd":"/"}"#
        #expect(expectedResponseMode(for: input) == .elicitation)
    }

    @Test("ElicitationResult event expects response")
    func elicitationResultExpectsResponse() {
        let input = #"{"hook_event_name":"ElicitationResult","session_id":"s1","cwd":"/"}"#
        #expect(expectedResponseMode(for: input) == .elicitation)
    }

    @Test("PreToolUse event is fire-and-forget")
    func preToolUseIsFireAndForget() {
        let input = #"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/"}"#
        #expect(expectedResponseMode(for: input) == .none)
    }

    @Test("SessionStart event is fire-and-forget")
    func sessionStartIsFireAndForget() {
        let input = #"{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/"}"#
        #expect(expectedResponseMode(for: input) == .none)
    }

    @Test("camelCase hookEventName also works")
    func camelCaseHookEventNameWorks() {
        let input = #"{"hookEventName":"PermissionRequest","sessionId":"s1"}"#
        #expect(expectedResponseMode(for: input) == .permissionRequest)
    }

    @Test("empty input returns none")
    func emptyInputReturnsNone() {
        #expect(expectedResponseMode(for: "") == .none)
    }

    @Test("invalid JSON returns none")
    func invalidJsonReturnsNone() {
        #expect(expectedResponseMode(for: "not json") == .none)
    }

    @Test("missing event name returns none")
    func missingEventNameReturnsNone() {
        let input = #"{"session_id":"s1","cwd":"/"}"#
        #expect(expectedResponseMode(for: input) == .none)
    }

    // MARK: - Statusline Message Building

    @Test("buildStatuslineMessage transforms Claude payload correctly")
    func buildStatuslineMessageTransformsPayload() throws {
        let input = #"""
        {
            "session_id": "sess-42",
            "context_window": {
                "total_input_tokens": 1000,
                "total_output_tokens": 500
            },
            "cost": {
                "total_cost_usd": 0.05
            },
            "model": {
                "id": "claude-sonnet-4-20250514"
            }
        }
        """#

        let message = try #require(buildStatuslineMessage(from: input))
        let parsed = try #require(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )

        #expect(parsed["type"] as? String == "StatuslineUpdate")
        #expect(parsed["session_id"] as? String == "sess-42")
        #expect(parsed["tokens_in"] as? UInt64 == 1000)
        #expect(parsed["tokens_out"] as? UInt64 == 500)
        #expect(parsed["cost_usd"] as? Double == 0.05)
        #expect(parsed["model"] as? String == "claude-sonnet-4-20250514")
    }

    @Test("buildStatuslineMessage handles missing fields gracefully")
    func buildStatuslineMessageHandlesMissingFields() throws {
        let input = #"{"session_id":"sess-99"}"#
        let message = try #require(buildStatuslineMessage(from: input))
        let parsed = try #require(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )

        #expect(parsed["type"] as? String == "StatuslineUpdate")
        #expect(parsed["session_id"] as? String == "sess-99")
        #expect(parsed["tokens_in"] is NSNull)
        #expect(parsed["tokens_out"] is NSNull)
        #expect(parsed["cost_usd"] is NSNull)
        #expect(parsed["model"] is NSNull)
    }

    @Test("buildStatuslineMessage returns nil for invalid JSON")
    func buildStatuslineMessageReturnsNilForInvalidJson() {
        #expect(buildStatuslineMessage(from: "not json") == nil)
    }

    @Test("buildStatuslineMessage includes model as null when absent")
    func buildStatuslineMessageModelNullWhenAbsent() throws {
        let input = #"""
        {
            "session_id": "s1",
            "context_window": {"total_input_tokens": 10, "total_output_tokens": 20},
            "cost": {"total_cost_usd": 0.01}
        }
        """#

        let message = try #require(buildStatuslineMessage(from: input))
        let parsed = try #require(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )
        #expect(parsed["model"] is NSNull)
        #expect(parsed["tokens_in"] as? UInt64 == 10)
        #expect(parsed["tokens_out"] as? UInt64 == 20)
    }

    // MARK: - Socket Integration

    @Test("socket client sends JSONL and receives response via SocketServer")
    func socketClientRoundtrip() async throws {
        let socketPath = makeUniqueSocketPath(testName: "cli-rt")
        let bridge = MessageBridge()
        let server = SocketServer(socketPath: socketPath, bridge: bridge)

        let processor = Task {
            while !Task.isCancelled {
                let (id, bytes) = await bridge.dequeue()
                let text = String(decoding: Data(bytes), as: UTF8.self)
                if text.contains("PermissionRequest") {
                    await bridge.respond(id: id, data: Data(#"{"decision":"allow"}"#.utf8))
                } else {
                    await bridge.respond(id: id, data: nil)
                }
            }
        }
        defer { processor.cancel() }

        try await server.start()
        #expect(await waitUntil { FileManager.default.fileExists(atPath: socketPath) })

        let payload = #"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/"}"#
        let response = cliSocketSend(socketPath: socketPath, payload: payload, waitForResponse: true)

        #expect(response == #"{"decision":"allow"}"#)

        await server.stop()
    }

    @Test("socket client fire-and-forget does not block")
    func socketClientFireAndForget() async throws {
        let socketPath = makeUniqueSocketPath(testName: "cli-ff")
        let bridge = MessageBridge()
        let recorder = MessageRecorder()
        let server = SocketServer(socketPath: socketPath, bridge: bridge)

        let processor = Task {
            while !Task.isCancelled {
                let (id, bytes) = await bridge.dequeue()
                await recorder.record(bytes)
                await bridge.respond(id: id, data: nil)
            }
        }
        defer { processor.cancel() }

        try await server.start()
        #expect(await waitUntil { FileManager.default.fileExists(atPath: socketPath) })

        let payload = #"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/"}"#
        let response = cliSocketSend(socketPath: socketPath, payload: payload, waitForResponse: false)
        #expect(response == nil)

        #expect(await waitUntil { await recorder.count() == 1 })

        await server.stop()
    }

    @Test("socket client returns nil when server not running")
    func socketClientReturnsNilWhenNoServer() {
        let response = cliSocketSend(
            socketPath: "/tmp/orbit-nonexistent-\(UUID().uuidString).sock",
            payload: "{}",
            waitForResponse: true
        )
        #expect(response == nil)
    }

    @Test("socket client sends statusline message to server")
    func socketClientSendsStatuslineMessage() async throws {
        let socketPath = makeUniqueSocketPath(testName: "cli-sl")
        let bridge = MessageBridge()
        let recorder = MessageRecorder()
        let server = SocketServer(socketPath: socketPath, bridge: bridge)

        let processor = Task {
            while !Task.isCancelled {
                let (id, bytes) = await bridge.dequeue()
                await recorder.record(bytes)
                await bridge.respond(id: id, data: nil)
            }
        }
        defer { processor.cancel() }

        try await server.start()
        #expect(await waitUntil { FileManager.default.fileExists(atPath: socketPath) })

        let statuslineInput = #"""
        {
            "session_id": "sess-1",
            "context_window": {"total_input_tokens": 100, "total_output_tokens": 50},
            "cost": {"total_cost_usd": 0.02},
            "model": {"id": "claude-sonnet-4-20250514"}
        }
        """#

        if let message = buildStatuslineMessage(from: statuslineInput) {
            _ = cliSocketSend(socketPath: socketPath, payload: message, waitForResponse: false)
        }

        #expect(await waitUntil { await recorder.count() == 1 })

        let received = await recorder.firstString() ?? ""
        let parsed = try #require(
            JSONSerialization.jsonObject(with: Data(received.utf8)) as? [String: Any]
        )
        #expect(parsed["type"] as? String == "StatuslineUpdate")
        #expect(parsed["session_id"] as? String == "sess-1")

        await server.stop()
    }

    @Test("CLI approval clears pending interaction in UI")
    @MainActor
    func cliApprovalClearsPendingInteractionInUi() async throws {
        let fixture = makeAppDelegateFixture()
        let payload = #"{"hook_event_name":"PermissionRequest","session_id":"cli-ui","cwd":"/repo","tool_name":"Bash","tool_use_id":"tool-42"}"#
        let bytes = Array(payload.utf8)

        let responseTask = Task {
            await AppDelegate.processSocketMessageForTesting(
                bytes: bytes,
                hookRouter: fixture.router,
                viewModel: fixture.viewModel
            )
        }

        #expect(await waitUntil {
            await MainActor.run {
                fixture.viewModel.pendingInteraction?.id == "tool-42"
            }
        })

        await fixture.router.resolvePermissionFromCli(sessionId: "cli-ui", toolUseId: "tool-42")
        let responseData = try #require(await responseTask.value)
        let responseText = String(decoding: responseData, as: UTF8.self)

        #expect(responseText.contains("\"behavior\":\"allow\""))
        #expect(fixture.viewModel.pendingInteraction?.id == nil)
    }

    @Test("CLI approval advances to next queued interaction")
    @MainActor
    func cliApprovalAdvancesToNextQueuedInteraction() async throws {
        let fixture = makeAppDelegateFixture()
        let firstPayload = #"{"hook_event_name":"PermissionRequest","session_id":"queue-1","cwd":"/repo","tool_name":"Bash","tool_use_id":"tool-1"}"#
        let secondPayload = #"{"hook_event_name":"PermissionRequest","session_id":"queue-2","cwd":"/repo","tool_name":"Edit","tool_use_id":"tool-2"}"#

        let firstResponseTask = Task {
            await AppDelegate.processSocketMessageForTesting(
                bytes: Array(firstPayload.utf8),
                hookRouter: fixture.router,
                viewModel: fixture.viewModel
            )
        }
        let secondResponseTask = Task {
            await AppDelegate.processSocketMessageForTesting(
                bytes: Array(secondPayload.utf8),
                hookRouter: fixture.router,
                viewModel: fixture.viewModel
            )
        }

        #expect(await waitUntil {
            await MainActor.run {
                fixture.viewModel.pendingInteractions.map(\.id) == ["tool-1", "tool-2"]
            }
        })

        await fixture.router.resolvePermissionFromCli(sessionId: "queue-1", toolUseId: "tool-1")

        #expect(await waitUntil {
            await MainActor.run {
                fixture.viewModel.pendingInteraction?.id == "tool-2"
                    && fixture.viewModel.pendingInteractions.map(\.id) == ["tool-2"]
            }
        })

        let firstResponse = try #require(await firstResponseTask.value)
        #expect(String(decoding: firstResponse, as: UTF8.self).contains("\"behavior\":\"allow\""))

        await fixture.router.resolvePermissionFromCli(sessionId: "queue-2", toolUseId: "tool-2")
        let secondResponse = try #require(await secondResponseTask.value)
        #expect(String(decoding: secondResponse, as: UTF8.self).contains("\"behavior\":\"allow\""))
        #expect(fixture.viewModel.pendingInteraction == nil)
    }

    @Test("CLI approval of queued tail keeps active head visible")
    @MainActor
    func cliApprovalOfQueuedTailKeepsActiveHeadVisible() async throws {
        let fixture = makeAppDelegateFixture()
        let firstPayload = #"{"hook_event_name":"PermissionRequest","session_id":"tail-1","cwd":"/repo","tool_name":"Bash","tool_use_id":"tool-1"}"#
        let secondPayload = #"{"hook_event_name":"PermissionRequest","session_id":"tail-2","cwd":"/repo","tool_name":"Edit","tool_use_id":"tool-2"}"#

        let firstResponseTask = Task {
            await AppDelegate.processSocketMessageForTesting(
                bytes: Array(firstPayload.utf8),
                hookRouter: fixture.router,
                viewModel: fixture.viewModel
            )
        }
        let secondResponseTask = Task {
            await AppDelegate.processSocketMessageForTesting(
                bytes: Array(secondPayload.utf8),
                hookRouter: fixture.router,
                viewModel: fixture.viewModel
            )
        }

        #expect(await waitUntil {
            await MainActor.run {
                fixture.viewModel.pendingInteractions.map(\.id) == ["tool-1", "tool-2"]
            }
        })

        await fixture.router.resolvePermissionFromCli(sessionId: "tail-2", toolUseId: "tool-2")

        #expect(await waitUntil {
            await MainActor.run {
                fixture.viewModel.pendingInteraction?.id == "tool-1"
                    && fixture.viewModel.pendingInteractions.map(\.id) == ["tool-1"]
            }
        })

        let secondResponse = try #require(await secondResponseTask.value)
        #expect(String(decoding: secondResponse, as: UTF8.self).contains("\"behavior\":\"allow\""))

        await fixture.router.resolvePermissionFromCli(sessionId: "tail-1", toolUseId: "tool-1")
        let firstResponse = try #require(await firstResponseTask.value)
        #expect(String(decoding: firstResponse, as: UTF8.self).contains("\"behavior\":\"allow\""))
        #expect(fixture.viewModel.pendingInteraction == nil)
    }

    // MARK: - Install/Uninstall via Installer

    @Test("Install and Uninstall via Installer with temp homeDir")
    func installAndUninstallWithTempHomeDir() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-cli-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let homeDir = tempDir.path

        try Installer.silentInstall(
            orbitCliPath: Installer.FALLBACK_ORBIT_HELPER_PATH,
            homeDir: homeDir
        )

        let state = try Installer.checkInstallState(
            orbitHelperPath: Installer.FALLBACK_ORBIT_HELPER_PATH,
            homeDir: homeDir
        )
        #expect(state == .orbitInstalled)

        try Installer.silentUninstall(force: false, homeDir: homeDir)

        let stateAfter = try Installer.checkInstallState(
            orbitHelperPath: Installer.FALLBACK_ORBIT_HELPER_PATH,
            homeDir: homeDir
        )
        #expect(stateAfter == .notInstalled)
    }

    @Test("Force uninstall cleans up even with drift")
    func forceUninstallCleansUpDrift() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-cli-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let homeDir = tempDir.path

        try Installer.silentInstall(
            orbitCliPath: Installer.FALLBACK_ORBIT_HELPER_PATH,
            homeDir: homeDir
        )

        let settingsPath = "\(homeDir)/.claude/settings.json"
        let settingsData = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        var settings = try JSONSerialization.jsonObject(with: settingsData) as! [String: Any]
        settings["statusLine"] = ["type": "command", "command": "/usr/local/bin/other-tool"]
        let modified = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try modified.write(to: URL(fileURLWithPath: settingsPath))

        let driftState = try Installer.checkInstallState(
            orbitHelperPath: Installer.FALLBACK_ORBIT_HELPER_PATH,
            homeDir: homeDir
        )
        #expect(driftState == .driftDetected)

        try Installer.silentForceInstall(
            orbitCliPath: Installer.FALLBACK_ORBIT_HELPER_PATH,
            homeDir: homeDir
        )
        try Installer.silentUninstall(force: true, homeDir: homeDir)

        let finalState = try Installer.checkInstallState(
            orbitHelperPath: Installer.FALLBACK_ORBIT_HELPER_PATH,
            homeDir: homeDir
        )
        #expect(finalState == .notInstalled)
    }
}

// MARK: - CLI Logic Mirrors (same logic as OrbitCLI, duplicated for testability)

private enum CLIResponseMode: Equatable {
    case none
    case permissionRequest
    case elicitation
}

private func expectedResponseMode(for input: String) -> CLIResponseMode {
    guard let data = input.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return .none
    }

    let eventName = (json["hook_event_name"] as? String)
        ?? (json["hookEventName"] as? String)
        ?? ""

    switch eventName {
    case "PermissionRequest":
        return .permissionRequest
    case "Elicitation", "ElicitationResult":
        return .elicitation
    default:
        return .none
    }
}

private func buildStatuslineMessage(from input: String) -> String? {
    guard let data = input.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }

    let sessionId = json["session_id"] as? String
    let contextWindow = json["context_window"] as? [String: Any]
    let cost = json["cost"] as? [String: Any]
    let modelObj = json["model"] as? [String: Any]

    let tokensIn = contextWindow?["total_input_tokens"] as? UInt64
    let tokensOut = contextWindow?["total_output_tokens"] as? UInt64
    let costUsd = cost?["total_cost_usd"] as? Double
    let model = modelObj?["id"] as? String

    let result: [String: Any] = [
        "type": "StatuslineUpdate",
        "session_id": sessionId as Any,
        "tokens_in": tokensIn as Any,
        "tokens_out": tokensOut as Any,
        "cost_usd": costUsd as Any,
        "model": model as Any,
    ]

    guard let outData = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
          let outString = String(data: outData, encoding: .utf8)
    else {
        return nil
    }

    return outString
}

// MARK: - Socket Client (same logic as SocketClient in OrbitCLI, for test use)

private func cliSocketSend(socketPath: String, payload: String, waitForResponse: Bool) -> String? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var noSigPipe: Int32 = 1
    _ = withUnsafePointer(to: &noSigPipe) {
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    let maxLength = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count < maxLength else { return nil }

    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.initializeMemory(as: UInt8.self, repeating: 0)
        raw.copyBytes(from: pathBytes)
    }

    let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
    let connectResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, addrLen)
        }
    }
    guard connectResult == 0 else { return nil }

    let line = payload + "\n"
    var offset = 0
    let lineBytes = Array(line.utf8)
    while offset < lineBytes.count {
        let n = lineBytes.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress!.advanced(by: offset), buf.count - offset)
        }
        if n > 0 { offset += n }
        else if n < 0, errno == EINTR { continue }
        else { return nil }
    }

    guard waitForResponse else { return nil }

    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n > 0 {
            buffer.append(chunk, count: n)
            if let nlIdx = buffer.firstIndex(of: 0x0A) {
                return String(decoding: buffer[..<nlIdx], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if n == 0 {
            if buffer.isEmpty { return nil }
            return String(decoding: buffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if errno == EINTR {
            continue
        } else {
            return nil
        }
    }
}

// MARK: - Helpers

private func makeUniqueSocketPath(testName: String) -> String {
    let short = testName.prefix(8)
    let unique = UUID().uuidString.prefix(8)
    return "/tmp/orb-\(short)-\(unique).sock"
}

private func waitUntil(
    timeout: TimeInterval = 2.0,
    pollIntervalNanoseconds: UInt64 = 20_000_000,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
    return await condition()
}

private actor MessageRecorder {
    private var items: [[UInt8]] = []

    func record(_ bytes: [UInt8]) { items.append(bytes) }
    func count() -> Int { items.count }

    func firstString() -> String? {
        guard let first = items.first else { return nil }
        return String(decoding: Data(first), as: UTF8.self)
    }
}

@MainActor
private func makeAppDelegateFixture() -> (router: HookRouter, viewModel: AppViewModel) {
    let sessionStore = SessionStore()
    let historyStore = HistoryStore(filePath: tempFilePath(prefix: "cli-history"))
    let debugLogger = HookDebugLogger(filePath: tempFilePath(prefix: "cli-debug"))
    let router = HookRouter(
        sessionStore: sessionStore,
        historyStore: historyStore,
        todayStats: TodayTokenStats(),
        debugLogger: debugLogger,
        todayStatsFilePath: tempFilePath(prefix: "cli-stats")
    )
    let viewModel = AppViewModel(
        sessionStore: sessionStore,
        historyStore: historyStore,
        hookRouter: router,
        onboardingManager: nil
    )
    return (router, viewModel)
}

private func tempFilePath(prefix: String) -> String {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
        .path
}
