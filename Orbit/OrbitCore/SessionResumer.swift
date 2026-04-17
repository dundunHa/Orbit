import Foundation

public enum ResumeTerminal: Sendable, Equatable {
    case tmux(binary: String, targetPane: String)
    case alacritty
    case terminalApp
}

public enum ResumeLaunchSpec: Sendable, Equatable {
    case appleScript(String)
    case process(program: String, args: [String])
}

enum SessionResumerError: Error {
    case invalidSessionId(String)
    case invalidWorkingDirectory(String)
    case processFailed(program: String, stderr: String)
    case launchFailed(String)
}

public enum SessionResumer {
    static let tmuxCandidates: [String] = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/opt/local/bin/tmux",
    ]

    static let claudeCandidates: [String] = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    static let alacrittyBinary = "/Applications/Alacritty.app/Contents/MacOS/alacritty"

    public static func resume(session: Session) async throws {
        try validateSessionId(sessionId: session.id)

        let cwdURL = URL(fileURLWithPath: session.cwd)
        guard FileManager.default.fileExists(atPath: cwdURL.path) else {
            throw SessionResumerError.invalidWorkingDirectory("Working directory does not exist: \(session.cwd)")
        }

        let canonicalCwd = cwdURL.standardizedFileURL.path
        let terminal = detectTerminal(session: session)
        let spec = buildLaunchSpec(terminal: terminal, cwd: canonicalCwd, sessionId: session.id)
        try await execute(spec: spec)
    }

    static func detectTerminal(session: Session) -> ResumeTerminal {
        if let tmux = findTmuxBinary() {
            if let tty = session.tty, let targetPane = tryMatchTtyToPane(tmuxBinary: tmux, savedTty: tty) {
                return .tmux(binary: tmux, targetPane: targetPane)
            }
            if let targetPane = detectTmuxActivePane(tmuxBinary: tmux) {
                return .tmux(binary: tmux, targetPane: targetPane)
            }
        }

        if FileManager.default.fileExists(atPath: alacrittyBinary) {
            return .alacritty
        }

        return .terminalApp
    }

    static func buildLaunchSpec(terminal: ResumeTerminal, cwd: String, sessionId: String) -> ResumeLaunchSpec {
        let escapedId = shellSingleQuote(sessionId)
        let claude = shellSingleQuote(findClaudeBinary())

        switch terminal {
        case .tmux(let binary, let targetPane):
            return .process(
                program: binary,
                args: [
                    "split-window",
                    "-h",
                    "-t",
                    targetPane,
                    "-c",
                    cwd,
                    "bash",
                    "-lc",
                    "\(claude) --resume \(escapedId)",
                ]
            )

        case .alacritty:
            return .process(
                program: alacrittyBinary,
                args: [
                    "msg",
                    "create-window",
                    "-e",
                    "bash",
                    "-lc",
                    "cd \(shellSingleQuote(cwd)) && \(claude) --resume \(escapedId)",
                ]
            )

        case .terminalApp:
            let command = "cd \(escapeForAppleScript(cwd)) && claude --resume '\(escapeForAppleScript(sessionId))'"
            let script = """
            tell application \"Terminal\"
                activate
                do script \"\(command)\"
            end tell
            """
            return .appleScript(script)
        }
    }

    static func execute(spec: ResumeLaunchSpec) async throws {
        switch spec {
        case .appleScript(let script):
            let result = try await runProcess(program: "/usr/bin/osascript", args: ["-e", script], waitForExit: true)
            guard result.status == 0 else {
                throw SessionResumerError.processFailed(program: "/usr/bin/osascript", stderr: result.stderr)
            }

        case .process(let program, let args):
            _ = try await runProcess(program: program, args: args, waitForExit: false)
        }
    }

    static func validateSessionId(sessionId: String) throws {
        if sessionId.isEmpty {
            throw SessionResumerError.invalidSessionId("Session ID cannot be empty")
        }
        if sessionId.count > 128 {
            throw SessionResumerError.invalidSessionId("Session ID too long")
        }
        if sessionId.hasPrefix("-") || sessionId.hasPrefix(".") {
            throw SessionResumerError.invalidSessionId("Session ID cannot start with '-' or '.'")
        }
        if sessionId.contains("..") || sessionId.contains("/") || sessionId.contains("\\") {
            throw SessionResumerError.invalidSessionId("Session ID contains invalid sequence")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if sessionId.rangeOfCharacter(from: allowed.inverted) != nil {
            throw SessionResumerError.invalidSessionId("Session ID contains invalid characters")
        }
    }

    static func shellSingleQuote(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    static func parseTmuxClients(_ output: String) -> String? {
        output
            .split(whereSeparator: \ .isNewline)
            .compactMap { line -> (tty: String, activity: UInt64)? in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 3, let activity = UInt64(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    return nil
                }
                return (String(parts[0]), activity)
            }
            .max(by: { $0.activity < $1.activity })?
            .tty
    }

    static func parseTmuxDisplay(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \ .isNewline).first else {
            return nil
        }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 3 else {
            return nil
        }
        return "\(parts[0]):\(parts[1]).\(parts[2])"
    }

    private static func findTmuxBinary() -> String? {
        tmuxCandidates.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private static func findClaudeBinary() -> String {
        claudeCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? "claude"
    }

    private static func tryMatchTtyToPane(tmuxBinary: String, savedTty: String) -> String? {
        guard
            let output = try? runProcessSync(
                program: tmuxBinary,
                args: [
                    "list-panes",
                    "-a",
                    "-F",
                    "#{pane_tty}\t#{session_name}\t#{window_index}\t#{pane_index}",
                ]
            ),
            output.status == 0
        else {
            return nil
        }

        for line in output.stdout.split(whereSeparator: \ .isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            if parts.count >= 4, String(parts[0]) == savedTty {
                return "\(parts[1]):\(parts[2]).\(parts[3])"
            }
        }
        return nil
    }

    private static func detectTmuxActivePane(tmuxBinary: String) -> String? {
        guard
            let listClients = try? runProcessSync(
                program: tmuxBinary,
                args: ["list-clients", "-F", "#{client_tty}\t#{session_name}\t#{client_activity}"]
            ),
            listClients.status == 0,
            let clientTty = parseTmuxClients(listClients.stdout)
        else {
            return nil
        }

        guard
            let display = try? runProcessSync(
                program: tmuxBinary,
                args: [
                    "display-message",
                    "-p",
                    "-t",
                    clientTty,
                    "#{session_name}\t#{window_index}\t#{pane_index}",
                ]
            ),
            display.status == 0
        else {
            return nil
        }

        return parseTmuxDisplay(display.stdout)
    }

    private static func runProcessSync(program: String, args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw SessionResumerError.launchFailed("Failed to launch process \(program): \(error.localizedDescription)")
        }
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private static func runProcess(program: String, args: [String], waitForExit: Bool) async throws -> (status: Int32, stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: program)
                process.arguments = args

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: SessionResumerError.launchFailed("Failed to launch process \(program): \(error.localizedDescription)"))
                    return
                }

                if !waitForExit {
                    continuation.resume(returning: (0, "", ""))
                    return
                }

                process.waitUntilExit()
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, stdout, stderr))
            }
        }
    }
}
