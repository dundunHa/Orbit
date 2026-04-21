import Foundation
import Darwin

/// Thread-safe bridge for passing socket message data between the SocketServer
/// and message processors. All data flows through actor methods, completely
/// eliminating @Sendable closure parameters that suffer from Swift runtime
/// type confusion when called from Task.detached on @unchecked Sendable classes.
public actor MessageBridge {
    public static let shared = MessageBridge()

    private var pending: [UInt64: [UInt8]] = [:]
    private var responseWaiters: [UInt64: CheckedContinuation<Data?, Never>] = [:]
    private var messageWaiters: [CheckedContinuation<(UInt64, [UInt8]), Never>] = []
    private var nextId: UInt64 = 0

    public init() {}

    /// Called by SocketServer: stores message bytes, notifies a waiting processor
    /// (or queues for later pickup), then blocks until the processor delivers a response.
    public func submitAndWait(_ bytes: [UInt8]) async -> Data? {
        let id = nextId
        nextId += 1

        if !messageWaiters.isEmpty {
            let waiter = messageWaiters.removeFirst()
            waiter.resume(returning: (id, bytes))
        } else {
            pending[id] = bytes
        }

        return await withCheckedContinuation { continuation in
            responseWaiters[id] = continuation
        }
    }

    /// Called by the processor: retrieves the next pending message.
    /// Suspends if no messages are available.
    public func dequeue() async -> (id: UInt64, bytes: [UInt8]) {
        if let firstKey = pending.keys.sorted().first,
           let bytes = pending.removeValue(forKey: firstKey) {
            return (firstKey, bytes)
        }
        return await withCheckedContinuation { continuation in
            messageWaiters.append(continuation)
        }
    }

    /// Called by the processor: delivers the response for a given message ID.
    public func respond(id: UInt64, data: Data?) {
        if let continuation = responseWaiters.removeValue(forKey: id) {
            continuation.resume(returning: data)
        }
    }
}

public final class SocketServer: @unchecked Sendable {
    private let socketPath: String
    private let state = RuntimeState()
    let bridge: MessageBridge

    private var acceptTask: Task<Void, Never>?

    public init(socketPath: String, bridge: MessageBridge = .shared) {
        self.socketPath = socketPath
        self.bridge = bridge
    }

    deinit {
        let path = socketPath
        Task.detached {
            _ = unlink(path)
        }
    }

    public var connectionCount: Int {
        get async {
            await state.connectionCount
        }
    }

    public func start() async throws {
        await stop()

        let socketURL = URL(fileURLWithPath: socketPath)
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existed = FileManager.default.fileExists(atPath: socketPath)
        let unlinkResult = unlink(socketPath)
        if existed {
            OrbitDiagnostics.shared.debug(
                .launch,
                "socketServer.cleanedStaleSocket",
                metadata: ["unlinkResult": "\(unlinkResult)"]
            )
        }

        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw makePOSIXError("socket() failed")
        }

        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            setsockopt(listenFD, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        do {
            try bindUnixSocket(fd: listenFD, path: socketPath)
            guard listen(listenFD, SOMAXCONN) == 0 else {
                throw makePOSIXError("listen() failed")
            }
            // Non-blocking mode: prevent accept() from blocking cooperative threads
            let currentFlags = fcntl(listenFD, F_GETFL)
            if currentFlags >= 0 {
                _ = fcntl(listenFD, F_SETFL, currentFlags | O_NONBLOCK)
            }
        } catch {
            close(listenFD)
            throw error
        }

        await state.setListenFD(listenFD)

        acceptTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.acceptLoop()
        }
    }

    public func stop() async {
        acceptTask?.cancel()
        acceptTask = nil

        let snapshot = await state.shutdownAndSnapshot()

        if let listenFD = snapshot.listenFD {
            close(listenFD)
        }

        for fd in snapshot.clientFDs {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }

        _ = unlink(socketPath)
    }

    private func acceptLoop() async {
        while !Task.isCancelled {
            guard let listenFD = await state.listenFD else {
                return
            }

            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if Task.isCancelled {
                    return
                }

                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    continue
                }

                if errno == EINTR {
                    continue
                }

                if errno == EBADF || errno == EINVAL {
                    return
                }

                continue
            }

            // Non-blocking mode for client socket
            let clientFlags = fcntl(clientFD, F_GETFL)
            if clientFlags >= 0 {
                _ = fcntl(clientFD, F_SETFL, clientFlags | O_NONBLOCK)
            }

            var noSigPipe: Int32 = 1
            _ = withUnsafePointer(to: &noSigPipe) {
                setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
            }

            await state.addClient(clientFD)

            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.handleClient(fd: clientFD)
            }
        }
    }

    private func handleClient(fd: Int32) async {
        defer {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            Task {
                await state.removeClient(fd)
            }
        }

        var buffered = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while !Task.isCancelled {
            let readCount = read(fd, &chunk, chunk.count)
            if readCount > 0 {
                buffered.append(chunk, count: Int(readCount))

                while let newlineIndex = buffered.firstIndex(of: 0x0A) {
                    let lineData = buffered[..<newlineIndex]
                    buffered.removeSubrange(...newlineIndex)

                    guard !lineData.isEmpty else { continue }

                    // Skip lines that contain only null bytes (connection probes / keepalives)
                    if lineData.allSatisfy({ $0 == 0x00 }) { continue }

                    let bytes = [UInt8](lineData)

                    // Submit bytes to the MessageBridge actor and wait for the
                    // processor to deliver a response. Data flows exclusively
                    // through actor method parameters — no @Sendable closure
                    // parameters are involved, avoiding Swift runtime type confusion.
                    let response = await self.bridge.submitAndWait(bytes)
                    if let response {
                        guard writeAll(fd: fd, data: response + Data([0x0A])) else {
                            return
                        }
                    }
                }
                continue
            }

            if readCount == 0 {
                return
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                continue
            }

            if errno == EINTR {
                continue
            }

            return
        }
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return true
            }

            while offset < rawBuffer.count {
                let written = write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }

                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        usleep(1000) // 1ms retry for non-blocking socket
                        continue
                    }
                    return false
                }

                return false
            }

            return true
        }
    }

    private func bindUnixSocket(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < maxLength else {
            throw POSIXError(.ENAMETOOLONG)
        }

        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.copyBytes(from: pathBytes)
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length)
            }
        }

        guard bindResult == 0 else {
            throw makePOSIXError("bind() failed")
        }
    }

    private func makePOSIXError(_ message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(message): \(String(cString: strerror(errno)))"])
    }
}

private actor RuntimeState {
    private(set) var listenFD: Int32?
    private var clientFDs: Set<Int32> = []

    var connectionCount: Int {
        clientFDs.count
    }

    func setListenFD(_ fd: Int32) {
        listenFD = fd
    }

    func addClient(_ fd: Int32) {
        clientFDs.insert(fd)
    }

    func removeClient(_ fd: Int32) {
        clientFDs.remove(fd)
    }

    func shutdownAndSnapshot() -> (listenFD: Int32?, clientFDs: [Int32]) {
        let snapshot = (listenFD, Array(clientFDs))
        listenFD = nil
        clientFDs.removeAll()
        return snapshot
    }
}
