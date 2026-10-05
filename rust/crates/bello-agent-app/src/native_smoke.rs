//! Opt-in native window lifecycle diagnostics. No pixel, input, IME or updater claim.
//! The production application path remains in main; this module only observes and
//! asks our own NSWindow to perform its ordinary, delegate-mediated close.
use std::{ffi::OsString, path::Path};

fn enabled() -> bool {
    std::env::var_os("BELLO_NATIVE_LIFECYCLE_SMOKE").as_deref() == Some(std::ffi::OsStr::new("1"))
}

pub(super) fn validate_launch() -> Result<(), Box<dyn std::error::Error>> {
    match std::env::var_os("BELLO_NATIVE_LIFECYCLE_SMOKE") {
        None => return Ok(()),
        Some(value) if value == "1" => {}
        _ => return Err("Native lifecycle smoke: invalid opt-in".into()),
    }
    let root = std::env::var_os("BELLO_NATIVE_SMOKE_ROOT").ok_or("Missing smoke fixture")?;
    let runner = std::env::var_os("RUNNER_TEMP").ok_or("Missing runner temporary directory")?;
    let home = std::env::var_os("HOME").ok_or("Missing isolated home")?;
    validate_paths(
        &std::env::args_os().skip(1).collect::<Vec<_>>(),
        Path::new(&root),
        Path::new(&runner),
        Path::new(&home),
    )?;
    if !cfg!(target_os = "macos") {
        return Err("Native lifecycle smoke requires macOS".into());
    }
    Ok(())
}

fn validate_paths(
    args: &[OsString],
    root: &Path,
    runner: &Path,
    home: &Path,
) -> Result<(), &'static str> {
    // Reject unknown/provider/credential arguments before reading any app data.
    if args.len() != 4 || args[0] != "--project" || args[2] != "--session" {
        return Err("Smoke accepts only explicit project and session fixture arguments");
    }
    let canonical = |p: &Path| p.canonicalize().map_err(|_| "Smoke fixture unavailable");
    if !root.is_absolute() || !runner.is_absolute() || !home.is_absolute() {
        return Err("Smoke fixture paths must be absolute");
    }
    let runner = canonical(runner)?;
    let resolved = canonical(root)?;
    if resolved != root
        || resolved.parent() != Some(runner.as_path())
        || !resolved
            .file_name()
            .is_some_and(|s| s.to_string_lossy().starts_with("bello-native-"))
    {
        return Err("Smoke fixture must be a dedicated runner temporary directory");
    }
    let project = root.join("project");
    let sessions = root.join("session");
    if Path::new(&args[1]) != project
        || Path::new(&args[3]) != sessions.join("default.json")
        || home != root.join("home")
    {
        return Err("Smoke arguments must use the isolated fixture layout");
    }
    for directory in [&project, &sessions, home] {
        if canonical(directory)? != directory
            || !directory.is_dir()
            || std::fs::read_dir(directory)
                .map_err(|_| "Smoke fixture unreadable")?
                .next()
                .is_some()
        {
            return Err("Smoke fixture directories must be fresh, empty and not symlinks");
        }
    }
    Ok(())
}

pub(super) fn install(cx: &mut gpui::App) {
    if !enabled() {
        return;
    }
    #[cfg(target_os = "macos")]
    native::install(cx);
    #[cfg(not(target_os = "macos"))]
    {
        let _ = cx;
        unreachable!("validate_launch rejects non-macOS smoke");
    }
}

// NSApplication.windows can contain framework-owned windows. Classify every
// entry, never select the first one or accept an unexpected visible window.
#[cfg(any(target_os = "macos", test))]
#[derive(Clone, Copy, Default)]
struct WindowCategory {
    expected_title: bool,
    gpui_window: bool,
    gpui_panel: bool,
    visible: bool,
    main: bool,
    key: bool,
}

