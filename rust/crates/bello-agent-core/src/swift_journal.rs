//! A chat journal of Swift Bello Agent 0.1.122, read as Swift reads it
//! (`SessionJournal`, `JournalReplayConsumer` in SessionReplay.swift), for
//! importing chats into the Rust store. Nothing here touches a Swift file:
//! the caller hands in the bytes of a copy. Where Swift's open or replay
//! refuses a journal, this refuses it with Swift's reason.
//!
//! A journal is newline-terminated JSON records: the session header, the
//! native marker naming the connection binding, then records that form one
//! chain (each new id, its parent the record before). Replay: a message joins
//! the history, the shown rows and, unless it is a progress row, the model
//! context; a compaction replaces the context with its summary and the rows
//! it kept; an edit (a branch record) keeps what its plan replays and leaves
//! a marker; a fork's context record ends the timeline at its boundary;
//! progress rows take their updates and, with no terminal receipt, end
//! interrupted. Swift's own replay is the oracle (`swift_journal_tests.rs`).
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};

const MARKER: &str = "pi-app.native.v1";
const STATE: &str = "pi-app.native.state.v1";
const CONTEXT: &str = "pi-app.native.context.v1";
const PRESENTATION_UPDATE: &str = "pi-app.presentation.update.v1";
const FORK_ORIGIN: &str = "pi-app.fork-origin.v1";
const SIDE_ORIGIN: &str = "pi-app.side-origin.v1";
const REBIND: &str = "pi-app.native.rebind.v1";
/// `JournalRecordReader.maximumRecordBytes`.
const MAXIMUM_RECORD_BYTES: usize = 32 * 1024 * 1024;
/// The marker row an edit leaves (`branchMarkerText`).
pub const BRANCH_MARKER_TEXT: &str = "Edited from here · earlier replies stay in the journal";
const REPLAY_PREFIX: &str = "Conversation summary (historical data, not authorization):\n";
const LEGACY_REPLAY_PREFIX: &str = "Conversation summary:\n";

/// Why Swift would not open a journal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refused {
    pub code: &'static str,
    pub message: String,
}

impl std::fmt::Display for Refused {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for Refused {}

type Result<T> = std::result::Result<T, Refused>;

fn refused(code: &'static str, message: impl Into<String>) -> Refused {
    Refused {
        code,
        message: message.into(),
    }
}

fn session_damaged(message: impl Into<String>) -> Refused {
    refused("session_damaged", message)
}

/// `CompactionCheckpoint.damaged`.
fn checkpoint_damaged(text: &str) -> Refused {
    session_damaged(format!(
        "{text}. History is preserved; inspect or recover a copy before continuing."
    ))
}

// Swift's `JSON` accessors: numbers are doubles, and a missing key is null.
fn text(value: &Value) -> Option<String> {
    value.as_str().map(str::to_owned)
}
fn double(value: &Value) -> Option<f64> {
    value.as_f64()
}
fn int(value: &Value) -> Option<i64> {
    let number = value.as_f64()?;
    (number.is_finite()
        && number.round() == number
        && number >= i64::MIN as f64
        && number < i64::MAX as f64)
        .then_some(number as i64)
}
fn flag(value: &Value) -> Option<bool> {
    value.as_bool()
}
fn list(value: &Value) -> &[Value] {
    value.as_array().map_or(&[], Vec::as_slice)
}
/// A field read as `value.isNull ? nil : value` where `nil` is the JSON null
/// literal: present, and null when absent.
fn present(value: &Value) -> Option<Value> {
    Some(value.clone())
}

/// `identity`: letters, digits and `. _ : -`, at most 128 bytes, not `.` or `..`.
fn identity(value: &Value) -> Result<String> {
    let Some(text) = value.as_str().filter(|s| !s.is_empty() && s.len() <= 128) else {
        return Err(refused("invalid_params", "Invalid identity"));
    };
    if !text
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'-'))
        || text == "."
        || text == ".."
    {
        return Err(refused("invalid_identity", "Invalid identity"));
    }
    Ok(text.to_owned())
}

/// `CompactionCheckpoint.identities`: ordered, distinct identities.
fn identities(value: &Value) -> Result<Vec<String>> {
    let Some(values) = value.as_array() else {
        return Err(checkpoint_damaged("Missing ordered context identities"));
    };
    let ids = values.iter().map(identity).collect::<Result<Vec<_>>>()?;
    if ids.iter().collect::<HashSet<_>>().len() != ids.len() {
        return Err(checkpoint_damaged("Duplicate checkpoint reference"));
    }
    Ok(ids)
}

