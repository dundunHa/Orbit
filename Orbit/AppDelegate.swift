import AppKit
import Combine
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
    private var diagnosticsCancellables = Set<AnyCancellable>()
    private var runtimeDiagnosticsWriter: OrbitRuntimeDiagnosticsWriter?
    private var runtimeDiagnosticsRevision = 0
    private var activeScenarioSummary: OrbitRuntimeDiagnostics.ScenarioSummary?
    private var lastDecisionSummary: OrbitRuntimeDiagnostics.DecisionSummary?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let environment = ProcessInfo.processInfo.environment
        let scenarioResolution = AppLaunchScenarioLoader.resolve(environment: environment)
        let scenarioLoader = scenarioResolution.loader
        let loadedScenario = scenarioResolution.scenario
        let scenarioLoadError = scenarioResolution.errorDescription
        let isScenarioMode = scenarioResolution.isScenarioMode

        if let scenarioLoader, let loadedScenario {
            activeScenarioSummary = OrbitRuntimeDiagnostics.ScenarioSummary(
                fixtureName: loadedScenario.name,
                schemaVersion: loadedScenario.schemaVersion,
                loadState: "loaded",
                error: nil
            )
            OrbitDiagnostics.shared.notice(
                .scenario,
                "scenario.loaded",
                metadata: [
                    "name": loadedScenario.name,
                    "path": scenarioLoader.fileURL.path
                ]
            )
        } else if let scenarioLoader, let scenarioLoadError {
            activeScenarioSummary = OrbitRuntimeDiagnostics.ScenarioSummary(
                fixtureName: scenarioLoader.fileURL.deletingPathExtension().lastPathComponent,
                schemaVersion: AppLaunchScenario.currentVersion,
                loadState: "failed",
                error: scenarioLoadError
            )
            OrbitDiagnostics.shared.error(
                .scenario,
                "scenario.loadFailed",
                metadata: [
                    "path": scenarioLoader.fileURL.path,
                    "error": scenarioLoadError
                ]
            )
        }

        // 1) Core state
        let sessionStore = SessionStore()
        let historyStore = HistoryStore(
            filePath: isScenarioMode ? Self.makeTestingFilePath(prefix: "history") : NSString(string: "~/.orbit/history.json").expandingTildeInPath
        )
        let debugLogger = HookDebugLogger(
            filePath: {
                if let configuredPath = environment["ORBIT_HOOK_DEBUG_LOG_PATH"], !configuredPath.isEmpty {
                    return configuredPath
                }
                if isScenarioMode {
                    return Self.makeTestingFilePath(prefix: "hook-debug")
                }
                return HookDebugLogger.defaultFilePath()
            }()
        )
        let todayStats = loadedScenario?.todayStats ?? TodayTokenStats.loadFromDisk()

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
            initialOnboardingState: loadedScenario.flatMap { try? $0.onboarding.makeState() }
                ?? onboardingManager.state
        )
        self.viewModel = viewModel

        startMessageProcessor(hookRouter: hookRouter, viewModel: viewModel, debugLogger: debugLogger)

        viewModel.onRetryOnboarding = { [weak self] in
            guard let self else { return }
            if isScenarioMode {
                viewModel.onboardingState = .installing
                self.scheduleRuntimeDiagnosticsWrite()
                return
            }
            guard let onboardingManager = self.onboardingManager else { return }
            onboardingManager.retryInstall()
            viewModel.refreshOnboardingState()
        }

        if let loadedScenario, let scenarioLoader {
            let applyTask = scenarioLoader.apply(
                loadedScenario,
                sessionStore: sessionStore,
                historyStore: historyStore,
                viewModel: viewModel
            )
            startupTasks.append(applyTask)
        }

        // Startup sequence
        if isScenarioMode {
            OrbitDiagnostics.shared.notice(
                .scenario,
                "scenario.modeEnabled",
                metadata: ["name": activeScenarioSummary?.fixtureName ?? "load_failed"]
            )
        } else {
            onboardingManager.startBackgroundCheck()

            let socketStartTask = Task {
                do {
                    try await socketServer.start()
                    OrbitDiagnostics.shared.info(.launch, "socketServer.started")
                } catch {
                    OrbitDiagnostics.shared.error(
                        .launch,
                        "socketServer.startFailed",
                        metadata: ["error": String(describing: error)]
                    )
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
        }

        setupPanel(viewModel: viewModel)
        let shouldPinExpandedScenario = isScenarioMode && loadedScenario?.overlay?.initialIntent == .expanded
        let shouldSuppressCollapsedScenario = isScenarioMode && loadedScenario?.overlay?.initialIntent == .collapsed
        overlayController?.setExpansionPinnedForTesting(shouldPinExpandedScenario)
        overlayController?.setExpansionSuppressedForTesting(shouldSuppressCollapsedScenario)
        if loadedScenario?.overlay?.initialIntent == .expanded {
            overlayController?.requestExpand()
        }
        viewModel.onPendingInteractionChanged = { [weak self, weak viewModel] in
            guard let self, let viewModel else { return }

            if let interaction = viewModel.pendingInteraction {
                OrbitDiagnostics.shared.notice(
                    .hook,
                    "pendingInteraction.set",
                    metadata: [
                        "kind": interaction.kind,
                        "tool": interaction.toolName,
                        "requestId": interaction.id,
                        "queueDepth": "\(viewModel.pendingInteractions.count)"
                    ]
                )
                if self.overlayController != nil {
                    self.overlayController?.requestExpand()
                } else {
                    OrbitDiagnostics.shared.error(.overlay, "overlayController.missingForExpand")
                }
            } else {
                self.overlayController?.interactionResolved()
            }
            self.scheduleRuntimeDiagnosticsWrite()
        }
        configureRuntimeDiagnostics(viewModel: viewModel, diagnosticsPath: AppLaunchScenarioLoader.diagnosticsPath(in: environment))
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

        if isScenarioMode {
            viewModel.todayStats = loadedScenario?.todayStats ?? viewModel.todayStats
        } else {
            viewModel.refreshSessions()
            viewModel.refreshHistory()
            viewModel.refreshOnboardingState()
            viewModel.todayStats = TodayTokenStats.loadFromDisk()
        }

        if !isScenarioMode {
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

        scheduleRuntimeDiagnosticsWrite()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        diagnosticsCancellables.removeAll()

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

    private func startMessageProcessor(hookRouter: HookRouter, viewModel: AppViewModel, debugLogger: HookDebugLogger) {
        let processorTask = Task.detached {
            while !Task.isCancelled {
                let (messageId, bytes) = await MessageBridge.shared.dequeue()

                // Process each message concurrently so PermissionRequest
                // doesn't block other events from different connections.
                Task {
                    let response = await AppDelegate.processSocketMessage(
                        bytes: bytes,
                        hookRouter: hookRouter,
                        viewModel: viewModel,
                        debugLogger: debugLogger
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
        viewModel: AppViewModel,
        debugLogger: HookDebugLogger
    ) async -> Data? {
        if bytes.allSatisfy({ $0 == 0 }) { return nil }

        let interval = OrbitDiagnostics.shared.beginInterval(
            .hook,
            "hook.processSocketMessage",
            metadata: ["byteCount": "\(bytes.count)"]
        )
        defer {
            OrbitDiagnostics.shared.endInterval(interval)
        }

        let data = Data(bytes)
        let decoder = JSONDecoder()

        if Self.isStatuslineUpdateMessage(data) {
            if let update = try? decoder.decode(StatuslineUpdate.self, from: data) {
                await hookRouter.routeStatuslineUpdate(update)
                await MainActor.run {
                    viewModel.refreshSessions()
                    viewModel.todayStats = TodayTokenStats.loadFromDisk()
                }
            }
            return nil
        }

        // HookPayload
        let payload: HookPayload?
        do {
            payload = try decoder.decode(HookPayload.self, from: data)
        } catch {
            let preview = String(decoding: data.prefix(200), as: UTF8.self)
            let hex = data.prefix(40).map { String(format: "%02x", $0) }.joined(separator: " ")
            OrbitDiagnostics.shared.error(
                .hook,
                "hookPayload.decodeFailed",
                metadata: [
                    "length": "\(data.count)",
                    "hexPrefix": hex,
                    "error": String(describing: error),
                    "preview": preview
                ]
            )
            payload = nil
        }

        if let payload {
            OrbitDiagnostics.shared.debug(
                .hook,
                "hook.eventReceived",
                metadata: [
                    "event": payload.hookEventName,
                    "sessionId": payload.sessionId
                ]
            )
            await debugLogger.log(
                source: "socket",
                sessionId: payload.sessionId,
                hookEventName: payload.hookEventName,
                requestId: nil,
                decision: "received",
                responseJson: nil,
                payloadSummary: payload.debugSummary,
                payloadDetails: payload.debugDetails
            )

            if let resolvedRequestId = await hookRouter.resolveInteractionFromCli(payload: payload) {
                await debugLogger.log(
                    source: "socket",
                    sessionId: payload.sessionId,
                    hookEventName: payload.hookEventName,
                    requestId: resolvedRequestId,
                    decision: "resolved_via_cli_event",
                    responseJson: nil,
                    payloadSummary: payload.debugSummary,
                    payloadDetails: payload.debugDetails
                )
            }

            let result = await hookRouter.routeHookEvent(payload)

            switch result {
            case .noResponse:
                await MainActor.run {
                    viewModel.refreshSessions()
                    viewModel.todayStats = TodayTokenStats.loadFromDisk()
                }
                if payload.hookEventName == "ElicitationResult" {
                    return Data("{}".utf8)
                }
                return nil

            case .awaitPermissionDecision(let requestId):
                OrbitDiagnostics.shared.notice(
                    .hook,
                    "permission.awaitingDecision",
                    metadata: [
                        "requestId": requestId,
                        "event": payload.hookEventName
                    ]
                )
                await MainActor.run {
                    viewModel.enqueuePendingInteraction(
                        PendingInteraction(
                        id: requestId,
                        kind: payload.hookEventName == "Elicitation" ? "elicitation" : "permission",
                        sessionId: payload.sessionId,
                        toolName: payload.toolName ?? "Permission",
                        toolInput: payload.toolInput ?? .null,
                        message: payload.message ?? "",
                        requestedSchema: payload.requestedSchema,
                        permissionSuggestions: payload.permissionSuggestions
                    )
                    )
                    viewModel.refreshSessions()
                }

                let decision = await hookRouter.awaitPermissionDecision(requestId: requestId)
                OrbitDiagnostics.shared.notice(
                    .hook,
                    "permission.decisionReceived",
                    metadata: [
                        "decision": decision.normalizedDecision(),
                        "requestId": requestId
                    ]
                )
                await MainActor.run {
                    viewModel.clearPendingInteraction(requestId: requestId)
                }

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

        return nil
    }

    #if DEBUG
    nonisolated static func processSocketMessageForTesting(
        bytes: [UInt8],
        hookRouter: HookRouter,
        viewModel: AppViewModel,
        debugLogger: HookDebugLogger
    ) async -> Data? {
        await processSocketMessage(bytes: bytes, hookRouter: hookRouter, viewModel: viewModel, debugLogger: debugLogger)
    }
    #endif

    nonisolated private static func isStatuslineUpdateMessage(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return false
        }
        return type == "StatuslineUpdate"
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

    private func configureRuntimeDiagnostics(viewModel: AppViewModel, diagnosticsPath: String?) {
        guard let diagnosticsPath else {
            return
        }

        runtimeDiagnosticsWriter = OrbitRuntimeDiagnosticsWriter(filePath: diagnosticsPath)
        runtimeDiagnosticsRevision = 0
        diagnosticsCancellables.removeAll()

        let scheduleWrite: () -> Void = { [weak self] in
            self?.scheduleRuntimeDiagnosticsWrite()
        }

        viewModel.onPermissionDecisionHandled = { [weak self] pendingInteraction, decision in
            self?.lastDecisionSummary = OrbitRuntimeDiagnostics.DecisionSummary(
                requestId: pendingInteraction.id,
                decision: decision.normalizedDecision(),
                reason: decision.reason,
                timestamp: Date()
            )
            scheduleWrite()
        }

        viewModel.$sessions
            .sink { _ in scheduleWrite() }
            .store(in: &diagnosticsCancellables)

        viewModel.$historyEntries
            .sink { _ in scheduleWrite() }
            .store(in: &diagnosticsCancellables)

        viewModel.$selectedSessionId
            .sink { _ in scheduleWrite() }
            .store(in: &diagnosticsCancellables)

        viewModel.$onboardingState
            .sink { _ in scheduleWrite() }
            .store(in: &diagnosticsCancellables)

        viewModel.$pendingInteractions
            .sink { _ in scheduleWrite() }
            .store(in: &diagnosticsCancellables)

        overlayController?.onRuntimeStateChanged = scheduleWrite
    }

    private func scheduleRuntimeDiagnosticsWrite() {
        guard let runtimeDiagnosticsWriter, let viewModel else {
            return
        }
        runtimeDiagnosticsRevision += 1
        let diagnostics = OrbitRuntimeDiagnostics.capture(
            viewModel: viewModel,
            overlayController: overlayController,
            revision: runtimeDiagnosticsRevision,
            scenario: activeScenarioSummary,
            lastDecision: lastDecisionSummary
        )
        Task {
            _ = await runtimeDiagnosticsWriter.submit(diagnostics)
        }
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

    private static func makeTestingFilePath(prefix: String) -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
            .path
    }
}

private extension HookPayload {
    var debugSummary: String? {
        toolName ?? mcpServerName ?? notificationType ?? action
    }

    var debugDetails: [String: String]? {
        var details: [String: String] = [:]

        if !cwd.isEmpty {
            details["cwd"] = cwd
        }
        if let toolName {
            details["tool_name"] = toolName
        }
        if let toolUseId {
            details["tool_use_id"] = toolUseId
        }
        if let mcpServerName {
            details["mcp_server_name"] = mcpServerName
        }
        if let notificationType {
            details["notification_type"] = notificationType
        }
        if let action {
            details["action"] = action
        }
        if let elicitationId {
            details["elicitation_id"] = elicitationId
        }
        if let mode {
            details["mode"] = mode
        }
        if let status {
            details["status"] = status
        }
        if let message, !message.isEmpty {
            details["message"] = String(message.prefix(120))
        }
        if let toolInput {
            details["tool_input"] = toolInput.debugString(maxLength: 240)
        }
        if let content {
            details["content"] = content.debugString(maxLength: 240)
        }

        return details.isEmpty ? nil : details
    }
}

private extension AnyCodable {
    func debugString(maxLength: Int) -> String {
        let rendered: String
        switch self {
        case .null:
            rendered = "null"
        case .bool(let value):
            rendered = value ? "true" : "false"
        case .int(let value):
            rendered = String(value)
        case .double(let value):
            rendered = String(value)
        case .string(let value):
            rendered = value
        case .array(let values):
            rendered = "[\(values.map { $0.debugString(maxLength: maxLength / max(1, values.count)) }.joined(separator: ","))]"
        case .object(let values):
            let pairs = values.keys.sorted().map { key in
                "\(key)=\(values[key]?.debugString(maxLength: maxLength) ?? "")"
            }
            rendered = "{\(pairs.joined(separator: ","))}"
        }

        if rendered.count <= maxLength {
            return rendered
        }

        return String(rendered.prefix(max(0, maxLength - 1))) + "…"
    }
}
