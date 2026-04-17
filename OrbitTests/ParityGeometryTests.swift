import AppKit
import Foundation
import Testing
@testable import Orbit

// swiftlint:disable file_length

/// Cross-referenced against Orbitbak commands.rs (line numbers cited inline)
/// and main.js:1067-1082 for dynamic height.
@Suite("ParityGeometry")
struct ParityGeometryTests {

    // MARK: – pillWidth

    /// Test 1: commands.rs:32-34  35+200+25=260
    @Test("pillWidth matches Rust formula")
    func pillWidth_matchesRustFormula() {
        let result = ParityGeometry.pillWidth(notchWidth: 200)
        #expect(result == 260)
    }

    /// Test 2: commands.rs:32-34  35+400+25=460
    @Test("pillWidth with large notch")
    func pillWidth_withLargeNotch() {
        let result = ParityGeometry.pillWidth(notchWidth: 400)
        #expect(result == 460)
    }

    // MARK: – pillLeft

    /// Test 3: commands.rs:36-39
    /// notchLeft=710, notchWidth=200, screenWidth=1440
    /// pillWidth=260, unclampedLeft=710-35=675, maxLeft=max(1440-260,0)=1180
    /// result=clamp(675, 0, 1180)=675
    @Test("pillLeft matches Rust clamp — normal case")
    func pillLeft_matchesRustClamp_normalCase() {
        let result = ParityGeometry.pillLeft(notchLeft: 710, notchWidth: 200, screenWidth: 1440)
        #expect(result == 675)
    }

    /// Test 4: commands.rs:36-39
    /// notchLeft=10, unclampedLeft=10-35=-25 → clamp to 0
    @Test("pillLeft clamps to zero when negative")
    func pillLeft_clampsToZero_whenNegative() {
        let result = ParityGeometry.pillLeft(notchLeft: 10, notchWidth: 200, screenWidth: 1440)
        #expect(result == 0)
    }

    /// Test 5: commands.rs:36-39
    /// notchLeft=1400, notchWidth=200, screenWidth=1440
    /// pillWidth=260, unclampedLeft=1400-35=1365, maxLeft=max(1440-260,0)=1180
    /// result=clamp(1365, 0, 1180)=1180
    @Test("pillLeft clamps to max when overflow")
    func pillLeft_clampsToMax_whenOverflow() {
        let result = ParityGeometry.pillLeft(notchLeft: 1400, notchWidth: 200, screenWidth: 1440)
        #expect(result == 1180)
    }

    /// Test 6: commands.rs:36-39
    /// screenWidth < pillWidth → maxLeft=max(0,0)=0 → clamp to 0
    @Test("pillLeft handles narrow screen (pillWidth > screenWidth)")
    func pillLeft_handlesNarrowScreen() {
        // pillWidth = 35+200+25 = 260, screenWidth = 200 < 260
        let result = ParityGeometry.pillLeft(notchLeft: 100, notchWidth: 200, screenWidth: 200)
        #expect(result == 0)
    }

    // MARK: – clampExpandedHeight

    /// Test 7: commands.rs:49-51  height within [168, 320] → unchanged
    @Test("clampExpandedHeight within range returns value unchanged")
    func clampExpandedHeight_withinRange() {
        let result = ParityGeometry.clampExpandedHeight(200)
        #expect(result == 200)
    }

    /// Test 8: commands.rs:49-51  100 < 168 → 168
    @Test("clampExpandedHeight below min clamps to minExpandedHeight")
    func clampExpandedHeight_belowMin() {
        let result = ParityGeometry.clampExpandedHeight(100)
        #expect(result == 168)
    }

    /// Test 9: commands.rs:49-51  500 > 320 → 320
    @Test("clampExpandedHeight above max clamps to maxExpandedHeight")
    func clampExpandedHeight_aboveMax() {
        let result = ParityGeometry.clampExpandedHeight(500)
        #expect(result == 320)
    }

    // MARK: – collapsedFrame

    private func makeGeometry(
        notchHeight: Double = 37,
        screenWidth: Double = 1440,
        notchLeft: Double = 710,
        notchWidth: Double = 200
    ) -> NotchGeometry {
        NotchGeometry(
            notchHeight: notchHeight,
            screenWidth: screenWidth,
            notchLeft: notchLeft,
            notchRight: notchLeft + notchWidth,
            notchWidth: notchWidth,
            leftSafeWidth: notchLeft,
            rightSafeWidth: screenWidth - notchLeft - notchWidth,
            leftZoneWidth: 35,
            rightZoneWidth: 25
        )
    }

    private func screenRect(
        originX: CGFloat = 0,
        originY: CGFloat = 0,
        width: CGFloat = 1440,
        height: CGFloat = 900
    ) -> NSRect {
        NSRect(x: originX, y: originY, width: width, height: height)
    }

    /// Test 10: commands.rs:56-76  x must be pillLeft (LEFT-aligned), not centered
    @Test("collapsedFrame x is pillLeft, not centered")
    func collapsedFrame_xIsPillLeft_notCentered() {
        let geo = makeGeometry()
        let screen = screenRect()
        let frame = ParityGeometry.collapsedFrame(geometry: geo, screenFrame: screen)

        // pillLeft(710,200,1440) = 675
        let expectedX: CGFloat = 675
        let wrongCenteredX = (screen.width - ParityGeometry.pillWidth(notchWidth: 200)) / 2

        #expect(frame.origin.x == expectedX)
        #expect(frame.origin.x != wrongCenteredX, "x must not be centered")
    }