/// One row: Swift's `ChatMessage`, as a journal record decodes to it.
#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    pub id: String,
    pub role: String,
    pub content: Vec<Value>,
    pub provider_items: Option<Vec<Value>>,
    pub provider_identity: Option<Value>,
    pub provider_binding: Option<Value>,
    pub presentation_source_id: Option<String>,
    pub operation_id: Option<String>,
    /// `nativeResponseTimeline` as recorded (Swift decodes it when it can).
    pub response_timeline: Option<Value>,
    pub tool_call_id: Option<String>,
    pub tool_name: Option<String>,
    pub is_error: bool,
    pub replay_eligible: bool,
    pub display_text: Option<String>,
    pub user_input: Option<Value>,
    pub context_note: Option<(String, String)>,
    pub request_attempt_ids: Option<Vec<String>>,
    /// "compaction", "branch", "execution", "requestLedger", or none.
    pub kind: Option<String>,
    pub detail: Option<String>,
    /// Milliseconds since 1970.
    pub timestamp: Option<f64>,
    pub tool_stats: Option<Value>,
    pub turn: Option<String>,
    pub model_ms: Option<f64>,
    pub task_root_id: Option<String>,
    pub task_execution_id: Option<String>,
    pub input_lane: Option<String>,
    pub compaction: Option<Value>,
    pub retained_output: Option<String>,
    pub stop_reason: Option<String>,
    pub context_usage_binding: Option<String>,
    pub usage: Option<Value>,
    /// A compaction summary's record: the rows it kept and its token count.
    /// Not part of Swift's row; the import needs it for legacy summaries.
    pub kept: Option<(Vec<String>, Option<i64>)>,
}

impl Row {
    fn new(id: String, role: &str, content: Vec<Value>) -> Self {
        Self {
            id,
            role: role.to_owned(),
            content,
            provider_items: None,
            provider_identity: None,
            provider_binding: None,
            presentation_source_id: None,
            operation_id: None,
            response_timeline: None,
            tool_call_id: None,
            tool_name: None,
            is_error: false,
            replay_eligible: true,
            display_text: None,
            user_input: None,
            context_note: None,
            request_attempt_ids: None,
            kind: None,
            detail: None,
            timestamp: None,
            tool_stats: None,
            turn: None,
            model_ms: None,
            task_root_id: None,
            task_execution_id: None,
            input_lane: None,
            compaction: None,
            retained_output: None,
            stop_reason: None,
            context_usage_binding: None,
            usage: None,
            kept: None,
        }
    }

    /// `ChatMessage(id:pi:)`.
    fn decode(id: String, pi: &Value) -> Result<Self> {
        let role = text(&pi["role"]).unwrap_or_default();
        if !["user", "assistant", "toolResult", "system"].contains(&role.as_str()) {
            return Err(refused("invalid_session", "Unsupported message role"));
        }
        let content = match pi["content"].as_str() {
            Some(text) => vec![text_block(text)],
            None => list(&pi["content"]).to_vec(),
        };
        let mut row = Row::new(id, &role, content);
        row.provider_items = (!pi["nativeProviderItems"].is_null())
            .then(|| list(&pi["nativeProviderItems"]).to_vec());
        row.provider_identity = present(&pi["nativeProviderIdentity"]);
        row.provider_binding = present(&pi["nativeProviderBinding"]);
        row.presentation_source_id = text(&pi["nativePresentationSourceID"]);
        row.operation_id = text(&pi["nativeOperationID"]);
        row.response_timeline = pi["nativeResponseTimeline"]
            .is_object()
            .then(|| pi["nativeResponseTimeline"].clone());
        row.tool_call_id = text(&pi["toolCallId"]);
        row.tool_name = text(&pi["toolName"]);
        row.is_error = flag(&pi["isError"]).unwrap_or(false);
        row.replay_eligible = flag(&pi["nativeReplayEligible"]).unwrap_or(true);
        row.display_text = text(&pi["nativeDisplayText"]);
        if !pi["nativeCompaction"].is_null() && int(&pi["nativeCompaction"]["version"]) != Some(2) {
            return Err(session_damaged(
                "Unsupported inherited compaction metadata version",
            ));
        }
        row.user_input = present(&pi["nativeUserInput"]);
        if let (Some(kind), Some(note)) = (
            text(&pi["nativeContextNote"]["kind"]),
            text(&pi["nativeContextNote"]["text"]),
        ) {
            row.context_note = Some((kind, note));
        }
        row.request_attempt_ids = (!pi["nativeRequestAttemptIds"].is_null()).then(|| {
            list(&pi["nativeRequestAttemptIds"])
                .iter()
                .filter_map(text)
                .collect()
        });
        row.kind = text(&pi["nativeKind"]);
        row.detail = text(&pi["nativeDetail"]);
        row.timestamp = double(&pi["timestamp"]);
        row.tool_stats = present(&pi["nativeToolStats"]);
        row.turn = text(&pi["nativeTurn"]);
        row.model_ms = double(&pi["nativeModelMs"]);
        row.task_root_id = text(&pi["nativeTaskRoot"]);
        row.input_lane = text(&pi["nativeInputLane"]);
        row.task_execution_id = text(&pi["nativeTaskExecution"]);
        row.compaction = present(&pi["nativeCompaction"]);
        row.retained_output = text(&pi["nativeRetainedOutput"]);
        row.stop_reason = text(&pi["nativeStopReason"]);
        row.context_usage_binding = text(&pi["nativeContextUsageBinding"]);
        row.usage = Some(
            if role == "assistant" && pi["usage"].as_object().is_some_and(|map| !map.is_empty()) {
                pi["usage"].clone()
            } else {
                Value::Null
            },
        );
        Ok(row)
    }

