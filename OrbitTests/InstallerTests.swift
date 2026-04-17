import Foundation
import Testing
@testable import Orbit

@Suite("Installer")
struct InstallerTests {
    private let hookCommand = "/Applications/Orbit.app/Contents/MacOS/orbit-helper hook"

    @Test("addOrbitHooks adds all 13 required events")
    func testAddOrbitHooksAddsAll13Events() throws {
        var settings: [String: Any] = [:]
        try Installer.addOrbitHooks(to: &settings, hookCommand: hookCommand)

        let hooks = try #require(settings["hooks"] as? [String: Any])
        #expect(hooks.count == Installer.HOOK_EVENTS.count)

        for event in Installer.HOOK_EVENTS {
            let entries = try #require(hooks[event] as? [Any])
            #expect(entries.contains(where: { entryContainsHookCommand($0, command: hookCommand) }))
        }
    }

    @Test("addOrbitHooks is idempotent")
    func testAddOrbitHooksIdempotent() throws {
        var settings: [String: Any] = [:]
        try Installer.addOrbitHooks(to: &settings, hookCommand: hookCommand)
        try Installer.addOrbitHooks(to: &settings, hookCommand: hookCommand)

        let hooks = try #require(settings["hooks"] as? [String: Any])
        for event in Installer.HOOK_EVENTS {
            let entries = try #require(hooks[event] as? [Any])
            let count = entries.filter { entryContainsHookCommand($0, command: hookCommand) }.count
            #expect(count == 1)
        }
    }

    @Test("removeOrbitHooks removes only Orbit hooks")
    func testRemoveOrbitHooksRemovesOnlyOrbit() throws {
        var settings: [String: Any] = [
            "hooks": [
                "PostToolUse": [
                    ["hooks": [["type": "command", "command": hookCommand]]],
                    ["hooks": [["type": "command", "command": "/usr/local/bin/custom-hook"]]],
                ]
            ]
        ]

        try Installer.removeOrbitHooks(from: &settings, hookCommands: [hookCommand])

        let hooks = try #require(settings["hooks"] as? [String: Any])
        let post = try #require(hooks["PostToolUse"] as? [Any])
        #expect(post.count == 1)
        #expect(entryContainsHookCommand(post[0], command: "/usr/local/bin/custom-hook"))
    }

    @Test("classifyStatusLine absent")
    func testClassifyStatusLineAbsent() {
        let config = Installer.classifyStatusLine([:], managedCommand: "/tmp/managed.sh")
        #expect(config == .absent)
    }

    @Test("classifyStatusLine standard command")
    func testClassifyStatusLineStandard() throws {
        let config = Installer.classifyStatusLine(
            ["statusLine": ["type": "command", "command": "/usr/local/bin/status"]],
            managedCommand: "/tmp/managed.sh"
        )

        switch config {
        case .standardCommand(let command):
            #expect(command == "/usr/local/bin/status")
        default:
            Issue.record("expected standard command")
        }
    }

    @Test("classifyStatusLine orbit orphaned")
    func testClassifyStatusLineOrbitOrphaned() {
        let managed = "/tmp/orbit-wrapper.sh"
        let config = Installer.classifyStatusLine(
            ["statusLine": ["type": "command", "command": managed]],
            managedCommand: managed
        )
        #expect(config == .orbitOrphaned)
    }

    @Test("classifyStatusLine unsupported")
    func testClassifyStatusLineUnsupported() {
        let config = Installer.classifyStatusLine(
            ["statusLine": ["type": "builtin", "name": "whatever"]],
            managedCommand: "/tmp/managed.sh"
        )
        #expect(config == .unsupported)
    }

    @Test("renderWrapperScript includes helper path substitution")
    func testRenderWrapperScriptContainsHelperPath() {
        let script = Installer.renderWrapperScript(
            helperPath: "/Applications/Orbit.app/Contents/MacOS/orbit-helper",
            originalCommand: "/usr/local/bin/status --json"
        )
        #expect(script.contains("ORBIT_HELPER='/Applications/Orbit.app/Contents/MacOS/orbit-helper'"))
        #expect(!script.contains("__ORBIT_HELPER_PATH__"))
        #expect(!script.contains("__ORBIT_ORIGINAL_CMD__"))
    }

    @Test("silentInstall writes hooks, wrapper and state")
    func testSilentInstallAddsHooksAndWrapper() throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        try Installer.silentInstall(
            orbitCliPath: "/Applications/Orbit.app/Contents/MacOS/orbit-helper",
            homeDir: home
        )

