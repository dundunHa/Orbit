import Foundation

public actor SessionStore {
    public private(set) var sessions: [String: Session] = [:]

    public init() {}

    public func getSession(_ id: String) -> Session? {
        sessions[id]
    }

    public func upsertSession(_ id: String, updater: (inout Session) -> Void) -> Session {
        var session = sessions[id] ?? Session(
            id: id,
            cwd: "",
            status: .waitingForInput,
            startedAt: Date(),
            lastEventAt: Date()
        )
        updater(&session)
        sessions[id] = session
        return session
    }

    public func allSessions() -> [String: Session] {
        sessions
    }

    public func removeSession(_ id: String) {
        sessions.removeValue(forKey: id)
    }
}