    /// The row's text blocks, joined.
    pub fn text(&self) -> String {
        self.content
            .iter()
            .filter(|block| block["type"] == "text")
            .filter_map(|block| block["text"].as_str())
            .collect()
    }

    /// The row's reasoning blocks, joined.
    pub fn thinking(&self) -> String {
        self.content
            .iter()
            .filter(|block| block["type"] == "thinking")
            .filter_map(|block| block["thinking"].as_str())
            .collect()
    }

    /// The tool calls of an assistant row.
    pub fn tool_calls(&self) -> impl Iterator<Item = &Value> {
        self.content
            .iter()
            .filter(|block| block["type"] == "toolCall")
    }

    /// Whether this is a progress row (a compaction's or a request ledger's).
    pub fn is_progress(&self) -> bool {
        matches!(self.kind.as_deref(), Some("execution" | "requestLedger"))
    }

    fn timeline_terminal(&self) -> Option<&str> {
        self.response_timeline.as_ref()?["terminal"].as_str()
    }

    /// `ResponseTimeline.finish`.
    fn finish_timeline(&mut self, outcome: &str, partial: bool) {
        let Some(Value::Object(timeline)) = self.response_timeline.as_mut() else {
            return;
        };
        timeline.insert("terminal".into(), json!(outcome));
        if let Some(Value::Array(segments)) = timeline.get_mut("segments") {
            for segment in segments {
                if segment["state"] == "streaming" {
                    segment["state"] = json!(outcome);
                    let revision = int(&segment["revision"]).unwrap_or(0);
                    segment["revision"] = json!(revision + 1);
                }
            }
        }
        if partial {
            timeline.insert("coverage".into(), json!("partial"));
        }
    }
}

fn text_block(text: &str) -> Value {
    json!({"type": "text", "text": text})
}

/// What a journal replays to.
#[derive(Clone, Debug, PartialEq)]
pub struct Replay {
    /// The session header: its id, the project directory and when it began.
    pub header: Value,
    /// Every row in journal order, including those an edit hid.
    pub history: Vec<Row>,
    /// The rows the chat shows.
    pub visible: Vec<Row>,
    /// The rows the model is sent.
    pub context: Vec<Row>,
    /// The newest run state: the queue, steering, pause and receipts.
    pub state: Option<Value>,
    /// Where a fork or a side came from.
    pub parent: Value,
    /// The connection the journal is bound to.
    pub binding: Option<Value>,
}

/// Complete lines: Swift's reader refuses a record without its newline (an
/// unfinished tail) and any record over 32 MiB.
fn lines(bytes: &[u8]) -> Result<Vec<&[u8]>> {
    let mut lines = Vec::new();
    let mut rest = bytes;
    while !rest.is_empty() {
        let Some(end) = rest.iter().position(|&byte| byte == b'\n') else {
            if rest.len() > MAXIMUM_RECORD_BYTES {
                return Err(session_damaged(
                    "An individual journal record exceeds 32 MiB",
                ));
            }
            return Err(session_damaged(
                "Incomplete journal tail preserved; recover a copy before continuing",
            ));
        };
        if end > MAXIMUM_RECORD_BYTES {
            return Err(session_damaged(
                "An individual journal record exceeds 32 MiB",
            ));
        }
        lines.push(&rest[..end]);
        rest = &rest[end + 1..];
    }
    Ok(lines)
}

fn parse(line: &[u8]) -> Result<Value> {
    serde_json::from_slice(line)
        .map_err(|error| refused("invalid_json", format!("Invalid JSON: {error}")))
}

/// Replays the journal of chat `id`, as Swift opens it: the whole journal,
/// checked as one chain, then every record in order.
pub fn replay(bytes: &[u8], id: &str) -> Result<Replay> {
    let lines = lines(bytes)?;
    let mut records = lines.iter().filter(|line| !line.is_empty());
    let header = records.next().map(|line| parse(line)).transpose()?;
    let header = header.filter(|header| {
        header["type"] == "session" && int(&header["version"]) == Some(3) && header["id"] == id
    });
    let Some(header) = header else {
        return Err(refused(
            "session_identity",
            "Session header does not match its identity",
        ));
    };
    // The open checks the whole chain first (`SessionJournal.chain`), then
    // the replay reads every record (`JournalReplayConsumer`).
    let records: Vec<&[u8]> = records.copied().collect();
    let mut last: Option<String> = None;
    let mut seen = HashSet::new();
    let mut marker: Option<Value> = None;
    let mut binding: Option<Value> = None;
    for line in &records {
        let item = parse(line)?;
        // `JournalChainCheck`: one branch, each id new, its parent the last.
        let record = identity(&item["id"])?;
        let parent = text(&item["parentId"]);
        if !seen.insert(record.clone()) || parent != last {
            return Err(session_damaged(
                "Native journal must be a valid single branch",
            ));
        }
        last = Some(record);
        let custom = item["customType"].as_str();
        if marker.is_none() && custom == Some(MARKER) {
            binding = Some(item["data"]["binding"].clone());
            marker = Some(item.clone());
        } else if custom == Some(REBIND) && marker.is_some() {
            // `Bindings.meet`: a move from the binding in force.
            if item["data"]["previous"] != binding.clone().unwrap_or(Value::Null)
                || !item["data"]["binding"].is_object()
            {
                return Err(session_damaged(
                    "A connection change in this journal does not follow the binding before it",
                ));
            }
            binding = Some(item["data"]["binding"].clone());
        }
    }
    if marker.is_none() {
        return Err(refused(
            "legacy_session",
            "This is not a compatible native session. Original Pi history remains read-only; use an explicit portable handoff.",
        ));
    }
    let mut consumer = Consumer::default();
    for line in &records {
        consumer.consume(parse(line)?)?;
    }
    Ok(consumer.finish(header, binding))
}

