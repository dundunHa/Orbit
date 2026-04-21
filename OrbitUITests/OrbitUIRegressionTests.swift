import XCTest

final class OrbitUIRegressionTests: OrbitUITestCase {
    func testPermissionAllowClearsPendingInteraction() throws {
        try assertPermissionDecision(
            buttonID: OrbitAccessibilityID.Permission.primaryAction,
            expectedDecision: "allow"
        )
    }

    func testPermissionDenyClearsPendingInteraction() throws {
        try assertPermissionDecision(
            buttonID: OrbitAccessibilityID.Permission.denyAction,
            expectedDecision: "deny"
        )
    }

    func testPermissionPassthroughClearsPendingInteraction() throws {
        try assertPermissionDecision(
            buttonID: OrbitAccessibilityID.Permission.passthroughAction,
            expectedDecision: "passthrough"
        )
    }

    func testOnboardingRetryMovesStateToInstalling() throws {
        try launchApp(with: .onboardingDrift)

        let retry = element(OrbitAccessibilityID.Onboarding.retryButton)
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        clickElement(retry)

        let diagnostics = try waitForDiagnostics { payload in
            payload.onboarding.typeName == "Installing"
        }

        XCTAssertFalse(diagnostics.onboarding.canRetry)
    }

    func testHistoryLoadMoreRevealsOlderEntry() throws {
        try launchApp(with: .activeAndHistory)

        let historyRow = element(OrbitAccessibilityID.History.row(sessionID: "hist-001"))
        XCTAssertFalse(historyRow.exists)

        let loadMore = element(OrbitAccessibilityID.Expanded.recentLoadMoreButton)
        XCTAssertTrue(loadMore.waitForExistence(timeout: 5))
        clickElement(loadMore)

        XCTAssertTrue(historyRow.waitForExistence(timeout: 5))
    }

    private func assertPermissionDecision(
        buttonID: String,
        expectedDecision: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try launchApp(with: .pendingPermission)

        let action = element(buttonID)
        XCTAssertTrue(action.waitForExistence(timeout: 5), file: file, line: line)
        clickElement(action, file: file, line: line)

        let diagnostics = try waitForDiagnostics(file: file, line: line) { payload in
            payload.pendingInteraction == nil && payload.lastDecision?.decision == expectedDecision
        }

        XCTAssertEqual(diagnostics.lastDecision?.requestId, "perm-request-001", file: file, line: line)
        XCTAssertFalse(element(OrbitAccessibilityID.Permission.root).exists, file: file, line: line)
    }
}
