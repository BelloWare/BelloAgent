//! Finite, credential-free baseline of the real persistence and Controller APIs.
//! See rust/perf/README.md. This is a measurement harness, not an optimized path.
use bello_agent_core::{
    Controller, Credential, Delta, Lane, Message, Profile, RunState, Session, SessionStore,
    Submission,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

type Failure = Box<dyn std::error::Error + Send + Sync>;
const CHUNK_BYTES: usize = 16;

fn chunk(i: usize) -> String {
    format!("{i:05}abcdefghijk")
}

fn distribution(values: &[f64]) -> Value {
    if values.is_empty() {
        return Value::Null;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let percentile = |p: f64| sorted[((sorted.len() as f64 * p).ceil() as usize).saturating_sub(1)];
    json!({"n": sorted.len(), "min": sorted[0], "p50": percentile(0.5),
        "p95": percentile(0.95), "p99": percentile(0.99), "max": sorted[sorted.len()-1],
        "mean": sorted.iter().sum::<f64>() / sorted.len() as f64,
        "percentile_method": "nearest rank"})
}

fn process_counters() -> Value {
    let io: BTreeMap<String, u64> = fs::read_to_string("/proc/self/io")
        .unwrap_or_default()
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once(':')?;
            Some((key.into(), value.trim().parse().ok()?))
        })
        .collect();
    let status: BTreeMap<String, u64> = fs::read_to_string("/proc/self/status")
        .unwrap_or_default()
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once(':')?;
            if !["VmRSS", "VmHWM"].contains(&key) {
                return None;
            }
            Some((key.into(), value.split_whitespace().next()?.parse().ok()?))
        })
        .collect();
    let stat = fs::read_to_string("/proc/self/stat").unwrap_or_default();
    let fields: Vec<_> = stat
        .rsplit_once(") ")
        .map(|(_, s)| s.split_whitespace().collect())
        .unwrap_or_default();
    json!({"io":io, "rss_kib":status.get("VmRSS"), "process_lifetime_peak_rss_kib":status.get("VmHWM"),
        "user_ticks": fields.get(11).and_then(|v| v.parse::<u64>().ok()),
        "system_ticks":fields.get(12).and_then(|v| v.parse::<u64>().ok())})
}

fn counter_delta(before: &Value, after: &Value, ticks: f64, elapsed: f64) -> Value {
    let diff = |a: &Value, b: &Value| b.as_u64().zip(a.as_u64()).map(|(b, a)| b.saturating_sub(a));
    let io: BTreeMap<_, _> = [
        "wchar",
        "syscw",
        "write_bytes",
        "cancelled_write_bytes",
        "rchar",
        "syscr",
        "read_bytes",
    ]
    .into_iter()
    .map(|key| (key, diff(&before["io"][key], &after["io"][key])))
    .collect();
    let user = diff(&before["user_ticks"], &after["user_ticks"]).unwrap_or(0) as f64 / ticks;
    let system = diff(&before["system_ticks"], &after["system_ticks"]).unwrap_or(0) as f64 / ticks;
    json!({"io":io,"cpu_user_seconds":user,"cpu_system_seconds":system,
        "cpu_percent_one_core":100.0*(user+system)/elapsed,"clock_ticks_per_second":ticks})
}

fn seed(path: &PathBuf, rows: usize, chars: usize) -> Result<Value, Failure> {
    if path.exists() {
        return Err("Refusing to replace an existing session fixture".into());
    }
    fs::create_dir_all(path.parent().unwrap())?;
    let mut s = Session::new();
    s.id = "deterministic-streaming-benchmark".into();
    s.title = "Synthetic ASCII transcript".into();
    s.messages = (0..rows)
        .map(|i| Message {
            user_content: None,
            id: format!("history-{i:06}"),
            role: if i % 2 == 0 { "user" } else { "assistant" }.into(),
            text: (0..chars)
                .map(|j| (b'a' + ((i + j) % 26) as u8) as char)
                .collect(),
            reasoning: String::new(),
            replay_eligible: true,
            state: "complete".into(),
            usage: Value::Null,
            model: None,
            tool_record: None,
            compaction: None,
        })
        .collect();
    let mut encoded = serde_json::to_vec(&s)?;
    encoded.push(b'\n');
    fs::write(path, &encoded)?;
    Ok(
        json!({"rows":rows,"characters_per_message":chars,"retained_ascii_characters":rows*chars,
        "retained_utf8_bytes":rows*chars,"initial_snapshot_bytes":encoded.len(),
        "seed_sha256":format!("{:x}",Sha256::digest(&encoded))}),
    )
}

