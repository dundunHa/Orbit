import Foundation

public enum HookRouteResult: Sendable, Equatable {
    case noResponse
    case awaitPermissionDecision(requestId: String)
}

public actor HookRouter {
    private let sessionStore: SessionStore
    private let historyStore: HistoryStore
    private var todayStats: TodayTokenStats
    private let todayStatsFilePath: String?
    private let debugLogger: HookDebugLogger
    private let nowProvider: @Sendable () -> Date

    // (parentSessionId, cwd, timestamp)
    private var pendingSpawns: [(String, String, Date)] = []

    // [requestId: continuation]
    private var pendingPermissions: [String: CheckedContinuation<PermissionDecision, Never>] = [:]
    private var resolvedPermissions: [String: PermissionDecision] = [:]

    public init(
        sessionStore: SessionStore,
        historyStore: HistoryStore,
        todayStats: TodayTokenStats,
        debugLogger: HookDebugLogger,
        todayStatsFilePath: String? = nil,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sessionStore = sessionStore
        self.historyStore = historyStore
        self.todayStats = todayStats
        self.todayStatsFilePath = todayStatsFilePath
        self.debugLogger = debugLogger
        self.nowProvider = nowProvider
    }

    public func routeHookEvent(_ payload: HookPayload) async -> HookRouteResult {
        let now = nowProvider()
        await ensureSessionExistsIfNeeded(payload: payload, now: now)

        let shouldAwaitPermission = payload.hookEventName == "PermissionRequest" || payload.hookEventName == "Elicitation"
        let requestId = shouldAwaitPermission ? interactionRequestId(payload: payload, now: now) : nil

        let session = await sessionStore.upsertSession(payload.sessionId) { session in
            session.id = payload.sessionId
            if !payload.cwd.isEmpty {
                session.cwd = payload.cwd
            }
            session.lastEventAt = now
            if let pid = payload.pid {
                session.pid = pid
            }
            if let tty = payload.tty {
                session.tty = tty
            }

            switch payload.hookEventName {
            case "SessionStart":
                session.status = .waitingForInput
                session.refreshTitleFromClaude()

            case "UserPromptSubmit":
                session.status = .processing
                if let message = payload.message, let title = normalizeTitle(message) {
                    session.title = title
                    session.titleSource = .userPrompt
                }

            case "PreToolUse":
                let toolName = payload.toolName ?? "Unknown"
                session.status = .runningTool(
                    toolName: toolName,
                    description: payload.toolDescriptionForStatus
                )
                session.toolCount += 1

                if toolName == "Task" {
                    session.hasSpawnedSubagent = true
                }

            case "PostToolUse", "PostToolUseFailure":
                session.status = .processing

            case "PermissionRequest":
                let toolName = payload.toolName ?? "Permission"
                session.status = .waitingForApproval(toolName: toolName, toolInput: payload.toolInput ?? .null)

            case "Elicitation":
                let toolName = payload.mcpServerName ?? "Question"
                session.status = .waitingForApproval(toolName: toolName, toolInput: payload.elicitationInput)

            case "ElicitationResult":
                session.status = .processing

            case "Stop", "SubagentStop":
                session.status = .waitingForInput

            case "SessionEnd":
                session.status = .ended

            case "PreCompact":
                session.status = .compacting

            case "Notification":
                if payload.notificationType == "idle_prompt" {
                    session.status = .waitingForInput
                } else if payload.notificationType == "permission_prompt" {
                    session.status = .waitingForApproval(
                        toolName: payload.toolName ?? "Permission",
                        toolInput: payload.toolInput ?? .null
                    )
                }

            default:
                break
            }
        }

        if payload.hookEventName == "PreToolUse", payload.toolName == "Task" {
            pendingSpawns.append((payload.sessionId, session.cwd, now))
        }

        if let requestId {
            await debugLogger.log(
                source: "hook",
                sessionId: payload.sessionId,
                hookEventName: payload.hookEventName,
                requestId: requestId,
                decision: "await_permission",
                responseJson: nil,
                payloadSummary: payload.toolName
            )
        }

        if payload.hookEventName == "SessionEnd" {
            await historyStore.save(session.asHistoryEntry(endedAt: now))
        }

        if let requestId {
            return .awaitPermissionDecision(requestId: requestId)
        }

        return .noResponse
    }

    public func routeStatuslineUpdate(_ update: StatuslineUpdate) async {
        let now = nowProvider()

        _ = await sessionStore.upsertSession(update.sessionId) { session in
            session.id = update.sessionId
            session.tokensIn = update.tokensIn
            session.tokensOut = update.tokensOut
            session.costUsd = update.costUsd
            session.model = update.model
            session.lastEventAt = now
        }

        var stats = todayStats
        stats.resetIfNewDay()

        let sessions = await sessionStore.allSessions().values
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        for session in sessions where Calendar.current.isDateInToday(session.startedAt) {
            let delta = stats.sessionTodayDelta(
                sessionId: session.id,
                totalIn: session.tokensIn,
                totalOut: session.tokensOut
            )
            totalIn += delta.0
            totalOut += delta.1
        }

        stats.tokensIn = totalIn
        stats.tokensOut = totalOut
        stats.updateRate(currentTotalOut: totalOut)
        stats.saveToDisk(filePath: todayStatsFilePath)
        todayStats = stats
    }

    public func resolvePermission(requestId: String, decision: PermissionDecision) {
        if let continuation = pendingPermissions.removeValue(forKey: requestId) {
            continuation.resume(returning: decision)
        } else {
            resolvedPermissions[requestId] = decision
        }

        Task {
            await debugLogger.log(
                source: "hook",
                sessionId: nil,
                hookEventName: "PermissionResolve",
                requestId: requestId,
                decision: decision.normalizedDecision(),
                responseJson: nil,
                payloadSummary: decision.reason
            )
        }
    }

    public func resolvePermissionFromCli(sessionId: String, toolUseId: String) {
        if pendingPermissions[toolUseId] != nil {
            resolvePermission(
                requestId: toolUseId,
                decision: PermissionDecision(decision: "allow", reason: "approved via CLI")
            )
            return
        }

        if let fallback = pendingPermissions.keys.first(where: { $0.hasPrefix("\(sessionId)-") }) {
            resolvePermission(
                requestId: fallback,
                decision: PermissionDecision(decision: "allow", reason: "approved via CLI")
            )
        }
    }

    public func awaitPermissionDecision(requestId: String) async -> PermissionDecision {
        if let resolved = resolvedPermissions.removeValue(forKey: requestId) {
            return resolved
        }

        return await withCheckedContinuation { continuation in
            pendingPermissions[requestId] = continuation
        }
    }

    private func ensureSessionExistsIfNeeded(payload: HookPayload, now: Date) async {
        let existing = await sessionStore.getSession(payload.sessionId)
        guard existing == nil else { return }

        let parentSessionId = matchParentSession(
            newSessionId: payload.sessionId,
            cwd: payload.cwd,
            now: now
        )

        _ = await sessionStore.upsertSession(payload.sessionId) { session in
            session.id = payload.sessionId
            session.cwd = payload.cwd
            session.status = .waitingForInput
            session.startedAt = now
            session.lastEventAt = now
            session.parentSessionId = parentSessionId
            session.pid = payload.pid
            session.tty = payload.tty
        }
    }

    private func interactionRequestId(payload: HookPayload, now: Date) -> String {
        if let elicitationId = payload.elicitationId, !elicitationId.isEmpty {
            return elicitationId
        }

        if let toolUseId = payload.toolUseId, !toolUseId.isEmpty {
            return toolUseId
        }

        return "\(payload.sessionId)-\(UInt64(now.timeIntervalSince1970 * 1000))"
    }

    private func matchParentSession(newSessionId: String, cwd: String, now: Date) -> String? {
        cleanupPendingSpawns(now: now)

        guard let index = pendingSpawns.indices.reversed().first(where: {
            let spawn = pendingSpawns[$0]
            return spawn.0 != newSessionId && spawn.1 == cwd && now.timeIntervalSince(spawn.2) <= 10
        }) else {
            return nil
        }

        let parentId = pendingSpawns[index].0
        pendingSpawns.remove(at: index)
        return parentId
    }

    private func cleanupPendingSpawns(now: Date) {
        pendingSpawns.removeAll { now.timeIntervalSince($0.2) > 30 }
    }

    #if DEBUG
    func pendingSpawnCountForTesting() -> Int {
        pendingSpawns.count
    }
    #endif
}

