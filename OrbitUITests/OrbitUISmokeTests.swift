import XCTest

final class OrbitUISmokeTests: OrbitUITestCase {
    func testIdleFixtureShowsPillOnly() throws {
        try launchApp(with: .idle)

        XCTAssertTrue(element(OrbitAccessibilityID.Pill.root).waitForExistence(timeout: 5))

        let diagnostics = try waitForDiagnostics { payload in
            payload.overlay?.phase == "collapsed"
        }

        XCTAssertEqual(diagnostics.scenario?.fixtureName, ScenarioFixture.idle.rawValue)
        XCTAssertEqual(diagnostics.counts.sessions, 0)
        XCTAssertNil(diagnostics.pendingInteraction)
    }

    func testPendingPermissionFixtureShowsPermissionPrompt() throws {
        try launchApp(with: .pendingPermission)

        XCTAssertTrue(element(OrbitAccessibilityID.Permission.root).waitForExistence(timeout: 5))
        XCTAssertTrue(element(OrbitAccessibilityID.Permission.message).waitForExistence(timeout: 5))
        XCTAssertTrue(element(OrbitAccessibilityID.Permission.toolInput).waitForExistence(timeout: 5))
        XCTAssertTrue(element(OrbitAccessibilityID.Permission.primaryAction).waitForExistence(timeout: 5))
        XCTAssertTrue(element(OrbitAccessibilityID.Permission.suggestion(index: 0)).waitForExistence(timeout: 5))
        XCTAssertTrue(element(OrbitAccessibilityID.Permission.denyAction).waitForExistence(timeout: 5))
        XCTAssertTrue(element(OrbitAccessibilityID.Permission.passthroughAction).waitForExistence(timeout: 5))

        let diagnostics = try waitForDiagnostics { payload in
            payload.overlay?.phase == "expanded"
                && payload.pendingInteraction?.id == "perm-request-001"
                && (payload.overlay?.expandedHeight ?? 0) > 240
        }

        XCTAssertEqual(diagnostics.counts.sessions, 1)
        XCTAssertEqual(diagnostics.pendingInteraction?.toolName, "Bash")
    }

    func testOnboardingDriftFixtureShowsRetryPath() throws {
        try launchApp(with: .onboardingDrift)

        XCTAssertTrue(element(OrbitAccessibilityID.Onboarding.root).waitForExistence(timeout: 5))
        XCTAssertTrue(element(OrbitAccessibilityID.Onboarding.retryButton).waitForExistence(timeout: 5))

        let diagnostics = try waitForDiagnostics { payload in
            payload.onboarding.typeName == "DriftDetected"
        }

        XCTAssertTrue(diagnostics.onboarding.canRetry)
        XCTAssertEqual(diagnostics.counts.sessions, 0)
    }

    func testActiveAndHistoryFixtureShowsExpandedLists() throws {
        try launchApp(with: .activeAndHistory)

        XCTAssertTrue(element(OrbitAccessibilityID.Expanded.root).waitForExistence(timeout: 5))
        XCTAssertTrue(element(OrbitAccessibilityID.Expanded.sessionTree).waitForExistence(timeout: 5))
        XCTAssertTrue(element(OrbitAccessibilityID.Expanded.recentLoadMoreButton).waitForExistence(timeout: 5))

        let diagnostics = try waitForDiagnostics { payload in
            payload.counts.sessions == 3 && payload.counts.historyEntries > 10
        }

        XCTAssertEqual(diagnostics.scenario?.fixtureName, ScenarioFixture.activeAndHistory.rawValue)
        XCTAssertEqual(diagnostics.selectedSessionId, "sess-root-running")
    }
}