fn deadline(hz: f64, i: usize) -> Duration {
    Duration::from_secs_f64(i as f64 / hz)
}

fn store_run(path: &PathBuf, count: usize, hz: f64, ticks: f64) -> Result<Value, Failure> {
    let mut store = SessionStore::open(path)?;
    store.transact(|s| {
        s.submit(Submission::new(
            "synthetic streaming fixture".into(),
            Lane::FollowUp,
        ))?;
        s.start_next()?;
        Ok(())
    })?;
    let reply_id = store.snapshot().active_reply.unwrap();
    let initial_bytes = fs::metadata(path)?.len();
    let before = process_counters();
    let start = Instant::now();
    let mut samples = Vec::with_capacity(count);
    let mut latency = Vec::with_capacity(count);
    let mut logical_bytes_written = 0;
    for i in 0..count {
        let target = start + deadline(hz, i);
        if let Some(wait) = target.checked_duration_since(Instant::now()) {
            std::thread::sleep(wait);
        }
        let delta = Delta::Text(chunk(i));
        let transaction_start = Instant::now();
        store.transact(|s| s.delta(&reply_id, delta))?;
        let end = Instant::now();
        let ms = (end - transaction_start).as_secs_f64() * 1000.0;
        let bytes = fs::metadata(path)?.len();
        logical_bytes_written += bytes;
        latency.push(ms);
        samples.push(
            json!({"chunk":i,"scheduled_ms":deadline(hz,i).as_secs_f64()*1000.0,
            "start_ms":(transaction_start-start).as_secs_f64()*1000.0,
            "end_ms":(end-start).as_secs_f64()*1000.0,"transaction_ms":ms,
            "snapshot_bytes":bytes,"cumulative_snapshot_bytes_written":logical_bytes_written}),
        );
    }
    let elapsed = start.elapsed().as_secs_f64();
    let after = process_counters();
    let final_text = store.snapshot().messages.last().unwrap().text.clone();
    assert_eq!(final_text, (0..count).map(chunk).collect::<String>());
    Ok(
        json!({"mode":"store","elapsed_seconds":elapsed,"initial_snapshot_bytes":initial_bytes,
        "final_snapshot_bytes":fs::metadata(path)?.len(),"logical_snapshot_bytes_written":logical_bytes_written,
        "stream_delta_bytes":count*CHUNK_BYTES,"write_amplification_vs_delta_bytes":logical_bytes_written as f64/(count*CHUNK_BYTES) as f64,
        "transaction_latency_ms":distribution(&latency),"counters_before":before,"counters_after":after,
        "counter_delta":counter_delta(&before,&after,ticks,elapsed),"samples":samples,
        "notes":["Pacing waits target finite fixture deadlines; no state-polling sleeps.",
            "Transaction includes clone, mutation, serialization, file sync, rename, directory sync.",
            "No Controller, SSE parsing, publication or GUI in this mode.",
            "Metadata sampling follows each transaction and is outside transaction latency.",
            "Logical bytes are the exact sum of each successfully committed snapshot file size."]}),
    )
}

