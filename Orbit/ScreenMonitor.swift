import AppKit

@MainActor
class ScreenMonitor: NSObject {
    private var lastGeometry: NotchGeometry
    private var lastScreenID: NSNumber?
    private weak var panel: FloatingPanel?
    private var onGeometryChanged: ((NotchGeometry, NSScreen?) -> Void)?
    nonisolated(unsafe) private var deferredSyncTask: Task<Void, Never>?
    nonisolated(unsafe) private var transitionGuardTasks: [Task<Void, Never>] = []

    init(
        panel: FloatingPanel,
        initialGeometry: NotchGeometry,
        initialScreen: NSScreen?,
        onGeometryChanged: ((NotchGeometry, NSScreen?) -> Void)? = nil
    ) {
        self.panel = panel
        self.lastGeometry = initialGeometry
        self.lastScreenID = ScreenMonitor.screenID(for: initialScreen)
        self.onGeometryChanged = onGeometryChanged
        super.init()
        startMonitoring()
    }

    deinit {
        deferredSyncTask?.cancel()
        for task in transitionGuardTasks { task.cancel() }
        transitionGuardTasks.removeAll()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func startMonitoring() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    func stopMonitoring() {
        deferredSyncTask?.cancel()
        cancelTransitionGuard()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func screenDidChange(_ notification: Notification) {
        syncEnvironment(force: false)
        scheduleDeferredSync(delay: 180_000_000)
    }

    @objc private func activeSpaceDidChange(_ notification: Notification) {
        syncEnvironment(force: true)
        // macOS Space transitions animate for ~400-700ms.
        // The WS repositions our panel during the animation, overriding snapPanelFrame.
        // Fire multiple forced syncs to fight back throughout the transition.
        scheduleTransitionGuard()
    }

    private func syncEnvironment(force: Bool) {
        let screen = targetScreen()
        let screenID = Self.screenID(for: screen)
        let newGeometry = DisplayPolicy.geometry(for: screen)
        guard force || geometryChangedSignificantly(newGeometry) || screenID != lastScreenID else { return }
        lastGeometry = newGeometry
        lastScreenID = screenID
        onGeometryChanged?(newGeometry, screen)
    }

    private func geometryChangedSignificantly(_ new: NotchGeometry) -> Bool {
        DisplayPolicy.geometryChangedSignificantly(lastGeometry, new)
    }

    private func targetScreen() -> NSScreen? {
        DisplayPolicy.targetScreen()
    }

    private func scheduleDeferredSync(delay: UInt64) {
        deferredSyncTask?.cancel()
        deferredSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.syncEnvironment(force: true)
            }
        }
    }

    /// Fire multiple forced syncs during a Space transition to counteract
    /// Window Server repositioning. Each sync calls handleScreenChange →
    /// snapPanelFrame, fighting WS at every stage of its animation.
    private func scheduleTransitionGuard() {
        cancelTransitionGuard()
        let delays: [UInt64] = [
            150_000_000,   // 150ms — early in WS animation
            300_000_000,   // 300ms — mid animation
            500_000_000,   // 500ms — late animation
            700_000_000,   // 700ms — animation definitely finished
        ]
        for delay in delays {
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.syncEnvironment(force: true)
                }
            }
            transitionGuardTasks.append(task)
        }
    }

    nonisolated private func cancelTransitionGuard() {
        for task in transitionGuardTasks {
            task.cancel()
        }
        transitionGuardTasks.removeAll()
    }

    private static func screenID(for screen: NSScreen?) -> NSNumber? {
        screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

}
