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
            action: SidebarAction::SetPinned(false),
        }
    } else {
        MenuCommand {
            title: "Pin Chat",
            symbol: "pin",
            action: SidebarAction::SetPinned(true),
        }
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
        2 => Some(copy_id_command().action),
        _ => None,
    }
}

fn finish_if_open(
    open: bool,
    choice: Option<SidebarAction>,
    completion: impl FnOnce(Option<SidebarAction>),
) {
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

#[cfg(target_os = "macos")]
pub(crate) use native::show_sidebar_menu;

#[cfg(target_os = "macos")]
mod native {
    use super::{
        SidebarAction, Tracking, ViewCategory, anchor_in_view, copy_id_command, finish_if_open,
        gpui_child_index, pin_command, selected_action,
    };
    use cocoa::{
        base::{BOOL, NO, YES, id, nil},
        foundation::{NSArray, NSPoint, NSRect, NSString},
    };
    use gpui::{AnyWindowHandle, App, AsyncApp, Pixels, Point, WindowId};
    use objc::{
        class,
        declare::ClassDecl,
        msg_send,
        runtime::{Class, Object, Sel},
        sel, sel_impl,
    };
    use std::{ffi::c_void, sync::OnceLock};

    type Completion = Box<dyn FnOnce(Option<SidebarAction>, &mut App)>;

    struct Request {
        app: AsyncApp,
        expected: WindowId,
        position: Point<Pixels>,
        pinned: bool,
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
    /// chat, project and request generation before applying a selected action.
    pub(crate) fn show_sidebar_menu(
        cx: &mut App,
        window: AnyWindowHandle,
        position: Point<Pixels>,
        pinned: bool,
        completion: impl FnOnce(Option<SidebarAction>, &mut App) + 'static,
    ) {
        let request = Box::new(Request {
            app: cx.to_async(),
            expected: window.window_id(),
            position,
            pinned,
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
            .update(|cx| {
                if !cx.windows()
                    .iter()
                    .any(|window| window.window_id() == request.expected)
                    // Pinned GPUI MacWindow::active_window reads NSApp.mainWindow,
                    // checks GPUIWindow, and returns that window's stored handle.
                    || !cx
                        .active_window()
                        .is_some_and(|window| window.window_id() == request.expected)
                {
                    return None;
                }
                // Retain that exact process-owned native identity now; update()
                // flushes GPUI effects after this callback returns. Tracking will
                // recheck that it is still the visible main window afterward.
                unsafe {
                    let app: id = msg_send![class!(NSApplication), sharedApplication];
                    let window: id = msg_send![app, mainWindow];
                    OwnedObject::retain(window)
                }
            })
            .ok()
            .flatten();

        // All App/Window borrows above have ended before any NSMenu is opened.
        let choice = native_window.and_then(|window| {
            Tracking::begin().and_then(|_tracking| unsafe { track_menu(&request, &window) })
        });

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
            finish_if_open(open, choice, |choice| completion(choice, cx));
        });
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
                    sel!(selectCopySessionId:),
                    select_copy_id as extern "C" fn(&mut Object, Sel, id),
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

    extern "C" fn select_copy_id(target: &mut Object, _: Sel, _: id) {
        // Like Pin, defer all GPUI/clipboard work until native tracking ends.
        unsafe { target.set_ivar(SELECTED_IVAR, 2u8) };
    }

    unsafe fn track_menu(request: &Request, window: &OwnedObject) -> Option<SidebarAction> {
        unsafe {
            let _pool = OwnedObject::from_owned(msg_send![class!(NSAutoreleasePool), new])?;
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
            for (index, command) in [pin_command(request.pinned), copy_id_command()]
                .into_iter()
                .enumerate()
            {
                if index == 1 {
                    let separator: id = msg_send![class!(NSMenuItem), separatorItem];
                    let _: () = msg_send![menu.0, addItem: separator];
                }
                let title = OwnedObject::from_owned(NSString::alloc(nil).init_str(command.title))?;
                let symbol =
                    OwnedObject::from_owned(NSString::alloc(nil).init_str(command.symbol))?;
                let action = match command.action {
                    SidebarAction::SetPinned(_) => sel!(selectPin:),
                    SidebarAction::CopySessionId => sel!(selectCopySessionId:),
                };
                let item: id = msg_send![class!(NSMenuItem), alloc];
                let item = OwnedObject::from_owned(msg_send![item,
                    initWithTitle: title.0 action: action keyEquivalent: empty.0
                ])?;
                // NSMenuItem's target is weak. representedObject retains it,
                // as in PiMenu.swift; no item or callback is owned by the target.
                let _: () = msg_send![item.0, setTarget: target.0];
                let _: () = msg_send![item.0, setRepresentedObject: target.0];
                let _: () = msg_send![item.0, setEnabled: YES];
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
            selected_action(selected, request.pinned)
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
                action: SidebarAction::SetPinned(true)
            }
        );
        assert_eq!(
            pin_command(true),
            MenuCommand {
                title: "Unpin Chat",
                symbol: "pin.slash",
                action: SidebarAction::SetPinned(false)
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
                Some(SidebarAction::SetPinned(!pinned))
            );
            assert_eq!(
                selected_action(2, pinned),
                Some(SidebarAction::CopySessionId)
            );
            assert_eq!(selected_action(3, pinned), None);
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
            Some(SidebarAction::SetPinned(true)),
            Some(SidebarAction::SetPinned(false)),
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