    /// Test 11: commands.rs:56-76  y = screen.origin.y + screen.height - height
    @Test("collapsedFrame y is screenMaxY minus height")
    func collapsedFrame_yIsScreenMaxYMinusHeight() {
        let geo = makeGeometry(notchHeight: 37)
        let screen = screenRect(originY: 100, height: 900)
        let frame = ParityGeometry.collapsedFrame(geometry: geo, screenFrame: screen)

        let expectedY = screen.origin.y + screen.height - CGFloat(geo.notchHeight)
        #expect(frame.origin.y == expectedY)
    }

    /// Test 12: commands.rs:56-76  width == pillWidth
    @Test("collapsedFrame width equals pillWidth")
    func collapsedFrame_widthIsPillWidth() {
        let geo = makeGeometry(notchWidth: 200)
        let screen = screenRect()
        let frame = ParityGeometry.collapsedFrame(geometry: geo, screenFrame: screen)

        #expect(frame.width == ParityGeometry.pillWidth(notchWidth: 200))
    }

    /// Test 13: commands.rs:298-300  height == notchHeight (collapsed_height = notch.notch_height)
    @Test("collapsedFrame height equals notchHeight")
    func collapsedFrame_heightIsNotchHeight() {
        let geo = makeGeometry(notchHeight: 37)
        let screen = screenRect()
        let frame = ParityGeometry.collapsedFrame(geometry: geo, screenFrame: screen)

        #expect(frame.height == 37)
    }

    // MARK: – expandedFrame

    /// Test 14: commands.rs:286-288  width == pillWidth, NOT 340 or any fixed default
    @Test("expandedFrame width is pillWidth, not 340")
    func expandedFrame_widthIsPillWidth_not340() {
        let geo = makeGeometry(notchWidth: 200)
        let screen = screenRect()
        let frame = ParityGeometry.expandedFrame(geometry: geo, screenFrame: screen, height: 250)

        #expect(frame.width == ParityGeometry.pillWidth(notchWidth: 200))
        #expect(frame.width != 340, "width must not be fixed 340")
    }

    /// Test 15: commands.rs:56-76  x = pillLeft (LEFT-aligned)
    @Test("expandedFrame x is pillLeft, not centered")
    func expandedFrame_xIsPillLeft_notCentered() {
        let geo = makeGeometry()
        let screen = screenRect()
        let frame = ParityGeometry.expandedFrame(geometry: geo, screenFrame: screen, height: 250)

        let expectedX: CGFloat = 675
        #expect(frame.origin.x == expectedX)
    }

    /// Test 16: commands.rs:292-294  height == passed value (already clamped by caller or raw)
    @Test("expandedFrame height equals passed height value")
    func expandedFrame_heightIsPassedValue() {
        let geo = makeGeometry()
        let screen = screenRect()
        let frame = ParityGeometry.expandedFrame(geometry: geo, screenFrame: screen, height: 250)

        #expect(frame.height == 250)
    }

    // MARK: – computeExpandedHeight

    /// Test 17: main.js:1067-1082
    /// notch=37, content=200
    /// minExpanded = 37+152 = 189
    /// contentHeight = 37+200 = 237
    /// nextHeight = clamp(237, 189, 320) = 237
    @Test("computeExpandedHeight matches JS formula — typical content")
    func computeExpandedHeight_matchesJSFormula() {
        let result = ParityGeometry.computeExpandedHeight(notchHeight: 37, contentScrollHeight: 200)
        #expect(result == 237)
    }

    /// Test 18: main.js:1067-1082
    /// notch=37, content=50
    /// minExpanded = 37+152 = 189
    /// contentHeight = 37+50 = 87 < 189
    /// nextHeight = clamp(87, 189, 320) = 189
    @Test("computeExpandedHeight min is notchHeight + 152")
    func computeExpandedHeight_minIsNotchPlus152() {
        let result = ParityGeometry.computeExpandedHeight(notchHeight: 37, contentScrollHeight: 50)
        #expect(result == 189)
    }

    /// Test 19: main.js:1067-1082
    /// notch=37, content=500
    /// contentHeight = 37+500 = 537 > 320
    /// nextHeight = clamp(537, 189, 320) = 320
    @Test("computeExpandedHeight max is 320")
    func computeExpandedHeight_maxIs320() {
        let result = ParityGeometry.computeExpandedHeight(notchHeight: 37, contentScrollHeight: 500)
        #expect(result == 320)
    }

    // MARK: – Constants

    /// Test 20: commands.rs:10-14
    @Test("constants match Rust source values")
    func constantsMatchRust() {
        #expect(ParityGeometry.leftZoneWidth == 35)
        #expect(ParityGeometry.rightZoneWidth == 25)
        #expect(ParityGeometry.mascotLeftInset == 8)
        #expect(ParityGeometry.minExpandedHeight == 168)
        #expect(ParityGeometry.maxExpandedHeight == 320)
    }
}
