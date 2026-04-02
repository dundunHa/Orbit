#[cfg(target_os = "macos")]
pub fn get_notch_position() -> (i32, i32) {
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
            let scale = screen.backingScaleFactor();

            let screen_width_px = (frame.size.width * scale) as i32;
            let pill_width_px = (300.0 * scale) as i32;

            let x = (screen_width_px - pill_width_px) / 2;

            let y = if best_inset_top > 0.0 {
                // Notch exists: position a few physical pixels from top
                (2.0 * scale) as i32
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