#[cfg(any(target_os = "macos", test))]
fn workspace_index(
    windows: &[WindowCategory],
    expected_active: bool,
) -> Result<Option<usize>, &'static str> {
    if windows.is_empty() {
        return Ok(None);
    }
    if windows.iter().filter(|w| w.gpui_window).count() != 1
        || windows.iter().any(|w| w.gpui_panel)
        || windows.iter().filter(|w| w.expected_title).count() != 1
    {
        return Err("unexpected_window_count");
    }
    let index = windows
        .iter()
        .position(|w| w.gpui_window && w.expected_title)
        .ok_or("unexpected_window")?;
    if windows
        .iter()
        .enumerate()
        .any(|(i, w)| i != index && (w.visible || w.main || w.key))
    {
        return Err("unexpected_visible_window");
    }
    let target = windows[index];
    if !target.visible || !target.main {
        return Ok(None);
    }
    if !expected_active {
        return Err("native_identity_mismatch");
    }
    Ok(Some(index))
}

#[cfg(target_os = "macos")]
mod native {
    use super::{WindowCategory, workspace_index};
    use cocoa::{
        base::{BOOL, YES, id, nil},
        foundation::{NSArray, NSRect, NSString},
    };
    use objc::{class, msg_send, sel, sel_impl};
    use std::{
        ffi::c_void,
        io::Write,
        sync::{
            OnceLock,
            atomic::{AtomicU8, Ordering},
        },
        time::{Duration, Instant},
    };

