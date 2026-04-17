import Foundation
import Testing
@testable import Orbit

@Suite("NotchGeometry")
struct NotchGeometryTests {
    @Test("fallback values match the Rust defaults")
    func fallbackValuesMatchDefaults() {
        let geometry = NotchGeometry.fallback

        #expect(geometry.notchHeight == 40)
        #expect(geometry.screenWidth == 1440)
        #expect(geometry.notchLeft == 710)
        #expect(geometry.notchRight == 730)
        #expect(geometry.notchWidth == 200)
        #expect(geometry.leftSafeWidth == 710)
        #expect(geometry.rightSafeWidth == 710)
    }

    @Test("hasNotch is true when notch height is positive")
    func hasNotchIsTrueForPositiveHeight() {
        let geometry = NotchGeometry(
            notchHeight: 1,
            screenWidth: 100,
            notchLeft: 10,
            notchRight: 20,
            notchWidth: 10,
            leftSafeWidth: 10,
            rightSafeWidth: 10,
            leftZoneWidth: 35,
            rightZoneWidth: 25
        )

        #expect(geometry.hasNotch)
    }

    @Test("hasNotch is false when notch height is zero")
    func hasNotchIsFalseForZeroHeight() {
        let geometry = NotchGeometry(
            notchHeight: 0,
            screenWidth: 100,
            notchLeft: 10,
            notchRight: 20,
            notchWidth: 10,
            leftSafeWidth: 10,
            rightSafeWidth: 10,
            leftZoneWidth: 35,
            rightZoneWidth: 25
        )

        #expect(!geometry.hasNotch)
    }

    @Test("best screen with notch is selected by top inset")
    func selectsScreenWithLargestTopInset() {
        let screens = [
            NotchGeometry.ScreenCandidate(
                safeAreaInsetsTop: 0,
                frameOriginX: 0,
                frameWidth: 1728,
                auxiliaryTopLeftAreaOriginX: 0,
                auxiliaryTopLeftAreaWidth: 864,
                auxiliaryTopRightAreaOriginX: 864,
                auxiliaryTopRightAreaWidth: 864
            ),
            NotchGeometry.ScreenCandidate(
                safeAreaInsetsTop: 40,
                frameOriginX: 100,
                frameWidth: 1440,
                auxiliaryTopLeftAreaOriginX: 100,
                auxiliaryTopLeftAreaWidth: 710,
                auxiliaryTopRightAreaOriginX: 830,
                auxiliaryTopRightAreaWidth: 610
            )
        ]

        let geometry = NotchGeometry.resolved(from: screens)

        #expect(geometry.notchHeight == 40)
        #expect(geometry.screenWidth == 1440)
        #expect(geometry.notchLeft == 710)
        #expect(geometry.notchRight == 730)
        #expect(geometry.notchWidth == 20)
        #expect(geometry.leftSafeWidth == 710)
        #expect(geometry.rightSafeWidth == 610)
    }

    @Test("screen without a notch centers the fallback notch width")
    func centersFallbackWidthWhenNoNotchExists() {
        let screens = [
            NotchGeometry.ScreenCandidate(
                safeAreaInsetsTop: 0,
                frameOriginX: 50,
                frameWidth: 2000,
                auxiliaryTopLeftAreaOriginX: 50,
                auxiliaryTopLeftAreaWidth: 0,
                auxiliaryTopRightAreaOriginX: 2050,
                auxiliaryTopRightAreaWidth: 0
            )
        ]

        let geometry = NotchGeometry.resolved(from: screens)

        #expect(geometry.notchHeight == 40)
        #expect(geometry.screenWidth == 2000)
        #expect(geometry.notchLeft == 900)
        #expect(geometry.notchRight == 1100)
        #expect(geometry.notchWidth == 200)
        #expect(geometry.leftSafeWidth == 900)
        #expect(geometry.rightSafeWidth == 900)
    }

    @Test("no screens returns the fallback geometry")
    func noScreensReturnsFallback() {
        let geometry = NotchGeometry.resolved(from: [])

        #expect(geometry.notchHeight == NotchGeometry.fallback.notchHeight)
        #expect(geometry.screenWidth == NotchGeometry.fallback.screenWidth)
        #expect(geometry.notchLeft == NotchGeometry.fallback.notchLeft)
        #expect(geometry.notchRight == NotchGeometry.fallback.notchRight)
        #expect(geometry.notchWidth == NotchGeometry.fallback.notchWidth)
        #expect(geometry.leftSafeWidth == NotchGeometry.fallback.leftSafeWidth)
        #expect(geometry.rightSafeWidth == NotchGeometry.fallback.rightSafeWidth)
    }
}
