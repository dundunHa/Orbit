import AppKit

/// Screen selection and geometry resolution policy.
/// Extracted from NotchGeometry.targetScreen() and ScreenMonitor.
@MainActor
struct DisplayPolicy {
    /// Returns the best screen for the overlay (same logic as NotchGeometry.targetScreen).
    static func targetScreen(from screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        NotchGeometry.targetScreen(from: screens)
    }

    /// Returns the top edge the overlay should visually attach to.
    /// 统一从屏幕可见区域顶部和顶部保留带推回物理顶边，
    /// 让不同屏幕类型都走同一条顶部计算链路。
    static func overlayTopMaxY(for screen: NSScreen?) -> CGFloat {
        guard let screen else {
            return 0
        }

        let visibleTop = screen.visibleFrame.maxY
        let topReservedHeight = max(screen.frame.maxY - visibleTop, 0)
        return visibleTop + topReservedHeight
    }

    static func overlayOriginY(for screen: NSScreen?, panelHeight: CGFloat) -> CGFloat {
        overlayTopMaxY(for: screen) - panelHeight
    }

    /// Returns the vertical anchor frame for the overlay.
    static func overlayAnchorFrame(for screen: NSScreen?) -> NSRect {
        guard let screen else {
            return .zero
        }

        let topMaxY = overlayTopMaxY(for: screen)
        return NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.origin.y,
            width: screen.frame.width,
            height: max(topMaxY - screen.frame.origin.y, 0)
        )
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
