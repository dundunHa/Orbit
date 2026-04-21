import SwiftUI

public struct PillView: View {
    public let status: SessionStatus
    public let geometry: NotchGeometry

    @State private var isBreathing = false
    @State private var isAlertBobbing = false
    
    public init(status: SessionStatus, geometry: NotchGeometry) {
        self.status = status
        self.geometry = geometry
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            HStack {
                ClaudeMascotView(status: status, isBreathing: isBreathing, isAlertBobbing: isAlertBobbing)
                    .padding(.leading, 6)
                Spacer()
            }
            .frame(width: geometry.leftZoneWidth)
            
            Spacer()
                .frame(width: geometry.notchWidth)
            
            HStack(spacing: 6) {
                Spacer()
                StatusDotView(status: status)
                    .accessibilityIdentifier(OrbitAccessibilityID.Pill.statusDot)
            }
            .padding(.trailing, 14)
            .frame(width: geometry.rightZoneWidth)
        }
        .frame(height: geometry.hasNotch ? geometry.notchHeight : 28.0)
        .background(
            Color.black
                .clipShape(BottomRoundedRectangle(radius: 22.0))
        )
        .accessibilityIdentifier(OrbitAccessibilityID.Pill.root)
        .onAppear {
            updateAnimations()
        }
        .onChange(of: status) { _, _ in
            updateAnimations()
        }
    }
    
    private func updateAnimations() {
        switch status {
        case .processing, .runningTool, .compacting:
            withAnimation(Animation.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                isBreathing = true
                isAlertBobbing = false
            }
        case .waitingForApproval:
            withAnimation(Animation.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                isAlertBobbing = true
                isBreathing = false
            }
        default:
            withAnimation {
                isBreathing = false
                isAlertBobbing = false
            }
        }
    }
}

struct ClaudeMascotView: View {
    let status: SessionStatus
    let isBreathing: Bool
    let isAlertBobbing: Bool
    
    private var scaleOffset: CGFloat {
        if isBreathing { return 1.03 }
        return 1.0
    }
    
    private var yOffset: CGFloat {
        if isBreathing { return -0.5 }
        if isAlertBobbing { return -0.6 }
        return 0.0
    }
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: "#d78787"))
                .frame(width: 22, height: 11)
            
            HStack(spacing: 4) {
                Rectangle()
                    .fill(Color(hex: "#000000"))
                    .frame(width: 4, height: 4)
                Rectangle()
                    .fill(Color(hex: "#000000"))
                    .frame(width: 4, height: 4)
            }
        }
        .frame(width: 28, height: 18)
        .opacity(0.96)
        .scaleEffect(scaleOffset)
        .offset(y: yOffset)
        .accessibilityIdentifier(OrbitAccessibilityID.Pill.mascot)
    }
}
