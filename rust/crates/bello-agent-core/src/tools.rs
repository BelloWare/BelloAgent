//! Source-backed native-tool implementation. Only `ls` is ported.
//!
//! This module never independently offers tools to a provider. The Controller's
//! explicit TrustedReadOnlyTools option can invoke it; desktop constructors keep
//! tools disabled. A caller supplies an explicit capability allowlist and path context. As in Swift, offering a capability is
//! an execution decision: `invoke` does not insert a per-call approval gate.
//!
//! Sources: PiAgentCore/{Tools,SessionTools,Support,Resources,
//! BlockingWorkExecutor,PiProviderRules}.swift. Workspace roots are resolution
//! context, NOT a sandbox: absolute, parent, tilde and symlink paths may leave
//! them. The injected home directory permits isolated fixtures without reading
//! the process's home configuration. Named-user `~user` lookup is not ported.
//!
//! `invoke` matches NativeTools' native validation; `invoke_prepared` additionally
//! applies SessionTools' schema preparation, for the ls schema only. The general
//! JSON Schema coercer and source tool cards remain unported. The opt-in core
//! Controller retains text above 64 KiB in private files (32 KiB preview,
//! 16 MiB maximum), checkpoints call/result history, and continues the tool loop.
//! Native ls itself has an entry bound, not a byte bound, and no `stats` field.

use crate::provider::ToolCall;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeSet, VecDeque},
    fs,
    path::{Component, Path, PathBuf},
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
};
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;
use unicode_normalization::UnicodeNormalization;

pub type ToolResult<T> = std::result::Result<T, ToolError>;