        let settings = try readJSONDict(at: claudeSettingsPath(home: home))
        let hooks = try #require(settings["hooks"] as? [String: Any])
        #expect(hooks.count == Installer.HOOK_EVENTS.count)

        for event in Installer.HOOK_EVENTS {
            let entries = try #require(hooks[event] as? [Any])
            #expect(entries.contains(where: { entryContainsHookCommand($0, command: hookCommand) }))
        }

        let statusLine = try #require(settings["statusLine"] as? [String: Any])
        #expect(statusLine["type"] as? String == "command")
        #expect(statusLine["command"] as? String == "\(home)/.orbit/statusline-wrapper.sh")

        let wrapperPath = "\(home)/.orbit/statusline-wrapper.sh"
        let statePath = "\(home)/.orbit/statusline-state.json"
        #expect(FileManager.default.fileExists(atPath: wrapperPath))
        #expect(FileManager.default.fileExists(atPath: statePath))
    }

    @Test("silentUninstall restores original statusLine")
    func testSilentUninstallRestoresStatusLine() throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let originalStatus = "/usr/local/bin/original-status --flag"
        try writeJSONDict(
            ["statusLine": ["type": "command", "command": originalStatus]],
            to: claudeSettingsPath(home: home)
        )

        try Installer.silentInstall(
            orbitCliPath: "/Applications/Orbit.app/Contents/MacOS/orbit-helper",
            homeDir: home
        )
        try Installer.silentUninstall(homeDir: home)

        let restored = try readJSONDict(at: claudeSettingsPath(home: home))
        let statusLine = try #require(restored["statusLine"] as? [String: Any])
        #expect(statusLine["command"] as? String == originalStatus)

        #expect(!FileManager.default.fileExists(atPath: "\(home)/.orbit/statusline-wrapper.sh"))
        #expect(!FileManager.default.fileExists(atPath: "\(home)/.orbit/statusline-state.json"))
    }

    @Test("silentUninstall in drift mode preserves user config")
    func testSilentUninstallDriftPreservesConfig() throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        try writeJSONDict(
            ["statusLine": ["type": "command", "command": "/usr/local/bin/original"]],
            to: claudeSettingsPath(home: home)
        )

        try Installer.silentInstall(
            orbitCliPath: "/Applications/Orbit.app/Contents/MacOS/orbit-helper",
            homeDir: home
        )

        try writeJSONDict(
            ["statusLine": ["type": "command", "command": "/usr/local/bin/user-drifted"]],
            to: claudeSettingsPath(home: home)
        )

        try Installer.silentUninstall(homeDir: home)

        let drifted = try readJSONDict(at: claudeSettingsPath(home: home))
        let statusLine = try #require(drifted["statusLine"] as? [String: Any])
        #expect(statusLine["command"] as? String == "/usr/local/bin/user-drifted")

        #expect(FileManager.default.fileExists(atPath: "\(home)/.orbit/statusline-wrapper.sh"))
        #expect(FileManager.default.fileExists(atPath: "\(home)/.orbit/statusline-state.json"))
    }

    @Test("checkInstallState reports orbitInstalled after install")
    func testCheckInstallStateOrbitInstalled() throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        try Installer.silentInstall(
            orbitCliPath: "/Applications/Orbit.app/Contents/MacOS/orbit-helper",
            homeDir: home
        )

        let state = try Installer.checkInstallState(
            orbitHelperPath: "/Applications/Orbit.app/Contents/MacOS/orbit-helper",
            homeDir: home
        )
        #expect(state == .orbitInstalled)
    }

    @Test("checkInstallState reports notInstalled for empty settings")
    func testCheckInstallStateNotInstalled() throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }

        let state = try Installer.checkInstallState(
            orbitHelperPath: "/Applications/Orbit.app/Contents/MacOS/orbit-helper",
            homeDir: home
        )
        #expect(state == .notInstalled)
    }

    private func makeTempHome() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func claudeSettingsPath(home: String) -> String {
        "\(home)/.claude/settings.json"
    }

    private func readJSONDict(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw NSError(domain: "InstallerTests", code: 1)
        }
        return dict
    }

    private func writeJSONDict(_ dict: [String: Any], to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func entryContainsHookCommand(_ entry: Any, command: String) -> Bool {
        guard
            let entryObject = entry as? [String: Any],
            let hooks = entryObject["hooks"] as? [Any]
        else {
            return false
        }

        return hooks.contains { hook in
            guard let hookObject = hook as? [String: Any] else {
                return false
            }
            return hookObject["type"] as? String == "command"
                && hookObject["command"] as? String == command
        }
    }
}
