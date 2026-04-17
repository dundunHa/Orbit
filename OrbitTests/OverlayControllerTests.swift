import AppKit
import Foundation

#if canImport(Testing) && canImport(Orbit)
import Testing
@testable import Orbit

@Suite("OverlayController")
@MainActor
struct OverlayControllerTests {
    @Test("init creates panel and state machine")
    func initCreatesPanelAndStateMachine() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.panel.close() }

        #expect(fixture.controller.stateMachine.phase == .collapsed)
        #expect(!fixture.controller.isExpanded)

        let expected = ParityGeometry.collapsedFrame(geometry: fixture.geometry, screenFrame: fixture.screen.frame)
        expectRectClose(fixture.controller.panel.frame, expected)
    }

    @Test("mouse enter triggers requestExpand")
    func mouseEnterTriggersRequestExpand() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.panel.close() }

        fixture.controller.panel.onMouseEnter?()

        #expect(fixture.controller.stateMachine.wantExpanded)
        #expect(fixture.controller.stateMachine.phase == .expanding)
    }

    @Test("mouse exit triggers scheduleCollapse")
    func mouseExitTriggersScheduleCollapse() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.panel.close() }

        fixture.controller.requestExpand()
        pumpMainRunLoop(seconds: 0.35)

        fixture.controller.panel.onMouseExit?()
        pumpMainRunLoop(seconds: 0.23)

        #expect(fixture.controller.stateMachine.phase == .collapsing)
    }

    @Test("expand animation sets ParityGeometry expanded frame")
    func expandAnimationSetsCorrectFrame() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.panel.close() }

        fixture.controller.requestExpand()
        pumpMainRunLoop(seconds: 0.35)

        let expected = ParityGeometry.expandedFrame(
            geometry: fixture.geometry,
            screenFrame: fixture.screen.frame,
            height: ParityGeometry.minExpandedHeight
        )
        expectRectClose(fixture.controller.panel.frame, expected)
        #expect(fixture.controller.stateMachine.phase == .expanded)
    }

    @Test("collapse animation sets ParityGeometry collapsed frame")
    func collapseAnimationSetsCorrectFrame() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.panel.close() }

        fixture.controller.requestExpand()
        pumpMainRunLoop(seconds: 0.35)

        fixture.controller.scheduleCollapse()
        pumpMainRunLoop(seconds: 0.80)

        let expected = ParityGeometry.collapsedFrame(geometry: fixture.geometry, screenFrame: fixture.screen.frame)
        expectRectClose(fixture.controller.panel.frame, expected)
        #expect(fixture.controller.stateMachine.phase == .collapsed)
    }

    @Test("isExpanded publish value updates on expand/collapse")
    func isExpandedPublishedUpdates() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.panel.close() }

        fixture.controller.requestExpand()
        #expect(fixture.controller.isExpanded)

        fixture.controller.scheduleCollapse()
        pumpMainRunLoop(seconds: 0.23)
        #expect(!fixture.controller.isExpanded)
    }

    @Test("screen change repositions collapsed panel")
    func screenChangeRepositionsCollapsedPanel() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.panel.close() }

        var changed = false
        fixture.controller.onGeometryChanged = { _ in changed = true }

        let newGeometry = shiftedGeometry(from: fixture.geometry, screen: fixture.screen, shift: 20)
        fixture.controller.handleScreenChange(geometry: newGeometry, screen: fixture.screen)

        let expected = ParityGeometry.collapsedFrame(geometry: newGeometry, screenFrame: fixture.screen.frame)
        expectRectClose(fixture.controller.panel.frame, expected)
        #expect(changed)
    }

    @Test("pending interaction blocks collapse")
    func pendingInteractionBlocksCollapse() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.panel.close() }

        fixture.viewModel.pendingInteraction = PendingInteraction(
            id: "req-1",
            kind: "permission",
            sessionId: "s1",
            toolName: "Bash",
            toolInput: .null,
            message: "allow?",
            requestedSchema: nil
        )

        fixture.controller.requestExpand()
        pumpMainRunLoop(seconds: 0.35)

        fixture.controller.scheduleCollapse()
        pumpMainRunLoop(seconds: 0.26)

        #expect(fixture.controller.stateMachine.phase == .expanded)
        #expect(fixture.controller.stateMachine.wantExpanded)
    }

    @Test("pending interaction ignores hover collapse arming")
    func pendingInteractionIgnoresHoverCollapseArming() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.panel.close() }

        fixture.viewModel.pendingInteraction = PendingInteraction(
            id: "req-1",
            kind: "permission",
            sessionId: "s1",
            toolName: "Bash",
            toolInput: .null,
            message: "allow?",
            requestedSchema: nil
        )

        fixture.controller.requestExpand()
        pumpMainRunLoop(seconds: 0.35)

        fixture.controller.panel.onMouseExit?()
        fixture.viewModel.pendingInteraction = nil
        pumpMainRunLoop(seconds: 0.26)

        #expect(fixture.controller.stateMachine.phase == .expanded)
        #expect(fixture.controller.stateMachine.wantExpanded)
    }

    @Test("pending interaction expand does not arm post expand collapse")
    func pendingInteractionExpandDoesNotArmPostExpandCollapse() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.panel.close() }

        fixture.viewModel.pendingInteraction = PendingInteraction(
            id: "req-1",
            kind: "permission",
            sessionId: "s1",
            toolName: "Bash",
            toolInput: .null,
            message: "allow?",
            requestedSchema: nil
        )

        fixture.controller.requestExpand()
        pumpMainRunLoop(seconds: 0.30)

        fixture.viewModel.pendingInteraction = nil
        pumpMainRunLoop(seconds: 0.26)

        #expect(fixture.controller.stateMachine.phase == .expanded)
        #expect(fixture.controller.stateMachine.wantExpanded)
    }

    @Test("resolved interaction releases hover-blocked collapse")
    func resolvedInteractionReleasesHoverBlockedCollapse() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.panel.close() }

        fixture.viewModel.pendingInteraction = PendingInteraction(
            id: "req-1",
            kind: "permission",
            sessionId: "s1",
            toolName: "Bash",
            toolInput: .null,
            message: "allow?",
            requestedSchema: nil
        )

        fixture.controller.requestExpand()
        pumpMainRunLoop(seconds: 0.35)

        fixture.controller.scheduleCollapse()
        pumpMainRunLoop(seconds: 0.26)

        #expect(fixture.controller.stateMachine.phase == .expanded)
        #expect(fixture.controller.stateMachine.wantExpanded)

        fixture.viewModel.pendingInteraction = nil
        fixture.controller.interactionResolved()

        #expect(fixture.controller.stateMachine.phase == .collapsing)
        #expect(!fixture.controller.stateMachine.wantExpanded)
    }

    @Test("queued interaction keeps collapse blocked after head resolves")
    func queuedInteractionKeepsCollapseBlockedAfterHeadResolves() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.panel.close() }

        fixture.viewModel.enqueuePendingInteraction(
            PendingInteraction(
                id: "req-1",
                kind: "permission",
                sessionId: "s1",
                toolName: "Bash",
                toolInput: .null,
                message: "allow?",
                requestedSchema: nil
            )
        )
        fixture.viewModel.enqueuePendingInteraction(
            PendingInteraction(
                id: "req-2",
                kind: "permission",
                sessionId: "s2",
                toolName: "Edit",
                toolInput: .null,
                message: "allow?",
                requestedSchema: nil
            )
        )

        fixture.controller.requestExpand()
        pumpMainRunLoop(seconds: 0.35)

        fixture.viewModel.clearPendingInteraction(requestId: "req-1")
        fixture.controller.scheduleCollapse()
        pumpMainRunLoop(seconds: 0.26)

        #expect(fixture.viewModel.pendingInteraction?.id == "req-2")
        #expect(fixture.controller.stateMachine.phase == .expanded)
        #expect(fixture.controller.stateMachine.wantExpanded)
    }

    @Test("transitionDidEnd advances phase")
    func transitionDidEndAdvancesPhase() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.panel.close() }

        fixture.controller.requestExpand()
        #expect(fixture.controller.stateMachine.phase == .expanding)

        fixture.controller.stateMachine.transitionDidEnd()

        #expect(fixture.controller.stateMachine.phase == .expanded)
    }

    @Test("content height update changes expanded frame")
    func contentHeightUpdateChangesExpandedFrame() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.panel.close() }

        fixture.controller.requestExpand()
        pumpMainRunLoop(seconds: 0.35)

        fixture.controller.updateExpandedHeight(contentScrollHeight: 260)
        pumpMainRunLoop(seconds: 0.35)

        let expectedHeight = ParityGeometry.clampExpandedHeight(
            ParityGeometry.computeExpandedHeight(
                notchHeight: CGFloat(fixture.geometry.notchHeight),
                contentScrollHeight: 260
            )
        )

        let expected = ParityGeometry.expandedFrame(
            geometry: fixture.geometry,
            screenFrame: fixture.screen.frame,
            height: expectedHeight
        )
        expectRectClose(fixture.controller.panel.frame, expected)
    }

    @Test("expanded screen change keeps expanded frame")
    func expandedScreenChangeKeepsExpandedFrame() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.panel.close() }

        fixture.controller.requestExpand()
        pumpMainRunLoop(seconds: 0.35)
        fixture.controller.updateExpandedHeight(contentScrollHeight: 220)
        pumpMainRunLoop(seconds: 0.35)

        let newGeometry = shiftedGeometry(from: fixture.geometry, screen: fixture.screen, shift: -15)
        fixture.controller.handleScreenChange(geometry: newGeometry, screen: fixture.screen)

        let expectedHeight = ParityGeometry.clampExpandedHeight(
            ParityGeometry.computeExpandedHeight(
                notchHeight: CGFloat(newGeometry.notchHeight),
                contentScrollHeight: 220
            )
        )
        let expected = ParityGeometry.expandedFrame(
            geometry: newGeometry,
            screenFrame: fixture.screen.frame,
            height: expectedHeight
        )
        expectRectClose(fixture.controller.panel.frame, expected)
    }
}

