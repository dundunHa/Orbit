import Foundation

/// Content-driven expanded height management.
/// Translates the main.js scheduleExpandedHeightUpdate() pattern to Swift.
@MainActor
struct RuntimeSizingPolicy {
    /// Current expanded height (clamped).
    private(set) var expandedHeight: CGFloat

    /// Callback when height changes — OverlayController uses this to update panel frame.
    var onHeightChanged: ((CGFloat) -> Void)?

    init(defaultHeight: CGFloat? = nil) {
        self.expandedHeight = defaultHeight ?? ParityGeometry.minExpandedHeight
    }

    /// Mirrors main.js scheduleExpandedHeightUpdate().
    /// Uses ParityGeometry.computeExpandedHeight + clampExpandedHeight.
    mutating func scheduleHeightUpdate(notchHeight: CGFloat, contentScrollHeight: CGFloat) {
        let newHeight = ParityGeometry.computeExpandedHeight(
            notchHeight: notchHeight,
            contentScrollHeight: contentScrollHeight
        )
        let clamped = ParityGeometry.clampExpandedHeight(newHeight)

        // Diff-before-apply: only trigger callback if height actually changed.
        if abs(clamped - expandedHeight) > 0.5 {
            expandedHeight = clamped
            onHeightChanged?(clamped)
        }
    }

    /// Reset to default when collapsing.
    mutating func resetToDefault() {
        expandedHeight = ParityGeometry.minExpandedHeight
    }
}
