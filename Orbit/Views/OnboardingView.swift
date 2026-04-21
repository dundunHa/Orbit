import SwiftUI

public struct OnboardingView: View {
    public let state: OnboardingState
    public let isRetrying: Bool
    public let onRetry: () -> Void
    
    public init(state: OnboardingState, isRetrying: Bool, onRetry: @escaping () -> Void) {
        self.state = state
        self.isRetrying = isRetrying
        self.onRetry = onRetry
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Setup")
                .font(.system(size: 10, weight: .regular))
                .textCase(.uppercase)
                .foregroundColor(Color.white.opacity(0.3))
            
            HStack(spacing: 8) {
                statusDot
                
                iconView
                
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.78))
                    .lineSpacing(4.4)
                    .accessibilityIdentifier(OrbitAccessibilityID.Onboarding.statusText)
                
                Spacer()
            }
            .accessibilityIdentifier(OrbitAccessibilityID.Onboarding.state(state))
            
            if canRetry {
                Button(action: onRetry) {
                    Text("Retry")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#08111f"))
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .background(Color(hex: "#60a5fa"))
                        .cornerRadius(8)
                }
                .accessibilityIdentifier(OrbitAccessibilityID.Onboarding.retryButton)
                .buttonStyle(.plain)
                .disabled(isRetrying)
                .opacity(isRetrying ? 0.5 : 1.0)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(OrbitAccessibilityID.Onboarding.root)
    }
    
    @ViewBuilder
    private var iconView: some View {
        switch state {
        case .welcome:
            Text("✨").font(.system(size: 11))
        case .checking, .installing:
            ProgressView()
                .controlSize(.small)
        case .connected:
            Text("✅").font(.system(size: 11))
        case .conflictDetected, .driftDetected:
            Text("⚠️").font(.system(size: 11))
        case .permissionDenied:
            Text("🔒").font(.system(size: 11))
        case .error:
            Text("❌").font(.system(size: 11))
        }
    }
    
    private var statusText: String {
        switch state {
        case .welcome:
            return "Welcome to Orbit"
        case .checking:
            return "Checking Claude Code configuration..."
        case .installing:
            return "Connecting Orbit to Claude Code..."
        case .connected:
            return "Connected to Claude Code"
        case .conflictDetected:
            return "Configuration conflict detected"
        case .permissionDenied:
            return "Permission required"
        case .driftDetected:
            return "Configuration drift detected"
        case .error(let msg):
            return "Orbit setup failed: \(msg)"
        }
    }
    
    private var canRetry: Bool {
        switch state {
        case .welcome, .checking, .installing, .connected:
            return false
        case .conflictDetected, .permissionDenied, .driftDetected, .error:
            return true
        }
    }
    
    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
    }
    
    private var dotColor: Color {
        switch state {
        case .welcome, .checking:
            return Color(hex: "#60a5fa")
        case .installing:
            return Color(hex: "#a78bfa")
        case .connected:
            return Color(hex: "#4ade80")
        case .conflictDetected, .driftDetected:
            return Color(hex: "#facc15")
        case .permissionDenied:
            return Color(hex: "#f97316")
        case .error:
            return Color(hex: "#f87171")
        }
    }
}
