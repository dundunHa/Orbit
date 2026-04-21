import Foundation
import XCTest

class OrbitUITestCase: XCTestCase {
    typealias DiagnosticsPayload = OrbitRuntimeDiagnostics

    var app: XCUIApplication!
    private(set) var diagnosticsURL: URL!
    private(set) var hookLogURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        defer {
            app = nil
        }

        if testRun?.hasSucceeded == false, let app {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Orbit UI failure screenshot"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }

        if testRun?.hasSucceeded == false, let diagnosticsURL, let data = try? Data(contentsOf: diagnosticsURL) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "runtime-diagnostics.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        if testRun?.hasSucceeded == false, let hookLogURL, let data = try? Data(contentsOf: hookLogURL) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.plain-text")
            attachment.name = "hook-debug.jsonl"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        try super.tearDownWithError()
    }

    func launchApp(with fixture: ScenarioFixture) throws {
        let scenarioURL = try fixture.resourceURL()
        diagnosticsURL = makeTempURL(prefix: "\(fixture.rawValue)-diagnostics", ext: "json")
        hookLogURL = makeTempURL(prefix: "\(fixture.rawValue)-hook", ext: "jsonl")

        app.launchEnvironment["ORBIT_TEST_SCENARIO_PATH"] = scenarioURL.path
        app.launchEnvironment["ORBIT_TEST_DIAGNOSTICS_PATH"] = diagnosticsURL.path
        app.launchEnvironment["ORBIT_HOOK_DEBUG_LOG_PATH"] = hookLogURL.path
        app.launch()
        activateApp()
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func clickElement(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        activateApp(file: file, line: line)
        XCTAssertTrue(element.waitForExistence(timeout: timeout), file: file, line: line)

        if !element.isHittable {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            activateApp(file: file, line: line)
        }

        element.click()
    }

    func waitForDiagnostics(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        predicate: (DiagnosticsPayload) -> Bool
    ) throws -> DiagnosticsPayload {
        let deadline = Date().addingTimeInterval(timeout)
        var lastPayload: DiagnosticsPayload?

        while Date() < deadline {
            if let payload = try? readDiagnostics() {
                lastPayload = payload
                if predicate(payload) {
                    return payload
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTFail("Timed out waiting for diagnostics predicate", file: file, line: line)
        return try XCTUnwrap(lastPayload, "No diagnostics payload was written", file: file, line: line)
    }

    func readDiagnostics() throws -> DiagnosticsPayload {
        let data = try Data(contentsOf: diagnosticsURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticsPayload.self, from: data)
    }

    private func makeTempURL(prefix: String, ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    private func activateApp(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), file: file, line: line)
    }
}