#[derive(Default)]
struct Consumer {
    history: Vec<Row>,
    visible: Vec<Row>,
    context: Vec<Row>,
    state: Option<Value>,
    parent: Value,
}

impl Consumer {
    fn consume(&mut self, item: Value) -> Result<()> {
        let custom = item["customType"].as_str();
        match (item["type"].as_str(), custom) {
            (_, Some(STATE)) => self.state = Some(item["data"].clone()),
            (Some("message"), _) => {
                let row = Row::decode(identity_required(&item["id"])?, &item["message"])?;
                if !row.is_progress() {
                    self.context.push(row.clone());
                }
                self.visible.push(row.clone());
                self.history.push(row);
            }
            (Some("compaction"), _) => self.compaction(&item)?,
            (Some("branch"), _) => self.branch(&item)?,
            (_, Some(PRESENTATION_UPDATE)) => {
                let target = identity(&item["data"]["id"])?;
                if let Some(position) = self.history.iter().rposition(|row| row.id == target)
                    && self.history[position].is_progress()
                {
                    let mut replacement = Row::decode(target.clone(), &item["message"])?;
                    replacement.replay_eligible = false;
                    if let Some(shown) = self.visible.iter().rposition(|row| row.id == target) {
                        self.visible[shown] = replacement.clone();
                    }
                    self.history[position] = replacement;
                }
            }
            (_, Some(CONTEXT)) => self.fork_context(&item)?,
            (_, Some(FORK_ORIGIN | SIDE_ORIGIN)) => self.parent = item["data"].clone(),
            _ => {}
        }
        Ok(())
    }

    /// A compaction record (`CompactionCheckpoint.restore`): the context
    /// becomes its summary and the rows it kept.
    fn compaction(&mut self, record: &Value) -> Result<()> {
        let active: Vec<&Row> = self
            .context
            .iter()
            .filter(|row| row.replay_eligible)
            .collect();
        let ordered: Vec<&str> = active.iter().map(|row| row.id.as_str()).collect();
        let available: HashSet<&str> = ordered.iter().copied().collect();
        let ids = identities(&record["nativeKeptIDs"])?;
        if !ids.iter().all(|id| available.contains(id.as_str())) {
            return Err(checkpoint_damaged(
                "Checkpoint references missing or abandoned context",
            ));
        }
        let metadata = &record["nativeCompaction"];
        if !record["nativeCompactionVersion"].is_null() || !metadata.is_null() {
            if int(&record["nativeCompactionVersion"]) != Some(2)
                || int(&metadata["version"]) != Some(2)
            {
                return Err(checkpoint_damaged(
                    "Unsupported compaction checkpoint version",
                ));
            }
            if identities(&metadata["sourceIDs"])? != ordered
                || identities(&metadata["keptIDs"])? != ids
            {
                return Err(checkpoint_damaged(
                    "Checkpoint source/order does not match the active branch",
                ));
            }
            let protected = identities(&metadata["protectedIDs"])?;
            let protected_set: HashSet<&str> = protected.iter().map(String::as_str).collect();
            let kept_set: HashSet<&str> = ids.iter().map(String::as_str).collect();
            let rest: Vec<&str> = ordered
                .iter()
                .copied()
                .filter(|id| kept_set.contains(id) && !protected_set.contains(id))
                .collect();
            let valid = protected_set.is_subset(&kept_set)
                && ids[..protected.len().min(ids.len())] == protected[..]
                && active
                    .iter()
                    .filter(|row| protected_set.contains(row.id.as_str()))
                    .all(|row| row.role == "user")
                && ordered
                    .iter()
                    .copied()
                    .filter(|id| protected_set.contains(id))
                    .eq(protected.iter().map(String::as_str))
                && rest
                    .iter()
                    .copied()
                    .eq(ids[protected.len().min(ids.len())..]
                        .iter()
                        .map(String::as_str));
            if !valid {
                return Err(checkpoint_damaged(
                    "Checkpoint protected inputs or retained group ordering is invalid",
                ));
            }
        } else if !ordered
            .iter()
            .copied()
            .filter(|id| ids.iter().any(|kept| kept == id))
            .eq(ids.iter().map(String::as_str))
        {
            return Err(checkpoint_damaged("Legacy checkpoint changes replay order"));
        }
        let by_id: HashMap<&str, &Row> = active.iter().map(|row| (row.id.as_str(), *row)).collect();
        let kept: Vec<Row> = ids
            .iter()
            .filter_map(|id| by_id.get(id.as_str()).map(|row| (*row).clone()))
            .collect();
        validate_groups(&kept)?;
        let summary = summary(record)?;
        self.context = std::iter::once(summary.clone()).chain(kept).collect();
        self.history.push(summary.clone());
        self.visible.push(summary.clone());
        if let Some(operation) = &summary.operation_id
            && let Some(position) = self.history.iter().position(|row| {
                row.kind.as_deref() == Some("execution")
                    && row.operation_id.as_ref() == Some(operation)
            })
        {
            // `adoptCompactionProgress`.
            let row = &mut self.history[position];
            row.finish_timeline("completed", false);
            row.detail = Some("Compaction · Checkpoint durably adopted".into());
            let replacement = row.clone();
            if let Some(shown) = self.visible.iter().position(|row| row.id == replacement.id) {
                self.visible[shown] = replacement;
            }
        }
        Ok(())
    }

