#[cfg(target_os = "macos")]
pub fn get_notch_position(pill_width: f64) -> (f64, f64, f64, f64) {
    use objc2::MainThreadMarker;
    use objc2_app_kit::NSScreen;

    if let Some(mtm) = MainThreadMarker::new() {
        let screens = NSScreen::screens(mtm);

        // Find the screen with the largest safeAreaInsets.top (= the notch screen)
        let mut best_screen = None;
        let mut best_inset_top: f64 = 0.0;

        for screen in screens.iter() {
            let insets = screen.safeAreaInsets();
            if insets.top > best_inset_top {
                best_inset_top = insets.top;
                best_screen = Some(screen);
            }
        }

        // Fall back to first screen if no notch found
        let screen = best_screen.or_else(|| screens.firstObject());

        if let Some(screen) = screen {
            let frame = screen.frame();
            let screen_width = frame.size.width; // Already in logical points

            let notch_height = if best_inset_top > 0.0 {
                best_inset_top
            } else {
                28.0 // Fallback for non-notch screens (menu bar height)
            };

            let x = (screen_width - pill_width) / 2.0;
            let y = 0.0; // Flush with top of screen to fuse with notch

            return (x, y, notch_height, screen_width);
        }
    }

    // Fallback: center on assumed 1440pt wide screen
    let screen_width = 1440.0;
    let x = (screen_width - pill_width) / 2.0;
    (x, 0.0, 28.0, screen_width)
}

#[cfg(not(target_os = "macos"))]
pub fn get_notch_position(pill_width: f64) -> (f64, f64, f64, f64) {
    let screen_width = 1440.0;
    let x = (screen_width - pill_width) / 2.0;
    (x, 0.0, 28.0, screen_width)
}
