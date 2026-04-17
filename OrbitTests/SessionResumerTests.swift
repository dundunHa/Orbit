import Foundation
import Testing
@testable import Orbit

@Suite("SessionResumer")
struct SessionResumerTests {
    @Test("testValidateSessionIdRejectsEmpty")
    func testValidateSessionIdRejectsEmpty() {
        do {
            try SessionResumer.validateSessionId(sessionId: "")
            Issue.record("expected empty session id to throw")
        } catch {
            #expect(Bool(true))
        }
    }

    @Test("testValidateSessionIdRejectsLong")
    func testValidateSessionIdRejectsLong() {
        let longId = String(repeating: "a", count: 129)
        do {
            try SessionResumer.validateSessionId(sessionId: longId)
            Issue.record("expected long session id to throw")
        } catch {
            #expect(Bool(true))
        }
    }

    @Test("testValidateSessionIdRejectsPathTraversal")
    func testValidateSessionIdRejectsPathTraversal() {
        for value in ["..", "abc/def", "abc\\def"] {
            do {
                try SessionResumer.validateSessionId(sessionId: value)
                Issue.record("expected path traversal-like session id to throw: \(value)")
            } catch {
                #expect(Bool(true))
            }
        }
    }

    @Test("testValidateSessionIdAcceptsValid")
    func testValidateSessionIdAcceptsValid() throws {
        try SessionResumer.validateSessionId(sessionId: "ses_abc123-def")
    }

    @Test("testShellSingleQuoteEscapesSingleQuotes")
    func testShellSingleQuoteEscapesSingleQuotes() {
        #expect(SessionResumer.shellSingleQuote("it's") == "'it'\"'\"'s'")
    }

    @Test("testBuildTmuxLaunchSpec")
    func testBuildTmuxLaunchSpec() {
        let spec = SessionResumer.buildLaunchSpec(
            terminal: .tmux(binary: "/opt/homebrew/bin/tmux", targetPane: "main:0.1"),
            cwd: "/tmp/project",
            sessionId: "ses_abc123-def"
        )

        switch spec {
        case .process(let program, let args):
            #expect(program == "/opt/homebrew/bin/tmux")
            #expect(args.count == 9)
            #expect(args[0] == "split-window")
            #expect(args[1] == "-h")
            #expect(args[2] == "-t")
            #expect(args[3] == "main:0.1")
            #expect(args[4] == "-c")
            #expect(args[5] == "/tmp/project")
            #expect(args[6] == "bash")
            #expect(args[7] == "-lc")
            #expect(args[8].contains("--resume 'ses_abc123-def'"))
        case .appleScript:
            Issue.record("expected process launch spec")
        }
    }

    @Test("testBuildTerminalAppLaunchSpec")
    func testBuildTerminalAppLaunchSpec() {
        let spec = SessionResumer.buildLaunchSpec(
            terminal: .terminalApp,
            cwd: "/tmp/project",
            sessionId: "ses_abc123-def"
        )

        switch spec {
        case .appleScript(let script):
            #expect(script.contains("tell application \"Terminal\""))
            #expect(script.contains("do script"))
            #expect(script.contains("ses_abc123-def"))
        case .process:
            Issue.record("expected AppleScript launch spec")
        }
    }

    @Test("testBuildAlacrittyLaunchSpec")
    func testBuildAlacrittyLaunchSpec() {
        let spec = SessionResumer.buildLaunchSpec(
            terminal: .alacritty,
            cwd: "/tmp/project",
            sessionId: "ses_abc123-def"
        )

        switch spec {
        case .process(let program, let args):
            #expect(program == SessionResumer.alacrittyBinary)
            #expect(args.count == 6)
            #expect(args[0] == "msg")
            #expect(args[1] == "create-window")
            #expect(args[2] == "-e")
            #expect(args[3] == "bash")
            #expect(args[4] == "-lc")
            #expect(args[5].contains("cd '/tmp/project'"))
            #expect(args[5].contains("--resume 'ses_abc123-def'"))
        case .appleScript:
            Issue.record("expected process launch spec")
        }
    }

    @Test("testParseTmuxClients")
    func testParseTmuxClients() {
        let output = """
        /dev/ttys001\tmain\t1712000100
        /dev/ttys002\twork\t1712000200
        /dev/ttys003\tdev\t1712000050
        """
        #expect(SessionResumer.parseTmuxClients(output) == "/dev/ttys002")
    }

    @Test("testParseTmuxDisplay")
    func testParseTmuxDisplay() {
        #expect(SessionResumer.parseTmuxDisplay("main\t0\t1\n") == "main:0.1")
    }
}
