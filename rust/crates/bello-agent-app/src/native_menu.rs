//! Source-faithful AppKit presentation for implemented chat sidebar actions.
//!
//! SidebarChatRow.contextMenu / SessionOrganizationActions supplies the labels
//! and symbols; PiMenu.swift supplies NSMenuItem's target/representedObject
//! ownership pattern. No GPUI App or Window borrow spans native menu tracking.

use crate::sidebar_actions::SidebarAction;

#[derive(Debug, PartialEq, Eq)]
struct MenuCommand {
    title: &'static str,
    symbol: &'static str,
    action: SidebarAction,
}

fn pin_command(pinned: bool) -> MenuCommand {
    if pinned {
        MenuCommand {
            title: "Unpin Chat",
            symbol: "pin.slash",
            action: SidebarAction::TogglePinned,
        }
    } else {
        MenuCommand {
            title: "Pin Chat",
            symbol: "pin",
            action: SidebarAction::TogglePinned,
        }
    }
}

fn archive_command(archived: bool) -> MenuCommand {
    MenuCommand {
        title: if archived {
            "Restore Chat"
        } else {
            "Archive Chat"
        },
        symbol: if archived {
            "arrow.uturn.backward"
        } else {
            "archivebox"
        },
        action: SidebarAction::ToggleArchived,
    }
}

fn copy_id_command() -> MenuCommand {
    MenuCommand {
        title: "Copy Session ID",
        symbol: "number",
        action: SidebarAction::CopySessionId,
    }
}

fn selected_action(selected: u8, pinned: bool) -> Option<SidebarAction> {
    match selected {
        1 => Some(pin_command(pinned).action),
        2 => Some(SidebarAction::ToggleArchived),
        3 => Some(copy_id_command().action),
        4 => Some(SidebarAction::MarkRead),
        5 => Some(SidebarAction::MarkUnread),
        _ => None,
    }
}

fn finish_if_open<T>(open: bool, choice: T, completion: impl FnOnce(T)) {
    if open {
        completion(choice);
    }
}

