import Foundation

#if canImport(Testing) && canImport(Orbit)
import Testing
@testable import Orbit

@Suite("RuntimeSizingPolicy")
@MainActor
struct RuntimeSizingPolicyTests {
    @Test("Default height is minExpandedHeight")
    func defaultHeight_isMinExpandedHeight() {
        let policy = RuntimeSizingPolicy()

        #expect(policy.expandedHeight == ParityGeometry.minExpandedHeight)
    }

    @Test("scheduleHeightUpdate computes correct height")
    func scheduleHeightUpdate_computesCorrectHeight() {
        var policy = RuntimeSizingPolicy()
        var callbackHeight: CGFloat?
        policy.onHeightChanged = { callbackHeight = $0 }

        policy.scheduleHeightUpdate(notchHeight: 37, contentScrollHeight: 200)

        let expected = ParityGeometry.computeExpandedHeight(notchHeight: 37, contentScrollHeight: 200)
        #expect(policy.expandedHeight == expected)
        #expect(callbackHeight == expected)
    }

    @Test("scheduleHeightUpdate clamps to maxExpandedHeight")
    func scheduleHeightUpdate_clampsToMaxExpandedHeight() {
        var policy = RuntimeSizingPolicy()

        policy.scheduleHeightUpdate(notchHeight: 37, contentScrollHeight: 1000)

        #expect(policy.expandedHeight == ParityGeometry.maxExpandedHeight)
    }

    @Test("scheduleHeightUpdate does not trigger callback for sub-0.5 changes")
    func scheduleHeightUpdate_ignoresSubHalfPointChanges() {
        var policy = RuntimeSizingPolicy(defaultHeight: 200)
        var callbackCount = 0
        policy.onHeightChanged = { _ in callbackCount += 1 }

        policy.scheduleHeightUpdate(notchHeight: 37, contentScrollHeight: 163.4) // new=200.4

        #expect(policy.expandedHeight == 200)
        #expect(callbackCount == 0)
    }

    @Test("resetToDefault resets height")
    func resetToDefault_resetsHeight() {
        var policy = RuntimeSizingPolicy(defaultHeight: 220)
        policy.scheduleHeightUpdate(notchHeight: 37, contentScrollHeight: 220)

        policy.resetToDefault()

        #expect(policy.expandedHeight == ParityGeometry.minExpandedHeight)
    }
}

#endif