    struct Probe {
        app: gpui::AsyncApp,
        expected: gpui::WindowId,
        last_counts: Option<String>,
    }
    static STAGE: AtomicU8 = AtomicU8::new(0);
    static STARTED: OnceLock<Instant> = OnceLock::new();
    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        fn CGSessionCopyCurrentDictionary() -> *const c_void;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFRelease(value: *const c_void);
    }
    #[link(name = "Metal", kind = "framework")]
    unsafe extern "C" {
        fn MTLCreateSystemDefaultDevice() -> id;
    }
    #[link(name = "System")]
    unsafe extern "C" {
        // dispatch_get_main_queue is a C inline accessor for this exported object.
        static _dispatch_main_q: c_void;
        fn dispatch_time(when: u64, delta: i64) -> u64;
        fn dispatch_after_f(
            when: u64,
            queue: *const c_void,
            context: *mut c_void,
            work: extern "C" fn(*mut c_void),
        );
    }
    fn fail(reason: &'static str) -> ! {
        eprintln!("BELLO_NATIVE_LIFECYCLE failure:{reason}");
        std::process::exit(2)
    }
    fn mark(expected: u8, next: u8, name: &'static str) {
        if STAGE
            .compare_exchange(expected, next, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            fail("marker_order");
        }
        println!("BELLO_NATIVE_LIFECYCLE {name}");
        if std::io::stdout().flush().is_err() {
            fail("log_write");
        }
    }
    pub(super) fn install(cx: &mut gpui::App) {
        if STARTED.set(Instant::now()).is_err() {
            fail("duplicate_install");
        }
        unsafe {
            let session = CGSessionCopyCurrentDictionary();
            if session.is_null() {
                fail("no_gui_session");
            }
            CFRelease(session);
            let screens: id = msg_send![class!(NSScreen), screens];
            if screens == nil || screens.count() == 0 {
                fail("no_display");
            }
            let device = MTLCreateSystemDefaultDevice();
            if device == nil {
                fail("no_metal_device");
            }
            let _: () = msg_send![device, release];
        }
        let windows = cx.windows();
        if windows.len() != 1 {
            fail("unexpected_gpui_window_count");
        }
        let probe = Box::new(Probe {
            app: cx.to_async(),
            expected: windows[0].window_id(),
            last_counts: None,
        });
        mark(0, 1, "environment_ready");
        cx.on_window_closed(|cx| {
            if !cx.windows().is_empty() {
                fail("unexpected_remaining_window");
            }
            mark(3, 4, "window_closed");
        })
        .detach();
        cx.on_app_quit(|_| {
            mark(4, 5, "app_quitting");
            async {}
        })
        .detach();
        schedule(probe);
    }
    fn schedule(probe: Box<Probe>) {
        unsafe {
            dispatch_after_f(
                dispatch_time(0, 100_000_000),
                std::ptr::addr_of!(_dispatch_main_q),
                Box::into_raw(probe).cast(),
                inspect,
            );
        }
    }
    extern "C" fn inspect(context: *mut c_void) {
        // A single scheduled main-queue callback owns this box; retries transfer
        // ownership to the next callback. No App/Window borrow crosses performClose.
        let mut probe = unsafe { Box::from_raw(context.cast::<Probe>()) };
        let expected_active = probe
            .app
            .update(|cx| {
                let windows = cx.windows();
                if windows.len() != 1 || windows[0].window_id() != probe.expected {
                    fail("unexpected_gpui_window_count");
                }
                // Pinned GPUI MacWindow::active_window reads NSApp.mainWindow,
                // checks GPUIWindow, then returns that native window's stored handle.
                cx.active_window()
                    .is_some_and(|handle| handle.window_id() == probe.expected)
            })
            .unwrap_or_else(|_| fail("app_unavailable"));
        // Invoked by the native main queue, outside a borrowed GPUI App/Window.
        // performClose: synchronously re-enters GPUI's windowShouldClose delegate.
        if STARTED
            .get()
            .is_none_or(|start| start.elapsed() > Duration::from_secs(15))
        {
            fail("window_not_ready");
        }
        unsafe {
            let app: id = msg_send![class!(NSApplication), sharedApplication];
            let windows: id = msg_send![app, windows];
            let count = if windows == nil { 0 } else { windows.count() };
            if count > 64 {
                fail("unexpected_window_count");
            }
            let expected = NSString::alloc(nil).init_str("Bello Agent");
            let mut categories = Vec::new();
            for i in 0..count {
                let window = windows.objectAtIndex(i);
                let title: id = msg_send![window, title];
                let expected_title: BOOL = msg_send![title, isEqualToString: expected];
                let gpui_window: BOOL = msg_send![window, isKindOfClass: class!(GPUIWindow)];
                let gpui_panel: BOOL = msg_send![window, isKindOfClass: class!(GPUIPanel)];
                let visible: BOOL = msg_send![window, isVisible];
                let main: BOOL = msg_send![window, isMainWindow];
                let key: BOOL = msg_send![window, isKeyWindow];
                categories.push(WindowCategory {
                    expected_title: expected_title == YES,
                    gpui_window: gpui_window == YES,
                    gpui_panel: gpui_panel == YES,
                    visible: visible == YES,
                    main: main == YES,
                    key: key == YES,
                });
            }
            let _: () = msg_send![expected, release];
            let tally =
                |test: fn(&WindowCategory) -> bool| categories.iter().filter(|w| test(w)).count();
            let counts = format!(
                "BELLO_NATIVE_WINDOW_COUNTS total={} expected={} gpui={} panels={} visible={} hidden={} main={} key={} matched_active={}",
                count,
                tally(|w| w.expected_title),
                tally(|w| w.gpui_window),
                tally(|w| w.gpui_panel),
                tally(|w| w.visible),
                tally(|w| !w.visible),
                tally(|w| w.main),
                tally(|w| w.key),
                usize::from(expected_active)
            );
            if probe.last_counts.as_ref() != Some(&counts) {
                println!("{counts}");
                if std::io::stdout().flush().is_err() {
                    fail("log_write");
                }
                probe.last_counts = Some(counts);
            }
            let index = match workspace_index(&categories, expected_active) {
                Ok(Some(index)) => index,
                Ok(None) => {
                    schedule(probe);
                    return;
                }
                Err(reason) => fail(reason),
            };
            let window = windows.objectAtIndex(index as u64);
            let native_main: id = msg_send![app, mainWindow];
            if window != native_main {
                fail("native_identity_mismatch");
            }
            let screen: id = msg_send![window, screen];
            let view: id = msg_send![window, contentView];
            if view == nil {
                fail("no_content_view");
            }
            let bounds: NSRect = msg_send![view, bounds];
            if screen == nil
                || !bounds.size.width.is_finite()
                || !bounds.size.height.is_finite()
                || bounds.size.width <= 0.0
                || bounds.size.height <= 0.0
            {
                schedule(probe);
                return;
            }
            mark(1, 2, "window_observed");
            mark(2, 3, "close_requested");
            let _: () = msg_send![window, performClose: nil];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn main_window() -> WindowCategory {
        WindowCategory {
            expected_title: true,
            gpui_window: true,
            visible: true,
            main: true,
            key: true,
            ..Default::default()
        }
    }
    #[test]
    fn selects_exact_main_gpui_window_after_hidden_auxiliary() {
        assert_eq!(
            workspace_index(&[WindowCategory::default(), main_window()], true),
            Ok(Some(1))
        );
    }
    #[test]
    fn rejects_unexpected_visible_main_key_or_gpui_windows() {
        for extra in [
            WindowCategory {
                visible: true,
                ..Default::default()
            },
            WindowCategory {
                main: true,
                ..Default::default()
            },
            WindowCategory {
                key: true,
                ..Default::default()
            },
            WindowCategory {
                gpui_window: true,
                ..Default::default()
            },
            WindowCategory {
                gpui_panel: true,
                ..Default::default()
            },
            WindowCategory {
                expected_title: true,
                ..Default::default()
            },
        ] {
            assert!(workspace_index(&[main_window(), extra], true).is_err());
        }
    }
    #[test]
    fn requires_unique_title_native_identity_and_ready_main_window() {
        assert_eq!(
            workspace_index(&[main_window()], false),
            Err("native_identity_mismatch")
        );
        let mut target = main_window();
        target.main = false;
        assert_eq!(workspace_index(&[target], false), Ok(None));
        target = main_window();
        target.expected_title = false;
        assert!(workspace_index(&[target], true).is_err());
        assert_eq!(workspace_index(&[], false), Ok(None));
        assert!(workspace_index(&[main_window(), main_window()], true).is_err());
    }

    fn fixture() -> (tempfile::TempDir, std::path::PathBuf, Vec<OsString>) {
        let runner = tempfile::tempdir().unwrap();
        let root = runner
            .path()
            .canonicalize()
            .unwrap()
            .join("bello-native-test");
        for name in ["project", "session", "home"] {
            std::fs::create_dir_all(root.join(name)).unwrap();
        }
        let args = vec![
            "--project".into(),
            root.join("project").into_os_string(),
            "--session".into(),
            root.join("session/default.json").into_os_string(),
        ];
        (runner, root, args)
    }
    #[test]
    fn accepts_only_fresh_explicit_fixture() {
        let (runner, root, args) = fixture();
        assert!(validate_paths(&args, &root, runner.path(), &root.join("home")).is_ok());
        std::fs::write(root.join("session/default.json"), b"{}").unwrap();
        assert!(validate_paths(&args, &root, runner.path(), &root.join("home")).is_err());
    }
    #[test]
    fn rejects_provider_credentials_unknown_and_missing_flags() {
        let (runner, root, args) = fixture();
        for flag in ["--profile", "--credential-stdin", "--unknown", "--help"] {
            let mut changed = args.clone();
            changed[0] = flag.into();
            assert!(validate_paths(&changed, &root, runner.path(), &root.join("home")).is_err());
        }
        assert!(validate_paths(&args[..2], &root, runner.path(), &root.join("home")).is_err());
    }
    #[test]
    fn rejects_external_paths_and_populated_project() {
        let (runner, root, mut args) = fixture();
        args[3] = runner.path().join("external.json").into_os_string();
        assert!(validate_paths(&args, &root, runner.path(), &root.join("home")).is_err());
        args[3] = root.join("session/default.json").into_os_string();
        std::fs::write(root.join("project/file"), b"fixture").unwrap();
        assert!(validate_paths(&args, &root, runner.path(), &root.join("home")).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn rejects_symlink_fixture_directory() {
        let (runner, root, args) = fixture();
        std::fs::remove_dir(root.join("project")).unwrap();
        std::os::unix::fs::symlink(root.join("home"), root.join("project")).unwrap();
        assert!(validate_paths(&args, &root, runner.path(), &root.join("home")).is_err());
    }
}
