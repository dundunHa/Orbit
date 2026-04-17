import Foundation
import Testing
@testable import Orbit

@Suite("OnboardingState")
struct OnboardingStateTests {

    @Test("typeName for all 8 states")
    func testTypeNames() {
        #expect(OnboardingState.welcome.typeName == "Welcome")
        #expect(OnboardingState.checking.typeName == "Checking")
        #expect(OnboardingState.installing.typeName == "Installing")
        #expect(OnboardingState.connected.typeName == "Connected")
        #expect(OnboardingState.conflictDetected("vim").typeName == "ConflictDetected")
        #expect(OnboardingState.permissionDenied.typeName == "PermissionDenied")
        #expect(OnboardingState.driftDetected.typeName == "DriftDetected")
        #expect(OnboardingState.error("oops").typeName == "Error")
    }

    @Test("trayStatus mapping for all states")
    func testTrayStatusMapping() {
        #expect(OnboardingState.welcome.trayStatus == .connecting)
        #expect(OnboardingState.checking.trayStatus == .connecting)
        #expect(OnboardingState.installing.trayStatus == .connecting)
        #expect(OnboardingState.connected.trayStatus == .connected)
        #expect(OnboardingState.conflictDetected("x").trayStatus == .conflict)
        #expect(OnboardingState.permissionDenied.trayStatus == .needsPermission)
        #expect(OnboardingState.driftDetected.trayStatus == .error)
        #expect(OnboardingState.error("x").trayStatus == .error)
    }

    @Test("needsAttention for all states")
    func testNeedsAttention() {
        #expect(OnboardingState.welcome.needsAttention == false)
        #expect(OnboardingState.checking.needsAttention == false)
        #expect(OnboardingState.installing.needsAttention == false)
        #expect(OnboardingState.connected.needsAttention == false)
        #expect(OnboardingState.conflictDetected("x").needsAttention == true)
        #expect(OnboardingState.permissionDenied.needsAttention == true)
        #expect(OnboardingState.driftDetected.needsAttention == true)
        #expect(OnboardingState.error("x").needsAttention == true)
    }

    @Test("isComplete for all states")
    func testIsComplete() {
        #expect(OnboardingState.welcome.isComplete == false)
        #expect(OnboardingState.checking.isComplete == false)
        #expect(OnboardingState.installing.isComplete == false)
        #expect(OnboardingState.connected.isComplete == true)
        #expect(OnboardingState.conflictDetected("x").isComplete == true)
        #expect(OnboardingState.permissionDenied.isComplete == true)
        #expect(OnboardingState.driftDetected.isComplete == true)
        #expect(OnboardingState.error("x").isComplete == true)
    }

    @Test("canRetry matches needsAttention")
    func testCanRetry() {
        #expect(OnboardingState.welcome.canRetry == false)
        #expect(OnboardingState.checking.canRetry == false)
        #expect(OnboardingState.installing.canRetry == false)
        #expect(OnboardingState.connected.canRetry == false)
        #expect(OnboardingState.conflictDetected("x").canRetry == true)
        #expect(OnboardingState.permissionDenied.canRetry == true)
        #expect(OnboardingState.driftDetected.canRetry == true)
        #expect(OnboardingState.error("x").canRetry == true)
    }

    @Test("statusText contains meaningful text")
    func testStatusText() {
        #expect(OnboardingState.welcome.statusText.contains("Welcome"))
        #expect(OnboardingState.checking.statusText.contains("Checking"))
        #expect(OnboardingState.installing.statusText.contains("Installing"))
        #expect(OnboardingState.connected.statusText.contains("Connected"))
        #expect(OnboardingState.conflictDetected("vim-statusline").statusText.contains("vim-statusline"))
        #expect(OnboardingState.permissionDenied.statusText.contains("Permission"))
        #expect(OnboardingState.driftDetected.statusText.contains("drift"))
        #expect(OnboardingState.error("disk full").statusText.contains("disk full"))
    }

    @Test("payload serializes to snake_case JSON keys")
    func testPayloadJSONKeys() throws {
        let payload = OnboardingState.connected.payload()
        let data = try JSONEncoder().encode(payload)
        let jsonObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(jsonObject["type"] as? String == "Connected")
        #expect(jsonObject["status_text"] as? String == "Connected to Claude Code!")
        #expect(jsonObject["tray_status"] as? String == "connected")
        #expect(jsonObject["tray_emoji"] as? String == "🟢")
        #expect(jsonObject["needs_attention"] as? Bool == false)
        #expect(jsonObject["is_complete"] as? Bool == true)
        #expect(jsonObject["can_retry"] as? Bool == false)

        #expect(jsonObject["typeName"] == nil)
        #expect(jsonObject["statusText"] == nil)
        #expect(jsonObject["needsAttention"] == nil)
    }

