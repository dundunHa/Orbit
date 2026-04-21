import Foundation

struct OrbitRuntimeDiagnostics: Codable, Sendable, Equatable {
    static let currentVersion = 1

    let version: Int
    let revision: Int
    let updatedAt: Date
    let scenario: ScenarioSummary?
    let overlay: OverlaySummary?
    let counts: CountsSummary
    let pendingInteraction: PendingInteractionSummary?
    let pendingQueueDepth: Int
    let selectedSessionId: String?
    let activeSessionId: String?
    let onboarding: OnboardingSummary
    let lastDecision: DecisionSummary?

    struct ScenarioSummary: Codable, Sendable, Equatable {
        let fixtureName: String
        let schemaVersion: Int
        let loadState: String
        let error: String?

        private enum CodingKeys: String, CodingKey {
            case fixtureName = "fixture_name"
            case schemaVersion = "schema_version"
            case loadState = "load_state"
            case error
        }
    }

    struct CountsSummary: Codable, Sendable, Equatable {
        let sessions: Int
        let historyEntries: Int

        private enum CodingKeys: String, CodingKey {
            case sessions
            case historyEntries = "history_entries"
        }
    }

    struct OverlaySummary: Codable, Sendable, Equatable {
        let phase: String
        let wantExpanded: Bool
        let isAnimating: Bool
        let collapseAfterTransition: Bool
        let isExpanded: Bool
        let expandedHeight: CGFloat

        private enum CodingKeys: String, CodingKey {
            case phase
            case wantExpanded = "want_expanded"
            case isAnimating = "is_animating"
            case collapseAfterTransition = "collapse_after_transition"
            case isExpanded = "is_expanded"
            case expandedHeight = "expanded_height"
        }
    }

    struct PendingInteractionSummary: Codable, Sendable, Equatable {
        let id: String
        let kind: String
        let sessionId: String
        let toolName: String
        let message: String

        private enum CodingKeys: String, CodingKey {
            case id
            case kind
            case sessionId = "session_id"
            case toolName = "tool_name"
            case message
        }
    }

    struct DecisionSummary: Codable, Sendable, Equatable {
        let requestId: String
        let decision: String
        let reason: String?
        let timestamp: Date

        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case decision
            case reason
            case timestamp
        }
    }

    struct OnboardingSummary: Codable, Sendable, Equatable {
        let typeName: String
        let statusText: String
        let trayStatus: String
        let trayEmoji: String
        let needsAttention: Bool
        let isComplete: Bool
        let canRetry: Bool

        private enum CodingKeys: String, CodingKey {
            case typeName = "type"
            case statusText = "status_text"
            case trayStatus = "tray_status"
            case trayEmoji = "tray_emoji"
            case needsAttention = "needs_attention"
            case isComplete = "is_complete"
            case canRetry = "can_retry"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case revision
        case updatedAt = "updated_at"
        case scenario
        case overlay
        case counts
        case pendingInteraction = "pending_interaction"
        case pendingQueueDepth = "pending_queue_depth"
        case selectedSessionId = "selected_session_id"
        case activeSessionId = "active_session_id"
        case onboarding
        case lastDecision = "last_decision"
    }
}
