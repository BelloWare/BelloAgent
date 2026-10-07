//! One project-scoped Streamable HTTP MCP manager shared by saved chat runtimes.
//! Configuration never discovers files or credentials. Ordinary app composition
//! remains disabled. The existing project editing gate serializes every invoke.
mod content;
mod outcome;
mod transport;
use crate::{
    Result, invalid,
    project_authority::{SavedProject, mcp::LoadedMcp},
    tools::ToolDefinition,
};
pub(crate) use content::Normalized;
pub(crate) use outcome::Ticket;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashSet},
    future::Future,
    path::Path,
    sync::{Arc, RwLock},
};
use tokio::sync::{Mutex, OwnedMutexGuard};
pub use tokio_util::sync::CancellationToken;
use transport::Http;

#[derive(Debug, thiserror::Error)]
#[error("{message}")]
pub(crate) struct McpError {
    pub code: &'static str,
    pub message: String,
    pub not_executed: bool,
}
pub(crate) type McpResult<T> = std::result::Result<T, McpError>;
impl McpError {
    fn rejected(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            not_executed: true,
        }
    }
    fn unknown(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            not_executed: false,
        }
    }
    fn config() -> Self {
        Self::rejected("mcp_config", "MCP configuration is invalid or unavailable")
    }
    fn protocol() -> Self {
        Self::unknown(
            "mcp_protocol",
            "Invalid or mismatched MCP JSON-RPC response; no automatic replay",
        )
    }
    fn limit() -> Self {
        Self::unknown(
            "mcp_limit",
            "MCP response exceeded its bounded limit; no automatic replay",
        )
    }
    fn cancelled(dispatched: bool) -> Self {
        if dispatched {
            Self::unknown(
                "mcp_cancelled",
                "MCP invocation interrupted. Effects may have occurred; inspect before retrying. No automatic replay.",
            )
        } else {
            Self::rejected(
                "mcp_cancelled",
                "Not executed: cancelled before MCP invocation",
            )
        }
    }
}
impl From<McpError> for crate::Error {
    fn from(value: McpError) -> Self {
        invalid(value.message)
    }
}
struct Server {
    config: crate::project_authority::mcp::ServerConfiguration,
    transport: Option<Http>,
    catalog: Option<(u64, Vec<Value>)>,
}
impl Server {
    async fn connect(&mut self, cancel: &CancellationToken) -> McpResult<()> {
        if self.transport.as_ref().is_some_and(|t| !t.expired) {
            return Ok(());
        }
        self.transport = None;
        self.catalog = None;
        let mut transport = Http::new(&self.config)?;
        let hello=transport.request("initialize",json!({"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"bello-agent-rust","version":"0.1.0"}}),cancel).await?;
        if !matches!(
            hello["protocolVersion"].as_str(),
            Some("2025-11-25" | "2025-06-18")
        ) || !hello["capabilities"]["tools"].is_object()
        {
            return Err(McpError::rejected(
                "mcp_version",
                "MCP server must support 2025-11-25 or 2025-06-18 and tools capability",
            ));
        }
        transport
            .notify("notifications/initialized", cancel)
            .await?;
        self.transport = Some(transport);
        Ok(())
    }
    async fn tools(&mut self, cancel: &CancellationToken) -> McpResult<Vec<Value>> {
        for attempt in 0..2 {
            self.connect(cancel).await?;
            let transport = self.transport.as_mut().expect("initialized transport");
            let generation = transport.generation;
            if let Some((cached, tools)) = &self.catalog
                && *cached == generation
            {
                return Ok(tools.clone());
            }
            let mut cursor = None::<String>;
            let mut seen = HashSet::new();
            let mut names = HashSet::new();
            let mut result = vec![];
            let mut total = 0usize;
            let mut bytes = 0usize;
            let mut expired = false;
            loop {
                let page = match transport
                    .request(
                        "tools/list",
                        cursor
                            .as_ref()
                            .map(|c| json!({"cursor":c}))
                            .unwrap_or(json!({})),
                        cancel,
                    )
                    .await
                {
                    Ok(page) => page,
                    Err(error) if error.code == "mcp_session_expired" && attempt == 0 => {
                        expired = true;
                        break;
                    }
                    Err(error) => return Err(error),
                };
                let tools = page["tools"].as_array().ok_or_else(|| {
                    McpError::rejected("mcp_schema", "MCP catalog needs a tools array")
                })?;
                total = total
                    .checked_add(tools.len())
                    .filter(|n| *n <= 2000)
                    .ok_or_else(McpError::limit)?;
                if tools.len() > 1000 {
                    return Err(McpError::limit());
                }
                for tool in tools {
                    let name = required(&tool["name"], "MCP tool")?;
                    if !tool["inputSchema"].is_object() || !names.insert(name.clone()) {
                        return Err(McpError::rejected(
                            "mcp_schema",
                            "MCP tool schema is missing or its name is duplicated",
                        ));
                    }
                    bytes = bytes
                        .checked_add(
                            serde_json::to_vec(tool)
                                .map_err(|_| McpError::protocol())?
                                .len(),
                        )
                        .filter(|n| *n <= 4 * 1024 * 1024)
                        .ok_or_else(McpError::limit)?;
                    if self
                        .config
                        .allowed_tools
                        .as_ref()
                        .is_none_or(|allowed| allowed.contains(&name))
                    {
                        result.push(tool.clone());
                    }
                }
                cursor = match page.get("nextCursor") {
                    None | Some(Value::Null) => None,
                    Some(Value::String(c)) if !c.is_empty() && c.len() <= 16_384 => Some(c.clone()),
                    _ => {
                        return Err(McpError::rejected(
                            "mcp_cursor",
                            "Invalid MCP catalog cursor",
                        ));
                    }
                };
                if let Some(cursor) = &cursor {
                    if seen.len() >= 100 || !seen.insert(cursor.clone()) {
                        return Err(McpError::rejected(
                            "mcp_cursor",
                            "MCP cursor repeated or exceeded the page limit",
                        ));
                    }
                } else {
                    break;
                }
            }
            if expired {
                continue;
            }
            self.catalog = Some((generation, result.clone()));
            return Ok(result);
        }
        Err(McpError::rejected(
            "mcp_session_expired",
            "MCP session repeatedly expired; no further retry",
        ))
    }
}
#[derive(Clone, Debug)]
pub struct McpStatus {
    pub busy: bool,
    pub outcome_unknown: bool,
    pub unknown_id: Option<String>,
    pub pending_results: usize,
}
pub struct McpManager {
    project: SavedProject,
    configuration: RwLock<LoadedMcp>,
    gate: Arc<Mutex<()>>,
    servers: Mutex<BTreeMap<String, Server>>,
    editing_gate: Arc<Mutex<()>>,
    ledger: Arc<outcome::Ledger>,
    runtime: tokio::runtime::Handle,
}
pub struct McpConfigurationChange {
    manager: Arc<McpManager>,
    _gate: OwnedMutexGuard<()>,
}
pub(crate) struct Performed {
    pub normalized: Normalized,
    pub ticket: Option<Ticket>,
}
fn server_map(loaded: &LoadedMcp) -> BTreeMap<String, Server> {
    loaded
        .configuration
        .servers
        .iter()
        .filter(|(_, s)| s.enabled)
        .map(|(name, config)| {
            (
                name.clone(),
                Server {
                    config: config.clone(),
                    transport: None,
                    catalog: None,
                },
            )
        })
        .collect()
}
impl McpManager {
    pub(crate) fn new(
        loaded: LoadedMcp,
        directory: &Path,
        editing_gate: Arc<Mutex<()>>,
    ) -> Result<Arc<Self>> {
        loaded.confirm().map_err(|e| invalid(e.to_string()))?;
        let ledger = outcome::Ledger::open(directory, loaded.project_id())?;
        let runtime = tokio::runtime::Handle::try_current()
            .unwrap_or(crate::runtime::shared_runtime()?.handle().clone());
        Ok(Arc::new(Self {
            project: loaded.project.clone(),
            servers: Mutex::new(server_map(&loaded)),
            configuration: RwLock::new(loaded),
            gate: Arc::new(Mutex::new(())),
            editing_gate,
            ledger,
            runtime,
        }))
    }
    // Only the same WorkspaceStore's cached manager may transfer this lease.
    // Root re-trust invalidates the old exact authority, but late tickets still
    // share the ledger and operation gate until physical settlement completes.
    pub(crate) fn rebind(&self, loaded: LoadedMcp) -> Result<Arc<Self>> {
        if self.project.id != loaded.project.id
            || self.project.path != loaded.project.path
            || !self
                .configuration
                .read()
                .is_ok_and(|current| current.same_store(&loaded))
        {
            return Err(invalid("MCP workspace authority changed"));
        }
        loaded.confirm().map_err(|e| invalid(e.to_string()))?;
        Ok(Arc::new(Self {
            project: loaded.project.clone(),
            servers: Mutex::new(server_map(&loaded)),
            configuration: RwLock::new(loaded),
            gate: self.gate.clone(),
            editing_gate: self.editing_gate.clone(),
            ledger: self.ledger.clone(),
            runtime: self.runtime.clone(),
        }))
    }
    pub fn project_id(&self) -> &str {
        &self.project.id
    }
    pub(crate) fn matches_project(&self, project: &SavedProject) -> bool {
        &self.project == project
    }
    pub(crate) fn matches_authority(&self, loaded: &LoadedMcp) -> bool {
        self.configuration
            .read()
            .is_ok_and(|current| current.same_authority(loaded))
    }
    /// Presentation-only exact configuration equality, with no vault/network
    /// read and no secret values exposed. It never grants dispatch authority.
    pub fn configuration_matches(&self, loaded: &LoadedMcp) -> bool {
        self.configuration
            .try_read()
            .is_ok_and(|current| current.same_configuration(loaded))
    }
    pub fn status(&self) -> McpStatus {
        let gate = self.gate.try_lock().ok();
        let status = self.ledger.status();
        McpStatus {
            busy: gate.is_none(),
            outcome_unknown: status.unknown,
            unknown_id: status.unknown_id,
            pending_results: status.pending,
        }
    }
    pub fn begin_configuration_change(self: &Arc<Self>) -> Result<McpConfigurationChange> {
        let gate = self
            .gate
            .clone()
            .try_lock_owned()
            .map_err(|_| invalid("MCP work is still running"))?;
        if self.ledger.status().pending != 0 {
            return Err(invalid(
                "MCP results are still waiting for durable retention",
            ));
        }
        Ok(McpConfigurationChange {
            manager: self.clone(),
            _gate: gate,
        })
    }
    pub fn acknowledge_unknown(&self, expected_unknown_id: &str, confirmed: bool) -> Result<()> {
        let _guard = self
            .gate
            .try_lock()
            .map_err(|_| invalid("MCP work is still running"))?;
        let loaded = self
            .configuration
            .read()
            .map_err(|_| invalid("MCP configuration is unavailable"))?
            .clone();
        loaded.confirm().map_err(|_| {
            invalid("MCP authority changed; review current project settings before acknowledging")
        })?;
        self.ledger.acknowledge(expected_unknown_id, confirmed)
    }
    async fn spawn<T: Send + 'static>(
        &self,
        cancel: CancellationToken,
        future: impl Future<Output = Result<T>> + Send + 'static,
    ) -> Result<T> {
        let _cancel_on_drop = cancel.drop_guard();
        self.runtime.spawn(future).await.map_err(|_| {
            invalid("MCP worker could not finish; check its outcome before continuing")
        })?
    }
    /// Reads the last canonical Inspector receipt without executing a tool or
    /// clearing unresolved outcome evidence. A readable receipt is not evidence
    /// that an earlier uncertain marker/checkpoint has become confirmed.
    pub async fn latest_result(
        self: &Arc<Self>,
        cancel: CancellationToken,
    ) -> Result<Option<Value>> {
        let manager = self.clone();
        let token = cancel.clone();
        self.spawn(cancel, async move {
            let _gate = lock(manager.gate.clone(), &token).await?;
            manager.confirm().await?;
            let ledger = manager.ledger.clone();
            let bytes = tokio::task::spawn_blocking(move || outcome::read_bounded(&ledger.receipt_path(), crate::tool_content::MAX_CONTENT_BYTES + 4096))
                .await.map_err(|_| invalid("MCP retained result reader failed"))??;
            let Some(bytes) = bytes else { return Ok(None); };
            #[derive(serde::Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Receipt { version: u32, project: String, invocation: String, server: String, tool: String, result: Retained }
            #[derive(serde::Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Retained { content: Vec<crate::tool_content::ContentBlock>, #[serde(rename="isError")] is_error: bool }
            let receipt: Receipt = serde_json::from_slice(&bytes).map_err(|_| invalid("MCP retained result is invalid; saved bytes were preserved"))?;
            if receipt.version != 1 || receipt.project != manager.project.id || uuid::Uuid::parse_str(&receipt.invocation).is_err()
                || required(&json!(receipt.server), "server").is_err() || required(&json!(receipt.tool), "tool").is_err() {
                return Err(invalid("MCP retained result identity is invalid; saved bytes were preserved"));
            }
            crate::tool_content::ToolContent { blocks: receipt.result.content.clone(), stats: None }.validate()?;
            let mut value = json!({"version":receipt.version,"project":receipt.project,"invocation":receipt.invocation,"server":receipt.server,"tool":receipt.tool,"result":{"content":receipt.result.content,"isError":receipt.result.is_error},"outcomeUnknown":manager.ledger.status().unknown});
            let secrets = manager.configuration.read().map_err(|_| invalid("MCP configuration is unavailable"))?.redactions();
            content::redact(&mut value, &secrets)?;
            Ok(Some(value))
        }).await
    }
    pub async fn list_servers(self: &Arc<Self>, cancel: CancellationToken) -> Result<Value> {
        self.discovery(json!({"action":"list"}), cancel).await
    }
    pub async fn list_tools(
        self: &Arc<Self>,
        server: &str,
        cancel: CancellationToken,
    ) -> Result<Value> {
        self.discovery(json!({"action":"list","server":server}), cancel)
            .await
    }
    pub async fn describe(
        self: &Arc<Self>,
        targets: Value,
        cancel: CancellationToken,
    ) -> Result<Value> {
        self.discovery(json!({"action":"describe","targets":targets}), cancel)
            .await
    }
    async fn discovery(
        self: &Arc<Self>,
        parameters: Value,
        cancel: CancellationToken,
    ) -> Result<Value> {
        let this = self.clone();
        let token = cancel.clone();
        self.spawn(cancel, async move {
            let _gate = lock(this.gate.clone(), &token).await?;
            this.confirm().await?;
            this.discovery_locked(&parameters, &token)
                .await
                .map_err(Into::into)
        })
        .await
    }
    async fn confirm(&self) -> McpResult<()> {
        let loaded = self
            .configuration
            .read()
            .map_err(|_| McpError::config())?
            .clone();
        tokio::task::spawn_blocking(move ||loaded.confirm()).await.map_err(|_|McpError::config())?.map_err(|_|McpError::rejected("mcp_config","Saved MCP authority/configuration changed or is unavailable; review and apply current settings"))
    }
    async fn discovery_locked(&self, p: &Value, cancel: &CancellationToken) -> McpResult<Value> {
        let fields = p.as_object().ok_or_else(arguments)?;
        let mut servers = self.servers.lock().await;
        let mut value = match p["action"].as_str() {
            Some("list") => {
                if fields
                    .keys()
                    .any(|k| !["action", "server"].contains(&k.as_str()))
                {
                    return Err(arguments());
                }
                if let Some(server) = p.get("server") {
                    let name = required(server, "server")?;
                    let tools = servers
                        .get_mut(&name)
                        .ok_or_else(unknown_server)?
                        .tools(cancel)
                        .await?;
                    let tools = tools
                        .into_iter()
                        .map(|mut t| {
                            let map = t.as_object_mut().expect("validated tool");
                            map.remove("inputSchema");
                            map.remove("outputSchema");
                            t
                        })
                        .collect::<Vec<_>>();
                    json!({"server":name,"tools":tools})
                } else {
                    json!({"servers":servers.iter().map(|(name,s)|json!({"server":name,"connected":s.transport.as_ref().is_some_and(|t|!t.expired)})).collect::<Vec<_>>(),"outcomeUnknown":self.ledger.status().unknown})
                }
            }
            Some("describe") => {
                if fields.len() != 2 {
                    return Err(arguments());
                }
                let targets = p["targets"]
                    .as_array()
                    .filter(|v| !v.is_empty() && v.len() <= 32)
                    .ok_or_else(arguments)?;
                let mut rows = vec![];
                for target in targets {
                    if target.as_object().is_none_or(|o| {
                        o.len() != 2 || !o.contains_key("server") || !o.contains_key("tool")
                    }) {
                        return Err(arguments());
                    }
                    let server = required(&target["server"], "server")?;
                    let tool = required(&target["tool"], "tool")?;
                    let catalog = servers
                        .get_mut(&server)
                        .ok_or_else(unknown_server)?
                        .tools(cancel)
                        .await?;
                    let schema = catalog
                        .into_iter()
                        .find(|t| t["name"] == tool)
                        .ok_or_else(unknown_tool)?;
                    rows.push(json!({"server":server,"tool":tool,"schema":schema}));
                    if serde_json::to_vec(&rows)
                        .map_err(|_| McpError::protocol())?
                        .len()
                        > 4 * 1024 * 1024
                    {
                        return Err(McpError::limit());
                    }
                }
                json!({"tools":rows})
            }
            _ => return Err(arguments()),
        };
        let secrets = self
            .configuration
            .read()
            .map_err(|_| McpError::config())?
            .redactions();
        content::redact(&mut value, &secrets)?;
        Ok(value)
    }
    pub(crate) async fn perform<F, Fut>(
        &self,
        p: &Value,
        read_only: bool,
        cancel: CancellationToken,
        admission: F,
    ) -> McpResult<Performed>
    where
        F: Fn() -> Fut,
        Fut: Future<Output = Result<()>>,
    {
        if p["action"] != "invoke" {
            let _gate = lock(self.gate.clone(), &cancel).await?;
            admission().await.map_err(|_| {
                McpError::rejected(
                    "mcp_unavailable",
                    "MCP authority was revoked before discovery",
                )
            })?;
            self.confirm().await?;
            let value = self.discovery_locked(p, &cancel).await?;
            return Ok(Performed {
                normalized: content::normalize(
                    crate::tools::result_text(value.to_string(), false),
                    &[],
                )?,
                ticket: None,
            });
        }
        if read_only {
            return Err(McpError::rejected(
                "read_only",
                "MCP invocation is disabled in read-only chats; server annotations are not authorization",
            ));
        }
        if p.as_object().is_none_or(|o| {
            o.len() != 4
                || !["action", "server", "tool", "arguments"]
                    .iter()
                    .all(|k| o.contains_key(*k))
        }) || !p["arguments"].is_object()
        {
            return Err(arguments());
        }
        let name = required(&p["server"], "server")?;
        let tool = required(&p["tool"], "tool")?;
        if serde_json::to_vec(p).map_err(|_| arguments())?.len() > 2 * 1024 * 1024 {
            return Err(arguments());
        }
        if self.ledger.status().unknown {
            return Err(McpError::rejected(
                "mcp_outcome_unknown",
                "A previous MCP invocation has an unknown outcome. Review its effects and acknowledge before requesting another invocation.",
            ));
        }
        let _editing = lock(self.editing_gate.clone(), &cancel).await?;
        let _gate = lock(self.gate.clone(), &cancel).await?;
        admission().await.map_err(|_| {
            McpError::rejected(
                "mcp_unavailable",
                "Not executed: saved chat authority changed while waiting for MCP invocation",
            )
        })?;
        self.confirm().await?;
        if self.ledger.status().unknown {
            return Err(McpError::rejected(
                "mcp_outcome_unknown",
                "A previous MCP invocation has an unknown outcome. Review its effects and acknowledge before invoking.",
            ));
        }
        let mut servers = self.servers.lock().await;
        let server = servers.get_mut(&name).ok_or_else(unknown_server)?;
        let catalog = server.tools(&cancel).await.map_err(|mut e| {
            e.not_executed = true;
            e
        })?;
        if !catalog.iter().any(|t| t["name"] == tool) {
            return Err(unknown_tool());
        }
        // Discovery may have waited on a server. Reconfirm exact authority at
        // the final effect boundary, not just before initialize/list.
        admission().await.map_err(|_| {
            McpError::rejected(
                "mcp_unavailable",
                "Not executed: saved chat authority changed before MCP dispatch",
            )
        })?;
        self.confirm().await?;
        if cancel.is_cancelled() {
            return Err(McpError::cancelled(false));
        }
        let ledger = self.ledger.clone();
        let marker_server = name.clone();
        let marker_tool = tool.clone();
        let ticket =
            tokio::task::spawn_blocking(move || ledger.begin(&marker_server, &marker_tool))
                .await
                .map_err(|_| {
                    McpError::rejected(
                        "mcp_marker",
                        "MCP outcome marker worker failed; no invocation dispatched",
                    )
                })?
                .map_err(|_| {
                    McpError::rejected(
                        "mcp_marker",
                        "MCP outcome marker was not confirmed; no invocation dispatched",
                    )
                })?;
        let call = json!({"name":tool,"arguments":p["arguments"]});
        let mut result = server
            .transport
            .as_mut()
            .expect("catalog initialized")
            .request("tools/call", call.clone(), &cancel)
            .await;
        if result
            .as_ref()
            .is_err_and(|e| e.code == "mcp_session_expired")
        {
            // Only source-proven unprocessed session expiry permits one retry.
            result = async {
                server.connect(&cancel).await.map_err(|mut e| {
                    e.not_executed = true;
                    e
                })?;
                admission().await.map_err(|_| {
                    McpError::rejected(
                        "mcp_unavailable",
                        "Not executed: authority changed after session expiry",
                    )
                })?;
                self.confirm().await?;
                server
                    .transport
                    .as_mut()
                    .expect("reinitialized")
                    .request("tools/call", call, &cancel)
                    .await
            }
            .await;
        }
        match result {
            Ok(value) => {
                let value = crate::tools::BlockingWorkExecutor::shared().run(cancel.clone(), move |token| crate::tools::mcp_images::normalize(value, &token)).await
                    .map_err(|_| McpError::unknown("mcp_result", "MCP image/result retention was interrupted; effects may have occurred. No automatic replay."))?;
                let secrets = self
                    .configuration
                    .read()
                    .map_err(|_| McpError::config())?
                    .redactions();
                let normalized = content::normalize(value, &secrets)?;
                Ok(Performed {
                    normalized,
                    ticket: Some(ticket),
                })
            }
            Err(error) => {
                if error.not_executed {
                    tokio::task::spawn_blocking(move || ticket.settle())
                        .await
                        .map_err(|_| {
                            McpError::unknown("mcp_marker", "MCP rejection marker could not settle")
                        })?
                        .map_err(|_| {
                            McpError::unknown(
                                "mcp_marker",
                                "MCP rejection marker was not durably cleared",
                            )
                        })?;
                }
                Err(error)
            }
        }
    }
    pub(crate) async fn retain_inspector(&self, performed: Performed) -> Result<Value> {
        let value = performed.normalized.value();
        let ticket = performed
            .ticket
            .ok_or_else(|| invalid("MCP invocation produced no receipt"))?;
        let (server, tool) = ticket.target()?;
        let bytes = serde_json::to_vec(
            &json!({"version":1,"project":self.project.id,"invocation":ticket.id(),"server":server,"tool":tool,"result":value}),
        )?;
        if bytes.len() > crate::tool_content::MAX_CONTENT_BYTES + 4096 {
            return Err(invalid("MCP Inspector receipt exceeds its bound"));
        }
        let ledger = self.ledger.clone();
        tokio::task::spawn_blocking(move || {
            ledger.write_receipt(&bytes)?;
            ticket.settle()
        })
        .await
        .map_err(|_| invalid("MCP Inspector result retention failed; outcome remains unknown"))??;
        Ok(value)
    }
}
impl McpConfigurationChange {
    pub async fn apply_configuration(
        self,
        loaded: LoadedMcp,
        cancel: CancellationToken,
    ) -> Result<()> {
        let manager = self.manager.clone();
        manager
            .spawn(cancel.clone(), async move {
                if cancel.is_cancelled() {
                    return Err(crate::Error::Cancelled);
                }
                let original = self
                    .manager
                    .configuration
                    .read()
                    .map_err(|_| invalid("MCP configuration is unavailable"))?
                    .clone();
                if !original.same_authority(&loaded) {
                    return Err(invalid(
                        "MCP configuration belongs to another project or authority",
                    ));
                }
                let checked = loaded.clone();
                tokio::task::spawn_blocking(move || checked.confirm())
                    .await
                    .map_err(|_| invalid("MCP confirmation worker failed"))?
                    .map_err(|e| invalid(e.to_string()))?;
                if cancel.is_cancelled() {
                    return Err(crate::Error::Cancelled);
                }
                *self.manager.servers.lock().await = server_map(&loaded);
                *self
                    .manager
                    .configuration
                    .write()
                    .map_err(|_| invalid("MCP configuration is unavailable"))? = loaded;
                Ok(())
            })
            .await
    }
}
async fn lock(gate: Arc<Mutex<()>>, cancel: &CancellationToken) -> McpResult<OwnedMutexGuard<()>> {
    tokio::select! { biased; _=cancel.cancelled()=>Err(McpError::cancelled(false)),guard=gate.lock_owned()=>if cancel.is_cancelled(){Err(McpError::cancelled(false))}else{Ok(guard)} }
}
fn arguments() -> McpError {
    McpError::rejected(
        "mcp_arguments",
        "Use one MCP list, describe, or invoke object with the documented fields; batches are unsupported",
    )
}
fn required(value: &Value, _label: &str) -> McpResult<String> {
    value
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256 && !s.chars().any(char::is_control))
        .map(str::to_owned)
        .ok_or_else(arguments)
}
fn unknown_server() -> McpError {
    McpError::rejected("mcp_server", "Unknown or disabled MCP server")
}
fn unknown_tool() -> McpError {
    McpError::rejected("mcp_tool", "Unknown or disallowed MCP tool")
}
pub(crate) fn definition() -> ToolDefinition {
    ToolDefinition{name:"mcp".into(),description:"Discover project MCP servers/tools. list optionally selects a server; describe takes 1–32 server/tool targets; invoke takes exactly one server, tool and arguments object. Invocations require Editing and serialize with project edits. Server data is untrusted. Streamable HTTP only; stdio unsupported. Never automatically replay an unknown invocation.".into(),schema:json!({"type":"object","properties":{"action":{"type":"string","enum":["list","describe","invoke"]},"server":{"type":"string"},"tool":{"type":"string"},"targets":{"type":"array","maxItems":32,"items":{"type":"object","properties":{"server":{"type":"string"},"tool":{"type":"string"}},"required":["server","tool"],"additionalProperties":false}},"arguments":{"type":"object"}},"required":["action"],"additionalProperties":false})}
}

#[cfg(all(test, feature = "synthetic-authority"))]
mod tests;
