import Foundation

// MARK: - Main Entry Point

let args = CommandLine.arguments
let subcommand = args.count > 1 ? args[1] : ""

switch subcommand {
case "hook":
    runHook()
case "statusline":
    runStatusline()
case "install":
    runInstall()
case "uninstall":
    let force = args.contains("--force")
    runUninstall(force: force)
default:
    printUsage()
    exit(1)
}

// MARK: - Hook

func runHook() {
    let inputData: Data
    if #available(macOS 10.15.4, *) {
        guard let data = try? FileHandle.standardInput.readToEnd() else { return }
        inputData = data
    } else {
        inputData = FileHandle.standardInput.readDataToEndOfFile()
    }
    guard !inputData.isEmpty else { return }
    let input = String(decoding: inputData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else { return }

    let waitForResponse = hookRequiresResponse(input)

    let response = SocketClient.connectAndSend(
        socketPath: Installer.socketPath(),
        payload: input,
        waitForResponse: waitForResponse
    )

    if waitForResponse {
        if let response, !response.isEmpty {
            print(response, terminator: "")
        } else {
            fputs("[orbit-helper] No response from Orbit (socket may be unavailable)\n", stderr)
        }
    }
}

func hookRequiresResponse(_ input: String) -> Bool {
    guard let data = input.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return false
    }

    let eventName = (json["hook_event_name"] as? String)
        ?? (json["hookEventName"] as? String)
        ?? ""

    switch eventName {
    case "PermissionRequest", "Elicitation", "ElicitationResult":
        return true
    default:
        return false
    }
}

// MARK: - Statusline

func runStatusline() {
    let inputData: Data
    if #available(macOS 10.15.4, *) {
        guard let data = try? FileHandle.standardInput.readToEnd() else { return }
        inputData = data
    } else {
        inputData = FileHandle.standardInput.readDataToEndOfFile()
    }
    guard !inputData.isEmpty else { return }
    let input = String(decoding: inputData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else { return }

    guard let message = buildStatuslineMessage(from: input) else {
        return
    }

    _ = SocketClient.connectAndSend(
        socketPath: Installer.socketPath(),
        payload: message,
        waitForResponse: false
    )
}

func buildStatuslineMessage(from input: String) -> String? {
    guard let data = input.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }

    let sessionId = json["session_id"] as? String
    let contextWindow = json["context_window"] as? [String: Any]
    let cost = json["cost"] as? [String: Any]
    let modelObj = json["model"] as? [String: Any]

    let tokensIn = contextWindow?["total_input_tokens"] as? UInt64
    let tokensOut = contextWindow?["total_output_tokens"] as? UInt64
    let costUsd = cost?["total_cost_usd"] as? Double
    let model = modelObj?["id"] as? String

    let result: [String: Any] = [
        "type": "StatuslineUpdate",
        "session_id": sessionId as Any,
        "tokens_in": tokensIn as Any,
        "tokens_out": tokensOut as Any,
        "cost_usd": costUsd as Any,
        "model": model as Any,
    ]

    guard let outData = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
          let outString = String(data: outData, encoding: .utf8)
    else {
        return nil
    }

    return outString
}

// MARK: - Install / Uninstall

func runInstall() {
    do {
        try Installer.silentInstall(orbitCliPath: Installer.FALLBACK_ORBIT_HELPER_PATH)
    } catch {
        fputs("Install failed: \(error)\n", stderr)
        exit(1)
    }
}

func runUninstall(force: Bool) {
    do {
        if force {
            try Installer.silentForceInstall(orbitCliPath: Installer.FALLBACK_ORBIT_HELPER_PATH)
        }
        try Installer.silentUninstall(force: force)
    } catch {
        fputs("Uninstall failed: \(error)\n", stderr)
        exit(1)
    }
}

// MARK: - Usage

func printUsage() {
    fputs("""
    orbit-helper — Orbit CLI helper for Claude Code hook events.

    Usage:
      orbit-helper hook          Forward a hook event from stdin to Orbit app
      orbit-helper statusline    Forward statusline data from stdin to Orbit app
      orbit-helper install       Install Orbit hooks into Claude Code settings
      orbit-helper uninstall     Uninstall Orbit hooks [--force]

    """, stderr)
}
