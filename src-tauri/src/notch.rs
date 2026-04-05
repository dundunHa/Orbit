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
            notch_width: 200.0,
            left_safe_width: 710.0,
            right_safe_width: 710.0,
        }
    }
}

#[cfg(target_os = "macos")]
fn read_notch_geometry(mtm: objc2::MainThreadMarker) -> NotchGeometry {
    use objc2_app_kit::NSScreen;

    let screens = NSScreen::screens(mtm);

    let mut best_screen = None;
    let mut best_inset_top: f64 = 0.0;

    for screen in screens.iter() {
        let insets = screen.safeAreaInsets();
        if insets.top > best_inset_top {
            best_inset_top = insets.top;
            best_screen = Some(screen);
        }
    }

    let screen = best_screen.or_else(|| screens.firstObject());

    if let Some(screen) = screen {
        let frame = screen.frame();
        let screen_width = frame.size.width;

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

    NotchGeometry::fallback()
}

#[cfg(target_os = "macos")]
fn run_on_main_thread<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Option<T> {
    use std::ffi::c_void;
    use std::sync::mpsc;

    unsafe extern "C" {
        static _dispatch_main_q: c_void;
        fn dispatch_async_f(
            queue: *const c_void,
            context: *mut c_void,
            work: unsafe extern "C" fn(*mut c_void),
        );
    }

    unsafe extern "C" fn trampoline(ctx: *mut c_void) {
        unsafe {
            if ctx.is_null() {
                eprintln!("[Orbit] trampoline received null context");
                return;
            }
            let f = Box::from_raw(ctx as *mut Box<dyn FnOnce()>);
            f();
        }
    }

    let (tx, rx) = mpsc::sync_channel(1);
    let callback: Box<Box<dyn FnOnce()>> = Box::new(Box::new(move || {
        let _ = tx.send(f());
    }));

    unsafe {
        dispatch_async_f(
            &_dispatch_main_q as *const c_void,
            Box::into_raw(callback) as *mut c_void,
            trampoline,
        );
    }

    rx.recv().ok()
}

#[cfg(target_os = "macos")]
pub fn get_notch_geometry() -> NotchGeometry {
    use objc2::MainThreadMarker;

    if let Some(mtm) = MainThreadMarker::new() {
        return read_notch_geometry(mtm);
    }

    run_on_main_thread(|| {
        MainThreadMarker::new()
            .map(read_notch_geometry)
            .unwrap_or_else(NotchGeometry::fallback)
    })
    .unwrap_or_else(NotchGeometry::fallback)
}

#[cfg(not(target_os = "macos"))]
pub fn get_notch_geometry() -> NotchGeometry {
    NotchGeometry::fallback()
}
