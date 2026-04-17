import Foundation
import Darwin

public struct StatuslineState: Codable, Sendable {
    public var originalStatusline: AnyCodable?
    public var originalWasAbsent: Bool
    public var managedCommand: String
    public var hookCommand: String?
    public var installId: String
    public var installedAt: String

    private enum CodingKeys: String, CodingKey {
        case originalStatusline = "original_statusline"
        case originalWasAbsent = "original_was_absent"
        case managedCommand = "managed_command"
        case hookCommand = "hook_command"
        case installId = "install_id"
        case installedAt = "installed_at"
    }

    public init(
        originalStatusline: AnyCodable?,
        originalWasAbsent: Bool,
        managedCommand: String,
        hookCommand: String?,
        installId: String,
        installedAt: String
    ) {
        self.originalStatusline = originalStatusline
        self.originalWasAbsent = originalWasAbsent
        self.managedCommand = managedCommand
        self.hookCommand = hookCommand
        self.installId = installId
        self.installedAt = installedAt
    }
}

public enum StatusLineConfig: Sendable, Equatable {
    case absent
    case standardCommand(command: String)
    case unsupported
    case orbitOrphaned
}

public enum UninstallMode: Sendable, Equatable {
    case restoreOriginal
    case preserveDrift
    case forceCleanup
}

public enum InstallError: Error, Sendable, Equatable {
    case permissionDenied
    case drift
    case conflict(String)
    case other(String)
}

public enum InstallState: Sendable, Equatable {
    case orbitInstalled
    case notInstalled
    case driftDetected
    case otherTool(String)
    case orphaned
}

public enum Installer {
    public static let SOCKET_PATH = "/tmp/orbit.sock"
    public static let SOCKET_PATH_ENV = "ORBIT_SOCKET_PATH"
    public static let FALLBACK_ORBIT_HELPER_PATH = "/Applications/Orbit.app/Contents/MacOS/orbit-helper"

    private static let STATUSLINE_STATE_FILE = "statusline-state.json"
    private static let STATUSLINE_WRAPPER_FILE = "statusline-wrapper.sh"
    private static let CLI_BINARY_NAME = "orbit-cli"
    private static let HELPER_BINARY_NAME = "orbit-helper"

    public static let HOOK_EVENTS: [String] = [
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "Stop",
        "SessionStart",
        "SessionEnd",
        "PermissionRequest",
        "Notification",
        "UserPromptSubmit",
        "SubagentStop",
        "PreCompact",
        "Elicitation",
        "ElicitationResult",
    ]

    public static let STATUSLINE_WRAPPER_TEMPLATE = #"""
#!/bin/bash
# Orbit statusline wrapper — fail-open, non-blocking
# Captures token data for Orbit, then passes through to user's original statusline

# Read stdin once, save to variable
INPUT=$(cat 2>/dev/null || true)

# Send to Orbit (non-blocking, fail-open)
ORBIT_HELPER=__ORBIT_HELPER_PATH__
if [ -n "$ORBIT_HELPER" ]; then
    (
        if command -v perl >/dev/null 2>&1; then
            echo "$INPUT" | perl -e 'alarm 2; system @ARGV' "$ORBIT_HELPER" statusline >/dev/null 2>&1 || true
        else
            echo "$INPUT" | "$ORBIT_HELPER" statusline >/dev/null 2>&1 || true
        fi
    ) &
    disown 2>/dev/null || true
fi

# Pass through to original statusline script (if any)
ORIGINAL_CMD=__ORBIT_ORIGINAL_CMD__
if [ -n "$ORIGINAL_CMD" ]; then
    if [ "$ORIGINAL_CMD" = "$0" ]; then
        exit 0
    fi

