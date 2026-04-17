import Foundation
@preconcurrency import Network
import Testing
@testable import Orbit

@Suite("SocketServer")
struct SocketServerTests {
    @Test("server starts and stops")
    func testServerStartsAndStops() async throws {
        let socketPath = makeUniqueSocketPath(testName: "start-stop")
        let server = SocketServer(socketPath: socketPath, bridge: MessageBridge())

        try await server.start()
        #expect(await waitUntil { FileManager.default.fileExists(atPath: socketPath) })

        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test("server accepts a connection and receives one JSONL message")
    func testServerAcceptsConnection() async throws {
        let socketPath = makeUniqueSocketPath(testName: "accept")
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

        _ = try await connectAndSend(
            socketPath: socketPath,
            message: #"{"type":"hook","value":1}"#,
            expectResponse: false
        )

        #expect(await waitUntil { await recorder.count() == 1 })
        let received = await recorder.firstString() ?? ""
        #expect(received == #"{"type":"hook","value":1}"#)

        await server.stop()
    }

    @Test("connection count tracks open and closed connections")
    func testConnectionCountTracking() async throws {
        let socketPath = makeUniqueSocketPath(testName: "count")
        let bridge = MessageBridge()
        let server = SocketServer(socketPath: socketPath, bridge: bridge)

        // Processor that responds immediately (needed so connections don't hang)
        let processor = Task {
            while !Task.isCancelled {
                let (id, _) = await bridge.dequeue()
                await bridge.respond(id: id, data: nil)
            }
        }
        defer { processor.cancel() }

        try await server.start()
        #expect(await waitUntil { FileManager.default.fileExists(atPath: socketPath) })

        let first = try await connectClient(socketPath: socketPath)
        let second = try await connectClient(socketPath: socketPath)

        #expect(await waitUntil { await server.connectionCount == 2 })

        first.cancel()
        second.cancel()

        #expect(await waitUntil { await server.connectionCount == 0 })

        await server.stop()
    }

    @Test("request/response roundtrip over one JSONL line")
    func testRequestResponseRoundtrip() async throws {
        let socketPath = makeUniqueSocketPath(testName: "roundtrip")
        let bridge = MessageBridge()
        let server = SocketServer(socketPath: socketPath, bridge: bridge)

        let processor = Task {
            while !Task.isCancelled {
                let (id, bytes) = await bridge.dequeue()
                let request = String(decoding: Data(bytes), as: UTF8.self)
                if request == #"{"event":"permission"}"# {
                    await bridge.respond(id: id, data: Data(#"{"decision":"allow"}"#.utf8))
                } else {
                    await bridge.respond(id: id, data: Data(#"{"decision":"deny"}"#.utf8))
                }
            }
        }
        defer { processor.cancel() }

        try await server.start()
        #expect(await waitUntil { FileManager.default.fileExists(atPath: socketPath) })

        let response = try await connectAndSend(
            socketPath: socketPath,
            message: #"{"event":"permission"}"#,
            expectResponse: true
        )

        #expect(response == #"{"decision":"allow"}"#)

        await server.stop()
    }

    @Test("stop removes socket file")
    func testServerCleansUpSocketOnStop() async throws {
        let socketPath = makeUniqueSocketPath(testName: "cleanup")
        let server = SocketServer(socketPath: socketPath, bridge: MessageBridge())

        try await server.start()
        #expect(await waitUntil { FileManager.default.fileExists(atPath: socketPath) })

        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    private func connectAndSend(socketPath: String, message: String, expectResponse: Bool) async throws -> String? {
        let connection = try await connectClient(socketPath: socketPath)
        defer { connection.cancel() }

        try await sendLine(message, over: connection)

        guard expectResponse else {
            return nil
        }

        return try await receiveLine(from: connection)
    }

    private func connectClient(socketPath: String) async throws -> NWConnection {
        let connection = NWConnection(to: .unix(path: socketPath), using: NWParameters(tls: nil))
        let state = ConnectionStateProbe()

        connection.stateUpdateHandler = { newState in
            Task { await state.capture(newState) }
        }

        connection.start(queue: DispatchQueue(label: "orbit.tests.socket-client.\(UUID().uuidString)"))

        let becameReady = await waitUntil {
            await state.isReady
        }

        if becameReady {
            return connection
        }

        if let failure = await state.failureMessage {
            throw SocketTestError.connectionFailed(failure)
        }

        throw SocketTestError.timeout("connection did not become ready")
    }

    private func sendLine(_ line: String, over connection: NWConnection) async throws {
        let payload = Data((line + "\n").utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: SocketTestError.connectionFailed(error.localizedDescription))
                    return
                }
                continuation.resume()
            })
        }
    }

    private func receiveLine(from connection: NWConnection) async throws -> String {
        var buffer = Data()

        while true {
            let chunk = try await receiveChunk(from: connection)

            if let content = chunk.data, !content.isEmpty {
                buffer.append(content)

                if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[..<newlineIndex]
                    return String(decoding: lineData, as: UTF8.self)
                }
            }

            if chunk.isComplete {
                throw SocketTestError.connectionFailed("connection closed before newline response")
            }
        }
    }

    private func receiveChunk(from connection: NWConnection) async throws -> (data: Data?, isComplete: Bool) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: SocketTestError.connectionFailed(error.localizedDescription))
                    return
                }
                continuation.resume(returning: (data, isComplete))
            }
        }
    }

    private func makeUniqueSocketPath(testName: String) -> String {
        // Unix domain socket paths are limited to ~104 bytes on macOS.
        // Use /tmp directly with a short name to stay within the limit.
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
            if await condition() {
                return true
            }

            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        return await condition()
    }
}

private actor MessageRecorder {
    private var items: [[UInt8]] = []

    func record(_ bytes: [UInt8]) {
        items.append(bytes)
    }

    func count() -> Int {
        items.count
    }

    func firstString() -> String? {
        guard let first = items.first else {
            return nil
        }
        return String(decoding: Data(first), as: UTF8.self)
    }
}

private actor ConnectionStateProbe {
    private var ready = false
    private var failure: String?

    var isReady: Bool {
        ready
    }

    var failureMessage: String? {
        failure
    }

    func capture(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready = true
        case .failed(let error):
            failure = error.localizedDescription
        case .cancelled:
            if !ready && failure == nil {
                failure = "cancelled"
            }
        default:
            break
        }
    }
}

private enum SocketTestError: Error {
    case timeout(String)
    case connectionFailed(String)
}
