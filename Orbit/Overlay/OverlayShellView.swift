import SwiftUI
import Observation

enum OverlayPayloadPhase: Equatable {
    case collapsed
    case expanding
    case expanded
    case collapsing
}

@Observable
final class OverlayBridge {
    var payloadPhase: OverlayPayloadPhase = .collapsed
    var activeStatus: SessionStatus = .waitingForInput
    /// Incremented to signal that the next .expanded phase change should
    /// skip animation and snap instantly (Space-transition recovery).
    var snapExpandedEpoch: UInt64 = 0
}

struct OverlayShellView: View {
    private static let expandAnimation = Animation.timingCurve(0.18, 0.88, 0.32, 1.0, duration: 0.24)
    private static let collapseAnimation = Animation.timingCurve(0.20, 0.82, 0.24, 1.0, duration: 0.26)
    var bridge: OverlayBridge
    let geometry: NotchGeometry
    let payload: () -> AnyView

    @State private var shouldRenderPayload = false
    @State private var payloadProgress: CGFloat = 0.0
    @State private var lastSnapEpoch: UInt64 = 0

    var body: some View {
        VStack(spacing: 0) {
            PillView(status: bridge.activeStatus, geometry: geometry)
                .transaction { transaction in
                    transaction.animation = nil
                }
                .overlay(
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 0.5)
                        .opacity(separatorOpacity),
                    alignment: .bottom
                )

            if shouldRenderPayload {
                payload()
                    .opacity(payloadOpacity)
                    .offset(y: payloadOffsetY)
                    .scaleEffect(x: 1.0, y: payloadScaleY, anchor: .top)
                    .blur(radius: payloadBlurRadius)
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .clipShape(BottomRoundedRectangle(radius: 22.0))
        .onAppear {
            syncPayloadPhase(bridge.payloadPhase)
        }
        .onChange(of: bridge.payloadPhase) { _, phase in
            syncPayloadPhase(phase)
        }
    }

    private var separatorOpacity: Double {
        Double(pow(payloadProgress, 1.2))
    }

    private var payloadOpacity: Double {
        Double(pow(payloadProgress, 1.1))
    }

    private var payloadOffsetY: CGFloat {
        -14.0 * (1.0 - payloadProgress)
    }

    private var payloadScaleY: CGFloat {
        0.92 + (0.08 * payloadProgress)
    }

    private var payloadBlurRadius: CGFloat {
        (1.0 - payloadProgress) * 1.5
    }

    private func syncPayloadPhase(_ phase: OverlayPayloadPhase) {
        switch phase {
        case .collapsed:
            shouldRenderPayload = false
            payloadProgress = 0.0

        case .expanding, .expanded:
            let shouldSnap = bridge.snapExpandedEpoch != lastSnapEpoch
            if shouldSnap {
                lastSnapEpoch = bridge.snapExpandedEpoch
            }

            if !shouldRenderPayload {
                shouldRenderPayload = true
                payloadProgress = 0.0
            }
            if shouldSnap {
                // Space-transition recovery: 跳过动画，立即 snap 到展开。
                // 取消正在执行的折叠 withAnimation 并强制 payloadProgress=1.0。
                withAnimation(.linear(duration: 0)) {
                    payloadProgress = 1.0
                }
            } else {
                withAnimation(Self.expandAnimation) {
                    payloadProgress = 1.0
                }
            }

        case .collapsing:
            if !shouldRenderPayload {
                shouldRenderPayload = true
                payloadProgress = 1.0
            }
            withAnimation(Self.collapseAnimation) {
                payloadProgress = 0.0
            }
        }
    }
}
