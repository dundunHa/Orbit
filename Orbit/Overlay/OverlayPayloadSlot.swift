import SwiftUI

private struct OverlayPayloadHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension View {
    func reportOverlayPayloadHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: OverlayPayloadHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        )
        .onPreferenceChange(OverlayPayloadHeightPreferenceKey.self) { height in
            guard height > 0.5 else { return }
            onChange(height)
        }
    }
}

private let kPermissionPayloadHeightFloor: CGFloat = 248

struct OverlayPayloadSlot: View {
    @ObservedObject var viewModel: AppViewModel
    let geometry: NotchGeometry
    let onContentHeightChange: (CGFloat) -> Void

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
                    .padding(.top, interaction.kind == "permission" ? 6 : 8)
                    // 给最外层 shell 预留更多底部留白，让已有的底部圆角更容易被看见。
                    .padding(.bottom, interaction.kind == "permission" ? 16 : 24)
                    .onAppear {
                        guard interaction.kind == "permission" else { return }
                        onContentHeightChange(kPermissionPayloadHeightFloor)
                    }
                    .reportOverlayPayloadHeight { height in
                        if interaction.kind == "permission" {
                            onContentHeightChange(max(height, kPermissionPayloadHeightFloor))
                        } else {
                            onContentHeightChange(height)
                        }
                    }
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
                .reportOverlayPayloadHeight(onContentHeightChange)
            } else {
                ExpandedView(
                    sessions: sortedSessions,
                    historyEntries: viewModel.historyEntries,
                    selectedSessionId: viewModel.selectedSessionId,
                    geometry: geometry
                )
                .onAppear {
                    onContentHeightChange(0)
                }
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
                message: interaction.message,
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
