import Foundation

/// Overlay animation phase — matches Orbitbak main.js state semantics exactly.
enum OverlayPhase: Equatable, Sendable {
    case collapsed   // pill-only, native window at notch height
    case expanding   // native window opened to max, content filling
    case expanded    // fully open, content visible
    case collapsing  // content shrinking, native window still at max
}

/// State machine that owns all overlay runtime state.
/// Implements the Orbitbak "elevator pattern" and animation lock.
@MainActor
final class OverlayStateMachine {
    // MARK: - State

    private(set) var phase: OverlayPhase = .collapsed
    private(set) var wantExpanded: Bool = false
    private(set) var isAnimating: Bool = false
    private(set) var collapseAfterTransition: Bool = false

    // MARK: - Timers

    private var collapseDebounceTimer: Timer?
    private var animationFallbackTimer: Timer?
    /// Generation counter for collapse debounce Tasks. Bumped on every
    /// cancelCollapse to invalidate in-flight Tasks that the Timer already
    /// dispatched before invalidation.
    private var collapseGeneration: UInt = 0

    // MARK: - Constants (Orbitbak parity)

    /// Orbitbak main.js (COLLAPSE_DELAY 常量): 200ms
    static let collapseDelay: TimeInterval = 0.200
    /// Orbitbak main.js (animation fallback 常量): 350ms
    static let animationFallbackDelay: TimeInterval = 0.350

    // MARK: - External query

    var hasPendingInteractions: (() -> Bool)?

    // MARK: - Callbacks

    var onExpandNativeWindow: (() -> Void)?
    var onSetExpandedContent: (() -> Void)?
    var onSetCollapsedContent: (() -> Void)?
    var onCollapseNativeWindow: (() -> Void)?
    var onScheduleHeightUpdate: (() -> Void)?

    deinit {
        // Orbitbak source: main.js:177-184, 997-1065（状态收敛与动画生命周期清理）
        collapseDebounceTimer?.invalidate()
        animationFallbackTimer?.invalidate()
    }

    // MARK: - Public entry points

    /// Orbitbak source: main.js:177-184, 997-1025（expand intent + reconcile 语义）
    func requestExpand() {
        NSLog("[Orbit] SM.requestExpand: phase=%@ isAnimating=%d wantExpanded=%d", "\(phase)", isAnimating ? 1 : 0, wantExpanded ? 1 : 0)
        cancelCollapse()
        wantExpanded = true

        // main.js 的 isAnimating 锁：动画期间禁止重入，仅更新意图。
        guard !isAnimating else {
            NSLog("[Orbit] SM.requestExpand: BLOCKED by isAnimating")
            return
        }

        guard phase != .expanded, phase != .expanding else {
            NSLog("[Orbit] SM.requestExpand: already expanded/expanding, skip")
            return
        }
        expandIsland()
    }

