import Foundation
import OSLog

enum OrbitDiagnosticsCategory: String, Sendable {
    case launch
    case overlay
    case hook
    case scenario
    case runtimeDiagnostics = "runtime_diagnostics"
    case uiTest = "ui_test"
}

enum OrbitDiagnosticsSeverity: String, Sendable {
    case debug
    case info
    case notice
    case error
}

enum OrbitDiagnosticsKind: String, Sendable {
    case log
    case signpostEvent
    case signpostBegin
    case signpostEnd
}

struct OrbitDiagnosticsEntry: Equatable, Sendable {
    let kind: OrbitDiagnosticsKind
    let severity: OrbitDiagnosticsSeverity?
    let category: OrbitDiagnosticsCategory
    let name: String
    let metadata: [String: String]
}

struct OrbitSignpostInterval {
    fileprivate let category: OrbitDiagnosticsCategory
    fileprivate let name: StaticString
    fileprivate let state: OSSignpostIntervalState
    fileprivate let metadata: [String: String]
}

final class OrbitDiagnostics: @unchecked Sendable {
    static let shared = OrbitDiagnostics()

    private let subsystem: String
    private let sinkLock = NSLock()
    private var sink: (@Sendable (OrbitDiagnosticsEntry) -> Void)?

    init(subsystem: String = Bundle.main.bundleIdentifier ?? "Orbit") {
        self.subsystem = subsystem
    }

    func installTestSink(_ sink: (@Sendable (OrbitDiagnosticsEntry) -> Void)?) {
        sinkLock.withLock {
            self.sink = sink
        }
    }

    func debug(_ category: OrbitDiagnosticsCategory, _ name: String, metadata: [String: String] = [:]) {
        emitLog(.debug, category, name, metadata: metadata)
    }

    func info(_ category: OrbitDiagnosticsCategory, _ name: String, metadata: [String: String] = [:]) {
        emitLog(.info, category, name, metadata: metadata)
    }

    func notice(_ category: OrbitDiagnosticsCategory, _ name: String, metadata: [String: String] = [:]) {
        emitLog(.notice, category, name, metadata: metadata)
    }

    func error(_ category: OrbitDiagnosticsCategory, _ name: String, metadata: [String: String] = [:]) {
        emitLog(.error, category, name, metadata: metadata)
    }

    func event(_ category: OrbitDiagnosticsCategory, _ name: StaticString, metadata: [String: String] = [:]) {
        signposter(for: category).emitEvent(name)
        record(
            OrbitDiagnosticsEntry(
                kind: .signpostEvent,
                severity: nil,
                category: category,
                name: String(describing: name),
                metadata: metadata
            )
        )
    }

    func beginInterval(_ category: OrbitDiagnosticsCategory, _ name: StaticString, metadata: [String: String] = [:]) -> OrbitSignpostInterval {
        let state = signposter(for: category).beginInterval(name)
        record(
            OrbitDiagnosticsEntry(
                kind: .signpostBegin,
                severity: nil,
                category: category,
                name: String(describing: name),
                metadata: metadata
            )
        )
        return OrbitSignpostInterval(category: category, name: name, state: state, metadata: metadata)
    }

    func endInterval(_ interval: OrbitSignpostInterval) {
        signposter(for: interval.category).endInterval(interval.name, interval.state)
        record(
            OrbitDiagnosticsEntry(
                kind: .signpostEnd,
                severity: nil,
                category: interval.category,
                name: String(describing: interval.name),
                metadata: interval.metadata
            )
        )
    }

    private func emitLog(
        _ severity: OrbitDiagnosticsSeverity,
        _ category: OrbitDiagnosticsCategory,
        _ name: String,
        metadata: [String: String]
    ) {
        let message = renderMessage(name, metadata: metadata)
        let logger = logger(for: category)

        switch severity {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .notice:
            logger.notice("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }

        record(
            OrbitDiagnosticsEntry(
                kind: .log,
                severity: severity,
                category: category,
                name: name,
                metadata: metadata
            )
        )
    }

    private func renderMessage(_ name: String, metadata: [String: String]) -> String {
        guard !metadata.isEmpty else {
            return name
        }
        let suffix = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return "\(name) \(suffix)"
    }

    private func record(_ entry: OrbitDiagnosticsEntry) {
        let sink = sinkLock.withLock { self.sink }
        sink?(entry)
    }

    private func logger(for category: OrbitDiagnosticsCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    private func signposter(for category: OrbitDiagnosticsCategory) -> OSSignposter {
        OSSignposter(logger: logger(for: category))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
