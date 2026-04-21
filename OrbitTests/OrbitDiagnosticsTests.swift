import Foundation
import Testing
@testable import Orbit

@Suite("OrbitDiagnostics")
struct OrbitDiagnosticsTests {
    @Test("log entries are routed to the test sink")
    func logEntriesRouteToTestSink() {
        let sink = TestEntrySink()
        OrbitDiagnostics.shared.installTestSink { entry in sink.append(entry) }
        defer {
            OrbitDiagnostics.shared.installTestSink(nil)
        }

        OrbitDiagnostics.shared.notice(
            .overlay,
            "overlay.requestExpand",
            metadata: ["phase": "collapsed"]
        )

        let entries = sink.snapshot
        #expect(entries.count == 1)
        #expect(entries[0].kind == .log)
        #expect(entries[0].severity == .notice)
        #expect(entries[0].category == .overlay)
        #expect(entries[0].name == "overlay.requestExpand")
        #expect(entries[0].metadata["phase"] == "collapsed")
    }

    @Test("signpost intervals emit begin and end entries")
    func signpostIntervalsEmitBeginAndEndEntries() {
        let sink = TestEntrySink()
        OrbitDiagnostics.shared.installTestSink { entry in sink.append(entry) }
        defer {
            OrbitDiagnostics.shared.installTestSink(nil)
        }

        let interval = OrbitDiagnostics.shared.beginInterval(
            .hook,
            "hook.processSocketMessage",
            metadata: ["byteCount": "42"]
        )
        OrbitDiagnostics.shared.endInterval(interval)

        let entries = sink.snapshot
        #expect(entries.count == 2)
        #expect(entries[0].kind == .signpostBegin)
        #expect(entries[1].kind == .signpostEnd)
        #expect(entries[0].category == .hook)
        #expect(entries[1].metadata["byteCount"] == "42")
    }
}

private final class TestEntrySink: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [OrbitDiagnosticsEntry] = []

    func append(_ entry: OrbitDiagnosticsEntry) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var snapshot: [OrbitDiagnosticsEntry] {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return snapshot
    }
}