#[derive(Debug, thiserror::Error)]
pub enum ToolError {
    #[error("{message}")]
    Failure { code: &'static str, message: String },
    #[error("Stopped")]
    Cancelled,
    // Foundation also throws its native filesystem error here. Its localized
    // wording is platform-specific and is not fabricated on another platform.
    #[error("{0}")]
    Io(#[from] std::io::Error),
}

impl ToolError {
    pub fn code(&self) -> Option<&'static str> {
        match self {
            Self::Failure { code, .. } => Some(code),
            _ => None,
        }
    }
    fn failure(code: &'static str, message: impl Into<String>) -> Self {
        Self::Failure {
            code,
            message: message.into(),
        }
    }
}

fn check_cancelled(token: &CancellationToken) -> ToolResult<()> {
    if token.is_cancelled() {
        Err(ToolError::Cancelled)
    } else {
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Capability {
    Ls,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    pub schema: Value,
}

fn ls_definition() -> ToolDefinition {
    ToolDefinition {
        name: "ls".into(),
        description: "List a directory, including hidden entries. Results are sorted and bounded."
            .into(),
        schema: json!({
            "type": "object",
            "properties": {"path": {"type": "string"}, "limit": {"type": "integer", "minimum": 1}},
            "required": [],
            "additionalProperties": false
        }),
    }
}

pub fn result_text(text: impl Into<String>, is_error: bool) -> Value {
    json!({"content": [{"type": "text", "text": text.into()}], "isError": is_error})
}

#[derive(Clone)]
pub struct NativeTools {
    paths: FileToolContext,
    capabilities: BTreeSet<Capability>,
    workers: BlockingWorkExecutor,
    #[cfg(test)]
    before_read: Option<Arc<dyn Fn() + Send + Sync>>,
}

impl NativeTools {
    /// Explicit absolute paths stand in for the Swift host's already-created
    /// file URLs. Construction performs no filesystem or environment discovery.
    pub fn new(
        cwd: PathBuf,
        additional_roots: impl IntoIterator<Item = PathBuf>,
        home: PathBuf,
        capabilities: impl IntoIterator<Item = Capability>,
    ) -> ToolResult<Self> {
        let mut roots = vec![cwd.clone()];
        for root in additional_roots {
            if !roots.contains(&root) {
                roots.push(root);
            }
        }
        if !home.is_absolute() || roots.iter().any(|root| !root.is_absolute()) {
            return Err(ToolError::failure(
                "invalid_params",
                "Tool context paths must be absolute",
            ));
        }
        Ok(Self {
            paths: FileToolContext { cwd, roots, home },
            capabilities: capabilities.into_iter().collect(),
            workers: BlockingWorkExecutor::shared(),
            #[cfg(test)]
            before_read: None,
        })
    }

    /// Isolated executor injection for deterministic synthetic fixtures.
    pub fn with_executor(mut self, workers: BlockingWorkExecutor) -> Self {
        self.workers = workers;
        self
    }

    #[cfg(test)]
    pub(crate) fn before_read(mut self, callback: Arc<dyn Fn() + Send + Sync>) -> Self {
        self.before_read = Some(callback);
        self
    }

    pub fn definitions(&self) -> Vec<ToolDefinition> {
        if self.capabilities.contains(&Capability::Ls) {
            vec![ls_definition()]
        } else {
            vec![]
        }
    }

    pub fn capability_ids(&self) -> Vec<&'static str> {
        if self.capabilities.contains(&Capability::Ls) {
            vec!["ls"]
        } else {
            vec![]
        }
    }

    /// SessionTools.piPrepared's exact applicable subset. Unknown/unoffered
    /// tools and non-object arguments pass through for native rejection.
    /// The original call is never mutated.
    pub fn prepare_call(&self, call: &ToolCall) -> ToolCall {
        let mut prepared = call.clone();
        if call.name != "ls" || !self.capabilities.contains(&Capability::Ls) {
            return prepared;
        }
        let Some(fields) = prepared.arguments.as_object_mut() else {
            return prepared;
        };
        // Both properties are optional and neither schema accepts null.
        for key in ["path", "limit"] {
            if fields.get(key).is_some_and(Value::is_null) {
                fields.remove(key);
            }
        }
        if let Some(value) = fields.get_mut("path") {
            match value {
                Value::Bool(flag) => *value = Value::String(flag.to_string()),
                Value::Number(number) => {
                    if let Some(number) = number.as_f64() {
                        *value = Value::String(js_string(number));
                    }
                }
                _ => {}
            }
        }
        if let Some(value) = fields.get_mut("limit") {
            let number = match value {
                Value::Bool(flag) => Some(if *flag { 1.0 } else { 0.0 }),
                Value::String(text) if !text.trim_matches(js_space).is_empty() => js_number(text),
                _ => None,
            };
            if let Some(number) = number.filter(|n| n.is_finite() && n.fract() == 0.0) {
                *value = if number >= i64::MIN as f64 && number < i64::MAX as f64 {
                    json!(number as i64)
                } else {
                    json!(number)
                };
            }
        }
        prepared
    }

    pub async fn invoke_prepared(
        &self,
        call: &ToolCall,
        cancellation: CancellationToken,
    ) -> ToolResult<Value> {
        self.invoke(&self.prepare_call(call), cancellation).await
    }

    /// NativeTools.invoke's key validation, then blocking-worker dispatch.
    /// This deliberately does not enforce the schema's minimum=1: source ls
    /// accepts zero and produces a leading newline before its truncation note.
    pub async fn invoke(
        &self,
        call: &ToolCall,
        cancellation: CancellationToken,
    ) -> ToolResult<Value> {
        check_cancelled(&cancellation)?;
        if call.name != "ls" || !self.capabilities.contains(&Capability::Ls) {
            return Err(ToolError::failure(
                "tool_unavailable",
                format!("Tool {} not found", call.name),
            ));
        }
        let fields = call.arguments.as_object().ok_or_else(|| {
            ToolError::failure("tool_arguments", "Tool arguments must be an object")
        })?;
        if fields.keys().any(|key| key != "path" && key != "limit") {
            return Err(ToolError::failure(
                "tool_arguments",
                "Missing or unsupported tool arguments",
            ));
        }
        let paths = self.paths.clone();
        let arguments = call.arguments.clone();
        #[cfg(test)]
        let before_read = self.before_read.clone();
        self.workers
            .run(cancellation, move |cancel| {
                #[cfg(test)]
                if let Some(callback) = before_read {
                    callback();
                }
                paths.ls(&arguments, &cancel)
            })
            .await
    }
}

#[derive(Clone)]
struct FileToolContext {
    cwd: PathBuf,
    roots: Vec<PathBuf>,
    home: PathBuf,
}

impl FileToolContext {
    fn path(&self, value: &Value) -> ToolResult<PathBuf> {
        if value.is_null() {
            return Ok(self.cwd.clone());
        }
        let text = value
            .as_str()
            .filter(|text| !text.is_empty() && text.len() <= 4096)
            .ok_or_else(|| ToolError::failure("invalid_params", "Invalid path"))?;
        if text == "~" {
            return Ok(canonical(&self.home));
        }
        if let Some(suffix) = text.strip_prefix("~/") {
            // Repeated separators after '~' remain relative to the home;
            // PathBuf::join would otherwise treat a second '/' as absolute.
            return Ok(canonical(&self.home.join(suffix.trim_start_matches('/'))));
        }
        if text.starts_with('~') {
            return Err(ToolError::failure(
                "tool_unavailable",
                "Named-user tilde expansion is not ported",
            ));
        }
        if text.starts_with('/') {
            return Ok(canonical(Path::new(text)));
        }
        let primary = canonical(&self.cwd.join(text));
        if self.roots.len() <= 1 || primary.exists() {
            return Ok(primary);
        }
        let elsewhere: Vec<_> = self
            .roots
            .iter()
            .skip(1)
            .map(|root| canonical(&root.join(text)))
            .filter(|path| path.exists())
            .collect();
        Ok(if elsewhere.len() == 1 {
            elsewhere[0].clone()
        } else {
            primary
        })
    }

    fn ls(&self, arguments: &Value, cancellation: &CancellationToken) -> ToolResult<Value> {
        check_cancelled(cancellation)?;
        let directory = self.path(&arguments["path"])?;
        let limit = bounded_int(&arguments["limit"], 200, 2000)?;
        // Source eagerly enumerates and sorts ALL entries before prefix(limit).
        // Do not introduce an early scan cap or exclude hidden files.
        let mut entries = fs::read_dir(directory)?.collect::<std::io::Result<Vec<_>>>()?;
        // Swift String comparison orders normalized Unicode scalars. Keep the
        // original spelling in the result (including decomposed filenames).
        entries.sort_by_cached_key(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .nfc()
                .collect::<String>()
        });
        let mut rows = Vec::with_capacity(entries.len().min(limit));
        for entry in entries.iter().take(limit) {
            check_cancelled(cancellation)?;
            let mut name = entry.file_name().to_string_lossy().into_owned();
            // Use entry metadata (lstat), not path.is_dir(): a directory symlink
            // is a symbolic-link entry. Traversing a symlink PATH still works.
            if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                name.push('/');
            }
            rows.push(name);
        }
        let mut text = rows.join("\n");
        if entries.len() > limit {
            text.push_str(&format!("\n[Truncated; {} entries]", entries.len()));
        }
        Ok(result_text(text, false))
    }
}

