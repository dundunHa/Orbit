import Foundation

extension OrbitAccessibilityID.Onboarding {
    public static func state(_ state: OnboardingState) -> String {
        OrbitAccessibilityID.Onboarding.state(key: state.accessibilityKey)
    }
}

private extension OnboardingState {
    var accessibilityKey: String {
        switch self {
        case .welcome:
            return "welcome"
        case .checking:
            return "checking"
        case .installing:
            return "installing"
        case .connected:
            return "connected"
        case .conflictDetected:
            return "conflict-detected"
        case .permissionDenied:
            return "permission-denied"
        case .driftDetected:
            return "drift-detected"
        case .error:
            return "error"
        }
    }
}
