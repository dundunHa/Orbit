import SwiftUI

public struct StatusDotView: View {
    public let status: SessionStatus
    
    @State private var isAnimating = false
    
    public init(status: SessionStatus) {
        self.status = status
    }
    
    private var dotColor: Color {
        switch status {
        case .waitingForInput:
            return Color(hex: "#4ade80")
        case .processing, .compacting:
            return Color(hex: "#60a5fa")
        case .runningTool:
            return Color(hex: "#a78bfa")
        case .waitingForApproval:
            return Color(hex: "#f97316")
        case .anomaly:
            return Color(hex: "#facc15")
        case .ended:
            return Color(hex: "#6b7280")
        }
    }
    
    private var opacityScale: Double {
        if !isAnimating { return 1.0 }
        
        switch status {
        case .processing, .compacting, .runningTool, .waitingForApproval:
            return 0.4
        case .anomaly:
            return 0.0
        case .waitingForInput, .ended:
            return 1.0
        }
    }
    
    public var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .opacity(isAnimating ? opacityScale : 1.0)
            .onAppear {
                if let anim = animation(for: status) {
                    withAnimation(anim) {
                        isAnimating = true
                    }
                }
            }
            .onChange(of: status) { _, newStatus in
                isAnimating = false
                if let newAnim = animation(for: newStatus) {
                    DispatchQueue.main.async {
                        withAnimation(newAnim) {
                            isAnimating = true
                        }
                    }
                }
            }
    }
    
    private func animation(for status: SessionStatus) -> Animation? {
        switch status {
        case .processing, .compacting:
            return Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)
        case .runningTool:
            return Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)
        case .waitingForApproval:
            return Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)
        case .anomaly:
            return Animation.easeInOut(duration: 0.5).repeatForever(autoreverses: true)
        case .waitingForInput, .ended:
            return nil
        }
    }
}