@MainActor
private struct OverlayControllerFixture {
    let controller: OverlayController
    let viewModel: AppViewModel
    let screen: NSScreen
    let geometry: NotchGeometry
}

@MainActor
private func makeFixture() throws -> OverlayControllerFixture {
    _ = NSApplication.shared

    let screen = try #require(DisplayPolicy.targetScreen(from: NSScreen.screens) ?? NSScreen.screens.first)
    let geometry = NotchGeometry.current(on: screen)

    let sessionStore = SessionStore()
    let historyStore = HistoryStore(filePath: tempPath(prefix: "overlay-history"))
    let debugLogger = HookDebugLogger(filePath: tempPath(prefix: "overlay-debug"))
    let router = HookRouter(
        sessionStore: sessionStore,
        historyStore: historyStore,
        todayStats: TodayTokenStats(),
        debugLogger: debugLogger,
        todayStatsFilePath: tempPath(prefix: "overlay-stats")
    )
    let viewModel = AppViewModel(
        sessionStore: sessionStore,
        historyStore: historyStore,
        hookRouter: router,
        onboardingManager: nil
    )

    let controller = OverlayController(screen: screen, geometry: geometry)
    controller.setupContent(viewModel: viewModel)

    return OverlayControllerFixture(
        controller: controller,
        viewModel: viewModel,
        screen: screen,
        geometry: geometry
    )
}

