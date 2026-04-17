import Foundation

#if canImport(Testing) && canImport(Orbit)
import Testing
@testable import Orbit

@Suite("OverlayRuntimeSnapshot")
struct OverlayRuntimeSnapshotTests {
    private let geometry = NotchGeometry.fallback

    @Test("collapsed snapshot is stable collapsed")
    func collapsedSnapshot_isStableCollapsed() {
        let snapshot = makeSnapshot(
            phase: .collapsed,
            wantExpanded: false,
            isAnimating: false,
            collapseAfterTransition: false,
            isExpanded: false
        )

        #expect(snapshot.isStableCollapsed)
    }

    @Test("expanded snapshot is stable expanded")
    func expandedSnapshot_isStableExpanded() {
        let snapshot = makeSnapshot(
            phase: .expanded,
            wantExpanded: true,
            isAnimating: false,
            collapseAfterTransition: false,
            isExpanded: true
        )

        #expect(snapshot.isStableExpanded)
    }

    @Test("expanding snapshot reports isExpanding")
    func expandingSnapshot_reportsIsExpanding() {
        let snapshot = makeSnapshot(
            phase: .expanding,
            wantExpanded: true,
            isAnimating: true,
            collapseAfterTransition: false,
            isExpanded: false
        )

        #expect(snapshot.isExpanding)
    }

    @Test("collapsing snapshot reports isCollapsing")
    func collapsingSnapshot_reportsIsCollapsing() {
        let snapshot = makeSnapshot(
            phase: .collapsing,
            wantExpanded: false,
            isAnimating: true,
            collapseAfterTransition: true,
            isExpanded: false
        )

        #expect(snapshot.isCollapsing)
    }

    @Test("collapsed snapshot is not stable expanded")
    func collapsedSnapshot_isNotStableExpanded() {
        let snapshot = makeSnapshot(
            phase: .collapsed,
            wantExpanded: false,
            isAnimating: false,
            collapseAfterTransition: false,
            isExpanded: false
        )

        #expect(!snapshot.isStableExpanded)
    }

    @Test("expanded snapshot is not stable collapsed")
    func expandedSnapshot_isNotStableCollapsed() {
        let snapshot = makeSnapshot(
            phase: .expanded,
            wantExpanded: true,
            isAnimating: false,
            collapseAfterTransition: false,
            isExpanded: true
        )

        #expect(!snapshot.isStableCollapsed)
    }

    @Test("animating collapsed is not stable collapsed")
    func animatingCollapsed_isNotStableCollapsed() {
        let snapshot = makeSnapshot(
            phase: .collapsed,
            wantExpanded: false,
            isAnimating: true,
            collapseAfterTransition: false,
            isExpanded: false
        )

        #expect(!snapshot.isStableCollapsed)
    }

    @Test("expanding with wantExpanded=true has consistent intent")
    func expandingIntent_isConsistent() {
        let snapshot = makeSnapshot(
            phase: .expanding,
            wantExpanded: true,
            isAnimating: true,
            collapseAfterTransition: false,
            isExpanded: false
        )

        #expect(snapshot.animationIntentConsistent)
    }

    @Test("collapsing with wantExpanded=false has consistent intent")
    func collapsingIntent_isConsistent() {
        let snapshot = makeSnapshot(
            phase: .collapsing,
            wantExpanded: false,
            isAnimating: true,
            collapseAfterTransition: false,
            isExpanded: false
        )

        #expect(snapshot.animationIntentConsistent)
    }

    @Test("expanding with wantExpanded=false is inconsistent")
    func expandingWithWantExpandedFalse_isInconsistent() {
        let snapshot = makeSnapshot(
            phase: .expanding,
            wantExpanded: false,
            isAnimating: true,
            collapseAfterTransition: false,
            isExpanded: false
        )

        #expect(!snapshot.animationIntentConsistent)
    }

    @Test("identical snapshots are equal")
    func identicalSnapshots_areEqual() {
        let lhs = makeSnapshot(
            phase: .expanded,
            wantExpanded: true,
            isAnimating: false,
            collapseAfterTransition: false,
            isExpanded: true,
            expandedHeight: 220
        )
        let rhs = makeSnapshot(
            phase: .expanded,
            wantExpanded: true,
            isAnimating: false,
            collapseAfterTransition: false,
            isExpanded: true,
            expandedHeight: 220
        )

        #expect(lhs == rhs)
    }

    @Test("description contains phase name")
    func description_containsPhaseName() {
        let snapshot = makeSnapshot(
            phase: .expanded,
            wantExpanded: true,
            isAnimating: false,
            collapseAfterTransition: false,
            isExpanded: true
        )

        #expect(!snapshot.description.isEmpty)
        #expect(snapshot.description.contains("expanded"))
    }

    private func makeSnapshot(
        phase: OverlayPhase,
        wantExpanded: Bool,
        isAnimating: Bool,
        collapseAfterTransition: Bool,
        isExpanded: Bool,
        expandedHeight: CGFloat = 168
    ) -> OverlayRuntimeSnapshot {
        OverlayRuntimeSnapshot(
            phase: phase,
            wantExpanded: wantExpanded,
            isAnimating: isAnimating,
            collapseAfterTransition: collapseAfterTransition,
            isExpanded: isExpanded,
            expandedHeight: expandedHeight,
            geometry: geometry
        )
    }
}

#endif