    /// An edit (a branch record): the shown rows end where the edited
    /// message was, and the context is what the edit's plan replays.
    fn branch(&mut self, record: &Value) -> Result<()> {
        let marker = identity(&record["id"])?;
        if !record["nativeBranchVersion"].is_null() {
            let plan = restore_branch(record, &self.history, &self.visible, &self.context)?;
            // `adoptBranch`.
            let mut nodes: HashMap<&str, &Row> = HashMap::new();
            for row in &self.history {
                nodes.entry(row.id.as_str()).or_insert(row);
            }
            let context: Vec<Row> = plan
                .replay
                .iter()
                .filter_map(|id| nodes.get(id.as_str()).map(|row| (*row).clone()))
                .collect();
            let mut visible: Vec<Row> = plan
                .display_prefix
                .iter()
                .filter_map(|id| nodes.get(id.as_str()).map(|row| (*row).clone()))
                .collect();
            let shown: HashSet<String> = visible.iter().map(|row| row.id.clone()).collect();
            visible.extend(
                context
                    .iter()
                    .filter(|row| !shown.contains(&row.id))
                    .cloned(),
            );
            self.context = context;
            self.visible = visible;
        } else {
            let ordered = identities(&record["keptIds"])?;
            let ids: HashSet<&str> = ordered.iter().map(String::as_str).collect();
            if !self
                .context
                .iter()
                .filter(|row| ids.contains(row.id.as_str()))
                .map(|row| row.id.as_str())
                .eq(ordered.iter().map(String::as_str))
            {
                return Err(session_damaged(
                    "Branch references missing, abandoned or reordered messages",
                ));
            }
            // `AgentSession.branch`.
            let from = text(&record["fromMessageId"]).unwrap_or_default();
            self.context.retain(|row| ids.contains(row.id.as_str()));
            match self.visible.iter().position(|row| row.id == from) {
                Some(index) => self.visible.truncate(index),
                None => self.visible.retain(|row| ids.contains(row.id.as_str())),
            }
            let shown: HashSet<String> = self.visible.iter().map(|row| row.id.clone()).collect();
            let summaries: Vec<Row> = self
                .context
                .iter()
                .filter(|row| !shown.contains(&row.id))
                .cloned()
                .collect();
            self.visible.extend(summaries);
        }
        let mut row = Row::new(marker, "system", Vec::new());
        row.kind = Some("branch".into());
        row.replay_eligible = false;
        row.display_text = Some(BRANCH_MARKER_TEXT.into());
        self.history.push(row.clone());
        self.visible.push(row);
        if !record["nativeState"].is_null() {
            self.state = Some(record["nativeState"].clone());
        }
        Ok(())
    }

    /// A fork's context record: the model context it names, and the shown
    /// rows up to the last of them.
    fn fork_context(&mut self, record: &Value) -> Result<()> {
        let by_id: HashMap<&str, &Row> = self
            .history
            .iter()
            .map(|row| (row.id.as_str(), row))
            .collect();
        let ids = identities(&record["data"]["ids"])?;
        let context = ids
            .iter()
            .map(|id| {
                by_id
                    .get(id.as_str())
                    .map(|row| (*row).clone())
                    .ok_or_else(|| session_damaged("Unknown context reference"))
            })
            .collect::<Result<Vec<_>>>()?;
        let boundary: HashSet<&str> = ids.iter().map(String::as_str).collect();
        let selected: Vec<String> = match self
            .visible
            .iter()
            .rposition(|row| boundary.contains(row.id.as_str()))
        {
            Some(end) => self.visible[..=end]
                .iter()
                .map(|row| row.id.clone())
                .collect(),
            None => Vec::new(),
        };
        if !record["data"]["visibleIDs"].is_null()
            && identities(&record["data"]["visibleIDs"])? != selected
        {
            return Err(session_damaged(
                "Fork timeline does not match the complete boundary",
            ));
        }
        let visible = selected
            .iter()
            .filter_map(|id| by_id.get(id.as_str()).map(|row| (*row).clone()))
            .collect();
        self.context = context;
        self.visible = visible;
        Ok(())
    }

