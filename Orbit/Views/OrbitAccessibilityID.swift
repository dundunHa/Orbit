import Foundation

public enum OrbitAccessibilityID {
    public enum Pill {
        public static let root = "orbit.pill.root"
        public static let mascot = "orbit.pill.mascot"
        public static let statusDot = "orbit.pill.status-dot"
    }

    public enum Expanded {
        public static let root = "orbit.expanded.root"
        public static let activeSection = "orbit.expanded.active-section"
        public static let recentSection = "orbit.expanded.recent-section"
        public static let sessionTree = "orbit.expanded.session-tree"
        public static let historyList = "orbit.expanded.history-list"
        public static let recentEmptyState = "orbit.expanded.history-empty"
        public static let recentLoadMoreButton = "orbit.expanded.history-load-more"
    }

    public enum SessionTree {
        public static let emptyState = "orbit.session-tree.empty"
        public static let rowPrefix = "orbit.session-tree.row"

        public static func row(sessionID: String) -> String {
            dynamicID(prefix: rowPrefix, key: sessionID)
        }
    }

    public enum History {
        public static let rowPrefix = "orbit.history.row"

        public static func row(sessionID: String) -> String {
            dynamicID(prefix: rowPrefix, key: sessionID)
        }
    }

    public enum Onboarding {
        public static let root = "orbit.onboarding.root"
        public static let statusText = "orbit.onboarding.status-text"
        public static let retryButton = "orbit.onboarding.retry"
        public static let statePrefix = "orbit.onboarding.state"

        public static func state(key: String) -> String {
            dynamicID(prefix: statePrefix, key: key)
        }
    }

    public enum Permission {
        public static let root = "orbit.permission.root"
        public static let toolApprovalBody = "orbit.permission.tool-approval"
        public static let askUserQuestionBody = "orbit.permission.ask-user-question"
        public static let message = "orbit.permission.message"
        public static let toolName = "orbit.permission.tool-name"
        public static let toolInput = "orbit.permission.tool-input"
        public static let questionProgress = "orbit.permission.question-progress"
        public static let questionHeader = "orbit.permission.question-header"
        public static let questionText = "orbit.permission.question-text"
        public static let fallbackText = "orbit.permission.fallback-text"
        public static let primaryAction = "orbit.permission.action.primary"
        public static let denyAction = "orbit.permission.action.deny"
        public static let passthroughAction = "orbit.permission.action.passthrough"
        public static let backAction = "orbit.permission.action.back"
        public static let suggestionPrefix = "orbit.permission.suggestion"
        public static let questionOptionPrefix = "orbit.permission.question-option"

        public static func suggestion(index: Int) -> String {
            indexedID(prefix: suggestionPrefix, index: index)
        }

        public static func questionOption(questionID: String, optionIndex: Int) -> String {
            dynamicID(
                prefix: questionOptionPrefix,
                key: "\(questionID).\(optionIndex)"
            )
        }
    }

    private static func indexedID(prefix: String, index: Int) -> String {
        dynamicID(prefix: prefix, key: String(index))
    }

    private static func dynamicID(prefix: String, key: String) -> String {
        "\(prefix).\(key)"
    }
}
