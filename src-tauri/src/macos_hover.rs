use objc2::ffi::{OBJC_ASSOCIATION_RETAIN_NONATOMIC, objc_setAssociatedObject};
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{AnyThread, DefinedClass, MainThreadOnly, define_class, msg_send};
use objc2_app_kit::{NSEvent, NSTrackingArea, NSTrackingAreaOptions, NSView};
use objc2_foundation::{MainThreadMarker, NSObject, NSObjectProtocol, NSRect};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use tauri::Emitter;

const HOVER_ENTER_EVENT: &str = "island-hover-enter";
const HOVER_LEAVE_EVENT: &str = "island-hover-leave";

static HOVER_OWNER_ASSOCIATION_KEY: u8 = 0;

#[derive(Debug)]
struct HoverTrackingOwnerIvars {
    app_handle: tauri::AppHandle,
}

define_class!(
    // SAFETY:
    // - The superclass NSObject has no additional subclassing requirements.
    // - The object is retained by the associated object on the content view.
    #[unsafe(super = NSObject)]
    #[name = "OrbitHoverTrackingOwner"]
    #[thread_kind = MainThreadOnly]
    #[ivars = HoverTrackingOwnerIvars]
    struct HoverTrackingOwner;

    // SAFETY: NSObjectProtocol has no additional safety requirements.
    unsafe impl NSObjectProtocol for HoverTrackingOwner {}

    impl HoverTrackingOwner {
        #[unsafe(method(mouseEntered:))]
        fn mouse_entered(&self, _event: &NSEvent) {
            let _ = self
                .ivars()
                .app_handle
                .emit_to("main", HOVER_ENTER_EVENT, ());
        }

        #[unsafe(method(mouseExited:))]
        fn mouse_exited(&self, _event: &NSEvent) {
            let _ = self
                .ivars()
                .app_handle
                .emit_to("main", HOVER_LEAVE_EVENT, ());
        }
    }
);

impl HoverTrackingOwner {
    fn new(app_handle: tauri::AppHandle, mtm: MainThreadMarker) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(HoverTrackingOwnerIvars { app_handle });
        // SAFETY: The signature of NSObject's init method is correct.
        unsafe { msg_send![super(this), init] }
    }
}

pub fn install_hover_tracking(
    window: &tauri::WebviewWindow,
    app_handle: tauri::AppHandle,
) -> Result<(), String> {
    let mtm = MainThreadMarker::new()
        .ok_or_else(|| "hover tracking must be installed on the main thread".to_string())?;

    let handle = window
        .window_handle()
        .map_err(|e| format!("failed to get window handle: {e}"))?;
    let RawWindowHandle::AppKit(appkit) = handle.as_raw() else {
        return Err("main window is not an AppKit window".to_string());
    };

    let ns_view = appkit.ns_view.as_ptr() as *mut NSView;
    unsafe {
        let ns_window = (*ns_view)
            .window()
            .ok_or_else(|| "failed to get NSWindow from NSView".to_string())?;

        ns_window.setAcceptsMouseMovedEvents(true);

        let content_view = ns_window
            .contentView()
            .ok_or_else(|| "failed to get NSWindow contentView".to_string())?;

        let owner = HoverTrackingOwner::new(app_handle, mtm);
        let options = NSTrackingAreaOptions::MouseEnteredAndExited
            | NSTrackingAreaOptions::ActiveAlways
            | NSTrackingAreaOptions::InVisibleRect;
        let tracking_area = NSTrackingArea::initWithRect_options_owner_userInfo(
            NSTrackingArea::alloc(),
            NSRect::ZERO,
            options,
            Some(&owner),
            None,
        );

        content_view.addTrackingArea(&tracking_area);

        let owner_object: Retained<AnyObject> = owner.into();
        objc_setAssociatedObject(
            Retained::as_ptr(&content_view) as *mut AnyObject,
            &HOVER_OWNER_ASSOCIATION_KEY as *const u8 as *const _,
            Retained::as_ptr(&owner_object) as *mut AnyObject,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC,
        );
    }

    Ok(())
}