    fn finish(mut self, header: Value, binding: Option<Value>) -> Replay {
        // `endWithoutReceipt`: a restart cannot make terminal evidence.
        for index in 0..self.history.len() {
            let row = &mut self.history[index];
            if !row.is_progress() || row.timeline_terminal().is_some() {
                continue;
            }
            row.finish_timeline("interrupted", true);
            let what = if row.kind.as_deref() == Some("requestLedger") {
                "Request"
            } else {
                "Compaction"
            };
            row.detail = Some(format!("{what} interrupted · no terminal receipt"));
            let replacement = row.clone();
            if let Some(shown) = self.visible.iter().position(|row| row.id == replacement.id) {
                self.visible[shown] = replacement;
            }
        }
        Replay {
            header,
            history: self.history,
            visible: self.visible,
            context: self.context,
            state: self.state,
            parent: self.parent,
            binding,
        }
    }
}

fn identity_required(value: &Value) -> Result<String> {
    // `required(item["id"], "message id")` then the chain's identity check.
    match value.as_str() {
        Some(id) if !id.is_empty() && id.len() <= 4096 => Ok(id.to_owned()),
        _ => Err(refused("invalid_params", "Invalid message id")),
    }
}

/// `CompactionCheckpoint.summary`: the row a checkpoint record replays as.
fn summary(record: &Value) -> Result<Row> {
    let metadata = &record["nativeCompaction"];
    let Some(written) = record["summary"]
        .as_str()
        .filter(|text| !text.trim().is_empty())
    else {
        return Err(checkpoint_damaged("Empty compaction summary"));
    };
    let prefix = if metadata.is_null() {
        LEGACY_REPLAY_PREFIX
    } else {
        REPLAY_PREFIX
    };
    let mut row = Row::new(
        identity(&record["id"])?,
        "system",
        vec![text_block(&format!("{prefix}{written}"))],
    );
    row.kind = Some("compaction".into());
    let kept_ids = identities(&record["nativeKeptIDs"])?;
    let kept = kept_ids.len();
    row.kept = Some((kept_ids, int(&record["tokensBefore"])));
    let tokens =
        int(&record["tokensBefore"]).map_or("unknown".to_owned(), |tokens| tokens.to_string());
    row.detail = Some(format!(
        "Compacted {tokens} estimated input tokens · {kept} messages kept"
    ));
    row.request_attempt_ids = Some(
        list(&record["nativeRequestAttemptIds"])
            .iter()
            .filter_map(|value| value.as_str().map(str::to_owned))
            .collect(),
    );
    // `metadata.isNull ? nil : metadata` is the JSON null literal: present.
    row.compaction = present(metadata);
    row.operation_id = text(&metadata["operationId"]);
    row.task_root_id = text(&metadata["taskRootId"]);
    Ok(row)
}

/// `CompactionPlanner.groups`: every tool batch complete, in order.
fn validate_groups(rows: &[Row]) -> Result<()> {
    let messages: Vec<&Row> = rows.iter().filter(|row| row.replay_eligible).collect();
    if messages
        .iter()
        .map(|row| &row.id)
        .collect::<HashSet<_>>()
        .len()
        != messages.len()
    {
        return Err(checkpoint_damaged("Duplicate active message identities"));
    }
    let mut index = 0;
    while index < messages.len() {
        let message = messages[index];
        if message.role == "toolResult" {
            return Err(checkpoint_damaged(
                "Tool result has no owning assistant in active context",
            ));
        }
        index += 1;
        let mut pending = HashSet::new();
        if message.role == "assistant" {
            for call in message.tool_calls() {
                let id = call["id"].as_str().unwrap_or_default();
                if id.is_empty() || !pending.insert(id.to_owned()) {
                    return Err(checkpoint_damaged(
                        "Invalid call identities in an assistant group",
                    ));
                }
            }
        }
        while !pending.is_empty() {
            let complete = index < messages.len()
                && messages[index].role == "toolResult"
                && messages[index]
                    .tool_call_id
                    .as_ref()
                    .is_some_and(|id| pending.remove(id));
            if !complete {
                return Err(checkpoint_damaged(
                    "An assistant/tool batch is incomplete; inspect its effects before compacting",
                ));
            }
            index += 1;
        }
    }
    Ok(())
}

/// `ReplayNode`: what an edit's plan reads of a row.
struct Node<'a> {
    role: &'a str,
    eligible: bool,
    summary: bool,
    dependencies: Option<Vec<String>>,
    summarized: Option<Vec<String>>,
    calls: Vec<String>,
    result: Option<&'a str>,
}

