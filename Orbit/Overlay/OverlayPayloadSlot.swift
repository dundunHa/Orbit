import SwiftUI

struct OverlayPayloadSlot: View {
    @ObservedObject var viewModel: AppViewModel
    let geometry: NotchGeometry

    var body: some View {
        Group {
            if let interaction = viewModel.pendingInteraction {
                interactionView(for: interaction)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
            } else if shouldShowOnboarding {
                OnboardingView(
                    state: viewModel.onboardingState,
                    isRetrying: viewModel.onboardingState == .installing,
                    onRetry: {
                        viewModel.retryOnboardingInstall()
                    }
                )
                .padding(.top, 8)
                .padding(.bottom, 16)
            } else {
                ExpandedView(
                    sessions: sortedSessions,
                    historyEntries: viewModel.historyEntries,
                    selectedSessionId: viewModel.selectedSessionId,
                    geometry: geometry
                )
            }
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func interactionView(for interaction: PendingInteraction) -> some View {
        if interaction.kind == "permission" {
            PermissionView(
                toolName: interaction.toolName,
                toolInput: interaction.toolInput
            ) { decision in
                viewModel.handlePermissionDecision(decision)
            }
        } else {
            ElicitationView(
                message: interaction.message,
                requestedSchema: interaction.requestedSchema
            ) { decision in
                viewModel.handlePermissionDecision(decision)
            }
        }
    }

    private var shouldShowOnboarding: Bool {
        viewModel.onboardingState != .connected && liveSessions.isEmpty
    }

    private var sortedSessions: [Session] {
        viewModel.sessions.values.sorted { lhs, rhs in
            lhs.lastEventAt > rhs.lastEventAt
        }
    }

    private var liveSessions: [Session] {
        viewModel.sessions.values.filter {
            if case .ended = $0.status {
                return false
            }
            return true
        }
    }
}
