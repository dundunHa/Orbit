import AppKit
import Combine
import SwiftUI

@MainActor
final class OverlayController: ObservableObject {
    @Published private(set) var isExpanded: Bool = false

    let panel: FloatingPanel
    let stateMachine: OverlayStateMachine
    let bridge: OverlayBridge

    private var geometry: NotchGeometry
    private var currentScreen: NSScreen?
    private var currentScreenFrame: NSRect
    private weak var viewModel: AppViewModel?

    private var expandedHeight: CGFloat = ParityGeometry.minExpandedHeight
    private var lastContentScrollHeight: CGFloat?
    private var collapseContentTransitionTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Monotonic counter that invalidates stale animation completion handlers.
    /// Incremented every time `snapPanelFrame` cancels an in-flight animation.
    private var animationEpoch: UInt64 = 0

    // MARK: – Screen-transition state

    /// True during the ~800 ms window after a Space/screen change fires.
    /// Mouse-exit events during this window are suppressed to prevent spurious collapses.
    private var isScreenTransitioning = false

    /// Expansion state captured at the very start of a transition (before any
    /// synthetic mouse-exit or epoch-invalidated animation can flip isExpanded).
    private var preTransitionExpanded = false

    /// Cancellable task that clears the transition flags after the guard window.
    private var screenTransitionEndTask: Task<Void, Never>?

    /// Timestamp of the last time the panel entered expanded state.
    /// Used to detect Space-switch-induced collapses when activeSpaceDidChange
    /// arrives after the collapse pipeline has already completed.
    private var lastExpandedAt: CFAbsoluteTime = 0

    var onGeometryChanged: ((NotchGeometry) -> Void)?

    private static let nativeAnimationDuration: TimeInterval = 0.24
    private static let collapseLeadDuration: UInt64 = 140_000_000

    init(screen: NSScreen, geometry: NotchGeometry) {
        self.geometry = geometry
        self.currentScreen = screen
        self.currentScreenFrame = screen.frame
        self.stateMachine = OverlayStateMachine()
        self.bridge = OverlayBridge()

        let collapsed = ParityGeometry.collapsedFrame(geometry: geometry, screenFrame: screen.frame)
        self.panel = FloatingPanel(contentRect: collapsed)
        self.panel.anchoredFrame = collapsed

        wireStateMachine()
        wirePanelHover()
    }

    deinit {
        collapseContentTransitionTask?.cancel()
        screenTransitionEndTask?.cancel()
    }

