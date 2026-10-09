//! Linux debug-only, explicitly disposable GUI validation. This is not production
//! cache admission or native acceptance. Same-UID hostile processes are outside
//! the boundary, as in Core's private cache filename admission.
use crate::{
    LaunchState, assets, launch_authority::AuthorityMode, workspace_lifetime::WorkspaceLifetime,
};
use bello_agent_core::{
    Controller, Message, SessionStore,
    sidebar_search::cache::{CacheBinding, PrivateCache},
    workspace::{ChatRecord, DraftRecord, WorkspaceSnapshot, WorkspaceStore},
};
use gpui::{App, Application};
use serde::{Deserialize, Serialize};
use std::{
    ffi::{CString, OsString},
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::OsStrExt,
            fs::{MetadataExt, OpenOptionsExt},
        },
    },
    path::{Component, Path, PathBuf},
    sync::{Arc, Mutex},
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
const FLAG: &str = "--synthetic-sidebar-search-fixture";
const MARKER: &str = ".bello-synthetic-sidebar-v2.json";
const IDS: [&str; 5] = [
    "00000000-0000-4000-8000-000000000101",
    "00000000-0000-4000-8000-000000000102",
    "00000000-0000-4000-8000-000000000103",
    "00000000-0000-4000-8000-000000000104",
    "00000000-0000-4000-8000-000000000105",
];
const TITLES: [&str; 5] = [
    "Synthetic selected",
    "Synthetic unopened",
    "Synthetic violetneedle title",
    "Synthetic retained tools",
    "Synthetic distant history",
];
const MAX_FILE: u64 = 16 * 1024 * 1024;

/// No public boolean can manufacture readiness. This wrapper is constructed only
/// after disposable-root and exact binding namespace validation and real open.
pub(crate) struct PreparedCache {
    workspace: std::sync::Weak<Mutex<WorkspaceStore>>,
    binding: CacheBinding,
    cache: PrivateCache,
}
impl PreparedCache {
    pub(crate) fn matches_workspace(&self, workspace: &Arc<Mutex<WorkspaceStore>>) -> bool {
        self.workspace.ptr_eq(&Arc::downgrade(workspace))
    }
    pub(crate) fn into_parts(self) -> (CacheBinding, PrivateCache) {
        (self.binding, self.cache)
    }
}

#[derive(Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Marker {
    schema: u32,
    fixture: String,
    root: PathBuf,
    uid: u32,
}
struct DisposableRoot {
    path: PathBuf,
    _directory: File,
    _lease: File,
    fresh: bool,
}
struct Prepared {
    _root: DisposableRoot,
    launch: LaunchState,
    cache: PreparedCache,
}

