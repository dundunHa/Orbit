import SwiftUI

struct OverlayPayloadSlot: View {
    @ObservedObject var viewModel: AppViewModel
    let geometry: NotchGeometry

    var body: some View {
        Group {
            if let interaction = viewModel.pendingInteraction {
                VStack(alignment: .leading, spacing: 8) {
                    if !viewModel.waitingPendingInteractions.isEmpty {
                        waitingSummaryView(viewModel.waitingPendingInteractions)
                    }
                    interactionView(for: interaction)
                        .id(interaction.id)
                }
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

    private func waitingSummaryView(_ waitingInteractions: [PendingInteraction]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(waitingInteractions.count) more waiting")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))

            HStack(spacing: 6) {
                ForEach(waitingInteractions.prefix(3), id: \.id) { interaction in
                    Text(interaction.toolName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.05))
                        .clipShape(Capsule())
                }
                if waitingInteractions.count > 3 {
                    Text("+\(waitingInteractions.count - 3)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
                Spacer()
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.03))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func interactionView(for interaction: PendingInteraction) -> some View {
        if interaction.kind == "permission" {
            PermissionView(
                toolName: interaction.toolName,
                toolInput: interaction.toolInput,
                permissionSuggestions: interaction.permissionSuggestions
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