    func setupContent(viewModel: AppViewModel) {
        self.viewModel = viewModel
        stateMachine.hasPendingInteractions = { [weak viewModel] in
            viewModel?.pendingInteraction != nil
        }

        bridge.activeStatus = viewModel.activeSession()?.status ?? .waitingForInput

        viewModel.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak viewModel] _ in
                guard let self, let viewModel else { return }
                self.bridge.activeStatus = viewModel.activeSession()?.status ?? .waitingForInput
            }
            .store(in: &cancellables)

        let root = OverlayShellView(
            bridge: bridge,
            geometry: geometry,
            payload: { [weak viewModel, weak self] in
                guard let viewModel, let self else { return AnyView(EmptyView()) }
                return AnyView(OverlayPayloadSlot(viewModel: viewModel, geometry: self.geometry))
            }
        )
        let host = NSHostingView(rootView: root)
        panel.contentView = host
        panel.setupTrackingArea()
        panel.orderFrontRegardless()
    }

    func requestExpand() {
        NSLog("[Orbit] OverlayController.requestExpand called, isExpanded=%d", isExpanded ? 1 : 0)
        stateMachine.requestExpand()
    }

    func scheduleCollapse() {
        stateMachine.scheduleCollapse()
    }

    func interactionResolved() {
        stateMachine.interactionResolved()
    }

    func handleScreenChange(geometry: NotchGeometry, screen: NSScreen) {
        self.geometry = geometry
        self.currentScreen = screen
        self.currentScreenFrame = screen.frame

        // 场景 A 根治: 折叠流水线(~580ms)可能在本通知之前完全结束，
        // 此时 isExpanded/phase 都已重置为 collapsed。用 lastExpandedAt
        // 兜底——如果面板在最近 1 秒内还是展开状态，几乎可以确定
        // 是 Space 切换触发的合成 mouseExited 导致的折叠。
        if !isScreenTransitioning {
            preTransitionExpanded = isExpanded
                || stateMachine.phase == .expanded
                || stateMachine.phase == .expanding
                || wasRecentlyExpanded()
        }

        isScreenTransitioning = true
        screenTransitionEndTask?.cancel()
        screenTransitionEndTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run {
                self?.isScreenTransitioning = false
                self?.preTransitionExpanded = false
            }
        }

        if preTransitionExpanded {
            stateMachine.cancelCollapse()

            collapseContentTransitionTask?.cancel()
            collapseContentTransitionTask = nil

            // 场景 D 修复: 无论当前 phase 是什么，都确保 wantExpanded=true，
            // 防止后续 reconcileExpandState 因 wantExpanded=false 重新折叠。
            stateMachine.forceWantExpanded()

            let phase = stateMachine.phase
            if phase == .collapsing || phase == .collapsed {
                stateMachine.abortCollapse()
            }

            // 无论从什么状态恢复，都强制设定展开的视觉状态。
            // 场景 C 修复: bump snapExpandedEpoch 让 SwiftUI 跳过动画
            // 直接 snap 到展开，取消正在执行的折叠 withAnimation。
            bridge.snapExpandedEpoch &+= 1
            bridge.payloadPhase = .expanded
            setExpanded(true)
        }

        onGeometryChanged?(geometry)
        snapPanelFrame()
    }

    func updateExpandedHeight(contentScrollHeight: CGFloat) {
        lastContentScrollHeight = contentScrollHeight
        let computed = ParityGeometry.computeExpandedHeight(
            notchHeight: CGFloat(geometry.notchHeight),
            contentScrollHeight: contentScrollHeight
        )
        expandedHeight = ParityGeometry.clampExpandedHeight(computed)

        guard stateMachine.phase == .expanded || stateMachine.phase == .expanding else {
            return
        }

        animatePanel(
            to: expandedFrame(height: expandedHeight),
            completion: nil
        )
    }

    private func wirePanelHover() {
        panel.onMouseEnter = { [weak self] in
            self?.stateMachine.requestExpand()
        }
        panel.onMouseExit = { [weak self] in
            guard let self, !self.isScreenTransitioning else { return }
            // Space 切换时 macOS 触发合成 mouseExited，但鼠标物理位置不变。
            // 仅在稳态阶段（collapsed/expanded）做 isMouseInsidePanel 检查，
            // 因为此时 panel.frame（模型值）与视觉位置一致。
            // 在动画阶段（expanding/collapsing），panel.frame 已是目标 frame，
            // 与当前视觉位置不符，检查会误判导致折叠被阻止。
            let stable = self.stateMachine.phase == .collapsed || self.stateMachine.phase == .expanded
            if stable, self.isMouseInsidePanel() { return }
            self.stateMachine.scheduleCollapse()
        }
    }

    /// 检查当前鼠标位置是否在面板 frame 内。
    /// Space 切换导致的合成 mouseExited 不会改变鼠标物理位置。
    private func isMouseInsidePanel() -> Bool {
        let mouseLocation = NSEvent.mouseLocation
        return panel.frame.contains(mouseLocation)
    }

    private func setExpanded(_ value: Bool) {
        guard isExpanded != value else { return }
        isExpanded = value
        if value {
            lastExpandedAt = CFAbsoluteTimeGetCurrent()
        }
    }

    /// 面板在最近 1 秒内是否处于展开状态。
    /// 用于场景 A: 折叠流水线在 activeSpaceDidChange 之前完全结束时，
    /// isExpanded 和 phase 都已重置，但时间戳仍保留展开痕迹。
    private func wasRecentlyExpanded() -> Bool {
        lastExpandedAt > 0 && (CFAbsoluteTimeGetCurrent() - lastExpandedAt) < 1.0
    }

    private func wireStateMachine() {
        stateMachine.onExpandNativeWindow = { [weak self] in
            guard let self else { return }
            self.collapseContentTransitionTask?.cancel()
            let targetFrame = self.expandedFrame(height: self.expandedHeight)
            NSLog("[Orbit] onExpandNativeWindow: animating to frame=%@", NSStringFromRect(targetFrame))
            self.animatePanel(to: targetFrame) {
                NSLog("[Orbit] onExpandNativeWindow: animation completed, setting expanded")
                self.setExpanded(true)
                self.bridge.payloadPhase = .expanded
                self.stateMachine.transitionDidEnd()
                // 展开动画期间，.inVisibleRect tracking area 跟随模型 frame
                // 立即扩大，可能吞没鼠标导致 mouseExited 从未触发。
                // 动画结束后检查鼠标是否仍在面板内，不在则补发折叠。
                if self.stateMachine.phase == .expanded, !self.isMouseInsidePanel() {
                    self.stateMachine.scheduleCollapse()
                }
            }
        }

        stateMachine.onSetExpandedContent = { [weak self] in
            guard let self else { return }
            self.collapseContentTransitionTask?.cancel()
            self.setExpanded(true)
            NSLog("[Orbit] onSetExpandedContent: payloadPhase -> expanding")
            self.bridge.payloadPhase = .expanding
        }

        stateMachine.onSetCollapsedContent = { [weak self] in
            guard let self else { return }
            self.bridge.payloadPhase = .collapsing

            self.collapseContentTransitionTask?.cancel()
            self.collapseContentTransitionTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.collapseLeadDuration)
                await MainActor.run {
                    self?.stateMachine.transitionDidEnd()
                }
            }
        }

        stateMachine.onCollapseNativeWindow = { [weak self] in
            guard let self else { return }
            self.animatePanel(to: self.collapsedFrame()) {
                self.setExpanded(false)
                self.bridge.payloadPhase = .collapsed
                self.stateMachine.transitionDidEnd()
            }
        }

        stateMachine.onScheduleHeightUpdate = { [weak self] in
            self?.applyScheduledHeightUpdate()
        }
    }

    private func applyScheduledHeightUpdate() {
        if let lastContentScrollHeight {
            let computed = ParityGeometry.computeExpandedHeight(
                notchHeight: CGFloat(geometry.notchHeight),
                contentScrollHeight: lastContentScrollHeight
            )
            expandedHeight = ParityGeometry.clampExpandedHeight(computed)
        } else {
            expandedHeight = ParityGeometry.minExpandedHeight
        }

        guard stateMachine.phase == .expanded || stateMachine.phase == .expanding else {
            return
        }

        let frame = expandedFrame(height: expandedHeight)
        panel.anchoredFrame = frame
        panel.setFrame(frame, display: true)
    }

    private func expandedFrame(height: CGFloat) -> NSRect {
        let frame = currentScreen?.frame ?? currentScreenFrame
        return ParityGeometry.expandedFrame(geometry: geometry, screenFrame: frame, height: height)
    }

    private func collapsedFrame() -> NSRect {
        let frame = currentScreen?.frame ?? currentScreenFrame
        return ParityGeometry.collapsedFrame(geometry: geometry, screenFrame: frame)
    }

    private func reanchorPanel(display: Bool) {
        let frame = isExpanded
            ? expandedFrame(height: expandedHeight)
            : collapsedFrame()
        panel.setFrame(frame, display: display)
    }

    /// Cancel any in-flight Core Animation on the panel and force-set the
    /// correct frame. Called during Space / screen transitions to counteract
    /// macOS Window Server repositioning the visual layer.
    private func snapPanelFrame() {
        // During a screen transition, use the expansion state captured at
        // transition-start rather than isExpanded, which may be stale if a
        // collapse animation ran to completion before activeSpaceDidChange fired
        // or if snapPanelFrame itself bumped animationEpoch and invalidated the
        // expand-animation completion callback that would have set isExpanded=true.
        let shouldBeExpanded = isExpanded || (isScreenTransitioning && preTransitionExpanded)
        let frame = shouldBeExpanded
            ? expandedFrame(height: expandedHeight)
            : collapsedFrame()

        // Bump the epoch so any in-flight animation completion handler
        // recognises itself as stale and becomes a no-op.
        animationEpoch &+= 1

        // Lock the panel to the correct anchor so constrainFrameRect rejects
        // any frame the Window Server proposes during the transition.
        panel.anchoredFrame = frame

        // Replace any in-flight animator frame animation with an instant snap.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            self.panel.animator().setFrame(frame, display: false)
        }

        // Set the definitive model frame (non-animated).
        panel.setFrame(frame, display: true)

        // Force the window server to re-evaluate position and z-ordering.
        panel.orderFrontRegardless()
    }

    private func animatePanel(to frame: NSRect, completion: (() -> Void)?) {
        // Set the anchor to the target so constrainFrameRect allows the
        // target frame but rejects any WS-proposed alternative.
        panel.anchoredFrame = frame
        let epoch = animationEpoch

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.nativeAnimationDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.24, 0.84, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            guard let self, self.animationEpoch == epoch else { return }
            completion?()
        }
    }

    var runtimeGeometry: NotchGeometry {
        geometry
    }

    var runtimeExpandedHeight: CGFloat {
        expandedHeight
    }
}