    echo "$INPUT" | /bin/bash -lc "$ORIGINAL_CMD"
fi
"""#

    public static func socketPath() -> String {
        ProcessInfo.processInfo.environment[SOCKET_PATH_ENV] ?? SOCKET_PATH
    }

    public static func checkInstallState(orbitHelperPath: String, homeDir: String? = nil) throws -> InstallState {
        let settingsPath = claudeSettingsPath(homeDir: homeDir)
        let statePath = statuslineStatePath(homeDir: homeDir)
        let wrapperPath = statuslineWrapperPath(homeDir: homeDir)
        let managedCommand = wrapperPath

        let settings = try readSettings(path: settingsPath)
        let state = try readStatuslineState(path: statePath)
        let currentCommand = getStatuslineCommand(settings)
        let desiredHookCommand = helperHookCommand(orbitHelperPath)

        if let state {
            if currentCommand == state.managedCommand {
                if !FileManager.default.fileExists(atPath: wrapperPath) {
                    return .orphaned
                }

                if !settingsHaveRequiredHookCommands(settings, command: desiredHookCommand)
                    || state.hookCommand != desiredHookCommand {
                    return .notInstalled
                }

                return .orbitInstalled
            }

            if currentCommand == managedCommand {
                return .orphaned
            }

            return .driftDetected
        }

        switch classifyStatuslineInternal(settings, managedCommand: managedCommand) {
        case .orbitOrphaned:
            return .orphaned
        case .unsupported:
            return .otherTool(currentCommand ?? "unknown")
        case .standardCommand, .absent:
            return .notInstalled
        }
    }

    public static func silentInstall(orbitCliPath: String, homeDir: String? = nil) throws {
        let settingsPath = claudeSettingsPath(homeDir: homeDir)
        try withFileLock(path: settingsPath) {
            let currentSettings = try readSettings(path: settingsPath)
            let hookCommand = helperHookCommand(orbitCliPath)
            let prepared = try prepareInstall(
                settings: currentSettings,
                helperPath: orbitCliPath,
                hookCommand: hookCommand,
                homeDir: homeDir,
                force: false
            )

            do {
                try writeWrapperScript(path: prepared.wrapperPath, script: prepared.wrapperScript)
                try writeSettings(path: settingsPath, settings: prepared.settings)
                try writeStatuslineState(path: statuslineStatePath(homeDir: homeDir), state: prepared.state)
            } catch {
                _ = try? removeFileIfExists(prepared.wrapperPath)
                throw mapInstallError(error)
            }
        }
    }

    public static func silentUninstall(force: Bool = false, homeDir: String? = nil) throws {
        let settingsPath = claudeSettingsPath(homeDir: homeDir)
        let settingsExisted = FileManager.default.fileExists(atPath: settingsPath)

        try withFileLock(path: settingsPath) {
            let currentSettings = try readSettings(path: settingsPath)
            let prepared = try prepareUninstall(settings: currentSettings, force: force, homeDir: homeDir)

            if prepared.mode == .preserveDrift {
                return
            }

            var settingsToWrite = prepared.settings
            let staleHookCommands = collectHookCommandsForCleanup(state: prepared.state, settings: settingsToWrite)
            try removeOrbitHooks(from: &settingsToWrite, hookCommands: staleHookCommands)

            if settingsExisted {
                try writeSettings(path: settingsPath, settings: settingsToWrite)
            }

            for path in prepared.filesToRemove {
                try removeFileIfExists(path)
            }
        }
    }

    public static func silentForceInstall(orbitCliPath: String, homeDir: String? = nil) throws {
        let settingsPath = claudeSettingsPath(homeDir: homeDir)
        let managedCommand = statuslineWrapperPath(homeDir: homeDir)

        try withFileLock(path: settingsPath) {
            let currentSettings = try readSettings(path: settingsPath)
            try backupSettings(currentSettings, homeDir: homeDir)

            let statePath = statuslineStatePath(homeDir: homeDir)
            let oldState = try readStatuslineState(path: statePath)
            _ = try? removeFileIfExists(statePath)

            var settingsForInstall = currentSettings
            if getStatuslineCommand(settingsForInstall) == managedCommand {
                if let oldState, !hasSelfReferentialOriginalStatusline(oldState) {
                    restoreOriginalStatusline(&settingsForInstall, state: oldState)
                } else {
                    clearStatusline(&settingsForInstall)
                }
            }

            let staleHookCommands = collectHookCommandsForCleanup(state: oldState, settings: settingsForInstall)
            try removeOrbitHooks(from: &settingsForInstall, hookCommands: staleHookCommands)

            let hookCommand = helperHookCommand(orbitCliPath)
            let prepared = try prepareInstall(
                settings: settingsForInstall,
                helperPath: orbitCliPath,
                hookCommand: hookCommand,
                homeDir: homeDir,
                force: true
            )

            do {
                try writeWrapperScript(path: prepared.wrapperPath, script: prepared.wrapperScript)
                try writeSettings(path: settingsPath, settings: prepared.settings)
                try writeStatuslineState(path: statePath, state: prepared.state)
            } catch {
                _ = try? writeSettings(path: settingsPath, settings: currentSettings)
                _ = try? removeFileIfExists(prepared.wrapperPath)
                if let oldState {
                    _ = try? writeStatuslineState(path: statePath, state: oldState)
                }
                throw mapInstallError(error)
            }
        }
    }

    public static func addOrbitHooks(to settings: inout [String: Any], hookCommand: String) throws {
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        guard settings["hooks"] == nil || settings["hooks"] is [String: Any] else {
            throw InstallError.other("settings.json hooks field must be an object when present")
        }

        for event in HOOK_EVENTS {
            var eventHooks = hooks[event] as? [Any] ?? []
            if hooks[event] != nil, !(hooks[event] is [Any]) {
                throw InstallError.other("hooks.\(event) must be an array when present")
            }

            let alreadyRegistered = eventHooks.contains { entryHasHookCommand($0, command: hookCommand) }
            if !alreadyRegistered {
                eventHooks.append([
                    "hooks": [[
                        "type": "command",
                        "command": hookCommand,
                    ]]
                ])
            }

            hooks[event] = eventHooks
        }

        settings["hooks"] = hooks
    }

    public static func removeOrbitHooks(from settings: inout [String: Any], hookCommands: [String]) throws {
        guard !hookCommands.isEmpty else { return }
        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for (event, value) in hooks {
            guard let entries = value as? [Any] else {
                continue
            }

            let filtered = entries.filter { entry in
                !hookCommands.contains(where: { command in entryHasHookCommand(entry, command: command) })
            }

            if filtered.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = filtered
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
    }

    public static func classifyStatusLine(_ settings: [String: Any], managedCommand: String) -> StatusLineConfig {
        classifyStatuslineInternal(settings, managedCommand: managedCommand)
    }

    public static func renderWrapperScript(helperPath: String, originalCommand: String?) -> String {
        STATUSLINE_WRAPPER_TEMPLATE
            .replacingOccurrences(of: "__ORBIT_HELPER_PATH__", with: shellSingleQuote(helperPath))
            .replacingOccurrences(of: "__ORBIT_ORIGINAL_CMD__", with: shellSingleQuote(originalCommand ?? ""))
    }

    // MARK: - Prepare

    private struct PreparedInstall {
        var settings: [String: Any]
        var state: StatuslineState
        var wrapperPath: String
        var wrapperScript: String
    }

    private struct PreparedUninstall {
        var settings: [String: Any]
        var mode: UninstallMode
        var state: StatuslineState?
        var filesToRemove: [String]
    }

    private static func prepareInstall(
        settings: [String: Any],
        helperPath: String,
        hookCommand: String,
        homeDir: String?,
        force: Bool
    ) throws -> PreparedInstall {
        let wrapperPath = statuslineWrapperPath(homeDir: homeDir)
        let statePath = statuslineStatePath(homeDir: homeDir)
        let managedCommand = wrapperPath
        let currentCommand = getStatuslineCommand(settings)

        if let existingState = try readStatuslineState(path: statePath) {
            if currentCommand == existingState.managedCommand {
                if !FileManager.default.fileExists(atPath: wrapperPath) {
                    if !force {
                        throw InstallError.conflict("statusLine points to Orbit wrapper, but wrapper file is missing")
                    }
                } else {
                    var state = existingState
                    if hasSelfReferentialOriginalStatusline(state) {
                        state.originalStatusline = nil
                        state.originalWasAbsent = true
                    }

                    var idempotentSettings = settings
                    let staleHookCommands = collectHookCommandsForCleanup(state: state, settings: idempotentSettings)
                    try removeOrbitHooks(from: &idempotentSettings, hookCommands: staleHookCommands)
                    state.hookCommand = hookCommand
                    try addOrbitHooks(to: &idempotentSettings, hookCommand: hookCommand)

                    return PreparedInstall(
                        settings: idempotentSettings,
                        state: state,
                        wrapperPath: wrapperPath,
                        wrapperScript: renderWrapperScript(helperPath: helperPath, originalCommand: originalStatuslineCommand(state))
                    )
                }
            } else if !force {
                throw InstallError.drift
            }
        }

        switch classifyStatuslineInternal(settings, managedCommand: managedCommand) {
        case .absent, .standardCommand:
            break
        case .unsupported:
            throw InstallError.conflict("statusLine has unsupported configuration")
        case .orbitOrphaned:
            if !force {
                throw InstallError.conflict("settings.json points to Orbit wrapper but no install state exists")
            }
        }

        var newSettings = settings
        let originalWasAbsent = settings["statusLine"] == nil
        let originalStatusline = try settings["statusLine"].map(AnyCodable.fromAny)

        try addOrbitHooks(to: &newSettings, hookCommand: hookCommand)
        newSettings["statusLine"] = [
            "type": "command",
            "command": managedCommand,
        ]

        return PreparedInstall(
            settings: newSettings,
            state: StatuslineState(
                originalStatusline: originalStatusline,
                originalWasAbsent: originalWasAbsent,
                managedCommand: managedCommand,
                hookCommand: hookCommand,
                installId: generateInstallId(),
                installedAt: nowISO8601()
            ),
            wrapperPath: wrapperPath,
            wrapperScript: renderWrapperScript(helperPath: helperPath, originalCommand: currentCommand)
        )
    }

    private static func prepareUninstall(settings: [String: Any], force: Bool, homeDir: String?) throws -> PreparedUninstall {
        let statePath = statuslineStatePath(homeDir: homeDir)
        let wrapperPath = statuslineWrapperPath(homeDir: homeDir)
        let currentCommand = getStatuslineCommand(settings)

        guard let state = try readStatuslineState(path: statePath) else {
            if force, currentCommand == wrapperPath {
                var cleaned = settings
                clearStatusline(&cleaned)
                return PreparedUninstall(
                    settings: cleaned,
                    mode: .forceCleanup,
                    state: nil,
                    filesToRemove: [wrapperPath]
                )
            }

            return PreparedUninstall(
                settings: settings,
                mode: .restoreOriginal,
                state: nil,
                filesToRemove: []
            )
        }

        let mode = evaluateUninstallMode(currentCommand: currentCommand, state: state, force: force)
        if mode == .preserveDrift {
            return PreparedUninstall(
                settings: settings,
                mode: mode,
                state: state,
                filesToRemove: []
            )
        }

        var newSettings = settings
        restoreOriginalStatusline(&newSettings, state: state)

        return PreparedUninstall(
            settings: newSettings,
            mode: mode,
            state: state,
            filesToRemove: [statePath, wrapperPath]
        )
    }

    // MARK: - Low-level IO

    private static func readSettings(path: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else {
            return [:]
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data.isEmpty {
            return [:]
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw InstallError.other("settings.json top-level value must be a JSON object")
        }
        return dict
    }

    private static func writeSettings(path: String, settings: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(settings) else {
            throw InstallError.other("settings contains non-JSON values")
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try atomicWrite(path: path, bytes: data)
    }

    private static func readStatuslineState(path: String) throws -> StatuslineState? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(StatuslineState.self, from: data)
    }

    private static func writeStatuslineState(path: String, state: StatuslineState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try atomicWrite(path: path, bytes: data)
    }

    private static func writeWrapperScript(path: String, script: String) throws {
        guard let data = script.data(using: .utf8) else {
            throw InstallError.other("failed to encode wrapper script")
        }
        try atomicWrite(path: path, bytes: data)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private static func removeFileIfExists(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }
        try FileManager.default.removeItem(atPath: path)
    }

    private static func atomicWrite(path: String, bytes: Data) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let unique = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        let tmpPath = "\(path).tmp.\(getpid()).\(unique)"
        let tmpURL = URL(fileURLWithPath: tmpPath)

        do {
            try bytes.write(to: tmpURL)
        } catch {
            throw mapInstallError(error)
        }

        if rename(tmpPath, path) != 0 {
            _ = try? FileManager.default.removeItem(atPath: tmpPath)
            throw mapErrnoToInstallError("failed to atomically rename \(tmpPath) to \(path)")
        }
    }

    private static func withFileLock<T>(path: String, body: () throws -> T) throws -> T {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw mapErrnoToInstallError("failed to open lock file: \(path)")
        }
        defer { close(fd) }

        guard flock(fd, LOCK_EX) == 0 else {
            throw mapErrnoToInstallError("failed to acquire file lock: \(path)")
        }
        defer { _ = flock(fd, LOCK_UN) }

        return try body()
    }

    // MARK: - Helpers

    private static func claudeSettingsPath(homeDir: String?) -> String {
        "\(resolvedHomeDir(homeDir))/.claude/settings.json"
    }

    private static func statuslineStatePath(homeDir: String?) -> String {
        "\(orbitDir(homeDir: homeDir))/\(STATUSLINE_STATE_FILE)"
    }

    private static func statuslineWrapperPath(homeDir: String?) -> String {
        "\(orbitDir(homeDir: homeDir))/\(STATUSLINE_WRAPPER_FILE)"
    }

    private static func orbitDir(homeDir: String?) -> String {
        "\(resolvedHomeDir(homeDir))/.orbit"
    }

    private static func resolvedHomeDir(_ homeDir: String?) -> String {
        homeDir ?? NSHomeDirectory()
    }

    private static func classifyStatuslineInternal(_ settings: [String: Any], managedCommand: String) -> StatusLineConfig {
        guard let statusLine = settings["statusLine"] else {
            return .absent
        }
        guard let statusObject = statusLine as? [String: Any] else {
            return .unsupported
        }
        guard statusObject["type"] as? String == "command" else {
            return .unsupported
        }
        guard let command = statusObject["command"] as? String else {
            return .unsupported
        }
        if command == managedCommand {
            return .orbitOrphaned
        }
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .unsupported
        }
        return .standardCommand(command: command)
    }

    private static func entryHasHookCommand(_ entry: Any, command: String) -> Bool {
        guard
            let entryObj = entry as? [String: Any],
            let hooks = entryObj["hooks"] as? [Any]
        else {
            return false
        }

        return hooks.contains { hook in
            guard let hookObj = hook as? [String: Any] else {
                return false
            }
            return hookObj["type"] as? String == "command"
                && hookObj["command"] as? String == command
        }
    }

    private static func settingsHaveRequiredHookCommands(_ settings: [String: Any], command: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else {
            return false
        }

        return HOOK_EVENTS.allSatisfy { event in
            guard let entries = hooks[event] as? [Any] else {
                return false
            }
            return entries.contains(where: { entryHasHookCommand($0, command: command) })
        }
    }

    private static func getStatuslineCommand(_ settings: [String: Any]) -> String? {
        (settings["statusLine"] as? [String: Any])?["command"] as? String
    }

    private static func evaluateUninstallMode(currentCommand: String?, state: StatuslineState, force: Bool) -> UninstallMode {
        if currentCommand == state.managedCommand {
            return .restoreOriginal
        }
        return force ? .forceCleanup : .preserveDrift
    }

    private static func helperHookCommand(_ helperPath: String) -> String {
        "\(helperPath) hook"
    }

    private static func shellSingleQuote(_ input: String) -> String {
        if input.isEmpty { return "''" }
        return "'\(input.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func originalStatuslineCommand(_ state: StatuslineState) -> String? {
        guard
            let original = state.originalStatusline?.asAny() as? [String: Any],
            original["type"] as? String == "command"
        else {
            return nil
        }
        return original["command"] as? String
    }

    private static func hasSelfReferentialOriginalStatusline(_ state: StatuslineState) -> Bool {
        originalStatuslineCommand(state) == state.managedCommand
    }

    private static func clearStatusline(_ settings: inout [String: Any]) {
        settings.removeValue(forKey: "statusLine")
    }

    private static func restoreOriginalStatusline(_ settings: inout [String: Any], state: StatuslineState) {
        if state.originalWasAbsent {
            settings.removeValue(forKey: "statusLine")
            return
        }

        if let original = state.originalStatusline?.asAny() {
            settings["statusLine"] = original
        } else {
            settings["statusLine"] = NSNull()
        }
    }

    private static func collectHookCommandsForCleanup(state: StatuslineState?, settings: [String: Any]) -> [String] {
        var commands: [String] = []

        if let command = state?.hookCommand {
            pushUnique(&commands, command)
            for alias in orbitHookAliases(command) {
                pushUnique(&commands, alias)
            }
        }

        let currentHook = helperHookCommand(FALLBACK_ORBIT_HELPER_PATH)
        pushUnique(&commands, currentHook)
        for alias in orbitHookAliases(currentHook) {
            pushUnique(&commands, alias)
        }

        for command in orbitHookCommandsInSettings(settings) {
            pushUnique(&commands, command)
        }

        return commands
    }

    private static func orbitHookAliases(_ command: String) -> [String] {
        guard command.hasSuffix(" hook") else { return [] }
        let binaryPath = String(command.dropLast(" hook".count))
        let binaryURL = URL(fileURLWithPath: binaryPath)
        let fileName = binaryURL.lastPathComponent

        if fileName == HELPER_BINARY_NAME {
            let cliPath = binaryURL.deletingLastPathComponent().appendingPathComponent(CLI_BINARY_NAME).path
            return [helperHookCommand(cliPath)]
        }

        if fileName == CLI_BINARY_NAME {
            let helperPath = binaryURL.deletingLastPathComponent().appendingPathComponent(HELPER_BINARY_NAME).path
            return [helperHookCommand(helperPath)]
        }

        return []
    }

    private static func orbitHookCommandsInSettings(_ settings: [String: Any]) -> [String] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var commands: [String] = []

        for value in hooks.values {
            guard let entries = value as? [Any] else { continue }
            for entry in entries {
                guard
                    let entryObj = entry as? [String: Any],
                    let innerHooks = entryObj["hooks"] as? [Any]
                else {
                    continue
                }

                for hook in innerHooks {
                    guard
                        let hookObj = hook as? [String: Any],
                        hookObj["type"] as? String == "command",
                        let command = hookObj["command"] as? String,
                        !orbitHookAliases(command).isEmpty
                    else {
                        continue
                    }
                    pushUnique(&commands, command)
                }
            }
        }

        return commands
    }

    private static func pushUnique(_ commands: inout [String], _ command: String) {
        if !commands.contains(command) {
            commands.append(command)
        }
    }

    private static func backupSettings(_ settings: [String: Any], homeDir: String?) throws {
        let backupDir = "\(orbitDir(homeDir: homeDir))/backups"
        let timestamp = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let name = "claude-settings-\(formatter.string(from: timestamp))-orbit-\(Int(timestamp.timeIntervalSince1970 * 1_000_000_000)).json"
        let path = "\(backupDir)/\(name)"

        guard JSONSerialization.isValidJSONObject(settings) else {
            throw InstallError.other("failed to serialize settings backup")
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try atomicWrite(path: path, bytes: data)
    }

    private static func nowISO8601() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func generateInstallId() -> String {
        "orbit-\(getpid())-\(UInt64(Date().timeIntervalSince1970 * 1_000_000_000))"
    }

    private static func mapInstallError(_ error: Error) -> InstallError {
        if let installError = error as? InstallError {
            return installError
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == EACCES || nsError.code == EPERM {
            return .permissionDenied
        }

        return .other(nsError.localizedDescription)
    }

    private static func mapErrnoToInstallError(_ fallback: String) -> InstallError {
        switch errno {
        case EACCES, EPERM:
            return .permissionDenied
        default:
            if let cString = strerror(errno) {
                return .other("\(fallback): \(String(cString: cString))")
            }
            return .other(fallback)
        }
    }
}

private extension AnyCodable {
    static func fromAny(_ any: Any) throws -> AnyCodable {
        switch any {
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .int(value)
        case let value as Double:
            return .double(value)
        case let value as String:
            return .string(value)
        case let value as [Any]:
            return .array(try value.map { try fromAny($0) })
        case let value as [String: Any]:
            var mapped: [String: AnyCodable] = [:]
            for (key, element) in value {
                mapped[key] = try fromAny(element)
            }
            return .object(mapped)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            let doubleValue = value.doubleValue
            if floor(doubleValue) == doubleValue {
                return .int(value.intValue)
            }
            return .double(doubleValue)
        default:
            throw InstallError.other("unsupported JSON value in AnyCodable conversion")
        }
    }

    func asAny() -> Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map { $0.asAny() }
        case .object(let values):
            return values.mapValues { $0.asAny() }
        }
    }
}
