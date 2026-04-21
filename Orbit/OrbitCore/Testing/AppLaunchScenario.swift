import Foundation

enum AppLaunchScenarioError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidPendingInteractionKind(String)
    case unsupportedOnboardingState(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported scenario version: \(version)"
        case .invalidPendingInteractionKind(let kind):
            return "Unsupported pending interaction kind: \(kind)"
        case .unsupportedOnboardingState(let value):
            return "Unsupported onboarding state: \(value)"
        }
    }
}

struct AppLaunchScenario: Codable, Sendable {
    static let currentVersion = 1

    struct Seed: Codable, Sendable {
        let sessions: [Session]
        let historyEntries: [HistoryEntry]
        let selectedSessionId: String?
        let onboardingState: OnboardingFixture
        let pendingInteraction: PendingInteractionFixture?
        let todayStats: TodayTokenStats?
        let overlay: OverlayFixture?

        private enum CodingKeys: String, CodingKey {
            case sessions
            case historyEntries = "history_entries"
            case selectedSessionId = "selected_session_id"
            case onboardingState = "onboarding_state"
            case pendingInteraction = "pending_interaction"
            case todayStats = "today_stats"
            case overlay
        }
    }

    struct OverlayFixture: Codable, Sendable, Equatable {
        enum InitialIntent: String, Codable, Sendable {
            case collapsed
            case expanded
        }

        let initialIntent: InitialIntent

        private enum CodingKeys: String, CodingKey {
            case initialIntent = "initial_intent"
        }
    }

    let schemaVersion: Int
    let fixtureName: String
    let description: String
    let seed: Seed
    let expected: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case fixtureName = "fixture_name"
        case description
        case seed
        case expected
    }

    var name: String { fixtureName }
    var sessions: [Session] { seed.sessions }
    var historyEntries: [HistoryEntry] { seed.historyEntries }
    var selectedSessionId: String? { seed.selectedSessionId }
    var onboarding: OnboardingFixture { seed.onboardingState }
    var pendingInteraction: PendingInteractionFixture? { seed.pendingInteraction }
    var todayStats: TodayTokenStats? { seed.todayStats }
    var overlay: OverlayFixture? { seed.overlay }

    func validated() throws -> AppLaunchScenario {
        guard schemaVersion == Self.currentVersion else {
            throw AppLaunchScenarioError.unsupportedVersion(schemaVersion)
        }
        if let pendingInteraction,
           pendingInteraction.kind != "permission",
           pendingInteraction.kind != "elicitation"
        {
            throw AppLaunchScenarioError.invalidPendingInteractionKind(pendingInteraction.kind)
        }
        _ = try onboarding.makeState()
        return self
    }
}

struct OnboardingFixture: Codable, Sendable, Equatable {
    let type: String
    let detail: String?

    func makeState() throws -> OnboardingState {
        switch type {
        case "Welcome":
            return .welcome
        case "Checking":
            return .checking
        case "Installing":
            return .installing
        case "Connected":
            return .connected
        case "ConflictDetected":
            return .conflictDetected(detail ?? "Scenario conflict")
        case "PermissionDenied":
            return .permissionDenied
        case "DriftDetected":
            return .driftDetected
        case "Error":
            return .error(detail ?? "Scenario error")
        default:
            throw AppLaunchScenarioError.unsupportedOnboardingState(type)
        }
    }
}

struct PendingInteractionFixture: Codable, Sendable, Equatable {
    let id: String
    let kind: String
    let sessionId: String
    let toolName: String
    let toolInput: AnyCodable
    let message: String
    let requestedSchema: AnyCodable?
    let permissionSuggestions: [PermissionUpdateEntry]?

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case sessionId = "session_id"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case message
        case requestedSchema = "requested_schema"
        case permissionSuggestions = "permission_suggestions"
    }

    func makePendingInteraction() -> PendingInteraction {
        PendingInteraction(
            id: id,
            kind: kind,
            sessionId: sessionId,
            toolName: toolName,
            toolInput: toolInput,
            message: message,
            requestedSchema: requestedSchema,
            permissionSuggestions: permissionSuggestions
        )
    }
}