private func tempPath(prefix: String) -> String {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
        .path
}

private func pumpMainRunLoop(seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

private func expectRectClose(_ actual: NSRect, _ expected: NSRect, tolerance: CGFloat = 1.0) {
    #expect(abs(actual.origin.x - expected.origin.x) <= tolerance)
    #expect(abs(actual.origin.y - expected.origin.y) <= tolerance)
    #expect(abs(actual.size.width - expected.size.width) <= tolerance)
    #expect(abs(actual.size.height - expected.size.height) <= tolerance)
}

@MainActor
private func shiftedGeometry(from base: NotchGeometry, screen: NSScreen, shift: Double) -> NotchGeometry {
    let minLeft = 0.0
    let maxLeft = max(base.screenWidth - base.notchWidth, 0)
    let shiftedLeft = min(max(base.notchLeft + shift, minLeft), maxLeft)
    return NotchGeometry(
        notchHeight: base.notchHeight,
        screenWidth: Double(screen.frame.width),
        notchLeft: shiftedLeft,
        notchRight: shiftedLeft + base.notchWidth,
        notchWidth: base.notchWidth,
        leftSafeWidth: max(shiftedLeft, 0),
        rightSafeWidth: max(Double(screen.frame.width) - (shiftedLeft + base.notchWidth), 0),
        leftZoneWidth: base.leftZoneWidth,
        rightZoneWidth: base.rightZoneWidth
    )
}

#endif
