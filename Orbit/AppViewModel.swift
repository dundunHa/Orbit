import Combine
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var sessions: [String: Session] = [:]
    @Published var historyEntries: [HistoryEntry] = []
    @Published var selectedSessionId: String?
    @Published var onboardingState: OnboardingState = .welcome
    @Published var pendingInteraction: PendingInteraction? {
        didSet {
            onPendingInteractionChanged?()
        }
    }
    @Published var todayStats: TodayTokenStats = .init()
    @Published var isConnected: Bool = false

    private let sessionStore: SessionStore
    private let historyStore: HistoryStore
    private let hookRouter: HookRouter
    private let onboardingManager: OnboardingManager?

    var onRetryOnboarding: (() -> Void)?
    var onPendingInteractionChanged: (() -> Void)?

    init(
        sessionStore: SessionStore,
        historyStore: HistoryStore,
        hookRouter: HookRouter,
        onboardingManager: OnboardingManager? = nil,
        initialTodayStats: TodayTokenStats = .init(),
        initialOnboardingState: OnboardingState = .welcome
    ) {
        self.sessionStore = sessionStore
        self.historyStore = historyStore
        self.hookRouter = hookRouter
        self.onboardingManager = onboardingManager
        self.todayStats = initialTodayStats
        self.onboardingState = initialOnboardingState
    }

    func refreshSessions() {
        Task {
            let all = await sessionStore.allSessions()
            await MainActor.run {
                self.sessions = all
                if let selectedSessionId,
                   all[selectedSessionId] == nil {
                    self.selectedSessionId = self.activeSession()?.id
                } else if self.selectedSessionId == nil {
                    self.selectedSessionId = self.activeSession()?.id
                }
            }
        }
    }

    func refreshHistory() {
        Task {
            let entries = await historyStore.loadAll()
            await MainActor.run {
                self.historyEntries = entries.sorted { $0.endedAt > $1.endedAt }
            }
        }
    }

    func handlePermissionDecision(_ decision: PermissionDecision) {
        guard let pending = pendingInteraction else { return }
        pendingInteraction = nil

        Task {
            await hookRouter.resolvePermission(requestId: pending.id, decision: decision)
            await MainActor.run {
                self.refreshSessions()
            }
        }
    }

    func activeSession() -> Session? {
        sessions.values.max { lhs, rhs in
            let lPriority = statusPriority(lhs.status)
            let rPriority = statusPriority(rhs.status)
            if lPriority == rPriority {
                return lhs.lastEventAt < rhs.lastEventAt
            }
            return lPriority < rPriority
        }
    }

    func refreshOnboardingState() {
        if let onboardingManager {
            onboardingState = onboardingManager.state
        }
    }

    func retryOnboardingInstall() {
        if let onRetryOnboarding {
            onRetryOnboarding()
            return
        }

        guard let onboardingManager else { return }
        onboardingManager.retryInstall()
        onboardingState = onboardingManager.state
    }

    private func statusPriority(_ status: SessionStatus) -> Int {
        switch status {
        case .waitingForApproval:
            return 6
        case .anomaly:
            return 5
        case .runningTool:
            return 4
        case .processing:
            return 3
        case .compacting:
            return 2
        case .waitingForInput:
            return 1
        case .ended:
            return 0
        }
    }
}