fn node(row: &Row) -> Node<'_> {
    let ids = |key: &str| -> Option<Vec<String>> {
        let compaction = row.compaction.as_ref()?;
        (!compaction[key].is_null()).then(|| {
            list(&compaction[key])
                .iter()
                .filter_map(|value| value.as_str().map(str::to_owned))
                .collect()
        })
    };
    Node {
        role: &row.role,
        eligible: row.replay_eligible,
        summary: row.kind.as_deref() == Some("compaction"),
        dependencies: ids("dependencyIDs"),
        summarized: ids("summarySourceIDs"),
        calls: row
            .tool_calls()
            .map(|call| call["id"].as_str().unwrap_or_default().to_owned())
            .collect(),
        result: row.tool_call_id.as_deref(),
    }
}

/// `HistoricalEditPlan`.
#[derive(Debug, PartialEq)]
struct EditPlan {
    replay: Vec<String>,
    display_prefix: Vec<String>,
    source_timeline: String,
}

fn plan_error(reason: &str) -> Refused {
    session_damaged(format!(
        "{reason} History is preserved; no edit was applied."
    ))
}

/// `EditReplayPlan.digest`.
fn digest(ids: &[String]) -> String {
    format!("{:x}", Sha256::digest(ids.join("\n").as_bytes()))
}

/// `EditReplayPlan.validateGroups`.
fn validate_plan_groups(
    ids: &[String],
    nodes: &HashMap<&str, Node>,
) -> std::result::Result<(), Refused> {
    if ids.len() > 100_000 || ids.iter().collect::<HashSet<_>>().len() != ids.len() {
        return Err(plan_error("Duplicate or excessive replay identities."));
    }
    let mut pending: HashSet<String> = HashSet::new();
    for id in ids {
        let Some(node) = nodes.get(id.as_str()).filter(|node| node.eligible) else {
            return Err(plan_error(&format!("Missing replay source: {id}.")));
        };
        if node.role == "toolResult" {
            if !node.result.is_some_and(|result| pending.remove(result)) {
                return Err(plan_error("Orphan or duplicate tool result."));
            }
        } else {
            if !pending.is_empty() {
                return Err(plan_error("Incomplete assistant/tool group."));
            }
            if node.calls.iter().collect::<HashSet<_>>().len() != node.calls.len()
                || node.calls.iter().any(String::is_empty)
            {
                return Err(plan_error("Invalid tool call identities."));
            }
            pending = node.calls.iter().cloned().collect();
        }
    }
    if !pending.is_empty() {
        return Err(plan_error("Incomplete assistant/tool group."));
    }
    Ok(())
}

/// `EditReplayPlan.prepare`.
fn prepare(
    target: &str,
    nodes: &HashMap<&str, Node>,
    visible: &[String],
    context: &[String],
) -> Result<EditPlan> {
    let position = visible.iter().position(|id| id == target);
    let target_node = nodes.get(target);
    let (Some(position), Some(true)) = (
        position.filter(|_| {
            nodes.len() <= 100_000 && visible.iter().collect::<HashSet<_>>().len() == visible.len()
        }),
        target_node.map(|node| node.role == "user" && node.eligible),
    ) else {
        return Err(plan_error(
            "The user message is unavailable or belongs to an abandoned branch.",
        ));
    };
    let prefix = &visible[..position];
    let mut replay = Vec::new();
    for id in prefix {
        let Some(node) = nodes.get(id.as_str()) else {
            return Err(plan_error(&format!("Missing historical source: {id}.")));
        };
        if node.eligible && !node.summary {
            replay.push(id.clone());
        }
    }
    let safe: HashSet<String> = replay.iter().cloned().collect();
    let mut budget: i64 = 250_000;
    let leaves =
        |roots: &[String], dependencies: bool, budget: &mut i64| -> Option<HashSet<String>> {
            let mut active = HashSet::new();
            let mut done = HashSet::new();
            let mut result = HashSet::new();
            let mut pending: Vec<(String, bool)> =
                roots.iter().map(|id| (id.clone(), false)).collect();
            while let Some((id, exiting)) = pending.pop() {
                *budget -= 1;
                if *budget < 0 {
                    return None;
                }
                if exiting {
                    active.remove(&id);
                    done.insert(id);
                    continue;
                }
                if done.contains(&id) {
                    continue;
                }
                if !active.insert(id.clone()) {
                    return None;
                }
                let node = nodes.get(id.as_str())?;
                pending.push((id.clone(), true));
                if node.summary {
                    let children = if dependencies {
                        node.dependencies.as_ref()
                    } else {
                        node.summarized.as_ref()
                    };
                    let children = children.filter(|children| !children.is_empty())?;
                    pending.extend(children.iter().map(|child| (child.clone(), false)));
                } else {
                    result.insert(id);
                }
            }
            Some(result)
        };
    let mut replaced: HashSet<String> = HashSet::new();
    for id in context {
        let Some(node) = nodes.get(id.as_str()) else {
            continue;
        };
        let (true, Some(dependencies), Some(summarized)) = (
            node.summary,
            node.dependencies.clone(),
            node.summarized.clone(),
        ) else {
            continue;
        };
        let Some(required) = leaves(&dependencies, true, &mut budget) else {
            continue;
        };
        let Some(sources) = leaves(&summarized, false, &mut budget) else {
            continue;
        };
        if required.is_empty()
            || sources.is_empty()
            || !required.is_subset(&safe)
            || !sources.is_subset(&required)
            || !sources.is_disjoint(&replaced)
        {
            continue;
        }
        let Some(insertion) = replay.iter().position(|id| sources.contains(id)) else {
            continue;
        };
        budget -= replay.len() as i64;
        if budget < 0 {
            continue;
        }
        let mut candidate = replay.clone();
        candidate.retain(|id| !sources.contains(id));
        let at = insertion.min(candidate.len());
        candidate.insert(at, id.clone());
        // A checkpoint that would split a protocol group: the raw prefix.
        if validate_plan_groups(&candidate, nodes).is_err() {
            continue;
        }
        replay = candidate;
        replaced.extend(sources);
    }
    validate_plan_groups(&replay, nodes)?;
    let replay_set: HashSet<&String> = replay.iter().collect();
    let display_prefix = prefix
        .iter()
        .filter(|id| {
            nodes.get(id.as_str()).map(|node| node.summary) != Some(true) || replay_set.contains(id)
        })
        .cloned()
        .collect();
    Ok(EditPlan {
        replay,
        display_prefix,
        source_timeline: digest(visible),
    })
}