private extension HookPayload {
    var toolDescriptionForStatus: String? {
        guard case .object(let object)? = toolInput else { return nil }

        if case .string(let description)? = object["description"] {
            return description
        }

        if case .string(let command)? = object["command"] {
            return command
        }

        return nil
    }

    var elicitationInput: AnyCodable {
        var object: [String: AnyCodable] = [:]
        if let requestedSchema {
            object["requested_schema"] = requestedSchema
        }
        if let message {
            object["message"] = .string(message)
        }
        if let action {
            object["action"] = .string(action)
        }
        if let content {
            object["content"] = content
        }
        return .object(object)
    }
}

private extension Session {
    mutating func refreshTitleFromClaude() {
        guard title?.isEmpty != false else { return }

        let lastPath = URL(fileURLWithPath: cwd).lastPathComponent
        let fallback = lastPath.isEmpty ? cwd : lastPath
        title = fallback.isEmpty ? nil : fallback
    }

    func asHistoryEntry(endedAt: Date) -> HistoryEntry {
        HistoryEntry(
            sessionId: id,
            parentSessionId: parentSessionId,
            cwd: cwd,
            startedAt: startedAt,
            endedAt: endedAt,
            toolCount: toolCount,
            durationSecs: Int64(max(0, endedAt.timeIntervalSince(startedAt))),
            title: title,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            costUsd: costUsd,
            model: model,
            tty: tty
        )
    }
}
