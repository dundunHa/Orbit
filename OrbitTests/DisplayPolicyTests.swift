import AppKit
import Foundation

#if canImport(Testing) && canImport(Orbit)
import Testing
@testable import Orbit

@Suite("DisplayPolicy")
@MainActor
struct DisplayPolicyTests {
    private final class MockScreen: NSScreen {
        private let topInset: CGFloat
        private let mockedFrame: NSRect

        init(topInset: CGFloat, frame: NSRect = NSRect(x: 0, y: 0, width: 1440, height: 900)) {
            self.topInset = topInset
            self.mockedFrame = frame
            super.init()
        }

        override var safeAreaInsets: NSEdgeInsets {
            NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        }

        override var frame: NSRect {
            mockedFrame
        }
    }

    private func makeGeometry(
        screenWidth: Double = 1440,
        notchHeight: Double = 40,
        notchLeft: Double = 710,
        notchRight: Double = 730,
        notchWidth: Double = 20,
        leftSafeWidth: Double = 710,
        rightSafeWidth: Double = 610
    ) -> NotchGeometry {
        NotchGeometry(
            notchHeight: notchHeight,
            screenWidth: screenWidth,
            notchLeft: notchLeft,
            notchRight: notchRight,
            notchWidth: notchWidth,
            leftSafeWidth: leftSafeWidth,
            rightSafeWidth: rightSafeWidth,
            leftZoneWidth: 35,
            rightZoneWidth: 25
        )
    }

    @Test("targetScreen picks screen with highest safeAreaInsets.top")
    func targetScreen_picksHighestTopInset() {
        let first = MockScreen(topInset: 0)
        let second = MockScreen(topInset: 38)
        let third = MockScreen(topInset: 20)

        let target = DisplayPolicy.targetScreen(from: [first, second, third])

        #expect(target === second)
    }

    @Test("currentGeometry returns valid geometry")
    func currentGeometry_returnsValidGeometry() {
        let geometry = DisplayPolicy.currentGeometry()

        #expect(geometry.screenWidth > 0)
        #expect(geometry.notchHeight >= 0)
        #expect(geometry.notchWidth >= 0)
    }

    @Test("geometryChangedSignificantly detects width change")
    func geometryChangedSignificantly_detectsWidthChange() {
        let old = makeGeometry(screenWidth: 1440)
        let new = makeGeometry(screenWidth: 1440.2)

        #expect(DisplayPolicy.geometryChangedSignificantly(old, new))
    }

    @Test("geometryChangedSignificantly ignores sub-threshold changes")
    func geometryChangedSignificantly_ignoresSubThresholdChanges() {
        let old = makeGeometry()
        let new = makeGeometry(
            screenWidth: 1440.05,
            notchHeight: 40.05,
            notchLeft: 710.05,
            notchRight: 730.05,
            notchWidth: 20.05,
            leftSafeWidth: 710.05,
            rightSafeWidth: 610.05
        )

        #expect(!DisplayPolicy.geometryChangedSignificantly(old, new))
    }

    @Test("geometry(for:) resolves geometry for specific screen")
    func geometryForSpecificScreen() {
        let screen = MockScreen(topInset: 44, frame: NSRect(x: 0, y: 0, width: 1600, height: 900))

        let geometry = DisplayPolicy.geometry(for: screen)

        #expect(geometry.notchHeight == 44)
        #expect(geometry.screenWidth == 1600)
        #expect(geometry.notchWidth == 0)
    }
}

#endif