fn bounded_int(value: &Value, fallback: usize, maximum: usize) -> ToolResult<usize> {
    if value.is_null() {
        return Ok(fallback);
    }
    let number = value
        .as_f64()
        .filter(|n| n.is_finite() && n.fract() == 0.0 && *n >= 0.0 && *n <= maximum as f64)
        .ok_or_else(|| ToolError::failure("invalid_range", "Invalid numeric range"))?;
    Ok(number as usize)
}

/// Foundation's standardizedFileURL resolves `..` against the real parent,
/// consulting symbolic links. It is not a lexical path normalization. Preserve
/// missing suffixes while resolving existing links, including dangling links.
/// Platform-specific Foundation path aliases (e.g. /private on macOS) remain
/// OS validation work; they are not simulated on Linux.
fn canonical(path: &Path) -> PathBuf {
    resolve_components(path, &mut 0)
}

fn resolve_components(path: &Path, symlinks: &mut usize) -> PathBuf {
    let mut resolved = PathBuf::new();
    for component in path.components() {
        match component {
            Component::ParentDir => {
                resolved.pop();
            }
            Component::CurDir => {}
            Component::Normal(name) => {
                resolved.push(name);
                if *symlinks < 40
                    && let Ok(target) = fs::read_link(&resolved)
                {
                    *symlinks += 1;
                    resolved.pop();
                    resolved = resolve_components(&resolved.join(target), symlinks);
                }
            }
            other => resolved.push(other.as_os_str()),
        }
    }
    resolved
}

fn js_space(ch: char) -> bool {
    matches!(ch, '\u{9}'..='\u{d}' | '\u{20}' | '\u{a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}' | '\u{feff}')
}