/// Called before current-directory/default-session, ordinary argument handling,
/// profile/stdin, native smoke validation, or any authority construction.
pub(crate) fn requested(args: &[OsString]) -> Result<Option<PathBuf>> {
    if !args
        .iter()
        .any(|arg| arg.as_bytes().starts_with(FLAG.as_bytes()))
    {
        return Ok(None);
    }
    if args.len() != 2 || args[0] != FLAG || args[1].as_bytes().starts_with(b"-") {
        return Err("Synthetic sidebar launch accepts exactly --synthetic-sidebar-search-fixture ROOT and no other arguments".into());
    }
    let root = PathBuf::from(&args[1]);
    lexical_absolute(&root)?;
    Ok(Some(root))
}
fn lexical_absolute(path: &Path) -> Result<()> {
    if !path.is_absolute()
        || path == Path::new("/")
        || path
            .components()
            .any(|part| !matches!(part, Component::RootDir | Component::Normal(_)))
        || path
            .as_os_str()
            .as_bytes()
            .split(|byte| *byte == b'/')
            .skip(1)
            .any(|part| part.is_empty() || part == b".")
    {
        return Err("Synthetic root must be a canonical absolute private directory".into());
    }
    Ok(())
}
fn uid() -> u32 {
    // SAFETY: geteuid has no memory preconditions.
    unsafe { libc::geteuid() }
}
fn owned_mode(metadata: &fs::Metadata, directory: bool, private: bool, expected_uid: u32) -> bool {
    (if directory {
        metadata.is_dir()
    } else {
        metadata.is_file()
    }) && (metadata.uid() == expected_uid || (!private && metadata.uid() == 0))
        && if private {
            metadata.mode() & 0o7777 == if directory { 0o700 } else { 0o600 }
                && (directory || metadata.nlink() == 1)
        } else {
            metadata.mode() & 0o022 == 0
        }
}
/// The probe is bounded so repeated interruption remains a closed admission.
fn exclude_acl(
    role: &str,
    attribute: &str,
    mut probe: impl FnMut() -> (isize, Option<i32>),
) -> Result<()> {
    const MAX_ATTEMPTS: usize = 3;
    for attempt in 1..=MAX_ATTEMPTS {
        let (count, errno) = probe();
        if count < 0 && matches!(errno, Some(libc::ENODATA) | Some(libc::ENOTSUP)) {
            return Ok(());
        }
        if count < 0 && errno == Some(libc::EINTR) && attempt < MAX_ATTEMPTS {
            continue;
        }
        return Err(format!(
            "Synthetic fixture ACL could not be excluded: role={role}, attribute={attribute}, result={count}, errno={errno:?}, attempts={attempt}"
        ).into());
    }
    unreachable!("the final interrupted probe returns a closed admission")
}
fn validate(file: &File, directory: bool, private: bool, role: &str) -> Result<()> {
    if !owned_mode(&file.metadata()?, directory, private, uid()) {
        return Err(format!(
            "Unsafe synthetic fixture owner, type, links, or permissions: role={role}"
        )
        .into());
    }
    for attr in [c"system.posix_acl_access", c"system.posix_acl_default"] {
        exclude_acl(role, attr.to_str()?, || {
            // SAFETY: valid owned descriptor, constant name, no output buffer.
            let count = unsafe {
                libc::fgetxattr(file.as_raw_fd(), attr.as_ptr(), std::ptr::null_mut(), 0)
            };
            let errno = (count < 0)
                .then(|| std::io::Error::last_os_error().raw_os_error())
                .flatten();
            (count, errno)
        })?;
    }
    Ok(())
}

