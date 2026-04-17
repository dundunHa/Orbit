import Foundation
import Dispatch
import Testing
@testable import Orbit

@Suite("AnomalyDetector")
struct AnomalyDetectorTests {
    @Test("processing session becomes anomaly")
    func testProcessingBecomesAnomaly() async throws {
        let time = MutableTimeSource(Date(timeIntervalSince1970: 1_000))
        let detector = AnomalyDetector(threshold: 60, pollInterval: 0.05, now: time.get)
        let recorder = EventRecorder()
        let snapshot = makeSnapshot(
            id: "session-1",
            status: .processing,
            lastEventAt: time.get().addingTimeInterval(-61)
        )

        await detector.start(sessions: { [snapshot] in [snapshot.id: snapshot] }) { id, status in
            await recorder.record(id: id, status: status)
            await detector.stop()
        }

        try await Task.sleep(nanoseconds: 120_000_000)

        let events = await recorder.events()
        #expect(events.count == 1)
        #expect(events[0].0 == "session-1")
        #expect(events[0].1 == .anomaly(idleSeconds: 61, previousStatus: .processing))
    }

    @Test("running tool session becomes anomaly")
    func testRunningToolBecomesAnomaly() async throws {
        let time = MutableTimeSource(Date(timeIntervalSince1970: 2_000))
        let detector = AnomalyDetector(threshold: 60, pollInterval: 0.05, now: time.get)
        let recorder = EventRecorder()
        let snapshot = makeSnapshot(
            id: "session-2",
            status: .runningTool(toolName: "grep"),
            lastEventAt: time.get().addingTimeInterval(-75)
        )

        await detector.start(sessions: { [snapshot] in [snapshot.id: snapshot] }) { id, status in
            await recorder.record(id: id, status: status)
            await detector.stop()
        }

        try await Task.sleep(nanoseconds: 120_000_000)

        let events = await recorder.events()
        #expect(events.count == 1)
        #expect(events[0].0 == "session-2")
        #expect(events[0].1 == .anomaly(idleSeconds: 75, previousStatus: .runningTool(toolName: "grep")))
    }

    @Test("other status does not become anomaly")
    func testOtherStatusNoAnomaly() async throws {
        let time = MutableTimeSource(Date(timeIntervalSince1970: 3_000))
        let detector = AnomalyDetector(threshold: 60, pollInterval: 0.05, now: time.get)
        let recorder = EventRecorder()
        let snapshot = makeSnapshot(
            id: "session-3",
            status: .other,
            lastEventAt: time.get().addingTimeInterval(-120)
        )

        await detector.start(sessions: { [snapshot] in [snapshot.id: snapshot] }) { id, status in
            await recorder.record(id: id, status: status)
        }

        try await Task.sleep(nanoseconds: 120_000_000)
        await detector.stop()

        #expect(await recorder.events().isEmpty)
    }

    @Test("anomaly idle seconds update on next tick")
    func testAnomalyIdleSecondsUpdated() async throws {
        let time = MutableTimeSource(Date(timeIntervalSince1970: 4_000))
        let detector = AnomalyDetector(threshold: 60, pollInterval: 0.05, now: time.get)
        let recorder = EventRecorder()
        let snapshot = makeSnapshot(
            id: "session-4",
            status: .anomaly(idleSeconds: 61, previousStatus: .processing),
            lastEventAt: time.get().addingTimeInterval(-61)
        )

        await detector.start(sessions: { [snapshot] in [snapshot.id: snapshot] }) { id, status in
            await recorder.record(id: id, status: status)
            if await recorder.count() == 2 {
                await detector.stop()
            }
        }

        try await Task.sleep(nanoseconds: 70_000_000)
        time.set(time.get().addingTimeInterval(5))
        try await Task.sleep(nanoseconds: 120_000_000)

        let events = await recorder.events()
        #expect(events.count >= 2)
        #expect(events[0].1 == .anomaly(idleSeconds: 61, previousStatus: .processing))
        #expect(events[1].1 == .anomaly(idleSeconds: 66, previousStatus: .processing))
    }

    @Test("stop cancels polling")
    func testStopCancelsPoll() async throws {
        let time = MutableTimeSource(Date(timeIntervalSince1970: 5_000))
        let detector = AnomalyDetector(threshold: 60, pollInterval: 0.02, now: time.get)
        let recorder = EventRecorder()
        let snapshot = makeSnapshot(
            id: "session-5",
            status: .processing,
            lastEventAt: time.get().addingTimeInterval(-61)
        )

        await detector.start(sessions: { [snapshot] in [snapshot.id: snapshot] }) { id, status in
            await recorder.record(id: id, status: status)
        }

        try await Task.sleep(nanoseconds: 80_000_000)
        let beforeStop = await recorder.count()
        await detector.stop()
        try await Task.sleep(nanoseconds: 120_000_000)
        let afterStop = await recorder.count()

        #expect(beforeStop > 0)
        #expect(afterStop == beforeStop)
    }

    private func makeSnapshot(id: String, status: SessionStatusSnapshot, lastEventAt: Date) -> SessionSnapshot {
        SessionSnapshot(id: id, status: status, lastEventAt: lastEventAt)
    }
}

private actor EventRecorder {
    private var values: [(String, SessionStatusSnapshot)] = []

    func record(id: String, status: SessionStatusSnapshot) {
        values.append((id, status))
    }

    func events() -> [(String, SessionStatusSnapshot)] {
        values
    }

    func count() -> Int {
        values.count
    }
}

private final class MutableTimeSource: @unchecked Sendable {
    private let queue = DispatchQueue(label: "orbit.anomaly-detector.time-source")
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func get() -> Date {
        queue.sync { value }
    }

    func set(_ newValue: Date) {
        queue.sync { value = newValue }
    }
}
