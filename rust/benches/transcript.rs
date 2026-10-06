//! Manual, bounded, synthetic GPUI transcript CPU-work benchmark.
//!
//! This file is a test-only module of the app binary, not a Cargo bench target.
//! Use `rust/scripts/transcript_benchmark.py`; normal CI compiles but skips the
//! ignored benchmark. The runner records source/build provenance separately.
//! Generic mode measures only full draw routes. It does not make this file a
//! source-compatible adapter for older app revisions without a transcript child.

use crate::{AgentView, LaunchState};
use bello_agent_core::{
    Controller, Message, RunState, SessionStore,
    workspace::{ChatRecord, DraftRecord, WorkspaceStore},
};
// Keep these imports explicit: importing gpui's `test` macro through a glob can
// cause ordinary #[test] attributes in this module to expand recursively.
use gpui::{
    ArenaClearNeeded, Bounds, Entity, Modifiers, MouseButton, Pixels, Render, ScrollDelta,
    ScrollWheelEvent, TestAppContext, VisualTestContext, WindowHandle, point, px, size,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::Read,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

const SCHEMA_VERSION: u32 = 3;
const METHOD_VERSION: &str = "logical-top-full-draw-v3-fresh-first-party-build";
const SCROLL_PREPARATION: &str = "untimed wheel to top, down 24px, back to top";
const MAX_CONFIG_BYTES: usize = 16 * 1024;
const CONFIG_ENV: &str = "BELLO_TRANSCRIPT_BENCHMARK_CONFIG";
const TOTALS: [usize; 3] = [100, 1_000, 10_000];
const KINDS: [&str; 2] = ["short", "multiline_unicode_reasoning"];
const REVEAL_MODES: [&str; 2] = ["default_100", "all_revealed"];
const ROUTES: [&str; 2] = [
    "root_entity_notify_auto_draw",
    "window_refresh_explicit_draw",
];
const CONSTRUCTION_WARMUP: usize = 7;
const CONSTRUCTION_SAMPLES: usize = 31;
const DRAW_WARMUP: usize = 3;
const DRAW_SAMPLES: usize = 21;
const DRAW_BUDGET_SECONDS: u64 = 45;
const PANE_WIDTH: f32 = 979.;

// Preserve these payloads byte-for-byte from the original synthetic baseline.
const DRAFT: &str = "Untouched ordinary draft e\u{301} 日本語 🦀\nsecond line";
const SHORT: &str = "A short fixed synthetic message for transcript measurement.";
const MULTILINE: &str = "**Synthetic Unicode transcript**\n你好 日本語 café e\u{301} 👩🏽‍💻 🦀\nThis bounded paragraph wraps across the normal conversation width.\n    let value = 42; // source text\n\nFinal line, with punctuation and a tab:\tend.";
const REASONING: &str = "Reasoning fixture only.\nCompare α and β; preserve e\u{301} and 日本語.\nNo provider call or actual model reasoning is involved.";

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum MeasurementMode {
    Generic,
    Cached,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct BuildProfile {
    opt_level: String,
    debuginfo: Value,
    debug_assertions: bool,
    overflow_checks: bool,
    test: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    schema_version: u32,
    method_version: String,
    totals: Vec<usize>,
    mode: MeasurementMode,
    fixture_dir: PathBuf,
    build_profile: BuildProfile,
}

impl Config {
    fn parse(bytes: &[u8]) -> Result<Self, &'static str> {
        if bytes.is_empty() || bytes.len() > MAX_CONFIG_BYTES {
            return Err("benchmark config must contain 1..=16384 bytes");
        }
        let config: Self =
            serde_json::from_slice(bytes).map_err(|_| "invalid benchmark config schema")?;
        if config.schema_version != SCHEMA_VERSION {
            return Err("unsupported benchmark config version");
        }
        if config.method_version != METHOD_VERSION {
            return Err("unsupported benchmark method version");
        }
        if config.totals.is_empty()
            || config.totals.len() > TOTALS.len()
            || config.totals.iter().any(|total| !TOTALS.contains(total))
            || config.totals.windows(2).any(|pair| pair[0] >= pair[1])
        {
            return Err("totals must be a nonempty ascending subset of 100,1000,10000");
        }
        if !config.fixture_dir.is_absolute()
            || config.fixture_dir.as_os_str().len() > 4096
            || config.fixture_dir.parent().is_none()
        {
            return Err("fixture_dir must be a bounded absolute non-root directory");
        }
        let profile = &config.build_profile;
        let valid_debuginfo = match &profile.debuginfo {
            Value::Null => true,
            Value::Number(number) => number.as_u64().is_some_and(|number| number <= 2),
            Value::String(value) => [
                "none",
                "limited",
                "full",
                "line-directives-only",
                "line-tables-only",
            ]
            .contains(&value.as_str()),
            _ => false,
        };
        if profile.opt_level != "0"
            || !profile.debug_assertions
            || !profile.overflow_checks
            || !profile.test
            || !valid_debuginfo
        {
            return Err("benchmark requires an unoptimized Cargo test profile with checks enabled");
        }
        Ok(config)
    }

    fn load() -> Self {
        // Validation happens before any fixture directory or session is created.
        // Never alter process environment in a Rust test process.
        for name in [
            "BELLO_PERF_LOG",
            "BELLO_TEST_APPEARANCE",
            "BELLO_TEST_WINDOW_SIZE",
        ] {
            assert!(
                std::env::var_os(name).is_none(),
                "benchmark requires app performance/appearance/size overrides to be unset"
            );
        }
        let path = PathBuf::from(
            std::env::var_os(CONFIG_ENV).expect("run rust/scripts/transcript_benchmark.py"),
        );
        assert!(path.is_absolute(), "benchmark config path must be absolute");
        let metadata = fs::symlink_metadata(&path).expect("read benchmark config metadata");
        assert!(
            metadata.is_file() && !metadata.file_type().is_symlink(),
            "benchmark config must be a regular file"
        );
        assert!(
            metadata.len() <= MAX_CONFIG_BYTES as u64,
            "benchmark config is too large"
        );
        let mut bytes = Vec::new();
        File::open(path)
            .expect("open benchmark config")
            .take(MAX_CONFIG_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .expect("read benchmark config");
        let config = Self::parse(&bytes).expect("validate benchmark config");
        assert_eq!(
            cfg!(debug_assertions),
            config.build_profile.debug_assertions,
            "build profile does not match Rust debug assertions"
        );
        let metadata =
            fs::symlink_metadata(&config.fixture_dir).expect("read fixture directory metadata");
        assert!(
            metadata.is_dir() && !metadata.file_type().is_symlink(),
            "fixture_dir must already exist as a non-symlink directory"
        );
        assert_eq!(
            fs::canonicalize(&config.fixture_dir).expect("resolve fixture directory"),
            config.fixture_dir,
            "fixture_dir must be canonical"
        );
        config
    }

    fn cached(&self) -> bool {
        self.mode == MeasurementMode::Cached
    }
}

fn emit(record: Value) {
    println!("BENCHMARK_JSON {record}");
}

fn metadata(config: &Config) -> Value {
    let mut record = json!({
        "record_type": "metadata",
        "schema_version": SCHEMA_VERSION,
        "method_version": METHOD_VERSION,
        "scroll_preparation": SCROLL_PREPARATION,
        "totals": config.totals,
        "measurement_mode": config.mode,
        "expected_cases": config.totals.len() * KINDS.len() * REVEAL_MODES.len(),
        "build_profile": config.build_profile,
        "cfg_debug_assertions": cfg!(debug_assertions),
        "measurement_label": "synthetic GPUI CPU-work wall time",
        "text_system": "NoopTextSystem",
        "payload_version": "transcript-v1",
        "window": [1280, 840],
        "pane_width": PANE_WIDTH,
        "draw_warmup": DRAW_WARMUP,
        "draw_samples": DRAW_SAMPLES,
        "draw_budget_seconds": DRAW_BUDGET_SECONDS,
    });
    if config.cached() {
        record["construction_warmup"] = json!(CONSTRUCTION_WARMUP);
        record["construction_samples"] = json!(CONSTRUCTION_SAMPLES);
    }
    record
}

fn payload(kind: &str, index: usize) -> Message {
    Message {
        id: format!("message-{index:05}"),
        role: if index.is_multiple_of(2) {
            "user"
        } else {
            "assistant"
        }
        .into(),
        text: if kind == "short" {
            SHORT.into()
        } else {
            MULTILINE.repeat(3)
        },
        reasoning: if kind == "multiline_unicode_reasoning" && index % 2 == 1 {
            REASONING.repeat(2)
        } else {
            String::new()
        },
        replay_eligible: true,
        state: "complete".into(),
        usage: Value::Null,
        model: None,
        tool_record: None,
    }
}

fn fixture(
    cx: &mut TestAppContext,
    config: &Config,
    total: usize,
    kind: &str,
) -> (PathBuf, WindowHandle<AgentView>, Entity<AgentView>) {
    // Retain only synthetic fixtures under the runner-owned output directory.
    // No user project/session path, provider configuration, or home is loaded.
    let project = tempfile::Builder::new()
        .prefix("fixture-")
        .tempdir_in(&config.fixture_dir)
        .expect("create synthetic fixture")
        .keep();
    // Workbench initialization discovers Git even when its panel is closed.
    // An invalid fixture-local gitdir stops discovery before it can walk into
    // the caller's real checkout if their output directory lives inside one.
    // This is not a repository and is never written outside the new fixture.
    fs::write(project.join(".git"), b"gitdir: .synthetic-no-repository\n")
        .expect("isolate synthetic fixture from ancestor repositories");
    assert!(
        bello_workbench::git::GitRepository::open(&project).is_err(),
        "synthetic fixture unexpectedly discovered a repository"
    );
    let path = project.join("session.json");
    let mut store = SessionStore::open(&path).expect("open synthetic session");
    store
        .transact(|session| {
            session.messages = (0..total).map(|index| payload(kind, index)).collect();
            session.state = RunState::Paused;
            Ok(())
        })
        .expect("write synthetic session");
    let record = ChatRecord::new(store.snapshot().id, "Transcript CPU fixture".into(), path);
    let draft = DraftRecord {
        revision: 17,
        text: DRAFT.into(),
        queued_edit: None,
    };
    let mut workspace = WorkspaceStore::open(project.join("workspace.json"), &project)
        .expect("open synthetic workspace");
    workspace
        .register(record.clone(), draft.clone())
        .expect("register synthetic draft");
    let launch = LaunchState {
        controller: Controller::new(store, None).expect("create unconfigured controller"),
        project: project.clone(),
        workspace: Arc::new(Mutex::new(workspace)),
        record,
        draft,
        pending: false,
    };
    let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
    let root = window.root(cx).expect("synthetic root view");
    cx.run_until_parked();
    (project, window, root)
}

fn summary(raw: &[u128]) -> Value {
    assert!(!raw.is_empty(), "every timing needs a completed sample");
    let mut ordered = raw.to_vec();
    ordered.sort_unstable();
    let count = ordered.len();
    let median_ns = if count.is_multiple_of(2) {
        (ordered[count / 2 - 1] as f64 + ordered[count / 2] as f64) / 2.
    } else {
        ordered[count / 2] as f64
    };
    json!({
        "samples": count,
        "median_us": median_ns / 1000.,
        "p95_us": ordered[((count * 95).div_ceil(100)).saturating_sub(1)] as f64 / 1000.,
        "min_us": ordered[0] as f64 / 1000.,
        "max_us": ordered[count - 1] as f64 / 1000.,
        "raw_ns": raw,
    })
}

fn unchanged(
    cx: &TestAppContext,
    root: &Entity<AgentView>,
    session: &[u8],
    workspace: &[u8],
    total: usize,
    visible: usize,
) {
    cx.read(|cx| {
        let view = root.read(cx);
        assert_eq!(
            serde_json::to_vec(&*view.session).unwrap(),
            session,
            "in-memory transcript/history changed"
        );
        assert_eq!(
            serde_json::to_vec(&view.workspace.lock().unwrap().snapshot()).unwrap(),
            workspace,
            "workspace/draft changed"
        );
        assert_eq!(view.session.state, RunState::Paused);
        assert_eq!(view.session.messages.len(), total);
        assert!(view.session.pending.is_empty());
        assert!(view.session.active.is_none());
        assert!(!view.controller.configured());
        assert_eq!(view.composer.read(cx).text(), DRAFT);
        assert_eq!(view.draft_revision, 17);
        assert_eq!(view.visible_messages, visible);
        assert!(view.editing.is_none());
        assert!(!view.composer.read(cx).has_marked_text());
        assert_eq!(view.pane_width, PANE_WIDTH);
    });
}

fn disk_snapshot(project: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    fn visit(directory: &Path, snapshot: &mut BTreeMap<PathBuf, Vec<u8>>) {
        for entry in fs::read_dir(directory).expect("read synthetic fixture directory") {
            let entry = entry.expect("read synthetic fixture entry");
            let kind = entry
                .file_type()
                .expect("read synthetic fixture entry type");
            assert!(!kind.is_symlink(), "synthetic fixture contains a symlink");
            if kind.is_dir() {
                visit(&entry.path(), snapshot);
            } else {
                assert!(kind.is_file(), "unexpected synthetic fixture entry type");
                snapshot.insert(
                    entry.path(),
                    fs::read(entry.path()).expect("read synthetic fixture file"),
                );
            }
        }
    }
    let mut snapshot = BTreeMap::new();
    visit(project, &mut snapshot);
    snapshot
}

// This checks the parent's complete ordered logical input, not the renderer's
// materialized trees. Renderer projection/cardinality is proved by app tests.
fn assert_logical_input(cx: &TestAppContext, root: &Entity<AgentView>, visible: usize) -> usize {
    cx.read(|cx| {
        let input = root.read(cx).transcript_input();
        assert_eq!(input.visible_messages, visible);
        let start = input.session.messages.len().saturating_sub(visible);
        let actual: Vec<_> = input.session.messages[start..]
            .iter()
            .map(|message| message.id.as_str())
            .collect();
        let expected: Vec<_> = (start..input.session.messages.len())
            .map(|index| format!("message-{index:05}"))
            .collect();
        assert_eq!(
            actual, expected,
            "parent logical input membership/order changed"
        );
        actual.len()
    })
}

fn force_draw(visual: &mut VisualTestContext) {
    visual.update(|window, cx| {
        window.refresh();
        window.draw(cx).clear();
    });
}

fn geometry_record(bounds: Bounds<Pixels>) -> Value {
    json!([
        f32::from(bounds.left()),
        f32::from(bounds.top()),
        f32::from(bounds.size.width),
        f32::from(bounds.size.height),
    ])
}

fn top_geometry(visual: &mut VisualTestContext, selector: &'static str, start: usize) -> Value {
    let viewport = visual
        .debug_bounds("queue-measured-transcript")
        .expect("transcript viewport");
    let first = visual
        .debug_bounds(selector)
        .expect("first logical message is reachable");
    assert!(viewport.size.width > px(0.) && viewport.size.height > px(0.));
    assert!(first.size.width > px(0.) && first.size.height > px(0.));
    assert!(first.left() >= viewport.left() && first.right() <= viewport.right());
    let top = first.top() - viewport.top();
    // The only possible preceding row is the Show earlier control. Its ordinary
    // button height plus 16px gap fits below 64px in this fixed test profile.
    assert!(
        top >= px(0.) && top <= px(64.),
        "first logical row is not at viewport top"
    );
    if start == 0 {
        assert!(
            top.abs() <= px(0.01),
            "unexpected leading content or scroll offset"
        );
    }
    assert!(first.top() < viewport.bottom() && first.bottom() > viewport.top());
    json!({
        "viewport": geometry_record(viewport),
        "first_row_index": start,
        "first_row": geometry_record(first),
    })
}

fn wheel(visual: &mut VisualTestContext, delta: f32) {
    let viewport = visual
        .debug_bounds("queue-measured-transcript")
        .expect("transcript viewport");
    let position = viewport.center();
    visual.simulate_mouse_move(position, None::<MouseButton>, Modifiers::none());
    visual.simulate_event(ScrollWheelEvent {
        position,
        delta: ScrollDelta::Pixels(point(px(0.), px(delta))),
        ..Default::default()
    });
    force_draw(visual);
}

fn prepare_logical_top(
    visual: &mut VisualTestContext,
    selector: &'static str,
    start: usize,
) -> Value {
    // Dispatch actual input through both renderers' existing wheel listeners.
    // No direct handle, ListState reset, product mutation, or guessed frame count.
    force_draw(visual);
    wheel(visual, 1_000_000_000.);
    let before = top_geometry(visual, selector, start);
    let first_top = visual.debug_bounds(selector).unwrap().top();
    wheel(visual, -24.);
    let displaced = visual
        .debug_bounds(selector)
        .expect("wheel keeps first row reachable");
    assert!(
        (first_top - displaced.top() - px(24.)).abs() <= px(0.01),
        "wheel did not move actual first-row geometry by 24px"
    );
    wheel(visual, 1_000_000_000.);
    let restored = top_geometry(visual, selector, start);
    assert_eq!(
        before, restored,
        "wheel did not restore logical top geometry"
    );
    restored
}

fn child_count(cx: &TestAppContext, root: &Entity<AgentView>) -> usize {
    cx.read(|cx| {
        root.read(cx)
            .transcript
            .as_ref()
            .expect("populated synthetic transcript")
            .read(cx)
            .render_count()
    })
}

fn cached_probes(
    cx: &mut TestAppContext,
    window: WindowHandle<AgentView>,
    root: &Entity<AgentView>,
) -> Value {
    let before = child_count(cx, root);
    let mut build = Vec::new();
    let mut destroy = Vec::new();
    let mut combined = Vec::new();
    for sample in 0..CONSTRUCTION_WARMUP + CONSTRUCTION_SAMPLES {
        let (construction, destruction, total) = window
            .update(cx, |view, window, cx| {
                let started = Instant::now();
                let tree = std::hint::black_box(view.conversation(window, cx));
                let built = Instant::now();
                drop(tree);
                // GPUI AnyElement descendants are arena-owned. Dropping only
                // the returned Div would omit most of subtree destruction.
                ArenaClearNeeded.clear();
                let finished = Instant::now();
                (
                    built.duration_since(started).as_nanos(),
                    finished.duration_since(built).as_nanos(),
                    finished.duration_since(started).as_nanos(),
                )
            })
            .expect("compose parent conversation");
        if sample >= CONSTRUCTION_WARMUP {
            build.push(construction);
            destroy.push(destruction);
            combined.push(total);
        }
    }
    let parent_composition_child_renders = child_count(cx, root) - before;
    assert_eq!(
        parent_composition_child_renders, 0,
        "parent composition unexpectedly rendered child"
    );
    let mut child_build = Vec::new();
    let mut child_destroy = Vec::new();
    let mut child_combined = Vec::new();
    for sample in 0..CONSTRUCTION_WARMUP + CONSTRUCTION_SAMPLES {
        let (construction, destruction, total) = window
            .update(cx, |view, window, cx| {
                let child = view.transcript.clone().expect("populated child");
                child.update(cx, |child, cx| {
                    // Deliberately bypass the cache. This is construction only,
                    // not a full miss-frame/layout/prepaint/paint measurement.
                    let started = Instant::now();
                    let tree = std::hint::black_box(child.render(window, cx));
                    let built = Instant::now();
                    drop(tree);
                    ArenaClearNeeded.clear();
                    let finished = Instant::now();
                    (
                        built.duration_since(started).as_nanos(),
                        finished.duration_since(built).as_nanos(),
                        finished.duration_since(started).as_nanos(),
                    )
                })
            })
            .expect("render synthetic child directly");
        if sample >= CONSTRUCTION_WARMUP {
            child_build.push(construction);
            child_destroy.push(destruction);
            child_combined.push(total);
        }
    }
    json!({
        "construction_warmup": CONSTRUCTION_WARMUP,
        "construction_scope": "parent conversation composition only; child not rendered",
        "parent_composition_child_renders": parent_composition_child_renders,
        "construction": summary(&build),
        "destruction_and_arena_clear": summary(&destroy),
        "construction_plus_destruction": summary(&combined),
        "direct_child_element_construction": summary(&child_build),
        "direct_child_element_destruction": summary(&child_destroy),
        "direct_child_element_combined": summary(&child_combined),
        "direct_child_element_scope": "returned element only (eager rows or deferred list shell); explicit cache bypass; no layout/prepaint/paint; 7 warmups + 31 measured",
    })
}

fn draw_routes(
    cx: &mut TestAppContext,
    visual: &mut VisualTestContext,
    root: &Entity<AgentView>,
    cached: bool,
) -> Vec<Value> {
    let mut routes = Vec::new();
    for route in ROUTES {
        let mut samples = Vec::new();
        let mut render_counts = Vec::new();
        let mut warmup_render_counts = Vec::new();
        let route_started = Instant::now();
        let mut warmup = 0;
        let mut budget_exhausted = false;
        for sample in 0..DRAW_WARMUP + DRAW_SAMPLES {
            let renders_before = cached.then(|| child_count(cx, root));
            let duration = if route == "root_entity_notify_auto_draw" {
                // GPUI test-support synchronously flushes dirty windows with
                // Window::draw().clear(). Include update, notification, observer
                // synchronization, deferred effects, full draw and arena cleanup.
                let started = Instant::now();
                root.update(cx, |_, cx| cx.notify());
                started.elapsed().as_nanos()
            } else {
                visual.update(|window, cx| {
                    // Refresh intentionally bypasses AnyView caching. Match the
                    // old baseline: refresh is OUTSIDE the draw-and-clear timer.
                    window.refresh();
                    let started = Instant::now();
                    window.draw(cx).clear();
                    started.elapsed().as_nanos()
                })
            };
            // Counter reads and JSON work remain outside each timed sample.
            let render_delta = renders_before.map(|before| child_count(cx, root) - before);
            if sample < DRAW_WARMUP {
                warmup += 1;
                if let Some(delta) = render_delta {
                    warmup_render_counts.push(delta);
                }
            } else {
                samples.push(duration);
                if let Some(delta) = render_delta {
                    render_counts.push(delta);
                }
            }
            // Preserve the original budget semantics: always complete warmup
            // and at least one measured sample; a final sample may overshoot.
            if sample >= DRAW_WARMUP
                && route_started.elapsed() > Duration::from_secs(DRAW_BUDGET_SECONDS)
            {
                budget_exhausted = true;
                break;
            }
        }
        let mut record = json!({
            "route": route,
            "warmup": warmup,
            "budget_seconds": DRAW_BUDGET_SECONDS,
            "budget_exhausted": budget_exhausted,
            "wall_seconds_including_warmup": route_started.elapsed().as_secs_f64(),
            "timings": summary(&samples),
        });
        if cached {
            record["child_render_counts_per_measured_sample"] = json!(render_counts);
            record["child_render_counts_per_warmup"] = json!(warmup_render_counts);
        }
        routes.push(record);
    }
    routes
}

#[gpui::test]
#[ignore = "manual synthetic CPU benchmark; run rust/scripts/transcript_benchmark.py"]
fn manual_transcript_benchmark(cx: &mut TestAppContext) {
    let config = Config::load();
    emit(metadata(&config));
    let mut cases = 0;
    for kind in KINDS {
        for &total in &config.totals {
            let (project, window, root) = fixture(cx, &config, total, kind);
            let mut visual = VisualTestContext::from_window(window.into(), cx);
            visual.simulate_resize(size(px(1280.), px(840.)));
            cx.run_until_parked();
            for mode in REVEAL_MODES {
                let visible = if mode == "default_100" { 100 } else { total };
                let start = total.saturating_sub(visible);
                // One static selector per case, never a materialized-tree count.
                let selector: &'static str =
                    Box::leak(format!("transcript-row-message-{start:05}").into_boxed_str());
                root.update(cx, |view, cx| {
                    view.visible_messages = visible;
                    cx.notify();
                });
                cx.run_until_parked();
                let (before, workspace_before, payload_bytes, pane_width) = cx.read(|cx| {
                    let view = root.read(cx);
                    let start = total.saturating_sub(visible);
                    let payload_bytes: usize = view.session.messages[start..]
                        .iter()
                        .map(|message| message.text.len() + message.reasoning.len())
                        .sum();
                    (
                        serde_json::to_vec(&*view.session).unwrap(),
                        serde_json::to_vec(&view.workspace.lock().unwrap().snapshot()).unwrap(),
                        payload_bytes,
                        view.pane_width,
                    )
                });
                assert_eq!(pane_width, PANE_WIDTH, "synthetic pane geometry changed");
                let disk_before = disk_snapshot(&project);
                let logical_rows = assert_logical_input(cx, &root, visible);
                let geometry_before = prepare_logical_top(&mut visual, selector, start);
                unchanged(cx, &root, &before, &workspace_before, total, visible);
                let probes = config.cached().then(|| cached_probes(cx, window, &root));
                let routes = draw_routes(cx, &mut visual, &root, config.cached());
                unchanged(cx, &root, &before, &workspace_before, total, visible);
                assert_eq!(
                    disk_snapshot(&project),
                    disk_before,
                    "synthetic persistent files changed"
                );
                // The last route is a full draw. Only known top geometry is
                // checked; GPUI can retain stale debug selectors for other rows.
                let logical_rows_after = assert_logical_input(cx, &root, visible);
                let geometry_after = top_geometry(&mut visual, selector, start);
                assert_eq!(
                    geometry_after, geometry_before,
                    "timed draws changed top geometry"
                );
                let mut record = json!({
                    "record_type": "case",
                    "schema_version": SCHEMA_VERSION,
                    "kind": kind,
                    "total": total,
                    "mode": mode,
                    "revealed": total.min(visible),
                    "hidden": total.saturating_sub(visible),
                    "measurement_mode": config.mode,
                    "build_profile": config.build_profile,
                    "window": [1280, 840],
                    "pane_width": pane_width,
                    "logical_input_rows_before": logical_rows,
                    "logical_input_rows_after": logical_rows_after,
                    "top_geometry_before": geometry_before,
                    "top_geometry_after": geometry_after,
                    "wheel_downward_displacement_px": 24,
                    "wheel_restored_top_geometry": true,
                    "unchanged_history_and_draft": true,
                    "persistent_snapshot_bytes_unchanged": true,
                    "logical_input_payload_utf8_bytes": payload_bytes,
                    "draw_routes": routes,
                });
                if let Some(Value::Object(probes)) = probes {
                    record.as_object_mut().unwrap().extend(probes);
                }
                emit(record);
                cases += 1;
            }
            window
                .update(cx, |_, window, _| window.remove_window())
                .expect("remove synthetic window");
            drop(root);
            cx.run_until_parked();
        }
    }
    emit(json!({
        "record_type": "complete",
        "schema_version": SCHEMA_VERSION,
        "cases": cases,
    }));
}

#[test]
fn config_rejects_unbounded_or_ambiguous_inputs() {
    let valid = json!({
        "schema_version": SCHEMA_VERSION,
        "method_version": METHOD_VERSION,
        "totals": [100, 1000, 10000],
        "mode": "cached",
        "fixture_dir": "/synthetic/fixtures",
        "build_profile": {
            "opt_level": "0", "debuginfo": 0, "debug_assertions": true,
            "overflow_checks": true, "test": true,
        },
    });
    assert!(Config::parse(&serde_json::to_vec(&valid).unwrap()).is_ok());
    for totals in [
        json!([]),
        json!([0]),
        json!([101]),
        json!([10001]),
        json!([100, 100]),
        json!([1000, 100]),
        json!([100, 1000, 10000, 10000]),
    ] {
        let mut invalid = valid.clone();
        invalid["totals"] = totals;
        assert!(Config::parse(&serde_json::to_vec(&invalid).unwrap()).is_err());
    }
    for (key, value) in [
        ("schema_version", json!(1)),
        ("schema_version", json!(2)),
        ("method_version", json!("legacy")),
        ("mode", json!("provider")),
        ("fixture_dir", json!("relative/fixtures")),
        ("fixture_dir", json!("/")),
        ("unexpected", json!(true)),
    ] {
        let mut invalid = valid.clone();
        invalid[key] = value;
        assert!(Config::parse(&serde_json::to_vec(&invalid).unwrap()).is_err());
    }
    for (key, value) in [
        ("opt_level", json!("3")),
        ("debug_assertions", json!(false)),
        ("overflow_checks", json!(false)),
        ("test", json!(false)),
        ("debuginfo", json!("arbitrary data")),
        ("unexpected", json!(true)),
    ] {
        let mut invalid = valid.clone();
        invalid["build_profile"][key] = value;
        assert!(Config::parse(&serde_json::to_vec(&invalid).unwrap()).is_err());
    }
    assert!(Config::parse(&[]).is_err());
    assert!(Config::parse(&vec![b' '; MAX_CONFIG_BYTES + 1]).is_err());
}

#[test]
fn payload_bytes_and_summary_conventions_match_baseline() {
    assert_eq!(SHORT.len(), 59);
    let short: usize = (0..100)
        .map(|index| {
            let message = payload("short", index);
            message.text.len() + message.reasoning.len()
        })
        .sum();
    let unicode: usize = (0..100)
        .map(|index| {
            let message = payload("multiline_unicode_reasoning", index);
            message.text.len() + message.reasoning.len()
        })
        .sum();
    assert_eq!(short, 5_900);
    assert_eq!(unicode, 81_000);
    let stats = summary(&[4_000, 1_000, 3_000, 2_000]);
    assert_eq!(stats["samples"], 4);
    assert_eq!(stats["median_us"], 2.5);
    assert_eq!(stats["p95_us"], 4.0);
    assert_eq!(stats["raw_ns"], json!([4000, 1000, 3000, 2000]));
}