fn checked(fd: i32) -> Result<File> {
    if fd < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    // SAFETY: successful open/openat returns a uniquely owned descriptor.
    Ok(unsafe { File::from_raw_fd(fd) })
}
fn directory_at(
    parent: &File,
    name: &std::ffi::OsStr,
    private: bool,
    create: bool,
) -> Result<File> {
    let name = CString::new(name.as_bytes())?;
    if create {
        // SAFETY: checked parent and one NUL-terminated component; never chmod existing data.
        let created = unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) };
        if created < 0 && std::io::Error::last_os_error().raw_os_error() != Some(libc::EEXIST) {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    // SAFETY: checked parent, one component; no-follow and non-blocking reject substitutions.
    let file = checked(unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY
                | libc::O_DIRECTORY
                | libc::O_NOFOLLOW
                | libc::O_CLOEXEC
                | libc::O_NONBLOCK,
        )
    })?;
    validate(
        &file,
        true,
        private,
        &format!("directory component {name:?}; private={private}"),
    )?;
    Ok(file)
}
fn regular(path: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    validate(
        &file,
        false,
        true,
        &format!("private regular file {}", path.display()),
    )?;
    Ok(file)
}
fn read_small(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let file = regular(path)?;
    if file.metadata()?.len() > limit {
        return Err("Synthetic fixture file exceeds its limit".into());
    }
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err("Synthetic fixture file exceeds its limit".into());
    }
    Ok(bytes)
}
impl DisposableRoot {
    fn admit(path: &Path) -> Result<Self> {
        lexical_absolute(path)?;
        // SAFETY: fixed absolute root, checked below before walking children.
        let mut parent = checked(unsafe {
            libc::open(
                c"/".as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
            )
        })?;
        validate(&parent, true, false, "filesystem root /")?;
        let parts: Vec<_> = path
            .components()
            .filter_map(|part| match part {
                Component::Normal(name) => Some(name),
                _ => None,
            })
            .collect();
        for (index, part) in parts.iter().enumerate() {
            let leaf = index + 1 == parts.len();
            parent = directory_at(&parent, part, leaf, leaf)?;
        }
        if path.canonicalize()? != path {
            return Err("Synthetic root is not canonical".into());
        }
        let by_path = fs::symlink_metadata(path)?;
        let by_fd = parent.metadata()?;
        if by_path.dev() != by_fd.dev() || by_path.ino() != by_fd.ino() {
            return Err("Synthetic root changed during admission".into());
        }
        let marker = Marker {
            schema: 2,
            fixture: "bello-sidebar-search-synthetic-only".into(),
            root: path.to_owned(),
            uid: uid(),
        };
        let marker_path = path.join(MARKER);
        let fresh = fs::read_dir(path)?.next().is_none();
        if fresh {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&marker_path)?;
            file.write_all(&serde_json::to_vec(&marker)?)?;
            file.sync_all()?;
            parent.sync_all()?;
        } else if !marker_path.try_exists()? {
            return Err("Refusing nonempty unmarked synthetic root".into());
        }
        let found: Marker = serde_json::from_slice(&read_small(&marker_path, 4096)?)
            .map_err(|_| "Invalid synthetic fixture marker")?;
        if found != marker {
            return Err("Synthetic root marker/schema/owner does not match".into());
        }
        let lease = regular(&marker_path)?;
        lease
            .try_lock()
            .map_err(|_| "Synthetic root is already in use")?;
        Ok(Self {
            path: path.to_owned(),
            _directory: parent,
            _lease: lease,
            fresh,
        })
    }
    fn child_directory(&self, name: &str) -> Result<()> {
        directory_at(&self._directory, std::ffi::OsStr::new(name), true, true)?;
        Ok(())
    }
    /// Validate every existing name before any catalog or session open. No
    /// recursive symlink traversal, arbitrary files, or foreign cache namespaces.
    fn validate_tree(&self, namespace: Option<&str>) -> Result<()> {
        Self::walk(&self.path, Path::new(""), namespace)
    }
    fn walk(directory: &Path, relative: &Path, namespace: Option<&str>) -> Result<()> {
        let file = File::open(directory)?;
        validate(
            &file,
            true,
            true,
            &format!("private tree directory {}", directory.display()),
        )?;
        for item in fs::read_dir(directory)? {
            let item = item?;
            let name = item.file_name();
            let name = name.to_str().ok_or("Non-UTF8 synthetic fixture filename")?;
            let path = relative.join(name);
            let info = fs::symlink_metadata(item.path())?;
            if info.file_type().is_symlink() {
                return Err("Synthetic fixture symlink refused".into());
            }
            let allowed = allowed_path(&path, info.is_dir(), namespace);
            if !allowed {
                return Err("Unknown or escaped synthetic fixture path".into());
            }
            if info.is_dir() {
                Self::walk(&item.path(), &path, namespace)?;
            } else {
                regular(&item.path())?;
            }
        }
        Ok(())
    }
}
fn allowed_path(path: &Path, directory: bool, namespace: Option<&str>) -> bool {
    let Some(path) = path.to_str() else {
        return false;
    };
    if directory
        && matches!(
            path,
            "project"
                | "chats"
                | "cache"
                | "cache/BelloAgent-rust"
                | "cache/BelloAgent-rust/search-cache"
                | "cache/BelloAgent-rust/search-cache/v1"
        )
    {
        return true;
    }
    if !directory
        && matches!(
            path,
            MARKER | "catalog.json" | "catalog.workspace.lock" | "chats/layout.json"
        )
    {
        return true;
    }
    if let Some(name) = path.strip_prefix("chats/") {
        if directory || name.contains('/') {
            return false;
        }
        return IDS.iter().any(|id| {
            name == format!("{id}.json")
                || name == format!("{id}.lock")
                || name
                    .strip_prefix(&format!("{id}.json."))
                    .and_then(|suffix| suffix.strip_suffix(".stream.jsonl"))
                    .is_some_and(|generation| uuid::Uuid::parse_str(generation).is_ok())
        });
    }
    if let Some(suffix) = path.strip_prefix("cache/BelloAgent-rust/search-cache/v1/") {
        let (actual, file) = suffix
            .split_once('/')
            .map_or((suffix, None), |(ns, file)| (ns, Some(file)));
        if actual.len() != 64
            || !actual
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || namespace.is_some_and(|expected| actual != expected)
        {
            return false;
        }
        return match file {
            None => directory,
            Some(file) => {
                !directory
                    && matches!(
                        file,
                        "owner.lock"
                            | "cache.sqlite3"
                            | "cache.sqlite3-wal"
                            | "cache.sqlite3-shm"
                            | "cache.sqlite3-journal"
                    )
            }
        };
    }
    false
}
fn validate_catalog(root: &Path) -> Result<WorkspaceSnapshot> {
    let catalog: WorkspaceSnapshot =
        serde_json::from_slice(&read_small(&root.join("catalog.json"), MAX_FILE)?)
            .map_err(|_| "Invalid synthetic fixture catalog")?;
    if catalog.project != root.join("project")
        || catalog.project_id.is_some()
        || catalog.chats.len() != IDS.len()
    {
        return Err("Synthetic catalog project or membership differs from fixture".into());
    }
    // Existing fixture ownership files must be present before Core may open them.
    regular(&root.join("catalog.workspace.lock"))?;
    let mut found = std::collections::BTreeSet::new();
    for record in &catalog.chats {
        if !IDS.contains(&record.id.as_str())
            || !found.insert(&record.id)
            || record.snapshot != root.join("chats").join(format!("{}.json", record.id))
            || record.connection_id.is_some()
        {
            return Err(
                "Synthetic catalog contains an external path, identity, or connection".into(),
            );
        }
        regular(&record.snapshot.with_extension("lock"))?;
        let checkpoint: serde_json::Value =
            serde_json::from_slice(&read_small(&record.snapshot, MAX_FILE)?)
                .map_err(|_| "Invalid synthetic fixture checkpoint")?;
        if checkpoint["id"].as_str() != Some(record.id.as_str()) {
            return Err("Synthetic checkpoint identity differs from catalog".into());
        }
    }
    Ok(catalog)
}
fn message(id: &str, role: &str, text: &str) -> Message {
    Message {
        task_root_id: None,
        user_content: None,
        id: id.into(),
        role: role.into(),
        text: text.into(),
        reasoning: String::new(),
        replay_eligible: true,
        state: "completed".into(),
        usage: serde_json::Value::Null,
        model: None,
        tool_record: None,
        compaction: None,
    }
}
fn tool_messages() -> Vec<Message> {
    use bello_agent_core::{
        provider::ToolCall,
        tool_history::{
            AssistantRecord, Completion, ReplayBinding, ResultRecord, ToolOutcome, ToolRecord,
        },
    };
    let mut assistant = message("synthetic-tool-assistant", "assistant", "");
    assistant.tool_record = Some(ToolRecord::Assistant(AssistantRecord {
        tool_batch_timing: None,
        completion: Completion::Complete,
        calls: vec![
            ToolCall {
                id: "synthetic-call-one".into(),
                name: "ls".into(),
                arguments: serde_json::json!({"path":"inputamberneedle e\u{301}"}),
            },
            ToolCall {
                id: "synthetic-call-two".into(),
                name: "ls".into(),
                arguments: serde_json::json!({"path":format!("{} inputtailneedle", "synthetic-padding ".repeat(5000))}),
            },
        ],
        binding: ReplayBinding {
            profile_id: "synthetic-history-only".into(),
            api: "openai-responses".into(),
            provider: "litellm".into(),
            model: "synthetic-history-only".into(),
            endpoint_sha256: "0".repeat(64),
        },
        provider_items: vec![],
    }));
    let mut rows = vec![assistant];
    for (index, (call, text)) in [
        (
            "synthetic-call-one",
            "outputcobaltneedle first synthetic output e\u{301}",
        ),
        (
            "synthetic-call-two",
            "outputcoralneedle second synthetic output\nAnother harmless line.",
        ),
    ]
    .into_iter()
    .enumerate()
    {
        let mut result = message(
            &format!("synthetic-tool-output-{index}"),
            "toolResult",
            text,
        );
        result.tool_record = Some(ToolRecord::Result(ResultRecord {
            duration_us: None,
            assistant_id: "synthetic-tool-assistant".into(),
            call_id: call.into(),
            is_error: false,
            outcome: ToolOutcome::Completed,
            content: None,
        }));
        rows.push(result);
    }
    rows
}
/// Enough actual retained rows to require distant outer-list navigation. Repeated
/// matches have distinct identities and labels; no source/provider work is faked.
fn distant_messages() -> Vec<Message> {
    (0..136)
        .map(|index| {
            let detail = match index {
                12 => "distantamberneedle alpha, the first retained match",
                64 => "distantamberneedle beta, the middle retained match",
                116 => "distantamberneedle gamma, the last retained match",
                _ => "harmless synthetic history without the target phrase",
            };
            message(
                &format!("synthetic-history-{index:03}"),
                if index % 2 == 0 { "user" } else { "assistant" },
                &format!("Synthetic distant row {index:03}: {detail}.\nThis numbered fixture row is retained only for scroll and reveal validation."),
            )
        })
        .collect()
}
fn seed(root: &DisposableRoot) -> Result<()> {
    for name in ["project", "chats", "cache"] {
        root.child_directory(name)?;
    }
    let mut owner =
        WorkspaceStore::open(root.path.join("catalog.json"), root.path.join("project"))?;
    for (index, id) in IDS.iter().enumerate() {
        let path = owner.chat_path(id)?;
        // Only fresh roots reach seed; neither existing sessions nor unrelated
        // files are overwritten to reset a validation run.
        if path.try_exists()? {
            return Err("Synthetic seed would overwrite existing data".into());
        }
        let mut store = SessionStore::pending_with_id(id)?;
        store.persist_to(&path)?;
        store.transact(|session| {
            session.title = TITLES[index].into();
            session.messages = match index {
                0 => vec![message(
                    "synthetic-loaded-user",
                    "user",
                    "loaded violetneedle synthetic selected transcript",
                )],
                1 => vec![message(
                    "synthetic-unopened-user",
                    "user",
                    "unopened violetneedle synthetic saved transcript",
                )],
                2 => vec![message(
                    "synthetic-title-only-user",
                    "user",
                    "This synthetic body contains only unrelated words.",
                )],
                3 => tool_messages(),
                _ => distant_messages(),
            };
            Ok(())
        })?;
        let mut record = ChatRecord::new((*id).into(), TITLES[index].into(), path);
        record.sidebar_order = Some((IDS.len() - index) as u64);
        owner.register(record, DraftRecord::default())?;
    }
    owner.select(IDS[0], 1)?;
    Ok(())
}
fn prepare(path: &Path) -> Result<Prepared> {
    let root = DisposableRoot::admit(path)?;
    root.validate_tree(None)?;
    if root.fresh {
        seed(&root)?;
    }
    root.validate_tree(None)?;
    let catalog = validate_catalog(&root.path)?;
    let workspace = Arc::new(Mutex::new(WorkspaceStore::open(
        root.path.join("catalog.json"),
        root.path.join("project"),
    )?));
    let membership = WorkspaceStore::search_membership_snapshot(&workspace)
        .map_err(|_| "Synthetic membership unavailable")?;
    let binding = CacheBinding::from_membership(membership.stamp())?;
    root.validate_tree(Some(&binding.namespace()))?;
    let cache = PrivateCache::open_synthetic_fixture(binding.clone(), &root.path.join("cache"))?;
    root.validate_tree(Some(&binding.namespace()))?;
    let selected = catalog.selected.as_deref().unwrap_or(IDS[0]);
    let record = catalog
        .chats
        .iter()
        .find(|chat| chat.id == selected)
        .ok_or("Synthetic selection is not a fixture member")?
        .clone();
    let store = SessionStore::open_existing_with_id(&record.snapshot, &record.id)?;
    let draft = catalog.drafts.get(&record.id).cloned().unwrap_or_default();
    let owner = Arc::downgrade(&workspace);
    let launch = LaunchState {
        controller: Controller::new(store, None)?,
        project: root.path.join("project"),
        workspace,
        record,
        draft,
        pending: false,
    };
    Ok(Prepared {
        _root: root,
        launch,
        cache: PreparedCache {
            workspace: owner,
            binding,
            cache,
        },
    })
}
pub(crate) fn run(path: PathBuf) -> Result<()> {
    // This is an exact opt-in process before GPUI/workers exist. Keep subsequent
    // baseline layout files private too; never relax an existing file's mode.
    // SAFETY: process startup has not created application worker threads.
    unsafe {
        libc::umask(0o077);
    }
    // A fixture never follows the ordinary BELLO_PERF_LOG path override.
    let _ = crate::PERF.set(None);
    let Prepared {
        _root,
        launch,
        cache,
    } = prepare(&path)?;
    Application::new()
        .with_assets(assets::Assets)
        .run(move |cx: &mut App| {
            bello_workbench_ui::init(cx);
            cx.set_global(crate::project_manager_controller::LaunchProjectAuthority {
                authority: Arc::new(bello_agent_core::project_authority::ProjectAuthority::new()),
                mode: AuthorityMode::Unavailable,
            });
            let window = WorkspaceLifetime::launch_with_title(
                launch,
                "Bello Agent — SYNTHETIC SIDEBAR VALIDATION — NO PROVIDER",
                cx,
            )
            .expect("Could not create synthetic validation window");
            window
                .update(cx, |view, _, cx| {
                    assert!(
                        view.install_synthetic_sidebar_cache(cache, cx),
                        "Synthetic cache owner differs from launch workspace"
                    );
                })
                .expect("Could not install synthetic sidebar cache");
            cx.on_window_closed(|cx| {
                if cx.windows().is_empty() {
                    cx.spawn(async move |cx| {
                        let _ = cx.update(|cx| {
                            if cx.windows().is_empty() {
                                cx.quit();
                            }
                        });
                    })
                    .detach();
                }
            })
            .detach();
            cx.activate(true);
        });
    drop(_root);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::exclude_acl;
    use super::{
        DisposableRoot, IDS, MARKER, Marker, Prepared, allowed_path, owned_mode, prepare,
        requested, uid, validate_catalog,
    };
    use std::{
        ffi::OsString,
        fs,
        os::unix::fs::{PermissionsExt, symlink},
        path::Path,
    };
    fn empty() -> tempfile::TempDir {
        tempfile::Builder::new()
            .prefix("synthetic-sidebar-test-")
            .permissions(fs::Permissions::from_mode(0o700))
            .tempdir_in(std::env::current_dir().unwrap())
            .unwrap()
    }
    #[test]
    fn acl_probe_retries_only_interruption_with_a_fixed_bound() {
        let mut calls = 0;
        exclude_acl("injected directory", "access", || {
            calls += 1;
            (
                -1,
                Some(if calls < 3 {
                    libc::EINTR
                } else {
                    libc::ENODATA
                }),
            )
        })
        .unwrap();
        assert_eq!(calls, 3);
        let mut calls = 0;
        let error = exclude_acl("injected directory", "access", || {
            calls += 1;
            (-1, Some(libc::EINTR))
        })
        .unwrap_err()
        .to_string();
        assert_eq!(calls, 3);
        assert!(error.contains("role=injected directory"));
        assert!(error.contains("attribute=access"));
        assert!(error.contains("result=-1"));
        assert!(error.contains(&format!("errno=Some({})", libc::EINTR)));
        assert!(error.contains("attempts=3"));
    }
    #[test]
    fn acl_probe_never_accepts_real_acl_or_unexpected_failure() {
        for result in [
            (0, None),
            (28, None),
            (0, Some(libc::EINTR)),
            (-1, Some(libc::EIO)),
            (-1, Some(libc::EACCES)),
            (-1, None),
        ] {
            let mut calls = 0;
            assert!(
                exclude_acl("injected file", "default", || {
                    calls += 1;
                    result
                })
                .is_err()
            );
            assert_eq!(calls, 1);
        }
        for errno in [libc::ENODATA, libc::ENOTSUP] {
            let mut calls = 0;
            exclude_acl("injected file", "default", || {
                calls += 1;
                (-1, Some(errno))
            })
            .unwrap();
            assert_eq!(calls, 1);
        }
        let mut calls = 0;
        assert!(
            exclude_acl("injected file", "default", || {
                calls += 1;
                if calls == 1 {
                    (-1, Some(libc::EINTR))
                } else {
                    (28, None)
                }
            })
            .is_err()
        );
        assert_eq!(calls, 2);
    }
    fn args(args: &[&str]) -> Vec<OsString> {
        args.iter().map(OsString::from).collect()
    }
    #[test]
    fn distant_history_has_stable_unique_rows_and_distinguishable_matches() {
        let rows = super::distant_messages();
        assert_eq!(rows.len(), 136);
        let ids = rows
            .iter()
            .map(|row| &row.id)
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(ids.len(), rows.len());
        let matches = rows
            .iter()
            .enumerate()
            .filter(|(_, row)| row.text.contains("distantamberneedle"))
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        assert_eq!(matches, [12, 64, 116]);
        for (index, label) in [(12, "alpha"), (64, "beta"), (116, "gamma")] {
            assert!(rows[index].text.contains(&format!("row {index:03}")));
            assert!(rows[index].text.contains(label));
        }
        let repeated = super::distant_messages();
        for (before, after) in rows.iter().zip(&repeated) {
            assert_eq!(before.id, after.id);
            assert_eq!(before.text, after.text);
            assert!(before.tool_record.is_none());
        }
    }
    #[test]
    fn prior_version_marker_is_refused_without_mutating_it() {
        let dir = empty();
        let old = dir.path().join(".bello-synthetic-sidebar-v1.json");
        fs::write(&old, b"preserved version-one synthetic evidence").unwrap();
        fs::set_permissions(&old, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(DisposableRoot::admit(dir.path()).is_err());
        assert_eq!(
            fs::read(&old).unwrap(),
            b"preserved version-one synthetic evidence"
        );
        assert!(!dir.path().join(MARKER).exists());
    }
    #[test]
    fn exact_arguments_reject_mixing_and_escape_before_any_io() {
        assert!(requested(&args(&["--help"])).unwrap().is_none());
        assert_eq!(
            requested(&args(&["--synthetic-sidebar-search-fixture", "/safe/root"]))
                .unwrap()
                .unwrap(),
            Path::new("/safe/root")
        );
        for case in [
            vec!["--synthetic-sidebar-search-fixture"],
            vec!["--synthetic-sidebar-search-fixture", "relative"],
            vec!["--synthetic-sidebar-search-fixture", "/safe/../foreign"],
            vec!["--synthetic-sidebar-search-fixture", "/safe/./root"],
            vec!["--synthetic-sidebar-search-fixture", "/"],
            vec![
                "--synthetic-sidebar-search-fixture",
                "/safe/root",
                "--profile",
                "/foreign",
            ],
            vec![
                "--credential-stdin",
                "--synthetic-sidebar-search-fixture",
                "/safe/root",
            ],
            vec!["--help", "--synthetic-sidebar-search-fixture", "/safe/root"],
            vec!["--synthetic-sidebar-search-fixture=/safe/root"],
        ] {
            assert!(requested(&args(&case)).is_err(), "{case:?}");
        }
    }
    #[test]
    fn nonempty_unmarked_root_is_untouched() {
        let dir = empty();
        fs::write(dir.path().join("unrelated"), "preserve me").unwrap();
        assert!(DisposableRoot::admit(dir.path()).is_err());
        assert_eq!(
            fs::read_to_string(dir.path().join("unrelated")).unwrap(),
            "preserve me"
        );
        assert!(!dir.path().join(MARKER).exists());
    }
    #[test]
    fn root_marker_binds_version_owner_and_canonical_root() {
        let dir = empty();
        drop(DisposableRoot::admit(dir.path()).unwrap());
        let path = dir.path().join(MARKER);
        let original = fs::read(&path).unwrap();
        for variant in 0..4 {
            let mut marker: Marker = serde_json::from_slice(&original).unwrap();
            match variant {
                0 => marker.schema += 1,
                1 => marker.uid += 1,
                2 => marker.root = "/foreign".into(),
                _ => marker.fixture = "ordinary".into(),
            }
            fs::write(&path, serde_json::to_vec(&marker).unwrap()).unwrap();
            assert!(DisposableRoot::admit(dir.path()).is_err());
        }
    }
    #[test]
    fn private_root_modes_ancestor_symlink_and_foreign_owner_fail_closed() {
        let dir = empty();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o755)).unwrap();
        assert!(DisposableRoot::admit(dir.path()).is_err());
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        assert!(!owned_mode(
            &fs::metadata(dir.path()).unwrap(),
            true,
            true,
            uid() + 1
        ));
        let parent = empty();
        let link = parent.path().join("link");
        symlink(dir.path(), &link).unwrap();
        assert!(DisposableRoot::admit(&link).is_err());
        fs::set_permissions(parent.path(), fs::Permissions::from_mode(0o777)).unwrap();
        assert!(DisposableRoot::admit(&parent.path().join("child")).is_err());
        assert!(!parent.path().join("child").exists());
    }
    #[test]
    fn marker_symlink_hardlink_and_parallel_launch_are_rejected() {
        let dir = empty();
        let root = DisposableRoot::admit(dir.path()).unwrap();
        assert!(DisposableRoot::admit(dir.path()).is_err());
        drop(root);
        let other = empty();
        fs::hard_link(dir.path().join(MARKER), other.path().join("marker")).unwrap();
        assert!(DisposableRoot::admit(dir.path()).is_err());
        fs::remove_file(other.path().join("marker")).unwrap();
        fs::rename(dir.path().join(MARKER), other.path().join("marker")).unwrap();
        symlink(other.path().join("marker"), dir.path().join(MARKER)).unwrap();
        assert!(DisposableRoot::admit(dir.path()).is_err());
    }
    #[test]
    fn fresh_restart_has_real_cache_fixed_membership_and_no_provider() {
        let dir = empty();
        let Prepared {
            launch,
            cache,
            _root,
        } = prepare(dir.path()).unwrap();
        assert!(!launch.controller.configured());
        let (binding, cache) = cache.into_parts();
        assert!(cache.readiness().is_ready());
        let namespace = binding.namespace();
        let session = launch.controller.snapshot();
        assert_eq!(session.id, IDS[0]);
        drop(cache);
        drop(launch);
        drop(_root);
        let reopened = prepare(dir.path()).unwrap();
        assert!(!reopened.launch.controller.configured());
        assert_eq!(reopened.cache.binding.namespace(), namespace);
        assert_eq!(validate_catalog(dir.path()).unwrap().chats.len(), 5);
    }
    #[test]
    fn catalog_external_source_and_connection_are_rejected_before_open() {
        let dir = empty();
        drop(prepare(dir.path()).unwrap());
        let path = dir.path().join("catalog.json");
        let original = fs::read(&path).unwrap();
        for variant in 0..3 {
            let mut value: serde_json::Value = serde_json::from_slice(&original).unwrap();
            match variant {
                0 => value["chats"][0]["snapshot"] = "/foreign/session.json".into(),
                1 => value["project"] = "/foreign".into(),
                _ => {
                    value["chats"][0]["connection_id"] =
                        "11111111-1111-4111-8111-111111111111".into()
                }
            }
            fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
            let before = fs::read(&path).unwrap();
            assert!(prepare(dir.path()).is_err());
            assert_eq!(fs::read(&path).unwrap(), before);
        }
    }
    #[test]
    fn source_journal_and_cache_links_are_rejected() {
        for kind in ["source", "journal", "cache"] {
            let dir = empty();
            drop(prepare(dir.path()).unwrap());
            let foreign = empty();
            let target = match kind {
                "source" => dir.path().join(format!("chats/{}.json", IDS[1])),
                "journal" => dir.path().join(format!(
                    "chats/{}.json.11111111-1111-4111-8111-111111111111.stream.jsonl",
                    IDS[1]
                )),
                _ => dir.path().join("cache/BelloAgent-rust"),
            };
            if target.is_dir() {
                fs::remove_dir_all(&target).unwrap();
            } else if target.exists() {
                fs::remove_file(&target).unwrap();
            }
            symlink(foreign.path(), &target).unwrap();
            assert!(prepare(dir.path()).is_err(), "{kind}");
        }
    }
    #[test]
    fn source_hardlink_unknown_sibling_and_cache_namespace_fail_closed() {
        let dir = empty();
        drop(prepare(dir.path()).unwrap());
        let foreign = empty();
        let source = dir.path().join(format!("chats/{}.json", IDS[1]));
        fs::hard_link(&source, foreign.path().join("copy")).unwrap();
        assert!(prepare(dir.path()).is_err());
        fs::remove_file(foreign.path().join("copy")).unwrap();
        fs::write(dir.path().join("unrelated"), b"preserve").unwrap();
        assert!(prepare(dir.path()).is_err());
        assert!(!allowed_path(
            Path::new(
                "cache/BelloAgent-rust/search-cache/v1/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            ),
            true,
            Some(&"b".repeat(64))
        ));
        assert!(!allowed_path(Path::new("project/outside"), false, None));
        assert!(!allowed_path(Path::new("chats/unknown.json"), false, None));
    }
}
