#[cfg(target_os = "macos")]
pub fn get_notch_position() -> (i32, i32) {
    use objc2_app_kit::NSScreen;
    use objc2::MainThreadMarker;

    // We must be on the main thread for NSScreen access
    if let Some(mtm) = MainThreadMarker::new() {
        let screens = NSScreen::screens(mtm);
        if let Some(screen) = screens.firstObject() {
            let frame = screen.frame();
            let insets = screen.safeAreaInsets();

            let screen_width = frame.size.width as i32;

            // Pill width
            let pill_width = 300;

            // Center horizontally
            let x = (screen_width - pill_width) / 2;

            // If notch exists (safeAreaInsets.top > 0), position at notch
            // Otherwise, position at very top of screen
            let y = if insets.top > 0.0 {
                2
            } else {
                0
            };

            return (x, y);
        }
    }

    // Fallback
    (560, 0)
}

#[cfg(not(target_os = "macos"))]
pub fn get_notch_position() -> (i32, i32) {
    (560, 0)
}
