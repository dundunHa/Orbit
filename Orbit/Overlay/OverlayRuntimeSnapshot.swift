import Foundation

/// A point-in-time snapshot of all overlay runtime state.
/// Used for testing, debugging, and runtime parity assertions.
struct OverlayRuntimeSnapshot: Equatable, Sendable, CustomStringConvertible {
    let phase: OverlayPhase
    let wantExpanded: Bool
    let isAnimating: Bool
    let collapseAfterTransition: Bool
    let isExpanded: Bool
    let expandedHeight: CGFloat
    let geometry: NotchGeometry

    var description: String {
        """
        OverlayRuntimeSnapshot(
          phase: \(phase),
          wantExpanded: \(wantExpanded),
          isAnimating: \(isAnimating),
          collapseAfterTransition: \(collapseAfterTransition),
          isExpanded: \(isExpanded),
          expandedHeight: \(expandedHeight),
          geometry: NotchGeometry(screenWidth: \(geometry.screenWidth), notchHeight: \(geometry.notchHeight))
        )
        """
    }

    // MARK: - Parity invariants

    /// Orbitbak parity: collapsed state has no animation
    var isStableCollapsed: Bool {
        phase == .collapsed && !isAnimating && !wantExpanded && !collapseAfterTransition
    }

    /// Orbitbak parity: expanded state has no animation
    var isStableExpanded: Bool {
        phase == .expanded && !isAnimating && wantExpanded && !collapseAfterTransition && isExpanded
    }

    /// Orbitbak parity: expanding means native window is opening
    var isExpanding: Bool {
        phase == .expanding && isAnimating
    }

    /// Orbitbak parity: collapsing means content is shrinking
    var isCollapsing: Bool {
        phase == .collapsing && isAnimating
    }

    /// Orbitbak parity: during animation, intent should be consistent
    var animationIntentConsistent: Bool {
        if isAnimating {
            if phase == .expanding {
                return wantExpanded
            }

            if phase == .collapsing {
                return !wantExpanded || collapseAfterTransition
            }
        }

        return true
    }

    static func == (lhs: OverlayRuntimeSnapshot, rhs: OverlayRuntimeSnapshot) -> Bool {
        lhs.phase == rhs.phase
            && lhs.wantExpanded == rhs.wantExpanded
            && lhs.isAnimating == rhs.isAnimating
            && lhs.collapseAfterTransition == rhs.collapseAfterTransition
            && lhs.isExpanded == rhs.isExpanded
            && lhs.expandedHeight == rhs.expandedHeight
            && lhs.geometry.notchHeight == rhs.geometry.notchHeight
            && lhs.geometry.screenWidth == rhs.geometry.screenWidth
            && lhs.geometry.notchLeft == rhs.geometry.notchLeft
            && lhs.geometry.notchRight == rhs.geometry.notchRight
            && lhs.geometry.notchWidth == rhs.geometry.notchWidth
            && lhs.geometry.leftSafeWidth == rhs.geometry.leftSafeWidth
            && lhs.geometry.rightSafeWidth == rhs.geometry.rightSafeWidth
            && lhs.geometry.leftZoneWidth == rhs.geometry.leftZoneWidth
            && lhs.geometry.rightZoneWidth == rhs.geometry.rightZoneWidth
    }
}

extension OverlayController {
    var snapshot: OverlayRuntimeSnapshot {
        OverlayRuntimeSnapshot(
            phase: stateMachine.phase,
            wantExpanded: stateMachine.wantExpanded,
            isAnimating: stateMachine.isAnimating,
            collapseAfterTransition: stateMachine.collapseAfterTransition,
            isExpanded: isExpanded,
            expandedHeight: runtimeExpandedHeight,
            geometry: runtimeGeometry
        )
    }
}