/// `AgentSession.restoreBranch` / `EditReplayPlan.restore`.
fn restore_branch(
    record: &Value,
    history: &[Row],
    visible: &[Row],
    context: &[Row],
) -> Result<EditPlan> {
    // `HistoricalBranch`'s decoding: these keys are required, with these types.
    let strings = |key: &str| -> Option<Vec<String>> {
        record[key]
            .as_array()?
            .iter()
            .map(|value| value.as_str().map(str::to_owned))
            .collect()
    };
    let decoded = (|| {
        let version = record["nativeBranchVersion"]
            .as_f64()
            .filter(|v| v.fract() == 0.)?;
        Some((
            version as i64,
            record["fromMessageId"].as_str()?.to_owned(),
            strings("keptIds")?,
            strings("selectedTimelinePrefix")?,
            record["sourceTimelineDigest"].as_str()?.to_owned(),
        ))
    })();
    let Some((version, from, kept, selected, timeline)) = decoded else {
        return Err(session_damaged("The branch record cannot be read"));
    };
    if version != 2 {
        return Err(plan_error(
            "Unsupported native branch version. Update Bello Agent to read this conversation.",
        ));
    }
    let nodes: HashMap<&str, Node> = history
        .iter()
        .map(|row| (row.id.as_str(), node(row)))
        .collect();
    let visible: Vec<String> = visible.iter().map(|row| row.id.clone()).collect();
    let context: Vec<String> = context.iter().map(|row| row.id.clone()).collect();
    let plan = prepare(&from, &nodes, &visible, &context)?;
    if plan.replay != kept || plan.display_prefix != selected || plan.source_timeline != timeline {
        return Err(plan_error(
            "The branch checkpoint does not match its historical sources.",
        ));
    }
    Ok(plan)
}

/// A row as the oracle dump writes it (`main.swift`'s `row`): what the
/// differential test compares.
pub fn oracle_row(row: &Row) -> Value {
    let mut value = Map::new();
    value.insert("id".into(), json!(row.id));
    value.insert("role".into(), json!(row.role));
    value.insert("text".into(), json!(row.text()));
    value.insert("thinking".into(), json!(row.thinking()));
    value.insert("isError".into(), json!(row.is_error));
    value.insert("replayEligible".into(), json!(row.replay_eligible));
    let calls: Vec<Value> = row
        .tool_calls()
        .map(|call| json!({"id": call["id"], "name": call["name"], "arguments": call["arguments"]}))
        .collect();
    if !calls.is_empty() {
        value.insert("toolCalls".into(), Value::Array(calls));
    }
    let strings = [
        ("kind", &row.kind),
        ("toolCallId", &row.tool_call_id),
        ("toolName", &row.tool_name),
        ("displayText", &row.display_text),
        ("stopReason", &row.stop_reason),
        ("detail", &row.detail),
        ("turn", &row.turn),
        ("taskRoot", &row.task_root_id),
        ("inputLane", &row.input_lane),
    ];
    for (key, field) in strings {
        if let Some(text) = field {
            value.insert(key.into(), json!(text));
        }
    }
    if let Some(input) = &row.user_input {
        value.insert("userInput".into(), input.clone());
    }
    if let Some(items) = &row.provider_items {
        value.insert("providerItems".into(), Value::Array(items.clone()));
    }
    for (key, field) in [
        ("usage", &row.usage),
        ("toolStats", &row.tool_stats),
        ("compaction", &row.compaction),
    ] {
        if let Some(field) = field {
            value.insert(key.into(), field.clone());
        }
    }
    if let Some(timestamp) = row.timestamp {
        value.insert("timestamp".into(), json!(timestamp));
    }
    Value::Object(value)
}

#[cfg(test)]
#[path = "swift_journal_tests.rs"]
mod tests;
