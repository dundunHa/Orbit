import Combine
import Foundation

// MARK: - OnboardingState

public enum OnboardingState: Sendable, Equatable {
    case welcome
    case checking
    case installing
    case connected
    case conflictDetected(String)
    case permissionDenied
    case driftDetected
    case error(String)
}

extension OnboardingState {
    public var typeName: String {
        switch self {
        case .welcome: "Welcome"
        case .checking: "Checking"
        case .installing: "Installing"
        case .connected: "Connected"
        case .conflictDetected: "ConflictDetected"
        case .permissionDenied: "PermissionDenied"
        case .driftDetected: "DriftDetected"
        case .error: "Error"
        }
    }

    public var statusText: String {
        switch self {
        case .welcome:
            "Welcome to Orbit! Click Start to begin setup."
        case .checking:
            "Checking Claude Code integration..."
        case .installing:
            "Installing Orbit hooks..."
        case .connected:
            "Connected to Claude Code!"
        case .conflictDetected(let tool):
            "Conflict detected: \(tool)"
        case .permissionDenied:
            "Permission denied. Please check file permissions."
        case .driftDetected:
            "Configuration drift detected. Click Retry to repair."
        case .error(let msg):
            "Error: \(msg)"
        }
    }

    public var trayStatus: TrayStatus {
        switch self {
        case .welcome, .checking, .installing:
            .connecting
        case .connected:
            .connected
        case .permissionDenied:
            .needsPermission
        case .conflictDetected:
            .conflict
        case .driftDetected, .error:
            .error
        }
    }

    public var needsAttention: Bool {
        switch self {
        case .conflictDetected, .permissionDenied, .driftDetected, .error:
            true
        case .welcome, .checking, .installing, .connected:
            false
        }
    }

    public var canRetry: Bool {
        needsAttention
    }

    public var isComplete: Bool {
        switch self {
        case .welcome, .checking, .installing:
            false
        case .connected, .conflictDetected, .permissionDenied, .driftDetected, .error:
            true
        }
    }

    public func payload() -> OnboardingStatePayload {
        OnboardingStatePayload(
            typeName: typeName,
            statusText: statusText,
            trayStatus: trayStatus.asString,
            trayEmoji: trayStatus.emoji,
            needsAttention: needsAttention,
            isComplete: isComplete,
            canRetry: canRetry
        )
    }
}

// MARK: - TrayStatus

public enum TrayStatus: Sendable, Equatable {
    case connecting
    case connected
    case needsPermission
    case conflict
    case error

    public var asString: String {
        switch self {
        case .connecting: "connecting"
        case .connected: "connected"
        case .needsPermission: "needs_permission"
        case .conflict: "conflict"
        case .error: "error"
        }
    }

    public var emoji: String {
        switch self {
        case .connecting: "🟡"
        case .connected: "🟢"
        case .needsPermission: "🔴"
        case .conflict: "⚠️"
        case .error: "🔴"
        }
    }

    public var tooltip: String {
        switch self {
        case .connecting: "Orbit - Connecting..."
        case .connected: "Orbit - Connected"
        case .needsPermission: "Orbit - Needs Permission"
        case .conflict: "Orbit - Conflict Detected"
        case .error: "Orbit - Error"
        }
    }
}

// MARK: - OnboardingStatePayload

public struct OnboardingStatePayload: Codable, Sendable, Equatable {
    public let typeName: String
    public let statusText: String
    public let trayStatus: String
    public let trayEmoji: String
    public let needsAttention: Bool
    public let isComplete: Bool
    public let canRetry: Bool

    private enum CodingKeys: String, CodingKey {
        case typeName = "type"
        case statusText = "status_text"
        case trayStatus = "tray_status"
        case trayEmoji = "tray_emoji"
        case needsAttention = "needs_attention"
        case isComplete = "is_complete"
        case canRetry = "can_retry"
    }

    public init(
        typeName: String,
        statusText: String,
        trayStatus: String,
        trayEmoji: String,
        needsAttention: Bool,
        isComplete: Bool,
        canRetry: Bool
    ) {
        self.typeName = typeName
        self.statusText = statusText
        self.trayStatus = trayStatus
        self.trayEmoji = trayEmoji
        self.needsAttention = needsAttention
        self.isComplete = isComplete
        self.canRetry = canRetry
    }
}

// MARK: - OnboardingManager

@MainActor
public final class OnboardingManager: ObservableObject, Sendable {
    @Published public private(set) var state: OnboardingState = .welcome
    private let orbitHelperPath: String

    public init(orbitHelperPath: String) {
        self.orbitHelperPath = orbitHelperPath
    }

    public var statePayload: OnboardingStatePayload {
        state.payload()
    }

    public func startBackgroundCheck(homeDir: String? = nil) {
        state = .checking

        let helperPath = orbitHelperPath
        let installState: InstallState
        do {
            installState = try Installer.checkInstallState(orbitHelperPath: helperPath, homeDir: homeDir)
        } catch {
            state = .error(error.localizedDescription)
            return
        }

        switch installState {
        case .orbitInstalled:
            state = .connected
        case .notInstalled:
            state = .installing
            do {
                try Installer.silentInstall(orbitCliPath: helperPath, homeDir: homeDir)
                state = .connected
            } catch let installError as InstallError {
                handleInstallError(installError)
            } catch {
                state = .error(error.localizedDescription)
            }
        case .driftDetected:
            state = .driftDetected
        case .otherTool(let tool):
            state = .conflictDetected(tool)
        case .orphaned:
            state = .conflictDetected("Orbit integration is incomplete. Click Retry to repair it.")
        }
    }

    public func retryInstall(homeDir: String? = nil) {
        state = .installing

        let helperPath = orbitHelperPath
        do {
            try Installer.silentForceInstall(orbitCliPath: helperPath, homeDir: homeDir)
            state = .connected
        } catch let installError as InstallError {
            switch installError {
            case .permissionDenied:
                state = .permissionDenied
            case .conflict(let tool):
                state = .error(tool)
            case .drift:
                state = .error("Configuration drift detected")
            case .other(let msg):
                state = .error(msg)
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func handleInstallError(_ installError: InstallError) {
        switch installError {
        case .permissionDenied:
            state = .permissionDenied
        case .conflict(let tool):
            state = .conflictDetected(tool)
        case .drift:
            state = .driftDetected
        case .other(let msg):
            state = .error(msg)
        }
    }
}
