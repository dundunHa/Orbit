import Foundation

public struct SessionSnapshot: Sendable, Equatable {
    public let id: String
    public let status: SessionStatusSnapshot
    public let lastEventAt: Date

    public init(id: String, status: SessionStatusSnapshot, lastEventAt: Date) {
        self.id = id
        self.status = status
        self.lastEventAt = lastEventAt
    }
}

public indirect enum SessionStatusSnapshot: Sendable, Equatable {
    case processing
    case runningTool(toolName: String)
    case anomaly(idleSeconds: UInt64, previousStatus: SessionStatusSnapshot)
    case other
}

public actor AnomalyDetector {
    public typealias TimeSource = @Sendable () -> Date

    private let threshold: TimeInterval
    private let pollInterval: TimeInterval
    private let now: TimeSource
    private var pollTask: Task<Void, Never>?
    private var trackedAnomalies: [String: SessionStatusSnapshot] = [:]

    public init(
        threshold: TimeInterval = 60.0,
        pollInterval: TimeInterval = 5.0,
        now: @escaping TimeSource = { Date() }
    ) {
        self.threshold = threshold
        self.pollInterval = pollInterval
        self.now = now
    }

    public func start(
        sessions: @escaping @Sendable () async -> [String: SessionSnapshot],
        onChange: @escaping @Sendable (String, SessionStatusSnapshot) async -> Void
    ) async {
        pollTask?.cancel()
        trackedAnomalies.removeAll()

        pollTask = Task { [threshold, pollInterval, now] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.nanoseconds(for: pollInterval))
                } catch {
                    break
                }

                if Task.isCancelled {
                    break
                }

                let snapshots = await sessions()
                for (sessionId, snapshot) in snapshots {
                    if Task.isCancelled {
                        break
                    }

                    await self.handle(snapshot: snapshot, sessionId: sessionId, threshold: threshold, now: now(), onChange: onChange)
                }
            }
        }
    }

    public func stop() async {
        pollTask?.cancel()
        pollTask = nil
        trackedAnomalies.removeAll()
    }

    private func handle(
        snapshot: SessionSnapshot,
        sessionId: String,
        threshold: TimeInterval,
        now: Date,
        onChange: @escaping @Sendable (String, SessionStatusSnapshot) async -> Void
    ) async {
        let elapsed = max(0, now.timeIntervalSince(snapshot.lastEventAt))
        let idleSeconds = UInt64(elapsed.rounded(.down))

        switch snapshot.status {
        case .anomaly(_, let previousStatus):
            let updated = SessionStatusSnapshot.anomaly(idleSeconds: idleSeconds, previousStatus: previousStatus)
            trackedAnomalies[sessionId] = updated
            await onChange(sessionId, updated)

        case .processing, .runningTool:
            if elapsed >= threshold {
                let previousStatus: SessionStatusSnapshot
                if case .anomaly(_, let cachedPreviousStatus)? = trackedAnomalies[sessionId] {
                    previousStatus = cachedPreviousStatus
                } else {
                    previousStatus = snapshot.status
                }

                let updated = SessionStatusSnapshot.anomaly(idleSeconds: idleSeconds, previousStatus: previousStatus)
                trackedAnomalies[sessionId] = updated
                await onChange(sessionId, updated)
            } else {
                trackedAnomalies.removeValue(forKey: sessionId)
            }

        case .other:
            trackedAnomalies.removeValue(forKey: sessionId)
        }
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        UInt64(max(0, interval) * 1_000_000_000)
    }
}
