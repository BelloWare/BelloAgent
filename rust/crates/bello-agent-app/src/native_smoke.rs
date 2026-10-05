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

#[cfg(target_os = "macos")]
mod native {
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
        schedule();
    }
    fn schedule() {
        unsafe {
            dispatch_after_f(
                dispatch_time(0, 100_000_000),
                std::ptr::addr_of!(_dispatch_main_q),
                std::ptr::null_mut(),
                inspect,
            );
        }
    }
    extern "C" fn inspect(_: *mut c_void) {
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
            if windows == nil || windows.count() == 0 {
                schedule();
                return;
            }
            if windows.count() != 1 {
                fail("unexpected_window_count");
            }
            let window = windows.objectAtIndex(0);
            let title: id = msg_send![window, title];
            let expected = NSString::alloc(nil).init_str("Bello Agent");
            let matches: BOOL = msg_send![title, isEqualToString: expected];
            let _: () = msg_send![expected, release];
            if matches != YES {
                fail("unexpected_window");
            }
            let visible: BOOL = msg_send![window, isVisible];
            let screen: id = msg_send![window, screen];
            let view: id = msg_send![window, contentView];
            if view == nil {
                fail("no_content_view");
            }
            let bounds: NSRect = msg_send![view, bounds];
            if visible != YES
                || screen == nil
                || !bounds.size.width.is_finite()
                || !bounds.size.height.is_finite()
                || bounds.size.width <= 0.0
                || bounds.size.height <= 0.0
            {
                schedule();
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
