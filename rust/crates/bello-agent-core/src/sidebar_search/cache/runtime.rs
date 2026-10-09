use super::{CacheError, Result};
use rusqlite::{Connection, limits::Limit};
use std::time::Duration;
pub(super) const SOURCE: &str =
    "2026-07-24 19:02:57 bf7c7f30031888f4e796e429ab3978879485813aaca6f641c7b33e4e09459bcc";
pub(super) fn validate(connection: &Connection) -> Result<()> {
    let identity: (String, String) =
        connection.query_row("SELECT sqlite_version(),sqlite_source_id()", [], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })?;
    if identity != ("3.53.4".into(), SOURCE.into()) {
        return Err(CacheError::UnsupportedBuild);
    }
    for option in ["ENABLE_FTS5", "STMTJRNL_SPILL=-1", "TEMP_STORE=3"] {
        let enabled: bool =
            connection.query_row("SELECT sqlite_compileoption_used(?1)", [option], |r| {
                r.get(0)
            })?;
        if !enabled {
            return Err(CacheError::UnsupportedBuild);
        }
    }
    {
        let option = "HAS_CODEC";
        let enabled: bool =
            connection.query_row("SELECT sqlite_compileoption_used(?1)", [option], |r| {
                r.get(0)
            })?;
        if enabled {
            return Err(CacheError::UnsupportedBuild);
        }
    }
    Ok(())
}
pub(super) fn probe() -> Result<()> {
    let connection = Connection::open_in_memory()?;
    validate(&connection)?;
    connection.execute_batch("CREATE VIRTUAL TABLE capability USING fts5(text,tokenize='trigram case_sensitive 1',detail=full); INSERT INTO capability(capability,rank) VALUES('secure-delete',1); INSERT INTO capability(text) VALUES('private synthetic capability');")?;
    let found: i64 = connection.query_row(
        "SELECT count(*) FROM capability WHERE capability MATCH '\"synthetic capability\"'",
        [],
        |r| r.get(0),
    )?;
    let secure: i64 = connection.query_row(
        "SELECT v FROM capability_config WHERE k='secure-delete'",
        [],
        |r| r.get(0),
    )?;
    if found != 1 || secure != 1 {
        return Err(CacheError::UnsupportedBuild);
    }
    Ok(())
}
pub(super) fn configure(connection: &Connection, reader: bool) -> Result<()> {
    validate(connection)?;
    // Official bundled source compiles extension support, but no connection may
    // enable it. Use upstream bindings; no extension-loading crate feature.
    let mut enabled = -1;
    // SAFETY: exclusive worker-owned live connection; this call only disables a
    // capability and queries its state, without registering a callback or SQL.
    let code = unsafe {
        let handle = connection.handle();
        let code = rusqlite::ffi::sqlite3_enable_load_extension(handle, 0);
        if code != rusqlite::ffi::SQLITE_OK {
            return Err(CacheError::UnsupportedBuild);
        }
        rusqlite::ffi::sqlite3_db_config(
            handle,
            rusqlite::ffi::SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION,
            -1,
            &mut enabled,
        )
    };
    if code != rusqlite::ffi::SQLITE_OK || enabled != 0 {
        return Err(CacheError::UnsupportedBuild);
    }
    connection.busy_timeout(Duration::ZERO)?;
    connection.set_limit(Limit::SQLITE_LIMIT_LENGTH, 512 * 1024)?;
    connection.set_limit(Limit::SQLITE_LIMIT_SQL_LENGTH, 64 * 1024)?;
    connection.set_limit(Limit::SQLITE_LIMIT_ATTACHED, 0)?;
    connection.set_limit(Limit::SQLITE_LIMIT_VARIABLE_NUMBER, 32)?;
    connection.execute_batch("PRAGMA secure_delete=ON; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-2048; PRAGMA synchronous=FULL; PRAGMA wal_autocheckpoint=0; PRAGMA max_page_count=131072;")?;
    let mode: String = connection.query_row("PRAGMA journal_mode=WAL", [], |r| r.get(0))?;
    if mode != "wal" {
        return Err(CacheError::UnsupportedBuild);
    }
    for (pragma, expected) in [
        ("PRAGMA secure_delete", 1),
        ("PRAGMA temp_store", 2),
        ("PRAGMA synchronous", 2),
        ("PRAGMA page_size", 4096),
        ("PRAGMA max_page_count", 131072),
    ] {
        let actual: i64 = connection.query_row(pragma, [], |r| r.get(0))?;
        if actual != expected {
            return Err(CacheError::UnsupportedBuild);
        }
    }
    if reader {
        connection.execute_batch("PRAGMA query_only=ON")?;
        let value: i64 = connection.query_row("PRAGMA query_only", [], |r| r.get(0))?;
        if value != 1 {
            return Err(CacheError::UnsupportedBuild);
        }
    }
    Ok(())
}
