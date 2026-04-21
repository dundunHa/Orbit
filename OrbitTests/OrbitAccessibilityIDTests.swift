import Foundation
import Testing
@testable import Orbit

@Suite("OrbitAccessibilityID")
struct OrbitAccessibilityIDTests {
    @Test("fixed identifiers stay stable and unique")
    func fixedIdentifiersAreStableAndUnique() {
        let ids = [
            OrbitAccessibilityID.Pill.root,
            OrbitAccessibilityID.Pill.mascot,
            OrbitAccessibilityID.Pill.statusDot,
            OrbitAccessibilityID.Expanded.root,
            OrbitAccessibilityID.Expanded.activeSection,
            OrbitAccessibilityID.Expanded.recentSection,
            OrbitAccessibilityID.Expanded.sessionTree,
            OrbitAccessibilityID.Expanded.historyList,
            OrbitAccessibilityID.Expanded.recentEmptyState,
            OrbitAccessibilityID.Expanded.recentLoadMoreButton,
            OrbitAccessibilityID.SessionTree.emptyState,
            OrbitAccessibilityID.Onboarding.root,
            OrbitAccessibilityID.Onboarding.statusText,
            OrbitAccessibilityID.Onboarding.retryButton,
            OrbitAccessibilityID.Permission.root,
            OrbitAccessibilityID.Permission.toolApprovalBody,
            OrbitAccessibilityID.Permission.askUserQuestionBody,
            OrbitAccessibilityID.Permission.message,
            OrbitAccessibilityID.Permission.toolName,
            OrbitAccessibilityID.Permission.toolInput,
            OrbitAccessibilityID.Permission.questionProgress,
            OrbitAccessibilityID.Permission.questionHeader,
            OrbitAccessibilityID.Permission.questionText,
            OrbitAccessibilityID.Permission.fallbackText,
            OrbitAccessibilityID.Permission.primaryAction,
            OrbitAccessibilityID.Permission.denyAction,
            OrbitAccessibilityID.Permission.passthroughAction,
            OrbitAccessibilityID.Permission.backAction,
        ]

        #expect(ids.count == Set(ids).count)
        #expect(OrbitAccessibilityID.Pill.root == "orbit.pill.root")
        #expect(OrbitAccessibilityID.Permission.primaryAction == "orbit.permission.action.primary")
        #expect(OrbitAccessibilityID.Expanded.recentLoadMoreButton == "orbit.expanded.history-load-more")
    }

    @Test("session row identifiers use stable prefix and primary key")
    func sessionRowIdentifiersUsePrefixAndPrimaryKey() {
        let sessionID = "sess_123"
        let identifier = OrbitAccessibilityID.SessionTree.row(sessionID: sessionID)

        #expect(identifier == "orbit.session-tree.row.sess_123")
        #expect(identifier.hasPrefix(OrbitAccessibilityID.SessionTree.rowPrefix + "."))
        #expect(identifier == OrbitAccessibilityID.SessionTree.row(sessionID: sessionID))
        #expect(identifier != OrbitAccessibilityID.SessionTree.row(sessionID: "sess_456"))
    }

    @Test("history row identifiers use stable prefix and primary key")
    func historyRowIdentifiersUsePrefixAndPrimaryKey() {
        let sessionID = "history-42"
        let identifier = OrbitAccessibilityID.History.row(sessionID: sessionID)

        #expect(identifier == "orbit.history.row.history-42")
        #expect(identifier.hasPrefix(OrbitAccessibilityID.History.rowPrefix + "."))
        #expect(identifier == OrbitAccessibilityID.History.row(sessionID: sessionID))
        #expect(identifier != OrbitAccessibilityID.History.row(sessionID: "history-99"))
    }

    @Test("onboarding state identifiers ignore associated display text")
    func onboardingStateIdentifiersIgnoreDisplayText() {
        let conflictA = OrbitAccessibilityID.Onboarding.state(.conflictDetected("vim"))
        let conflictB = OrbitAccessibilityID.Onboarding.state(.conflictDetected("zed"))
        let errorA = OrbitAccessibilityID.Onboarding.state(.error("disk full"))
        let errorB = OrbitAccessibilityID.Onboarding.state(.error("permission denied"))

        #expect(conflictA == "orbit.onboarding.state.conflict-detected")
        #expect(conflictA == conflictB)
        #expect(errorA == "orbit.onboarding.state.error")
        #expect(errorA == errorB)
    }

    @Test("permission option identifiers depend on question id and index, not labels")
    func permissionOptionIdentifiersDependOnQuestionAndIndex() {
        let first = OrbitAccessibilityID.Permission.questionOption(questionID: "confirm-delete", optionIndex: 0)
        let second = OrbitAccessibilityID.Permission.questionOption(questionID: "confirm-delete", optionIndex: 1)
        let otherQuestion = OrbitAccessibilityID.Permission.questionOption(questionID: "choose-scope", optionIndex: 0)

        #expect(first == "orbit.permission.question-option.confirm-delete.0")
        #expect(first != second)
        #expect(first != otherQuestion)
    }

    @Test("permission suggestion identifiers are indexed and stable")
    func permissionSuggestionIdentifiersAreIndexedAndStable() {
        let first = OrbitAccessibilityID.Permission.suggestion(index: 0)
        let second = OrbitAccessibilityID.Permission.suggestion(index: 1)

        #expect(first == "orbit.permission.suggestion.0")
        #expect(second == "orbit.permission.suggestion.1")
        #expect(first != second)
    }
}