async fn controller_run(
    path: &PathBuf,
    count: usize,
    hz: f64,
    ticks: f64,
) -> Result<Value, Failure> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let address = listener.local_addr()?;
    let sent = Arc::new(Mutex::new(vec![None::<Instant>; count]));
    let server_sent = Arc::clone(&sent);
    let expected = (0..count).map(chunk).collect::<String>();
    let server_expected = expected.clone();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await?;
        stream.set_nodelay(true)?;
        let mut request = Vec::new();
        let mut buf = vec![0; 8192];
        loop {
            let n = stream.read(&mut buf).await?;
            if n == 0 {
                return Err("Fixture received an incomplete request".into());
            }
            request.extend_from_slice(&buf[..n]);
            if request.len() > 32 * 1024 * 1024 + 65536 {
                return Err("Request too large".into());
            }
            if let Some(end) = request.windows(4).position(|v| v == b"\r\n\r\n") {
                let headers = String::from_utf8_lossy(&request[..end]).to_ascii_lowercase();
                let size: usize = headers
                    .lines()
                    .find_map(|line| line.strip_prefix("content-length: "))
                    .ok_or("No request content-length")?
                    .parse()?;
                if request.len() >= end + 4 + size {
                    break;
                }
            }
        }
        stream
            .write_all(
                b"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
            )
            .await?;
        let start = Instant::now();
        let mut send_samples = Vec::with_capacity(count);
        let mut fixture_bytes = 0usize;
        for i in 0..count {
            tokio::time::sleep_until((start + deadline(hz, i)).into()).await;
            let body = format!(
                "data: {}\n\n",
                json!({"type":"response.output_text.delta","delta":chunk(i)})
            );
            let began = Instant::now();
            server_sent.lock().unwrap()[i] = Some(began);
            stream.write_all(body.as_bytes()).await?;
            let ended = Instant::now();
            fixture_bytes += body.len();
            send_samples.push(
                json!({"chunk":i,"scheduled_ms":deadline(hz,i).as_secs_f64()*1000.0,
                "write_start_ms":(began-start).as_secs_f64()*1000.0,
                "write_complete_ms":(ended-start).as_secs_f64()*1000.0}),
            );
        }
        let terminal = format!(
            "data: {}\n\n",
            json!({"type":"response.completed","response":{
            "status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":server_expected}]}],
            "usage":{"input_tokens":0,"output_tokens":0}}})
        );
        stream.write_all(terminal.as_bytes()).await?;
        stream.shutdown().await?;
        Ok::<Value, Failure>(
            json!({"send_samples":send_samples,"request_bytes":request.len(),
            "delta_sse_bytes":fixture_bytes,"terminal_sse_bytes":terminal.len(),"elapsed_seconds":start.elapsed().as_secs_f64()}),
        )
    });
    let profile: Profile =
        serde_json::from_value(json!({"id":"local-benchmark","api":"openai-responses",
        "providerId":"litellm","modelId":"synthetic-only","baseUrl":format!("http://{address}"),
        "contextWindow":32000,"maxOutputTokens":4096}))?;
    let controller = Controller::new(
        SessionStore::open(path)?,
        Some((profile, Credential::new("synthetic-not-a-secret".into())?)),
    )?;
    let mut updates = controller.subscribe();
    let before = process_counters();
    let start = Instant::now();
    controller.submit("synthetic streaming fixture".into(), Lane::FollowUp)?;
    let submit_ms = start.elapsed().as_secs_f64() * 1000.0;
    let mut next_chunk = 0;
    let mut samples = Vec::with_capacity(count);
    let mut latency = Vec::with_capacity(count);
    let mut read_latency = Vec::new();
    let mut publications_observed = 0;
    let mut coalesced_chunks = 0;
    loop {
        // A watch receiver can coalesce revisions. Every latency means first observation
        // containing a chunk, never an exact timestamp of the private publish operation.
        let snapshot = updates.borrow_and_update().clone();
        publications_observed += 1;
        let read_start = Instant::now();
        let shared = controller.snapshot_shared();
        read_latency.push(read_start.elapsed().as_secs_f64() * 1e6);
        std::hint::black_box(&shared);
        let observed = Instant::now();
        let message = snapshot
            .messages
            .last()
            .filter(|m| m.role == "assistant" && m.model.as_deref() == Some("synthetic-only"));
        let visible = message.map_or(0, |m| m.text.len() / CHUNK_BYTES).min(count);
        let grouped = visible - next_chunk;
        coalesced_chunks += grouped.saturating_sub(1);
        for i in next_chunk..visible {
            let when =
                sent.lock().unwrap()[i].ok_or("Observed a chunk before fixture write started")?;
            let ms = (observed - when).as_secs_f64() * 1000.0;
            latency.push(ms);
            samples.push(json!({"chunk":i,"first_observed_ms_from_submit":(observed-start).as_secs_f64()*1000.0,
                "send_start_to_first_observation_ms":ms,"observation_revision":snapshot.revision,
                "chunks_in_observation":grouped,"observed_text_bytes":visible*CHUNK_BYTES}));
        }
        next_chunk = visible;
        if snapshot.state == RunState::Error {
            return Err(format!("Controller failed: {:?}", snapshot.error).into());
        }
        // Current Controller commits once more for the exhausted queue after
        // finish(), then marks its worker inactive before that publication.
        // Wait for this real event, so shutdown() cannot race the idle-but-still-
        // active interval and turn the finished fixture into a paused session.
        if snapshot.state == RunState::Idle
            && visible == count
            && snapshot.revision >= count as u64 + 4
        {
            assert_eq!(message.unwrap().text, expected);
            break;
        }
        updates.changed().await?;
    }
    let server_report = server.await??;
    controller.shutdown().await?;
    let elapsed = start.elapsed().as_secs_f64();
    let after = process_counters();
    let final_revision = controller.snapshot_shared().revision;
    // Deliberately after all timed / I/O-counter measurements.
    drop(updates);
    drop(controller);
    let reopened = SessionStore::open(path)?.snapshot();
    assert_eq!(reopened.messages.last().unwrap().text, expected);
    assert_eq!(reopened.state, RunState::Idle);
    Ok(
        json!({"mode":"controller","elapsed_seconds":elapsed,"submit_acknowledgement_ms":submit_ms,
        "final_snapshot_bytes":fs::metadata(path)?.len(),"final_revision":final_revision,
        "publications_observed":publications_observed,"coalesced_chunk_count":coalesced_chunks,
        "send_start_to_first_observation_ms":distribution(&latency),"snapshot_shared_read_us":distribution(&read_latency),
        "counters_before":before,"counters_after":after,"counter_delta":counter_delta(&before,&after,ticks,elapsed),
        "samples":samples,"fixture":server_report,"reopen_validated":true,
        "notes":["Real loopback HTTP -> SSE parser -> provider callback -> SessionStore transaction -> Controller watch publication.",
            "First observation latency includes socket scheduling, parsing, persistence, publish and observer scheduling; not exact publish time.",
            "The process also runs the loopback fixture and observer, so aggregate CPU and syscall counters include their work.",
            "snapshot_shared_read_us times an Arc snapshot read; no GUI layout, rendering, compositor or presentation is measured.",
            "Peak RSS is process-lifetime VmHWM, including fixture seeding and initialization."]}),
    )
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Failure> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 7 {
        return Err("Usage: session_streaming_bench store|controller SESSION_DIR ROWS CHARS_PER_MESSAGE CHUNKS HZ".into());
    }
    let mode = &args[1];
    let path = PathBuf::from(&args[2]).join("session.json");
    let rows = args[3].parse::<usize>()?;
    let chars = args[4].parse::<usize>()?;
    let count = args[5].parse::<usize>()?;
    let hz = args[6].parse::<f64>()?;
    if rows == 0 || chars == 0 || count == 0 || count > 99_999 || !hz.is_finite() || hz <= 0.0 {
        return Err("Invalid fixture dimensions".into());
    }
    let fixture = seed(&path, rows, chars)?;
    let ticks = std::env::var("BENCH_CLK_TCK")
        .unwrap_or("100".into())
        .parse::<f64>()?;
    let measured = match mode.as_str() {
        "store" => store_run(&path, count, hz, ticks)?,
        "controller" => {
            tokio::time::timeout(
                Duration::from_secs_f64(30.0 + count as f64 / hz * 6.0),
                controller_run(&path, count, hz, ticks),
            )
            .await??
        }
        _ => return Err("Mode must be store or controller".into()),
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({"schema_version":1,"fixture":fixture,"chunks":count,
        "offered_hz":hz,"chunk_bytes":CHUNK_BYTES,"offered_duration_seconds":count as f64/hz,
        "pacing":"deadline based, finite fixture; delayed direct-store work is not skipped",
        "session_path":path,"measurement":measured}))?
    );
    Ok(())
}
