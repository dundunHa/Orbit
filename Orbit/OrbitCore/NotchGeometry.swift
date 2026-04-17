import AppKit
import Foundation

public struct NotchGeometry: Sendable {
    public let notchHeight: Double
    public let screenWidth: Double
    public let notchLeft: Double
    public let notchRight: Double
    public let notchWidth: Double
    public let leftSafeWidth: Double
    public let rightSafeWidth: Double

    public let leftZoneWidth: Double
    public let rightZoneWidth: Double
    public var pillWidth: Double {
        leftZoneWidth + notchWidth + rightZoneWidth
    }
    public var pillLeft: Double {
        let unclampedLeft = notchLeft - leftZoneWidth
        let maxLeft = max(screenWidth - pillWidth, 0)
        return min(max(unclampedLeft, 0), maxLeft)
    }

    private static let defaultLeftZoneWidth: Double = 35
    private static let defaultRightZoneWidth: Double = 25

    public static let fallback = NotchGeometry(
        notchHeight: 40,
        screenWidth: 1440,
        notchLeft: 710,
        notchRight: 730,
        notchWidth: 200,
        leftSafeWidth: 710,
        rightSafeWidth: 710,
        leftZoneWidth: defaultLeftZoneWidth,
        rightZoneWidth: defaultRightZoneWidth
    )

    public var hasNotch: Bool {
        notchHeight > 0
    }

    struct ScreenCandidate: Sendable {
        let safeAreaInsetsTop: Double
        let frameOriginX: Double
        let frameWidth: Double
        let auxiliaryTopLeftAreaOriginX: Double
        let auxiliaryTopLeftAreaWidth: Double
        let auxiliaryTopRightAreaOriginX: Double
        let auxiliaryTopRightAreaWidth: Double
    }

    static func resolved(from screens: [ScreenCandidate]) -> NotchGeometry {
        guard !screens.isEmpty else {
            return .fallback
        }

        var bestScreen: ScreenCandidate?
        var bestInsetTop: Double = 0

        for screen in screens {
            if screen.safeAreaInsetsTop > bestInsetTop {
                bestInsetTop = screen.safeAreaInsetsTop
                bestScreen = screen
            }
        }

        if let screen = bestScreen, bestInsetTop > 0 {
            let notchLeft = (screen.auxiliaryTopLeftAreaOriginX + screen.auxiliaryTopLeftAreaWidth) - screen.frameOriginX
            let notchRight = screen.auxiliaryTopRightAreaOriginX - screen.frameOriginX

            return NotchGeometry(
                notchHeight: bestInsetTop,
                screenWidth: screen.frameWidth,
                notchLeft: notchLeft,
                notchRight: notchRight,
                notchWidth: max(notchRight - notchLeft, 0),
                leftSafeWidth: screen.auxiliaryTopLeftAreaWidth,
                rightSafeWidth: screen.auxiliaryTopRightAreaWidth,
                leftZoneWidth: defaultLeftZoneWidth,
                rightZoneWidth: defaultRightZoneWidth
            )
        }

        guard let screen = screens.first else {
            return .fallback
        }

        return centeredFallback(screenWidth: screen.frameWidth)
    }

    @MainActor
    private static func screenCandidate(from screen: NSScreen) -> ScreenCandidate {
        let frame = screen.frame
        let insets = screen.safeAreaInsets

        return ScreenCandidate(
            safeAreaInsetsTop: Double(insets.top),
            frameOriginX: Double(frame.origin.x),
            frameWidth: Double(frame.width),
            auxiliaryTopLeftAreaOriginX: Double(screen.auxiliaryTopLeftArea?.origin.x ?? 0),
            auxiliaryTopLeftAreaWidth: Double(screen.auxiliaryTopLeftArea?.width ?? 0),
            auxiliaryTopRightAreaOriginX: Double(screen.auxiliaryTopRightArea?.origin.x ?? 0),
            auxiliaryTopRightAreaWidth: Double(screen.auxiliaryTopRightArea?.width ?? 0)
        )
    }

    @MainActor
    public static func targetScreen(from screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        guard !screens.isEmpty else {
            return nil
        }

        if let notchScreen = screens.max(by: { $0.safeAreaInsets.top < $1.safeAreaInsets.top }),
           notchScreen.safeAreaInsets.top > 0
        {
            return notchScreen
        }

        return screens.first
    }

    @MainActor
    public static func current(on screen: NSScreen?) -> NotchGeometry {
        guard let screen else {
            return current()
        }
        return resolved(from: [screenCandidate(from: screen)])
    }

    @MainActor
    public static func current() -> NotchGeometry {
        let candidates = NSScreen.screens.map(screenCandidate(from:))

        return resolved(from: candidates)
    }

    private static func centeredFallback(screenWidth: Double) -> NotchGeometry {
        let fallback = Self.fallback
        let notchLeft = (screenWidth - fallback.notchWidth) / 2

        return NotchGeometry(
            notchHeight: fallback.notchHeight,
            screenWidth: screenWidth,
            notchLeft: notchLeft,
            notchRight: notchLeft + fallback.notchWidth,
            notchWidth: fallback.notchWidth,
            leftSafeWidth: notchLeft,
            rightSafeWidth: notchLeft,
            leftZoneWidth: defaultLeftZoneWidth,
            rightZoneWidth: defaultRightZoneWidth
        )
    }
}
