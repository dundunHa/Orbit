import AppKit

/// Screen selection and geometry resolution policy.
/// Extracted from NotchGeometry.targetScreen() and ScreenMonitor.
@MainActor
struct DisplayPolicy {
    /// Returns the best screen for the overlay (same logic as NotchGeometry.targetScreen).
    static func targetScreen(from screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        NotchGeometry.targetScreen(from: screens)
    }

    /// Returns current geometry for the best screen.
    static func currentGeometry() -> NotchGeometry {
        NotchGeometry.current()
    }

    /// Returns geometry for a specific screen.
    static func geometry(for screen: NSScreen?) -> NotchGeometry {
        NotchGeometry.current(on: screen)
    }

    /// Checks if geometry changed significantly (threshold = 0.1, matching ScreenMonitor).
    static func geometryChangedSignificantly(_ old: NotchGeometry, _ new: NotchGeometry) -> Bool {
        let threshold: Double = 0.1
        return abs(new.screenWidth - old.screenWidth) > threshold
            || abs(new.notchHeight - old.notchHeight) > threshold
            || abs(new.notchLeft - old.notchLeft) > threshold
            || abs(new.notchRight - old.notchRight) > threshold
            || abs(new.notchWidth - old.notchWidth) > threshold
            || abs(new.leftSafeWidth - old.leftSafeWidth) > threshold
            || abs(new.rightSafeWidth - old.rightSafeWidth) > threshold
    }
}