fn js_number(text: &str) -> Option<f64> {
    let text = text.trim_matches(js_space);
    if text.is_empty() {
        return Some(0.0);
    }
    let bytes = text.as_bytes();
    if bytes.len() > 2 && bytes[0] == b'0' {
        let radix = match bytes[1] {
            b'x' | b'X' => Some(16),
            b'o' | b'O' => Some(8),
            b'b' | b'B' => Some(2),
            _ => None,
        };
        if let Some(radix) = radix {
            let mut number = 0.0;
            for ch in text[2..].chars() {
                if !ch.is_ascii() {
                    return None;
                }
                number = number * radix as f64 + ch.to_digit(radix)? as f64;
            }
            return Some(number);
        }
    }
    // JavaScript decimal literal, excluding Rust's accepted NaN/inf spellings.
    let mut i = usize::from(matches!(bytes.first(), Some(b'+' | b'-')));
    let start = i;
    while bytes.get(i).is_some_and(u8::is_ascii_digit) {
        i += 1;
    }
    let mut digits = i - start;
    if bytes.get(i) == Some(&b'.') {
        i += 1;
        let start = i;
        while bytes.get(i).is_some_and(u8::is_ascii_digit) {
            i += 1;
        }
        digits += i - start;
    }
    if digits == 0 {
        return None;
    }
    if matches!(bytes.get(i), Some(b'e' | b'E')) {
        i += 1;
        if matches!(bytes.get(i), Some(b'+' | b'-')) {
            i += 1;
        }
        let start = i;
        while bytes.get(i).is_some_and(u8::is_ascii_digit) {
            i += 1;
        }
        if i == start {
            return None;
        }
    }
    if i != bytes.len() {
        return None;
    }
    text.parse().ok()
}

