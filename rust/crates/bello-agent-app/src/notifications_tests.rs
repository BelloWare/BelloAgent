use super::*;
use bello_agent_core::read_observation::{OutputProjection, OutputSummary};

fn observation(generation: &str, sequence: u64) -> AcceptedReadObservation {
    AcceptedReadObservation {
        generation: generation.into(),
        source_revision: sequence,
        history: OutputProjection::Known(OutputSummary::default()),
        busy: false,
        terminal: None,
        failure_sequence: 0,
        completed_task_sequence: sequence,
    }
}
#[test]
fn receipt_tracker_baselines_consumes_muted_completion_and_keeps_fast_followup() {
    let mut tracker = CompletionTracker::default();
    assert!(!tracker.observe(&observation("writer-a", 3), false));
    assert!(tracker.observe(&observation("writer-a", 4), false));
    assert!(!tracker.observe(&observation("writer-a", 4), false));
    assert!(!tracker.observe(&observation("writer-b", 100), false));
    assert!(!tracker.observe(&observation("writer-b", 101), true));
    assert!(!tracker.observe(&observation("writer-b", 101), false));
    let mut fast = observation("writer-b", 102);
    fast.busy = true;
    assert!(tracker.observe(&fast, false));
    assert!(!completion_cue(true, false, SoundExclusions::default()));
    assert!(
        !tracker.observe(&fast, false),
        "enabling sound does not replay a consumed cue"
    );
    assert!(completion_cue(true, true, SoundExclusions::default()));
    for (completed, enabled, archived, shutdown) in [
        (false, true, false, false),
        (true, false, false, false),
        (true, true, true, false),
        (true, true, false, true),
    ] {
        assert!(!completion_cue(
            completed,
            enabled,
            SoundExclusions {
                archived,
                shut_down: shutdown,
                ..Default::default()
            }
        ));
    }
    for exclusions in [
        SoundExclusions {
            background_task: true,
            ..Default::default()
        },
        SoundExclusions {
            connection_test: true,
            ..Default::default()
        },
        SoundExclusions {
            imported: true,
            ..Default::default()
        },
    ] {
        assert!(!completion_cue(true, true, exclusions));
    }
}
#[test]
fn sound_policy_coalesces_successful_playback_and_suppresses_test_and_overlap() {
    let second = Duration::from_secs(1);
    assert!(playback_allowed(Duration::ZERO, None, false, false));
    assert!(!playback_allowed(
        Duration::from_millis(999),
        Some(Duration::ZERO),
        false,
        false
    ));
    assert!(playback_allowed(second, Some(Duration::ZERO), false, false));
    assert!(!playback_allowed(second, None, true, false));
    assert!(!playback_allowed(second, None, false, true));
    assert!(!playback_allowed(
        Duration::ZERO,
        Some(second),
        false,
        false
    ));
    // A refused/native failed play does not set last_played.
    let mut sound = Notifications::new(None);
    assert!(!sound.play());
    assert!(sound.last_played.is_none());
}
#[test]
fn badge_counts_chats_not_outputs_and_uses_manual_failure_archive_rules() {
    let mut chats = (0..5)
        .map(|i| ChatRecord::new(i.to_string(), "chat".into(), PathBuf::from(i.to_string())))
        .collect::<Vec<_>>();
    chats[3].archived_at = Some(1);
    let unread = ChatReadState {
        unread_count: 12,
        ..Default::default()
    };
    let failure = ChatReadState {
        unread_failure: true,
        ..unread.clone()
    };
    let manual = ChatReadState {
        manual_unread: true,
        ..failure.clone()
    };
    let state = [
        Some(unread.clone()),
        Some(failure),
        Some(manual),
        Some(unread),
        None,
    ];
    assert_eq!(dock_badge(chats.iter().zip(state)), Some("2".into()));
    assert_eq!(dock_badge(chats.iter().map(|r| (r, None))), None);
    assert_eq!(dock_badge(std::iter::empty()), None);
}
#[test]
fn preference_defaults_on_and_roundtrips_false_without_writing_on_load() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("notifications.json");
    let mut sound = Notifications::new(Some(path.clone()));
    assert!(sound.enabled());
    assert!(!path.exists());
    sound.set_enabled(false).unwrap();
    assert!(!Notifications::new(Some(path.clone())).enabled());
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&std::fs::read(&path).unwrap()).unwrap(),
        serde_json::json!({"completionSoundEnabled": false})
    );
    std::fs::write(&path, b"{}").unwrap();
    assert!(Notifications::new(Some(path)).enabled());
    let mut failed = Notifications::new(Some(dir.path().join("missing").join("prefs.json")));
    std::fs::write(dir.path().join("missing"), b"file").unwrap();
    assert!(failed.set_enabled(false).is_err());
    assert!(failed.enabled());
}

#[cfg(target_os = "macos")]
#[gpui::test]
fn settings_sound_draft_cancel_save_and_preview_use_existing_settings_controls(
    cx: &mut gpui::TestAppContext,
) {
    use crate::transcript_view_tests::fixture_with;
    use gpui::{Modifiers, VisualTestContext};
    let (_dir, window, root) = fixture_with(cx, vec![], 0, None, false);
    window
        .update(cx, |v, w, cx| v.open_connections(w, cx))
        .unwrap();
    cx.run_until_parked();
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    let click = |visual: &mut VisualTestContext, selector: &'static str| {
        let bounds = visual
            .debug_bounds(selector)
            .expect("visible sound setting");
        visual.simulate_click(bounds.center(), Modifiers::none());
    };
    click(&mut visual, "settings-completion-sound");
    cx.run_until_parked();
    cx.read(|cx| {
        assert!(
            cx.global::<Notifications>().enabled(),
            "draft has not been saved"
        );
        assert!(
            !root
                .read(cx)
                .connections
                .presentation
                .completion_sound_enabled
        );
        assert!(root.read(cx).connections.presentation.dirty);
    });
    click(&mut visual, "settings-completion-preview");
    cx.run_until_parked();
    cx.read(|cx| {
        assert!(
            cx.global::<Notifications>().last_played.is_none(),
            "native test remains silent"
        )
    });
    click(&mut visual, "settings-cancel");
    cx.run_until_parked();
    window
        .update(cx, |v, w, cx| v.open_connections(w, cx))
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| {
        assert!(
            root.read(cx)
                .connections
                .presentation
                .completion_sound_enabled
        )
    });
    click(&mut visual, "settings-completion-sound");
    cx.run_until_parked();
    click(&mut visual, "settings-save");
    cx.run_until_parked();
    cx.read(|cx| {
        assert!(!cx.global::<Notifications>().enabled());
        assert!(!root.read(cx).connections.open);
    });
}

#[gpui::test]
fn dock_badge_refreshes_from_restored_manual_read_state_and_clears(cx: &mut gpui::TestAppContext) {
    let (_dir, window, _root) =
        crate::transcript_view_tests::fixture_with(cx, vec![], 0, None, false);
    window
        .update(cx, |v, _, cx| {
            let id = v.record.id.clone();
            v.mark_chat_read_state(&id, true, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| assert_eq!(cx.global::<Notifications>().badge, Some(Some("1".into()))));
    window
        .update(cx, |v, _, cx| {
            let id = v.record.id.clone();
            v.mark_chat_read_state(&id, false, cx);
        })
        .unwrap();
    cx.run_until_parked();
    cx.read(|cx| assert_eq!(cx.global::<Notifications>().badge, Some(None)));
}
