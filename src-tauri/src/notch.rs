#[derive(Clone, Copy, Debug)]
pub struct NotchGeometry {
    pub notch_height: f64,
    pub screen_width: f64,
    pub notch_left: f64,
    pub notch_right: f64,
    pub notch_width: f64,
    pub left_safe_width: f64,
    pub right_safe_width: f64,
}

impl NotchGeometry {
    pub const fn fallback() -> Self {
        Self {
            notch_height: 40.0,
            screen_width: 1440.0,
            notch_left: 710.0,
            notch_right: 730.0,
            notch_width: 100.0,
            left_safe_width: 710.0,
            right_safe_width: 710.0,
        }
    }
}

#[cfg(target_os = "macos")]
pub fn get_notch_geometry() -> NotchGeometry {
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

            if best_inset_top > 0.0 {
                let left_area = screen.auxiliaryTopLeftArea();
                let right_area = screen.auxiliaryTopRightArea();
                let notch_left = (left_area.origin.x + left_area.size.width) - frame.origin.x;
                let notch_right = right_area.origin.x - frame.origin.x;

                return NotchGeometry {
                    notch_height: best_inset_top,
                    screen_width,
                    notch_left,
                    notch_right,
                    notch_width: (notch_right - notch_left).max(0.0),
                    left_safe_width: left_area.size.width,
                    right_safe_width: right_area.size.width,
                };
            }

            let notch = NotchGeometry::fallback();
            let centered_left = (screen_width - notch.notch_width) / 2.0;
            return NotchGeometry {
                screen_width,
                notch_left: centered_left,
                notch_right: centered_left + notch.notch_width,
                left_safe_width: centered_left,
                right_safe_width: centered_left,
                ..notch
            };
        }
    }

    NotchGeometry::fallback()
}

#[cfg(not(target_os = "macos"))]
pub fn get_notch_geometry() -> NotchGeometry {
    NotchGeometry::fallback()
}
