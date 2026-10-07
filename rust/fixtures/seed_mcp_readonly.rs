//! Supplemental GUI fixture only. Creates a genuine disconnected ReadOnly saved
//! chat using the normal stores; no Controller, manager, authority or credentials.
use bello_agent_core::{
    SessionStore,
    workspace::{ChatRecord, ChatToolMode, DraftRecord, WorkspaceStore},
};
use std::path::PathBuf;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let project = std::fs::canonicalize(args.next().ok_or("expected PROJECT SESSION")?)?;
    let session = PathBuf::from(args.next().ok_or("expected PROJECT SESSION")?);
    if args.next().is_some() || !session.is_absolute() || !project.is_dir() {
        return Err("expected one existing project and one absolute new session path".into());
    }
    let catalog = session.with_extension("workspace.json");
    if session.exists() || catalog.exists() {
        return Err("fixture refuses to replace an existing session or catalog".into());
    }
    std::fs::create_dir_all(session.parent().ok_or("session has no parent")?)?;
    let mut store = SessionStore::open(&session)?;
    store.transact(|state| {
        state.title = "Saved ReadOnly MCP fixture".into();
        Ok(())
    })?;
    let snapshot = store.snapshot();
    let mut record = ChatRecord::new(snapshot.id.clone(), snapshot.title, session);
    record.tool_mode = ChatToolMode::ReadOnly;
    let mut workspace = WorkspaceStore::open(catalog, &project)?;
    workspace.register(record, DraftRecord::default())?;
    drop(store);
    drop(workspace);
    println!("Created genuine saved ReadOnly fixture {}", snapshot.id);
    Ok(())
}
