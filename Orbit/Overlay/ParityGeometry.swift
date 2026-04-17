import AppKit
import Foundation

/// Pure geometry functions with 1:1 parity to Orbitbak commands.rs.
/// All functions are static — this enum has no instances.
enum ParityGeometry {

    // MARK: – Constants (commands.rs:10-14)

    static let leftZoneWidth: CGFloat = 35.0
    static let rightZoneWidth: CGFloat = 25.0
    static let mascotLeftInset: CGFloat = 8.0
    static let minExpandedHeight: CGFloat = 240.0
    static let maxExpandedHeight: CGFloat = 360.0

    // MARK: – Derived calculations

    /// commands.rs:32-34
    static func pillWidth(notchWidth: CGFloat) -> CGFloat {
        leftZoneWidth + notchWidth + rightZoneWidth
    }

    /// commands.rs:36-39
    static func pillLeft(notchLeft: CGFloat, notchWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {
        let width = pillWidth(notchWidth: notchWidth)
        let unclampedLeft = notchLeft - leftZoneWidth
        let maxLeft = max(screenWidth - width, 0)
        return min(max(unclampedLeft, 0), maxLeft)
    }

    /// commands.rs:49-51
    static func clampExpandedHeight(_ height: CGFloat) -> CGFloat {
        min(max(height, minExpandedHeight), maxExpandedHeight)
    }

    // MARK: – Frame calculations (commands.rs:56-76)

    /// commands.rs:298-300  collapsed_height() = notch.notch_height
    /// x = pillLeft (LEFT-aligned, not centered)
    /// y = screen.origin.y + screen.height - height
    static func collapsedFrame(geometry: NotchGeometry, screenFrame: NSRect) -> NSRect {
        let width = pillWidth(notchWidth: geometry.notchWidth)
        let x = pillLeft(
            notchLeft: geometry.notchLeft,
            notchWidth: geometry.notchWidth,
            screenWidth: geometry.screenWidth
        )
        let height = geometry.notchHeight
        let y = screenFrame.origin.y + screenFrame.height - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// commands.rs:286-288, 292-294
    /// x = pillLeft (LEFT-aligned, not centered)
    /// y = screen.origin.y + screen.height - height
    /// height is the caller-supplied value (use clampExpandedHeight before passing if needed)
    static func expandedFrame(geometry: NotchGeometry, screenFrame: NSRect, height: CGFloat)
        -> NSRect
    {
        let width = pillWidth(notchWidth: geometry.notchWidth)
        let x = pillLeft(
            notchLeft: geometry.notchLeft,
            notchWidth: geometry.notchWidth,
            screenWidth: geometry.screenWidth
        )
        let y = screenFrame.origin.y + screenFrame.height - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    // MARK: – Dynamic height (main.js:1067-1082)

    /// Mirrors the JS formula:
    ///   minExpandedHeight = notchHeight + 152
    ///   contentHeight     = notchHeight + contentScrollHeight
    ///   nextHeight        = clamp(contentHeight, minExpandedHeight, 320)
    static func computeExpandedHeight(notchHeight: CGFloat, contentScrollHeight: CGFloat) -> CGFloat
    {
        let minHeight = notchHeight + 152
        let contentHeight = notchHeight + contentScrollHeight
        return min(max(contentHeight, minHeight), maxExpandedHeight)
    }
}