    /// Orbitbak source: main.js:177-184, 1027-1047（mouseleave + debounce + collapse intent）
    func scheduleCollapse() {
        NSLog("[Orbit] SM.scheduleCollapse: phase=%@ isAnimating=%d", "\(phase)", isAnimating ? 1 : 0)
        cancelCollapse()
        let generation = collapseGeneration

        collapseDebounceTimer = Timer.scheduledTimer(withTimeInterval: Self.collapseDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                // Timer 触发后创建的 Task 可能在 cancelCollapse 之后才执行。
                // 通过 generation 检查确保过期 Task 不会覆写 wantExpanded。
                guard self.collapseGeneration == generation else { return }

                // Orbitbak: pending interaction blocks collapse.
                let hasPending = self.hasPendingInteractions?() == true
                NSLog("[Orbit] SM.scheduleCollapse timer fired: phase=%@ hasPending=%d", "\(self.phase)", hasPending ? 1 : 0)
                if hasPending {
                    self.wantExpanded = true
                    return
                }

                self.wantExpanded = false

                // Orbitbak: 动画期间不重入，transition 结束后由 reconcile 决定。
                guard !self.isAnimating else { return }

                guard self.phase != .collapsed, self.phase != .collapsing else { return }
                self.collapseIsland()
            }
        }
    }

    /// Orbitbak source: main.js:1027-1047（collapse debounce cancel 语义）
    func cancelCollapse() {
        collapseDebounceTimer?.invalidate()
        collapseDebounceTimer = nil
        collapseGeneration &+= 1
    }

    /// Force wantExpanded=true during a screen transition. Called by
    /// OverlayController to prevent reconcileExpandState from re-collapsing
    /// the panel after a Space switch (scene D fix).
    func forceWantExpanded() {
        wantExpanded = true
    }

    /// Hard-abort an in-flight collapse sequence.  Called by OverlayController
    /// when a Space/screen transition is detected while the panel was expanded.
    /// Resets the state machine back to `.expanded` so subsequent reconcile calls
    /// do not re-trigger a collapse.
    func abortCollapse() {
        cancelCollapse()
        clearAnimationFallbackTimer()

        guard phase == .collapsing || phase == .collapsed else { return }

        phase = .expanded
        isAnimating = false
        collapseAfterTransition = false
        wantExpanded = true
    }

    /// Orbitbak source: main.js:177-184, 1049-1065（transitionend + finish/reconcile）
    func transitionDidEnd() {
        clearAnimationFallbackTimer()

        NSLog("[Orbit] SM.transitionDidEnd: phase=%@ wantExpanded=%d collapseAfterTransition=%d", "\(phase)", wantExpanded ? 1 : 0, collapseAfterTransition ? 1 : 0)

        if phase == .collapsing, collapseAfterTransition {
            finishCollapse()
            return
        }

        isAnimating = false

        if phase == .expanding {
            phase = .expanded
        }

        reconcileExpandState()
    }

    /// Orbitbak source: main.js:1049-1065（transitioncancel 与 transitionend 同路径收敛）
    func transitionDidCancel() {
        transitionDidEnd()
    }

    /// Orbitbak source: main.js:177-184, 1027-1065（interaction resolved 后清理 intent 并折叠）
    func interactionResolved() {
        NSLog("[Orbit] SM.interactionResolved: phase=%@ isAnimating=%d", "\(phase)", isAnimating ? 1 : 0)
        cancelCollapse()
        wantExpanded = false

        if isAnimating {
            return
        }

        if phase == .expanded {
            collapseIsland()
        }
    }

    // MARK: - Internal (Orbitbak function parity)

    /// Orbitbak main.js:997-1025 expandIsland()
    /// Elevator pattern: native window FIRST, then content.
    private func expandIsland() {
        guard !isAnimating else { return }

        NSLog("[Orbit] SM.expandIsland: starting expand")
        phase = .expanding
        isAnimating = true
        collapseAfterTransition = false

        onExpandNativeWindow?()
        onSetExpandedContent?()
        onScheduleHeightUpdate?()

        scheduleAnimationFallbackTimer()
    }

    /// Orbitbak main.js:1027-1047 collapseIsland()
    /// Elevator pattern: content FIRST, native window later in finishCollapse().
    private func collapseIsland() {
        guard !isAnimating else { return }
        guard phase != .collapsed, phase != .collapsing else { return }

        phase = .collapsing
        isAnimating = true
        collapseAfterTransition = true

        onSetCollapsedContent?()
        onScheduleHeightUpdate?()

        scheduleAnimationFallbackTimer()
    }

    /// Orbitbak main.js:1049-1065 finishCollapse()
    private func finishCollapse() {
        clearAnimationFallbackTimer()

        collapseAfterTransition = false
        isAnimating = false
        phase = .collapsed

        onCollapseNativeWindow?()
        onScheduleHeightUpdate?()

        // 若动画期间意图反转（wantExpanded=true），立即对齐。
        reconcileExpandState()
    }

    /// Orbitbak main.js:177-184 reconcileExpandState()
    private func reconcileExpandState() {
        guard !isAnimating else { return }

        if wantExpanded {
            if phase == .collapsed {
                expandIsland()
            }
            return
        }

        if phase == .expanded {
            collapseIsland()
        }
    }

    // MARK: - Timer helpers

    /// Orbitbak source: main.js:997-1065（animation fallback timeout = 350ms）
    private func scheduleAnimationFallbackTimer() {
        clearAnimationFallbackTimer()

        animationFallbackTimer = Timer.scheduledTimer(withTimeInterval: Self.animationFallbackDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.transitionDidEnd()
            }
        }
    }

    /// Orbitbak source: main.js:1049-1065（transitionend / cancel / finish 清理 fallback）
    private func clearAnimationFallbackTimer() {
        animationFallbackTimer?.invalidate()
        animationFallbackTimer = nil
    }
}
