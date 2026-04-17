import Foundation

#if canImport(Testing) && canImport(Orbit)
import Testing
@testable import Orbit

@Suite("OverlayStateMachine")
@MainActor
struct OverlayStateMachineTests {
    @Test("requestExpand_whenCollapsed_beginsExpanding")
    func requestExpand_whenCollapsed_beginsExpanding() {
        let machine = OverlayStateMachine()

        machine.requestExpand()

        #expect(machine.wantExpanded)
        #expect(machine.isAnimating)
        #expect(machine.phase == .expanding)
    }

    @Test("requestExpand_whenAlreadyExpanded_isNoOp")
    func requestExpand_whenAlreadyExpanded_isNoOp() {
        let machine = OverlayStateMachine()
        var nativeCount = 0
        var contentCount = 0
        machine.onExpandNativeWindow = { nativeCount += 1 }
        machine.onSetExpandedContent = { contentCount += 1 }

        machine.requestExpand()
        machine.transitionDidEnd()
        #expect(machine.phase == .expanded)

        machine.requestExpand()

        #expect(machine.phase == .expanded)
        #expect(machine.wantExpanded)
        #expect(!machine.isAnimating)
        #expect(nativeCount == 1)
        #expect(contentCount == 1)
    }

    @Test("requestExpand_duringAnimation_setsWantExpandedOnly")
    func requestExpand_duringAnimation_setsWantExpandedOnly() {
        let machine = OverlayStateMachine()
        var nativeCount = 0
        machine.onExpandNativeWindow = { nativeCount += 1 }

        machine.requestExpand()
        machine.scheduleCollapse()
        machine.requestExpand()

        #expect(machine.wantExpanded)
        #expect(machine.isAnimating)
        #expect(machine.phase == .expanding)
        #expect(nativeCount == 1)
    }

    @Test("requestExpand_clearsCollapseDebounce")
    func requestExpand_clearsCollapseDebounce() async {
        let machine = OverlayStateMachine()
        machine.requestExpand()
        machine.transitionDidEnd()
        #expect(machine.phase == .expanded)

        machine.scheduleCollapse()
        machine.requestExpand()
        try? await Task.sleep(nanoseconds: 260_000_000)

        #expect(machine.phase == .expanded)
        #expect(machine.wantExpanded)
    }

    @Test("scheduleCollapse_afterDelay_collapsesWhenNoInteractions")
    func scheduleCollapse_afterDelay_collapsesWhenNoInteractions() async {
        let machine = OverlayStateMachine()
        machine.hasPendingInteractions = { false }
        machine.requestExpand()
        machine.transitionDidEnd()

        machine.scheduleCollapse()
        try? await Task.sleep(nanoseconds: 260_000_000)

        #expect(machine.phase == .collapsing)
        #expect(!machine.wantExpanded)
        #expect(machine.isAnimating)
    }

    @Test("scheduleCollapse_cancelledByRequestExpand")
    func scheduleCollapse_cancelledByRequestExpand() async {
        let machine = OverlayStateMachine()
        machine.hasPendingInteractions = { false }
        machine.requestExpand()
        machine.transitionDidEnd()

        machine.scheduleCollapse()
        machine.requestExpand()
        try? await Task.sleep(nanoseconds: 260_000_000)

        #expect(machine.phase == .expanded)
        #expect(machine.wantExpanded)
        #expect(!machine.isAnimating)
    }

    @Test("scheduleCollapse_blockedByPendingInteraction")
    func scheduleCollapse_blockedByPendingInteraction() async {
        let machine = OverlayStateMachine()
        machine.hasPendingInteractions = { true }
        machine.requestExpand()
        machine.transitionDidEnd()

        machine.scheduleCollapse()
        try? await Task.sleep(nanoseconds: 260_000_000)

        #expect(machine.phase == .expanded)
        #expect(machine.wantExpanded)
        #expect(!machine.isAnimating)
    }

    @Test("transitionDidEnd_withCollapseAfterTransition_finishesCollapse")
    func transitionDidEnd_withCollapseAfterTransition_finishesCollapse() {
        let machine = OverlayStateMachine()
        machine.hasPendingInteractions = { false }
        machine.requestExpand()
        machine.transitionDidEnd()
        machine.scheduleCollapse()

        RunLoop.main.run(until: Date().addingTimeInterval(0.26))
        #expect(machine.phase == .collapsing)

        machine.transitionDidEnd()

        #expect(machine.phase == .collapsed)
        #expect(!machine.isAnimating)
    }