thread_local! {
    static TRACKING: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

// Native menu tracking runs a nested event loop. Never recursively enter a
// second menu if another request is dispatched during that loop.
struct Tracking;
impl Tracking {
    fn begin() -> Option<Self> {
        TRACKING.with(|tracking| {
            if tracking.replace(true) {
                None
            } else {
                Some(Self)
            }
        })
    }
}
impl Drop for Tracking {
    fn drop(&mut self) {
        TRACKING.with(|tracking| tracking.set(false));
    }
}

// GPUI mouse positions are logical pixels from the content area's top-left.
// AppKit uses points in the target view's coordinate system, not backing pixels.
fn anchor_in_view(
    position: (f64, f64),
    origin: (f64, f64),
    size: (f64, f64),
    flipped: bool,
) -> Option<(f64, f64)> {
    let (x, y) = position;
    let (width, height) = size;
    if ![x, y, origin.0, origin.1, width, height]
        .iter()
        .all(|value| value.is_finite())
        || width <= 0.0
        || height <= 0.0
        || x < 0.0
        || x > width
        || y < 0.0
        || y > height
    {
        return None;
    }
    Some((
        origin.0 + x,
        origin.1 + if flipped { y } else { height - y },
    ))
}

// Inverse of the menu anchor mapping, except a fresh pointer may legitimately
// be outside the content area. Do not clamp it: that would hide a real exit.
// Both AppKit points and GPUI logical pixels are unscaled here (not Retina
// backing pixels). Unknown/nonrepresentable geometry must not release a hold.
fn pointer_from_view(
    position: (f64, f64),
    origin: (f64, f64),
    size: (f64, f64),
    flipped: bool,
) -> Option<(f32, f32)> {
    let (width, height) = size;
    if ![position.0, position.1, origin.0, origin.1, width, height]
        .iter()
        .all(|value| value.is_finite())
        || width <= 0.0
        || height <= 0.0
    {
        return None;
    }
    let x = (position.0 - origin.0) as f32;
    let y = if flipped {
        position.1 - origin.1
    } else {
        height - (position.1 - origin.1)
    } as f32;
    (x.is_finite() && y.is_finite()).then_some((x, y))
}

#[derive(Clone, Copy, Default)]
struct ViewCategory {
    gpui_view: bool,
    expected_window: bool,
    direct_child: bool,
}

// GPUI 0.2.2 creates GPUIView with contentView.bounds, then adds it beneath
// contentView (platform/mac/window.rs:680–682, 775). The content view itself is
// an AppKit container. Find the unique attached GPUIView, not the first child.
fn gpui_child_index(content_attached: bool, children: &[ViewCategory]) -> Option<usize> {
    if !content_attached {
        return None;
    }
    let mut gpui_children = children
        .iter()
        .enumerate()
        .filter(|(_, child)| child.gpui_view);
    let (index, child) = gpui_children.next()?;
    if gpui_children.next().is_some() || !child.expected_window || !child.direct_child {
        return None;
    }
    Some(index)
}

#[cfg(all(target_os = "macos", not(test)))]
pub(crate) use native::{application_active, readable_window};
#[cfg(target_os = "macos")]
pub(crate) use native::{current_sidebar_pointer, show_sidebar_menu};

#[cfg(target_os = "macos")]
mod native {
    use super::{
        MenuCommand, SidebarAction, Tracking, ViewCategory, anchor_in_view, archive_command,
        copy_id_command, finish_if_open, gpui_child_index, pin_command, pointer_from_view,
        selected_action,
    };
    use cocoa::{
        base::{BOOL, NO, YES, id, nil},
        foundation::{NSArray, NSPoint, NSRect, NSString},
    };
    use gpui::{AnyWindowHandle, App, AsyncApp, Pixels, Point, WindowId, point, px};
    use objc::{
        class,
        declare::ClassDecl,
        msg_send,
        runtime::{Class, Object, Sel},
        sel, sel_impl,
    };
    use std::{ffi::c_void, sync::OnceLock};

    type MenuResult = (Option<SidebarAction>, Option<Point<Pixels>>);
    type Completion = Box<dyn FnOnce(Option<SidebarAction>, Option<Point<Pixels>>, &mut App)>;

    struct Request {
        app: AsyncApp,
        expected: WindowId,
        position: Point<Pixels>,
        pinned: bool,
        archived: bool,
        can_read: bool,
        can_unread: bool,
        completion: Completion,
    }

    #[link(name = "System")]
    unsafe extern "C" {
        // dispatch_get_main_queue is an inline accessor for this exported object.
        static _dispatch_main_q: c_void;
        fn dispatch_async_f(
            queue: *const c_void,
            context: *mut c_void,
            work: extern "C" fn(*mut c_void),
        );
    }

    /// Asynchronously opens source sidebar actions at a content-area position.
    /// Cancellation or an unavailable native anchor returns None. A closed GPUI
    /// window discards the completion. Callers additionally validate their own
    /// chat, project and request generation before consuming either result. The
    /// pointer is sampled directly from AppKit after tracking; None means unknown,
    /// never proof of a sidebar exit. Preserve any pointer hold until a later
    /// fresh pointer event or the independent background/window-detach release.
    pub(crate) fn show_sidebar_menu(
        cx: &mut App,
        window: AnyWindowHandle,
        position: Point<Pixels>,
        pinned: bool,
        archived: bool,
        read_actions: (bool, bool),
        completion: impl FnOnce(Option<SidebarAction>, Option<Point<Pixels>>, &mut App) + 'static,
    ) {
        let request = Box::new(Request {
            app: cx.to_async(),
            expected: window.window_id(),
            position,
            pinned,
            archived,
            can_read: read_actions.0,
            can_unread: read_actions.1,
            completion: Box::new(completion),
        });
        // Do not use cx.defer: deferred GPUI work still owns the App borrow.
        // This box transfers once to the process's native main queue. AsyncApp
        // retains the application only weakly; no entity or native window is
        // retained while this request waits to start.
        unsafe {
            dispatch_async_f(
                std::ptr::addr_of!(_dispatch_main_q),
                Box::into_raw(request).cast(),
                present,
            );
        }
    }

    extern "C" fn present(context: *mut c_void) {
        // The native main-queue callback is the sole owner of this allocation.
        let request = unsafe { Box::from_raw(context.cast::<Request>()) };
        let native_window = request
            .app
            .update(|cx| retained_active_window(request.expected, cx))
            .ok()
            .flatten();

        // All App/Window borrows above have ended before any NSMenu is opened.
        let result = native_window
            .and_then(|window| {
                Tracking::begin().and_then(|_tracking| unsafe { track_menu(&request, &window) })
            })
            .unwrap_or_default();

        let Request {
            app,
            expected,
            completion,
            ..
        } = *request;
        // The nested native loop has ended and released its native objects.
        // Recheck liveness because Close/Quit may have run inside that loop.
        let _ = app.update(move |cx| {
            let open = cx
                .windows()
                .iter()
                .any(|window| window.window_id() == expected);
            finish_if_open(open, result, |(choice, pointer)| {
                completion(choice, pointer, cx)
            });
        });
    }

    /// Queries the exact active window's current native pointer without entering
    /// a tracking loop or consulting GPUI's cached mouse position. Suitable for
    /// first layout and activation. None is unknown and must remain conservative.
    pub(crate) fn current_sidebar_pointer(
        window: AnyWindowHandle,
        cx: &App,
    ) -> Option<Point<Pixels>> {
        // AppKit property reads and coordinate conversion do not run a nested
        // event loop. Unlike menu presentation, this query may hold an App borrow.
        unsafe {
            let _pool = OwnedObject::from_owned(msg_send![class!(NSAutoreleasePool), new])?;
            let native_window = retained_active_window(window.window_id(), cx)?;
            let (content, view) = retained_content_views(&native_window)?;
            current_pointer(&native_window, &content, &view)
        }
    }

    #[cfg(not(test))]
    pub(crate) fn application_active() -> bool {
        unsafe {
            let app: id = msg_send![class!(NSApplication), sharedApplication];
            if app == nil {
                return false;
            }
            let active: BOOL = msg_send![app, isActive];
            active == YES
        }
    }

    /// Read-only exact-window evidence. Native execution/occlusion acceptance
    /// remains a separate gate; missing properties or identity fail closed.
    #[cfg(not(test))]
    pub(crate) fn readable_window(window: AnyWindowHandle, cx: &App) -> bool {
        unsafe {
            let Some(_pool) = OwnedObject::from_owned(msg_send![class!(NSAutoreleasePool), new])
            else {
                return false;
            };
            let Some(native) = retained_active_window(window.window_id(), cx) else {
                return false;
            };
            let Some((_, view)) = retained_content_views(&native) else {
                return false;
            };
            let hidden: BOOL = msg_send![view.0, isHiddenOrHasHiddenAncestor];
            let rect: NSRect = msg_send![view.0, visibleRect];
            let app: id = msg_send![class!(NSApplication), sharedApplication];
            let active: BOOL = msg_send![app, isActive];
            let key: BOOL = msg_send![native.0, isKeyWindow];
            let visible: BOOL = msg_send![native.0, isVisible];
            let minimized: BOOL = msg_send![native.0, isMiniaturized];
            let occlusion: usize = msg_send![native.0, occlusionState];
            let sheet: id = msg_send![native.0, attachedSheet];
            crate::sidebar_read_state::NativeReadEvidence {
                active: active == YES,
                key: key == YES,
                visible: visible == YES,
                minimized: minimized == YES,
                occlusion_visible: (occlusion & (1 << 1)) != 0,
                attached_sheet: sheet != nil,
                hidden_view: hidden == YES,
                view_rect: [
                    rect.origin.x,
                    rect.origin.y,
                    rect.size.width,
                    rect.size.height,
                ],
            }
            .readable()
        }
    }

    fn retained_active_window(expected: WindowId, cx: &App) -> Option<OwnedObject> {
        if !cx.windows().iter().any(|window| window.window_id() == expected)
            // Pinned GPUI MacWindow::active_window reads NSApp.mainWindow,
            // checks GPUIWindow, and returns that window's stored handle.
            || !cx.active_window().is_some_and(|window| window.window_id() == expected)
        {
            return None;
        }
        // Retain this exact identity, never the first window or a title match.
        // The menu path checks it again after update() flushes GPUI effects.
        unsafe {
            let app: id = msg_send![class!(NSApplication), sharedApplication];
            let window: id = msg_send![app, mainWindow];
            OwnedObject::retain(window)
        }
    }

    // A +1 reference, used only on the main thread. Each allocation/retain has
    // one corresponding release even when native validation returns early.
    struct OwnedObject(id);
    impl Drop for OwnedObject {
        fn drop(&mut self) {
            unsafe {
                let _: () = msg_send![self.0, release];
            }
        }
    }
    impl OwnedObject {
        unsafe fn from_owned(object: id) -> Option<Self> {
            (object != nil).then_some(Self(object))
        }

        unsafe fn retain(object: id) -> Option<Self> {
            if object == nil {
                return None;
            }
            let retained = unsafe { msg_send![object, retain] };
            unsafe { Self::from_owned(retained) }
        }
    }

    const SELECTED_IVAR: &str = "belloSidebarSelected";
    fn target_class() -> Option<&'static Class> {
        static CLASS: OnceLock<Option<&'static Class>> = OnceLock::new();
        *CLASS.get_or_init(|| {
            let mut class = ClassDecl::new("BelloAgentSidebarMenuTarget", class!(NSObject))?;
            class.add_ivar::<u8>(SELECTED_IVAR);
            unsafe {
                class.add_method(
                    sel!(selectPin:),
                    select_pin as extern "C" fn(&mut Object, Sel, id),
                );
                class.add_method(
                    sel!(selectArchive:),
                    select_archive as extern "C" fn(&mut Object, Sel, id),
                );
                class.add_method(
                    sel!(selectCopySessionId:),
                    select_copy_id as extern "C" fn(&mut Object, Sel, id),
                );
            }
            unsafe {
                class.add_method(
                    sel!(selectMarkRead:),
                    select_mark_read as extern "C" fn(&mut Object, Sel, id),
                );
                class.add_method(
                    sel!(selectMarkUnread:),
                    select_mark_unread as extern "C" fn(&mut Object, Sel, id),
                );
            }
            Some(class.register())
        })
    }

    extern "C" fn select_pin(target: &mut Object, _: Sel, _: id) {
        // Record intent only. Running the Rust completion here would re-enter
        // GPUI while AppKit is still dispatching this menu's action.
        unsafe { target.set_ivar(SELECTED_IVAR, 1u8) };
    }

    extern "C" fn select_archive(target: &mut Object, _: Sel, _: id) {
        unsafe { target.set_ivar(SELECTED_IVAR, 2u8) };
    }

    extern "C" fn select_copy_id(target: &mut Object, _: Sel, _: id) {
        // Like Pin, defer all GPUI/clipboard work until native tracking ends.
        unsafe { target.set_ivar(SELECTED_IVAR, 3u8) };
    }

    extern "C" fn select_mark_read(target: &mut Object, _: Sel, _: id) {
        unsafe { target.set_ivar(SELECTED_IVAR, 4u8) };
    }
    extern "C" fn select_mark_unread(target: &mut Object, _: Sel, _: id) {
        unsafe { target.set_ivar(SELECTED_IVAR, 5u8) };
    }

    unsafe fn track_menu(request: &Request, window: &OwnedObject) -> Option<MenuResult> {
        unsafe {
            let _pool = OwnedObject::from_owned(msg_send![class!(NSAutoreleasePool), new])?;
            let (content, view) = retained_content_views(window)?;

            // GPUI's mouse coordinate conversion uses the content area's height
            // (MacWindowState::content_size and convert_mouse_position). First
            // express the point in that container, then let AppKit convert into
            // its verified GPUIView child, respecting origins and flipped axes.
            let bounds: NSRect = msg_send![content.0, bounds];
            let flipped: BOOL = msg_send![content.0, isFlipped];
            let (x, y) = anchor_in_view(
                (request.position.x.to_f64(), request.position.y.to_f64()),
                (bounds.origin.x, bounds.origin.y),
                (bounds.size.width, bounds.size.height),
                flipped == YES,
            )?;
            let anchor: NSPoint = msg_send![view.0,
                convertPoint: NSPoint::new(x, y) fromView: content.0
            ];
            if !anchor.x.is_finite() || !anchor.y.is_finite() {
                return None;
            }

            let empty = OwnedObject::from_owned(NSString::alloc(nil).init_str(""))?;
            let menu = OwnedObject::from_owned(msg_send![class!(NSMenu), new])?;
            let _: () = msg_send![menu.0, setAutoenablesItems: NO];
            let target = OwnedObject::from_owned(msg_send![target_class()?, new])?;
            (*target.0).set_ivar(SELECTED_IVAR, 0u8);
            for (index, command) in [
                pin_command(request.pinned),
                archive_command(request.archived),
                copy_id_command(),
                MenuCommand {
                    title: "Mark as Read",
                    symbol: "checkmark",
                    action: SidebarAction::MarkRead,
                },
                MenuCommand {
                    title: "Mark as Unread",
                    symbol: "circle.fill",
                    action: SidebarAction::MarkUnread,
                },
            ]
            .into_iter()
            .enumerate()
            {
                if index == 2 {
                    let separator: id = msg_send![class!(NSMenuItem), separatorItem];
                    let _: () = msg_send![menu.0, addItem: separator];
                }
                let title = OwnedObject::from_owned(NSString::alloc(nil).init_str(command.title))?;
                let symbol =
                    OwnedObject::from_owned(NSString::alloc(nil).init_str(command.symbol))?;
                let action = match command.action {
                    SidebarAction::TogglePinned => sel!(selectPin:),
                    SidebarAction::ToggleArchived => sel!(selectArchive:),
                    SidebarAction::CopySessionId => sel!(selectCopySessionId:),
                    SidebarAction::MarkRead => sel!(selectMarkRead:),
                    SidebarAction::MarkUnread => sel!(selectMarkUnread:),
                };
                let item: id = msg_send![class!(NSMenuItem), alloc];
                let item = OwnedObject::from_owned(msg_send![item,
                    initWithTitle: title.0 action: action keyEquivalent: empty.0
                ])?;
                // NSMenuItem's target is weak. representedObject retains it,
                // as in PiMenu.swift; no item or callback is owned by the target.
                let _: () = msg_send![item.0, setTarget: target.0];
                let _: () = msg_send![item.0, setRepresentedObject: target.0];
                let enabled = match command.action {
                    SidebarAction::MarkRead => request.can_read,
                    SidebarAction::MarkUnread => request.can_unread,
                    _ => true,
                };
                let _: () = msg_send![item.0, setEnabled: if enabled { YES } else { NO }];
                let image: id = msg_send![class!(NSImage),
                    imageWithSystemSymbolName: symbol.0 accessibilityDescription: nil
                ];
                let _: () = msg_send![item.0, setImage: image];
                let _: () = msg_send![menu.0, addItem: item.0];
            }

            let _: BOOL = msg_send![menu.0,
                popUpMenuPositioningItem: nil atLocation: anchor inView: view.0
            ];
            let selected = *(*target.0).get_ivar::<u8>(SELECTED_IVAR);
            let pointer = current_pointer(window, &content, &view);
            Some((selected_action(selected, request.pinned), pointer))
        }
    }

    // Both query paths validate the same unique GPUIView and retain both views
    // before reading coordinates. Unknown/replaced native hierarchies are not
    // silently treated as the expected GPUI content area.
    unsafe fn retained_content_views(window: &OwnedObject) -> Option<(OwnedObject, OwnedObject)> {
        unsafe {
            let app: id = msg_send![class!(NSApplication), sharedApplication];
            let main_window: id = msg_send![app, mainWindow];
            if main_window != window.0 {
                return None;
            }
            let gpui_class = Class::get("GPUIWindow")?;
            let gpui_window: BOOL = msg_send![window.0, isKindOfClass: gpui_class];
            let visible: BOOL = msg_send![window.0, isVisible];
            let main: BOOL = msg_send![window.0, isMainWindow];
            if gpui_window != YES || visible != YES || main != YES {
                return None;
            }
            // This is the exact window retained after cx.active_window matched
            // the expected handle. Never pick the first window or use its title.
            let content: id = msg_send![window.0, contentView];
            let content = OwnedObject::retain(content)?;
            let attached_window: id = msg_send![content.0, window];
            let subviews: id = msg_send![content.0, subviews];
            if subviews == nil || subviews.count() > 64 {
                return None;
            }
            let view_class = Class::get("GPUIView")?;
            let mut children = Vec::new();
            for i in 0..subviews.count() {
                let child = subviews.objectAtIndex(i);
                let gpui_view: BOOL = msg_send![child, isKindOfClass: view_class];
                let child_window: id = msg_send![child, window];
                let superview: id = msg_send![child, superview];
                children.push(ViewCategory {
                    gpui_view: gpui_view == YES,
                    expected_window: child_window == window.0,
                    direct_child: superview == content.0,
                });
            }
            let index = gpui_child_index(attached_window == window.0, &children)?;
            let view = OwnedObject::retain(subviews.objectAtIndex(index as u64))?;

            Some((content, view))
        }
    }

    // Called directly for layout/activation, or after native menu tracking ends,
    // while the exact window and both views remain retained on the main thread.
    // GPUI's Window cache can be stale after activation or nested tracking.
    unsafe fn current_pointer(
        window: &OwnedObject,
        content: &OwnedObject,
        view: &OwnedObject,
    ) -> Option<Point<Pixels>> {
        unsafe {
            let app: id = msg_send![class!(NSApplication), sharedApplication];
            // Both query paths already required this exact main window. If its
            // activation/main ownership has changed, do not interpret the sample
            // as an exit. The owner handles background/detach independently; a
            // later successful query or real pointer event can recheck position.
            let active: BOOL = msg_send![app, isActive];
            let main: id = msg_send![app, mainWindow];
            let visible: BOOL = msg_send![window.0, isVisible];
            let current_content: id = msg_send![window.0, contentView];
            let attached: id = msg_send![content.0, window];
            let view_window: id = msg_send![view.0, window];
            let parent: id = msg_send![view.0, superview];
            if active != YES
                || main != window.0
                || visible != YES
                || current_content != content.0
                || attached != window.0
                || view_window != window.0
                || parent != content.0
            {
                return None;
            }
            // GPUI creates an untransformed content container. If an unexpected
            // native transform appeared during tracking, retain the hold rather
            // than confuse view units with GPUI logical pixels. This check may
            // conservatively remain true even after a transform was reset.
            let transformed: BOOL = msg_send![content.0, isRotatedOrScaledFromBase];
            if transformed != NO {
                return None;
            }
            // Apple defines this as the current pointer independent of both
            // the event being handled and events pending in the event queue:
            // https://developer.apple.com/documentation/appkit/nswindow/mouselocationoutsideofeventstream
            let base: NSPoint = msg_send![window.0, mouseLocationOutsideOfEventStream];
            // nil means the same window's base coordinates, not screen pixels.
            let local: NSPoint = msg_send![content.0, convertPoint: base fromView: nil];
            let bounds: NSRect = msg_send![content.0, bounds];
            let flipped: BOOL = msg_send![content.0, isFlipped];
            let (x, y) = pointer_from_view(
                (local.x, local.y),
                (bounds.origin.x, bounds.origin.y),
                (bounds.size.width, bounds.size.height),
                flipped == YES,
            )?;
            Some(point(px(x), px(y)))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::Cell, rc::Rc};

    #[test]
    fn pin_commands_match_source_labels_symbols_and_desired_state() {
        assert_eq!(
            pin_command(false),
            MenuCommand {
                title: "Pin Chat",
                symbol: "pin",
                action: SidebarAction::TogglePinned
            }
        );
        assert_eq!(
            pin_command(true),
            MenuCommand {
                title: "Unpin Chat",
                symbol: "pin.slash",
                action: SidebarAction::TogglePinned
            }
        );
    }

    #[test]
    fn archive_commands_match_source_labels_symbols_and_activation_intent() {
        assert_eq!(
            archive_command(false),
            MenuCommand {
                title: "Archive Chat",
                symbol: "archivebox",
                action: SidebarAction::ToggleArchived
            }
        );
        assert_eq!(
            archive_command(true),
            MenuCommand {
                title: "Restore Chat",
                symbol: "arrow.uturn.backward",
                action: SidebarAction::ToggleArchived
            }
        );
    }

    #[test]
    fn sidebar_copy_id_label_symbol_and_selection_are_source_exact() {
        assert_eq!(
            copy_id_command(),
            MenuCommand {
                title: "Copy Session ID",
                symbol: "number",
                action: SidebarAction::CopySessionId
            }
        );
        for pinned in [false, true] {
            assert_eq!(selected_action(0, pinned), None);
            assert_eq!(
                selected_action(1, pinned),
                Some(SidebarAction::TogglePinned)
            );
            assert_eq!(
                selected_action(3, pinned),
                Some(SidebarAction::CopySessionId)
            );
            assert_eq!(
                selected_action(2, pinned),
                Some(SidebarAction::ToggleArchived)
            );
            assert_eq!(selected_action(4, pinned), Some(SidebarAction::MarkRead));
            assert_eq!(selected_action(5, pinned), Some(SidebarAction::MarkUnread));
            assert_eq!(selected_action(u8::MAX, pinned), None);
        }
    }

    #[test]
    fn anchor_uses_view_coordinates_without_retina_scaling() {
        assert_eq!(
            anchor_in_view((40.0, 60.0), (0.0, 0.0), (800.0, 600.0), false),
            Some((40.0, 540.0))
        );
        assert_eq!(
            anchor_in_view((40.0, 60.0), (2.0, 3.0), (800.0, 600.0), true),
            Some((42.0, 63.0))
        );
        assert_eq!(
            anchor_in_view((40.0, 60.0), (2.0, 3.0), (800.0, 600.0), false),
            Some((42.0, 543.0))
        );
    }

    #[test]
    fn invalid_or_no_longer_visible_positions_do_not_open_a_menu() {
        for position in [
            (f64::NAN, 0.0),
            (0.0, f64::INFINITY),
            (-1.0, 0.0),
            (801.0, 0.0),
            (0.0, 601.0),
        ] {
            assert_eq!(
                anchor_in_view(position, (0.0, 0.0), (800.0, 600.0), false),
                None
            );
        }
        assert_eq!(
            anchor_in_view((0.0, 0.0), (0.0, 0.0), (0.0, 600.0), false),
            None
        );
        assert_eq!(
            anchor_in_view((0.0, 0.0), (f64::NAN, 0.0), (800.0, 600.0), false),
            None
        );
    }

    #[test]
    fn completion_pointer_inverts_anchor_in_points_for_both_axes() {
        for flipped in [false, true] {
            let origin = (2.0, 3.0);
            let size = (800.0, 600.0);
            let anchored = anchor_in_view((40.0, 60.0), origin, size, flipped).unwrap();
            assert_eq!(
                pointer_from_view(anchored, origin, size, flipped),
                Some((40.0, 60.0))
            );
        }
    }

    #[test]
    fn completion_pointer_preserves_outside_coordinates_without_clamping() {
        assert_eq!(
            pointer_from_view((-10.0, 650.0), (0.0, 0.0), (800.0, 600.0), false),
            Some((-10.0, -50.0))
        );
        assert_eq!(
            pointer_from_view((900.0, 650.0), (0.0, 0.0), (800.0, 600.0), true),
            Some((900.0, 650.0))
        );
    }

    #[test]
    fn invalid_completion_pointer_remains_unknown_not_a_synthetic_exit() {
        for position in [(f64::NAN, 0.0), (0.0, f64::INFINITY), (f64::MAX, 0.0)] {
            assert_eq!(
                pointer_from_view(position, (0.0, 0.0), (800.0, 600.0), false),
                None
            );
        }
        for size in [(0.0, 600.0), (800.0, -1.0), (800.0, f64::NAN)] {
            assert_eq!(
                pointer_from_view((40.0, 60.0), (0.0, 0.0), size, false),
                None
            );
        }
        assert_eq!(
            pointer_from_view((40.0, 60.0), (f64::INFINITY, 0.0), (800.0, 600.0), false),
            None
        );
        finish_if_open(
            true,
            (None::<SidebarAction>, None::<(f32, f32)>),
            |result| {
                assert_eq!(result, (None, None));
            },
        );
    }

    struct DropCount(Rc<Cell<usize>>);
    impl Drop for DropCount {
        fn drop(&mut self) {
            self.0.set(self.0.get() + 1);
        }
    }

    #[test]
    fn selection_and_cancel_deliver_once_and_release_the_callback() {
        for choice in [
            None,
            Some(SidebarAction::TogglePinned),
            Some(SidebarAction::TogglePinned),
            Some(SidebarAction::CopySessionId),
        ] {
            let calls = Cell::new(0);
            let drops = Rc::new(Cell::new(0));
            let owned = DropCount(drops.clone());
            finish_if_open(true, choice, |result| {
                assert_eq!(result, choice);
                calls.set(calls.get() + 1);
                drop(owned);
            });
            assert_eq!(calls.get(), 1);
            assert_eq!(drops.get(), 1);
        }
    }

    #[test]
    fn closed_window_discards_and_releases_the_callback() {
        let drops = Rc::new(Cell::new(0));
        let owned = DropCount(drops.clone());
        finish_if_open(false, Some(SidebarAction::CopySessionId), |_| {
            drop(owned);
            panic!("a closed window must never receive the selection");
        });
        assert_eq!(drops.get(), 1);
    }

    #[test]
    fn closed_window_discards_fresh_pointer_alongside_selection() {
        finish_if_open(
            false,
            (
                Some(SidebarAction::CopySessionId),
                Some((-10.0f32, 20.0f32)),
            ),
            |_| panic!("a detached owner must never consume the pointer sample"),
        );
    }

    #[test]
    fn nested_request_cannot_reset_the_active_tracking_guard() {
        let first = Tracking::begin().unwrap();
        assert!(Tracking::begin().is_none());
        assert!(Tracking::begin().is_none());
        drop(first);
        assert!(Tracking::begin().is_some());
    }

    fn attached_gpui_view() -> ViewCategory {
        ViewCategory {
            gpui_view: true,
            expected_window: true,
            direct_child: true,
        }
    }

    #[test]
    fn pinned_gpui_contract_uses_child_of_appkit_content_container() {
        // GPUI 0.2.2's contentView is an ordinary NSView container, with its
        // separately allocated GPUIView added beneath it. Auxiliary AppKit
        // children can precede or follow that child; their order is immaterial.
        assert_eq!(gpui_child_index(true, &[attached_gpui_view()]), Some(0));
        assert_eq!(
            gpui_child_index(
                true,
                &[
                    ViewCategory::default(),
                    attached_gpui_view(),
                    ViewCategory::default()
                ]
            ),
            Some(1)
        );
    }

    #[test]
    fn gpui_child_must_be_unique_direct_and_attached_to_expected_window() {
        assert_eq!(gpui_child_index(true, &[]), None);
        assert_eq!(gpui_child_index(true, &[ViewCategory::default()]), None);
        assert_eq!(gpui_child_index(false, &[attached_gpui_view()]), None);
        assert_eq!(
            gpui_child_index(true, &[attached_gpui_view(), attached_gpui_view()]),
            None
        );
        assert_eq!(
            gpui_child_index(
                true,
                &[ViewCategory {
                    expected_window: false,
                    ..attached_gpui_view()
                }]
            ),
            None
        );
        assert_eq!(
            gpui_child_index(
                true,
                &[ViewCategory {
                    direct_child: false,
                    ..attached_gpui_view()
                }]
            ),
            None
        );
    }
}