    @Test("payload round-trips through JSON")
    func testPayloadRoundTrip() throws {
        let original = OnboardingState.conflictDetected("vim").payload()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OnboardingStatePayload.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("TrayStatus")
struct TrayStatusTests {

    @Test("asString values")
    func testAsString() {
        #expect(TrayStatus.connecting.asString == "connecting")
        #expect(TrayStatus.connected.asString == "connected")
        #expect(TrayStatus.needsPermission.asString == "needs_permission")
        #expect(TrayStatus.conflict.asString == "conflict")
        #expect(TrayStatus.error.asString == "error")
    }

    @Test("emoji values")
    func testEmoji() {
        #expect(TrayStatus.connecting.emoji == "🟡")
        #expect(TrayStatus.connected.emoji == "🟢")
        #expect(TrayStatus.needsPermission.emoji == "🔴")
        #expect(TrayStatus.conflict.emoji == "⚠️")
        #expect(TrayStatus.error.emoji == "🔴")
    }

    @Test("tooltip values")
    func testTooltip() {
        #expect(TrayStatus.connecting.tooltip == "Orbit - Connecting...")
        #expect(TrayStatus.connected.tooltip == "Orbit - Connected")
        #expect(TrayStatus.needsPermission.tooltip == "Orbit - Needs Permission")
        #expect(TrayStatus.conflict.tooltip == "Orbit - Conflict Detected")
        #expect(TrayStatus.error.tooltip == "Orbit - Error")
    }
}

@Suite("OnboardingManager")
struct OnboardingManagerTests {

    @Test("initial state is welcome")
    @MainActor
    func testInitialState() {
        let manager = OnboardingManager(orbitHelperPath: "/tmp/fake-helper")
        #expect(manager.state == .welcome)
    }

    @Test("statePayload reflects current state")
    @MainActor
    func testStatePayload() {
        let manager = OnboardingManager(orbitHelperPath: "/tmp/fake-helper")
        let payload = manager.statePayload
        #expect(payload.typeName == "Welcome")
        #expect(payload.trayStatus == "connecting")
    }

    @Test("happy path: notInstalled → installing → connected")
    @MainActor
    func testHappyPath() throws {
        let home = makeTempHome()
        defer { cleanup(home) }

        writeClaudeSettings(home: home, settings: [:])

        let manager = OnboardingManager(orbitHelperPath: "/Applications/Orbit.app/Contents/MacOS/orbit-helper")
        manager.startBackgroundCheck(homeDir: home)

        #expect(manager.state == .connected)
        #expect(manager.statePayload.typeName == "Connected")
        #expect(manager.statePayload.isComplete == true)
    }

    @Test("already installed → connected directly")
    @MainActor
    func testAlreadyInstalled() throws {
        let home = makeTempHome()
        defer { cleanup(home) }

        let helperPath = "/Applications/Orbit.app/Contents/MacOS/orbit-helper"
        try Installer.silentInstall(orbitCliPath: helperPath, homeDir: home)

        let manager = OnboardingManager(orbitHelperPath: helperPath)
        manager.startBackgroundCheck(homeDir: home)

        #expect(manager.state == .connected)
    }

    @Test("conflict detection: otherTool")
    @MainActor
    func testConflictDetection() {
        let home = makeTempHome()
        defer { cleanup(home) }

        writeClaudeSettings(home: home, settings: [
            "statusLine": ["type": "builtin", "name": "something"]
        ])

        let manager = OnboardingManager(orbitHelperPath: "/Applications/Orbit.app/Contents/MacOS/orbit-helper")
        manager.startBackgroundCheck(homeDir: home)

        switch manager.state {
        case .conflictDetected:
            break
        default:
            Issue.record("expected conflictDetected, got \(manager.state)")
        }
        #expect(manager.statePayload.needsAttention == true)
    }

    @Test("retry from drift state succeeds via force install")
    @MainActor
    func testRetryFromDrift() throws {
        let home = makeTempHome()
        defer { cleanup(home) }

        let helperPath = "/Applications/Orbit.app/Contents/MacOS/orbit-helper"
        try Installer.silentInstall(orbitCliPath: helperPath, homeDir: home)

        writeClaudeSettings(home: home, settings: [
            "statusLine": ["type": "command", "command": "/usr/local/bin/other-tool"]
        ])

        let manager = OnboardingManager(orbitHelperPath: helperPath)
        manager.startBackgroundCheck(homeDir: home)
        #expect(manager.state == .driftDetected)
        #expect(manager.state.needsAttention == true)

        manager.retryInstall(homeDir: home)
        #expect(manager.state == .connected)
    }

    @Test("orphaned state maps to conflictDetected with repair message")
    @MainActor
    func testOrphanedState() throws {
        let home = makeTempHome()
        defer { cleanup(home) }

        let wrapperPath = "\(home)/.orbit/statusline-wrapper.sh"
        writeClaudeSettings(home: home, settings: [
            "statusLine": ["type": "command", "command": wrapperPath]
        ])

        let manager = OnboardingManager(orbitHelperPath: "/Applications/Orbit.app/Contents/MacOS/orbit-helper")
        manager.startBackgroundCheck(homeDir: home)

        switch manager.state {
        case .conflictDetected(let msg):
            #expect(msg.contains("incomplete"))
        default:
            Issue.record("expected conflictDetected for orphaned, got \(manager.state)")
        }
    }

    @Test("drift detected state")
    @MainActor
    func testDriftDetected() throws {
        let home = makeTempHome()
        defer { cleanup(home) }

        let helperPath = "/Applications/Orbit.app/Contents/MacOS/orbit-helper"
        try Installer.silentInstall(orbitCliPath: helperPath, homeDir: home)

        writeClaudeSettings(home: home, settings: [
            "statusLine": ["type": "command", "command": "/usr/local/bin/other-tool"]
        ])

        let manager = OnboardingManager(orbitHelperPath: helperPath)
        manager.startBackgroundCheck(homeDir: home)

        #expect(manager.state == .driftDetected)
        #expect(manager.statePayload.trayStatus == "error")
    }

    private func makeTempHome() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-onboarding-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func cleanup(_ home: String) {
        try? FileManager.default.removeItem(atPath: home)
    }

    private func writeClaudeSettings(home: String, settings: [String: Any]) {
        let path = "\(home)/.claude/settings.json"
        let url = URL(fileURLWithPath: path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try! JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: url, options: .atomic)
    }
}