    @Test("transitionDidEnd_reconciles_wantExpandedTrue")
    func transitionDidEnd_reconciles_wantExpandedTrue() {
        let machine = OverlayStateMachine()
        machine.requestExpand()

        machine.transitionDidEnd()

        #expect(machine.phase == .expanded)
        #expect(machine.wantExpanded)
        #expect(!machine.isAnimating)
    }

    @Test("transitionDidEnd_reconciles_wantExpandedFalse")
    func transitionDidEnd_reconciles_wantExpandedFalse() {
        let machine = OverlayStateMachine()
        machine.hasPendingInteractions = { false }
        machine.requestExpand()
        machine.transitionDidEnd()
        machine.scheduleCollapse()

        RunLoop.main.run(until: Date().addingTimeInterval(0.26))
        machine.transitionDidEnd()

        #expect(machine.phase == .collapsed)
        #expect(!machine.wantExpanded)
        #expect(!machine.isAnimating)
    }

    @Test("expandIsland_elevatorOrder_nativeFirst")
    func expandIsland_elevatorOrder_nativeFirst() {
        let machine = OverlayStateMachine()
        var events: [String] = []
        machine.onExpandNativeWindow = { events.append("native") }
        machine.onSetExpandedContent = { events.append("content") }

        machine.requestExpand()

        #expect(events == ["native", "content"])
    }

    @Test("collapseIsland_elevatorOrder_contentFirst")
    func collapseIsland_elevatorOrder_contentFirst() {
        let machine = OverlayStateMachine()
        var events: [String] = []
        machine.hasPendingInteractions = { false }
        machine.onSetCollapsedContent = { events.append("content") }
        machine.onCollapseNativeWindow = { events.append("native") }

        machine.requestExpand()
        machine.transitionDidEnd()
        machine.scheduleCollapse()
        RunLoop.main.run(until: Date().addingTimeInterval(0.26))
        machine.transitionDidEnd()

        #expect(events == ["content", "native"])
    }

    @Test("animationFallbackTimer_firesIfTransitionStalls")
    func animationFallbackTimer_firesIfTransitionStalls() async {
        let machine = OverlayStateMachine()

        machine.requestExpand()
        #expect(machine.phase == .expanding)

        try? await Task.sleep(nanoseconds: 420_000_000)

        #expect(machine.phase == .expanded)
        #expect(!machine.isAnimating)
    }

    @Test("interactionResolved_clearsWantExpanded")
    func interactionResolved_clearsWantExpanded() {
        let machine = OverlayStateMachine()
        machine.requestExpand()
        machine.transitionDidEnd()

        machine.interactionResolved()

        #expect(!machine.wantExpanded)
    }

    @Test("interactionResolved_collapsesIfExpanded")
    func interactionResolved_collapsesIfExpanded() {
        let machine = OverlayStateMachine()
        machine.requestExpand()
        machine.transitionDidEnd()

        machine.interactionResolved()

        #expect(machine.phase == .collapsing)
        #expect(machine.isAnimating)
    }

    @Test("fullCycle_expandThenCollapse")
    func fullCycle_expandThenCollapse() {
        let machine = OverlayStateMachine()
        machine.hasPendingInteractions = { false }

        machine.requestExpand()
        machine.transitionDidEnd()
        #expect(machine.phase == .expanded)

        machine.scheduleCollapse()
        RunLoop.main.run(until: Date().addingTimeInterval(0.26))
        machine.transitionDidEnd()

        #expect(machine.phase == .collapsed)
        #expect(!machine.wantExpanded)
        #expect(!machine.isAnimating)
    }

    @Test("rapidHoverEnterExit_animationLockPreventsReentry")
    func rapidHoverEnterExit_animationLockPreventsReentry() {
        let machine = OverlayStateMachine()
        var nativeCount = 0
        machine.onExpandNativeWindow = { nativeCount += 1 }

        machine.requestExpand()
        machine.scheduleCollapse()
        machine.requestExpand()
        machine.requestExpand()

        #expect(nativeCount == 1)
        #expect(machine.phase == .expanding)
        #expect(machine.wantExpanded)
        #expect(machine.isAnimating)
    }
}

#endif