fn js_string(number: f64) -> String {
    if number == 0.0 {
        return "0".into();
    }
    if number < 0.0 {
        return format!("-{}", js_string(-number));
    }
    // Source uses shortest round-trip digits, decimal notation for [1e-6,1e21),
    // and a signed exponent outside it.
    let raw = number.to_string();
    let (mantissa, exponent) = raw
        .split_once(['e', 'E'])
        .map_or((raw.as_str(), 0), |(a, b)| {
            (a, b.parse::<i32>().unwrap_or(0))
        });
    let mut point = mantissa.find('.').unwrap_or(mantissa.len()) as i32 + exponent;
    let mut digits: String = mantissa.chars().filter(|ch| *ch != '.').collect();
    let leading = digits.bytes().take_while(|ch| *ch == b'0').count();
    digits.drain(..leading);
    point -= leading as i32;
    while digits.ends_with('0') {
        digits.pop();
    }
    let count = digits.len() as i32;
    if count <= point && point <= 21 {
        return digits + &"0".repeat((point - count) as usize);
    }
    if 0 < point && point <= 21 {
        digits.insert(point as usize, '.');
        return digits;
    }
    if -6 < point && point <= 0 {
        return "0.".to_owned() + &"0".repeat((-point) as usize) + &digits;
    }
    let exponent = point - 1;
    if digits.len() > 1 {
        digits.insert(1, '.');
    }
    format!("{digits}e{exponent:+}")
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Occupancy {
    pub active: usize,
    pub waiting: usize,
}

/// Shared four-worker, 64-waiting FIFO executor. Running cancellation remains
/// cooperative: a blocked OS call retains its slot until it actually returns.
/// Dropping the future also cancels/removes waiting work. No Tokio cooperative
/// runtime thread performs the filesystem operation.
#[derive(Clone)]
pub struct BlockingWorkExecutor {
    inner: Arc<ExecutorInner>,
}

struct ExecutorInner {
    state: Mutex<ExecutorState>,
    maximum_workers: usize,
    maximum_waiting: usize,
    next_id: AtomicU64,
}

#[derive(Default)]
struct ExecutorState {
    active: usize,
    waiting: VecDeque<Job>,
}

struct Job {
    id: u64,
    cancellation: CancellationToken,
    complete: Box<dyn FnOnce(Option<ToolError>) + Send>,
}

impl BlockingWorkExecutor {
    pub fn shared() -> Self {
        static SHARED: OnceLock<BlockingWorkExecutor> = OnceLock::new();
        SHARED.get_or_init(Self::default).clone()
    }

    pub fn new(maximum_workers: usize, maximum_waiting: usize) -> Self {
        assert!(maximum_workers > 0);
        Self {
            inner: Arc::new(ExecutorInner {
                state: Mutex::new(ExecutorState::default()),
                maximum_workers,
                maximum_waiting,
                next_id: AtomicU64::new(1),
            }),
        }
    }

    pub fn limits(&self) -> (usize, usize) {
        (self.inner.maximum_workers, self.inner.maximum_waiting)
    }

    pub fn occupancy(&self) -> Occupancy {
        let state = self
            .inner
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        Occupancy {
            active: state.active,
            waiting: state.waiting.len(),
        }
    }

    pub async fn run<T, F>(&self, cancellation: CancellationToken, operation: F) -> ToolResult<T>
    where
        T: Send + 'static,
        F: FnOnce(CancellationToken) -> ToolResult<T> + Send + 'static,
    {
        let cancellation = cancellation.child_token();
        let id = self.inner.next_id.fetch_add(1, Ordering::Relaxed);
        let mut guard = CancelOnDrop {
            executor: self.clone(),
            id,
            cancellation: cancellation.clone(),
            armed: true,
        };
        let (sender, mut receiver) = oneshot::channel();
        let token = cancellation.clone();
        self.enqueue(Job {
            id,
            cancellation: cancellation.clone(),
            complete: Box::new(move |rejected| {
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    if let Some(error) = rejected {
                        return Err(error);
                    }
                    check_cancelled(&token)?;
                    let value = operation(token.clone())?;
                    check_cancelled(&token)?;
                    Ok(value)
                }))
                .unwrap_or_else(|_| Err(ToolError::failure("tool_worker", "File worker panicked")));
                let _ = sender.send(outcome);
            }),
        });
        let result = tokio::select! {
            biased;
            _ = cancellation.cancelled() => {
                self.cancel_waiting(id);
                // Do not release a running worker slot early, or report its
                // operation settled before an uninterruptible call returns.
                receiver.await
            }
            result = &mut receiver => result,
        };
        guard.armed = false;
        result.unwrap_or_else(|_| {
            Err(ToolError::failure(
                "tool_worker",
                "File worker stopped without a result",
            ))
        })
    }

    fn enqueue(&self, job: Job) {
        let mut state = self
            .inner
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if job.cancellation.is_cancelled() {
            drop(state);
            (job.complete)(Some(ToolError::Cancelled));
        } else if state.active < self.inner.maximum_workers {
            state.active += 1;
            drop(state);
            self.dispatch(job);
        } else if state.waiting.len() < self.inner.maximum_waiting {
            state.waiting.push_back(job);
        } else {
            drop(state);
            (job.complete)(Some(ToolError::failure(
                "tool_busy",
                "File workers and their waiting queue are full. Retry after an active read or search finishes.",
            )));
        }
    }

    fn cancel_waiting(&self, id: u64) {
        let mut state = self
            .inner
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let removed = state
            .waiting
            .iter()
            .position(|job| job.id == id)
            .and_then(|i| state.waiting.remove(i));
        drop(state);
        if let Some(job) = removed {
            (job.complete)(Some(ToolError::Cancelled));
        }
    }

    fn dispatch(&self, mut job: Job) {
        let executor = self.clone();
        let spawned = std::thread::Builder::new()
            .name("bello-file-worker".into())
            .spawn(move || {
                loop {
                    (job.complete)(None);
                    match executor.next() {
                        Some(next) => job = next,
                        None => break,
                    }
                }
            });
        if spawned.is_err() {
            // The failed spawn drops its job/sender. Its waiter receives a
            // worker error, and a surviving queue can still make progress.
            if let Some(next) = self.next() {
                self.dispatch(next);
            }
        }
    }

    fn next(&self) -> Option<Job> {
        let mut state = self
            .inner
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        match state.waiting.pop_front() {
            Some(job) => Some(job),
            None => {
                state.active -= 1;
                None
            }
        }
    }
}

impl Default for BlockingWorkExecutor {
    fn default() -> Self {
        Self::new(4, 64)
    }
}

struct CancelOnDrop {
    executor: BlockingWorkExecutor,
    id: u64,
    cancellation: CancellationToken,
    armed: bool,
}
impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        if self.armed {
            self.cancellation.cancel();
            self.executor.cancel_waiting(self.id);
        }
    }
}
