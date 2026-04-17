import AppKit

@MainActor
class FloatingPanel: NSPanel {
    private var trackingArea: NSTrackingArea?
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?

    /// The frame this panel should be anchored to.  When set,
    /// `constrainFrameRect` returns this value instead of accepting whatever
    /// the Window Server proposes — preventing macOS from repositioning the
    /// panel during Space / screen transitions.
    var anchoredFrame: NSRect?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: 25)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false
    }
    override var canBecomeKey: Bool { true }

    // Prevent macOS from repositioning the panel during Space / fullscreen
    // transitions.  The default implementation constrains windows to the
    // screen's visibleFrame, which pushes a notch-anchored panel below the
    // menu-bar area.  We manage our own positioning via setFrame.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return anchoredFrame ?? frameRect
    }
    func setupTrackingArea() {
        if let existing = trackingArea {
            contentView?.removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView?.addTrackingArea(area)
        trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { onMouseEnter?() }
    override func mouseExited(with event: NSEvent) { onMouseExit?() }
}
