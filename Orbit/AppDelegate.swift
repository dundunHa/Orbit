import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var overlayController: OverlayController?

    private var viewModel: AppViewModel?

    private var sessionStore: SessionStore?
    private var historyStore: HistoryStore?
    private var debugLogger: HookDebugLogger?
    private var hookRouter: HookRouter?
    private var socketServer: SocketServer?
    private var anomalyDetector: AnomalyDetector?
    private var onboardingManager: OnboardingManager?

    private var trayController: TrayController?
    private var screenMonitor: ScreenMonitor?
    private var refreshTimer: Timer?
    private var startupTasks: [Task<Void, Never>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        // 1) Core state
        let sessionStore = SessionStore()
        let historyStore = HistoryStore()
        let debugLogger = HookDebugLogger()
        let todayStats = TodayTokenStats.loadFromDisk()

        // 2) HookRouter
        let hookRouter = HookRouter(
            sessionStore: sessionStore,
            historyStore: historyStore,
            todayStats: todayStats,
            debugLogger: debugLogger,
            todayStatsFilePath: nil
        )

        // 3) SocketServer
        let socketServer = SocketServer(socketPath: "/tmp/orbit.sock")

        // 4) AnomalyDetector
        let anomalyDetector = AnomalyDetector()

        // 5) OnboardingManager
        let orbitHelperPath = resolveOrbitHelperPath()
        let onboardingManager = OnboardingManager(orbitHelperPath: orbitHelperPath)

        self.sessionStore = sessionStore
        self.historyStore = historyStore
        self.debugLogger = debugLogger
        self.hookRouter = hookRouter
        self.socketServer = socketServer
        self.anomalyDetector = anomalyDetector
        self.onboardingManager = onboardingManager

        let viewModel = AppViewModel(
            sessionStore: sessionStore,
            historyStore: historyStore,
            hookRouter: hookRouter,
            onboardingManager: onboardingManager,
            initialTodayStats: todayStats,
            initialOnboardingState: onboardingManager.state
        )
        self.viewModel = viewModel

        startMessageProcessor(hookRouter: hookRouter, viewModel: viewModel)

        viewModel.onRetryOnboarding = { [weak self] in
            guard let self, let onboardingManager = self.onboardingManager else { return }
            onboardingManager.retryInstall()
            viewModel.refreshOnboardingState()
        }

        // Startup sequence
        onboardingManager.startBackgroundCheck()

        let socketStartTask = Task {
            do {
                try await socketServer.start()
                NSLog("[Orbit] SocketServer started successfully")
            } catch {
                NSLog("[Orbit] SocketServer failed to start: %@", "\(error)")
            }
        }
        startupTasks.append(socketStartTask)

        let anomalyStartTask = Task {
            await anomalyDetector.start(
                sessions: {
                    let all = await sessionStore.allSessions()
                    var snapshots: [String: SessionSnapshot] = [:]
                    for session in all.values {
                        switch session.status {
                        case .processing:
                            snapshots[session.id] = SessionSnapshot(
                                id: session.id,
                                status: .processing,
                                lastEventAt: session.lastEventAt
                            )
                        case .runningTool(let name, _):
                            snapshots[session.id] = SessionSnapshot(
                                id: session.id,
                                status: .runningTool(toolName: name),
                                lastEventAt: session.lastEventAt
                            )
                        default:
                            break
                        }
                    }
                    return snapshots
                },
                onChange: { [weak self] sessionId, newStatus in
                    _ = await sessionStore.upsertSession(sessionId) { session in
                        switch newStatus {
                        case .anomaly(let idleSeconds, let previousStatus):
                            session.status = .anomaly(
                                idleSeconds: idleSeconds,
                                previousStatus: AppDelegate.mapSnapshotStatus(previousStatus)
                            )
                        default:
                            break
                        }
                    }

                    await MainActor.run {
                        self?.viewModel?.refreshSessions()
                    }
                }
            )
        }
        startupTasks.append(anomalyStartTask)

        setupPanel(viewModel: viewModel)
        viewModel.onPendingInteractionChanged = { [weak self, weak viewModel] in
            guard let self, let viewModel else { return }

            if let interaction = viewModel.pendingInteraction {
                NSLog("[Orbit] pendingInteraction set: kind=%@ tool=%@ id=%@", interaction.kind, interaction.toolName, interaction.id)
                if self.overlayController != nil {
                    NSLog("[Orbit] Calling requestExpand()")
                    self.overlayController?.requestExpand()
                } else {
                    NSLog("[Orbit] WARNING: overlayController is nil, cannot expand!")
                }
            } else {
                self.overlayController?.interactionResolved()
            }
        }
        setupTray()

        if let overlayController {
            let screen = DisplayPolicy.targetScreen()
            let geometry = NotchGeometry.current(on: screen)
            let screenMonitor = ScreenMonitor(panel: overlayController.panel, initialGeometry: geometry, initialScreen: screen) { [weak self] geometry, screen in
                guard let self, let screen else { return }
                self.overlayController?.handleScreenChange(geometry: geometry, screen: screen)
            }
            self.screenMonitor = screenMonitor
        }

        viewModel.refreshSessions()
        viewModel.refreshHistory()
        viewModel.refreshOnboardingState()
        viewModel.todayStats = TodayTokenStats.loadFromDisk()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let viewModel = self.viewModel else { return }
                viewModel.refreshSessions()
                viewModel.refreshHistory()
                viewModel.refreshOnboardingState()
                viewModel.todayStats = TodayTokenStats.loadFromDisk()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil

        for task in startupTasks {
            task.cancel()
        }
        startupTasks.removeAll()

        if let anomalyDetector {
            Task {
                await anomalyDetector.stop()
            }
        }

        if let socketServer {
            Task {
                await socketServer.stop()
            }
        }
    }

    private func startMessageProcessor(hookRouter: HookRouter, viewModel: AppViewModel) {
        let processorTask = Task.detached {
            while !Task.isCancelled {
                let (messageId, bytes) = await MessageBridge.shared.dequeue()

                // Process each message concurrently so PermissionRequest
                // doesn't block other events from different connections.
                Task {
                    let response = await AppDelegate.processSocketMessage(
                        bytes: bytes,
                        hookRouter: hookRouter,
                        viewModel: viewModel
                    )
                    await MessageBridge.shared.respond(id: messageId, data: response)
                }
            }
        }
        startupTasks.append(processorTask)
    }

    nonisolated private static func processSocketMessage(
        bytes: [UInt8],
        hookRouter: HookRouter,
        viewModel: AppViewModel
    ) async -> Data? {
        if bytes.allSatisfy({ $0 == 0 }) { return nil }

        let data = Data(bytes)
        let decoder = JSONDecoder()

        // HookPayload
        let payload: HookPayload?
        do {
            payload = try decoder.decode(HookPayload.self, from: data)
        } catch {
            let preview = String(decoding: data.prefix(200), as: UTF8.self)
            let hex = data.prefix(40).map { String(format: "%02x", $0) }.joined(separator: " ")
            NSLog("[Orbit] HookPayload decode failed (len=%d hex=%@): %@ — data: %@", data.count, hex, "\(error)", preview)
            payload = nil
        }

        if let payload {
            NSLog("[Orbit] Hook event: %@ session=%@", payload.hookEventName, payload.sessionId)
            let result = await hookRouter.routeHookEvent(payload)

            switch result {
            case .noResponse:
                await MainActor.run {
                    viewModel.refreshSessions()
                    viewModel.todayStats = TodayTokenStats.loadFromDisk()
                }
                return nil

            case .awaitPermissionDecision(let requestId):
                NSLog("[Orbit] Awaiting permission decision: requestId=%@ event=%@", requestId, payload.hookEventName)
                await MainActor.run {
                    viewModel.pendingInteraction = PendingInteraction(
                        id: requestId,
                        kind: payload.hookEventName == "Elicitation" ? "elicitation" : "permission",
                        sessionId: payload.sessionId,
                        toolName: payload.toolName ?? "Permission",
                        toolInput: payload.toolInput ?? .null,
                        message: payload.message ?? "",
                        requestedSchema: payload.requestedSchema
                    )
                    viewModel.refreshSessions()
                }

                let decision = await hookRouter.awaitPermissionDecision(requestId: requestId)
                NSLog("[Orbit] Permission decision received: %@ for requestId=%@", decision.normalizedDecision(), requestId)

                if let responseDict = buildInteractionResponse(payload: payload, decision: decision),
                   let responseData = serializeInteractionResponse(responseDict)
                {
                    await MainActor.run {
                        viewModel.refreshSessions()
                        viewModel.todayStats = TodayTokenStats.loadFromDisk()
                    }
                    return responseData
                }

                // passthrough or nil response: return empty JSON so orbit-helper
                // doesn't hang waiting for socket data that never comes.
                await MainActor.run {
                    viewModel.refreshSessions()
                    viewModel.todayStats = TodayTokenStats.loadFromDisk()
                }
                return Data("{}".utf8)
            }
        }

        // StatuslineUpdate
        if let update = try? decoder.decode(StatuslineUpdate.self, from: data) {
            await hookRouter.routeStatuslineUpdate(update)
            await MainActor.run {
                viewModel.refreshSessions()
                viewModel.todayStats = TodayTokenStats.loadFromDisk()
            }
            return nil
        }

        return nil
    }

    private func setupPanel(viewModel: AppViewModel) {
        guard let screen = DisplayPolicy.targetScreen() else { return }
        let geometry = DisplayPolicy.geometry(for: screen)

        let overlayController = OverlayController(screen: screen, geometry: geometry)
        overlayController.setupContent(viewModel: viewModel)

        self.overlayController = overlayController
    }

    func expand() {
        overlayController?.requestExpand()
    }

    func collapse() {
        overlayController?.scheduleCollapse()
    }

    func togglePanel() {
        if overlayController?.isExpanded == true {
            collapse()
        } else {
            expand()
        }
    }

    private func setupTray() {
        let trayController = TrayController(statsProvider: { [weak self] in
            self?.viewModel?.todayStats ?? TodayTokenStats()
        })
        trayController.appDelegate = self
        trayController.setup()
        self.trayController = trayController
    }

    nonisolated private static func mapSnapshotStatus(_ status: SessionStatusSnapshot) -> SessionStatus {
        switch status {
        case .processing:
            return .processing
        case .runningTool(let toolName):
            return .runningTool(toolName: toolName, description: nil)
        case .anomaly(_, let previousStatus):
            return mapSnapshotStatus(previousStatus)
        case .other:
            return .processing
        }
    }

    private func resolveOrbitHelperPath() -> String {
        let bundle = Bundle.main

        // 1) Check inside the app bundle: Orbit.app/Contents/MacOS/orbit-helper
        if let execPath = bundle.executablePath {
            let macosDir = (execPath as NSString).deletingLastPathComponent
            let bundleHelper = (macosDir as NSString).appendingPathComponent("orbit-helper")
            if FileManager.default.fileExists(atPath: bundleHelper) {
                return bundleHelper
            }
        }

        // 2) Xcode build products: orbit-helper sits alongside Orbit.app in the same Products dir
        if let execPath = bundle.executablePath {
            // execPath = .../DerivedData/.../Build/Products/Debug/Orbit.app/Contents/MacOS/Orbit
            let appBundle = (execPath as NSString)
                .deletingLastPathComponent  // MacOS
                .replacingOccurrences(of: "/Contents/MacOS", with: "")  // Orbit.app
            let productsDir = (appBundle as NSString).deletingLastPathComponent  // Products/Debug
            let devHelper = (productsDir as NSString).appendingPathComponent("orbit-helper")
            if FileManager.default.fileExists(atPath: devHelper) {
                return devHelper
            }
        }

        return Installer.FALLBACK_ORBIT_HELPER_PATH
    }
}
