import Foundation

extension OrbitRuntimeDiagnostics {
    static func capture(
        viewModel: AppViewModel,
        overlayController: OverlayController?,
        revision: Int,
        scenario: ScenarioSummary?,
        lastDecision: DecisionSummary?
    ) -> OrbitRuntimeDiagnostics {
        let overlay = overlayController.map { controller in
            let snapshot = controller.snapshot
            return OverlaySummary(
                phase: String(describing: snapshot.phase),
                wantExpanded: snapshot.wantExpanded,
                isAnimating: snapshot.isAnimating,
                collapseAfterTransition: snapshot.collapseAfterTransition,
                isExpanded: snapshot.isExpanded,
                expandedHeight: snapshot.expandedHeight
            )
        }
        let pending = viewModel.pendingInteraction.map {
            PendingInteractionSummary(
                id: $0.id,
                kind: $0.kind,
                sessionId: $0.sessionId,
                toolName: $0.toolName,
                message: $0.message
            )
        }
        let onboarding = viewModel.onboardingState.payload()

        return OrbitRuntimeDiagnostics(
            version: currentVersion,
            revision: revision,
            updatedAt: Date(),
            scenario: scenario,
            overlay: overlay,
            counts: CountsSummary(
                sessions: viewModel.sessions.count,
                historyEntries: viewModel.historyEntries.count
            ),
            pendingInteraction: pending,
            pendingQueueDepth: viewModel.pendingInteractions.count,
            selectedSessionId: viewModel.selectedSessionId,
            activeSessionId: viewModel.activeSession()?.id,
            onboarding: OnboardingSummary(
                typeName: onboarding.typeName,
                statusText: onboarding.statusText,
                trayStatus: onboarding.trayStatus,
                trayEmoji: onboarding.trayEmoji,
                needsAttention: onboarding.needsAttention,
                isComplete: onboarding.isComplete,
                canRetry: onboarding.canRetry
            ),
            lastDecision: lastDecision
        )
    }
}

actor OrbitRuntimeDiagnosticsWriter {
    private let fileURL: URL?
    private let encoder: JSONEncoder
    private var newestSubmittedRevision = 0

    init(filePath: String?) {
        self.fileURL = filePath.map { URL(fileURLWithPath: $0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    @discardableResult
    func submit(_ diagnostics: OrbitRuntimeDiagnostics) -> Bool {
        guard let fileURL else {
            return false
        }
        guard diagnostics.revision > newestSubmittedRevision else {
            return false
        }
        newestSubmittedRevision = diagnostics.revision

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(diagnostics)
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            OrbitDiagnostics.shared.error(
                .runtimeDiagnostics,
                "runtimeDiagnostics.writeFailed",
                metadata: [
                    "path": fileURL.path,
                    "error": String(describing: error)
                ]
            )
            return false
        }
    }
}
