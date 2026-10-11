use super::*;

#[test]
fn transcript_display_defaults_to_compact_and_round_trips_swift_words() {
    assert_eq!(
        TranscriptDisplayMode::default(),
        TranscriptDisplayMode::Compact
    );
    assert_eq!(TranscriptDisplayMode::Normal.label(), "Normal");
    assert_eq!(
        TranscriptDisplayMode::Compact.detail(),
        "A finished turn folds its work behind one line above the answer."
    );
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("settings").join("app-settings.json");
    let mut settings = AppSettings::new(Some(path.clone()));
    assert_eq!(
        settings.transcript_display(),
        TranscriptDisplayMode::Compact
    );
    settings
        .set_transcript_display(TranscriptDisplayMode::Normal)
        .unwrap();
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&std::fs::read(&path).unwrap()).unwrap(),
        serde_json::json!({"transcriptView": "normal"})
    );
    assert_eq!(
        AppSettings::new(Some(path.clone())).transcript_display(),
        TranscriptDisplayMode::Normal
    );
    std::fs::write(&path, br#"{"transcriptView":"sideways"}"#).unwrap();
    assert_eq!(
        AppSettings::new(Some(path)).transcript_display(),
        TranscriptDisplayMode::Compact
    );
}

#[test]
fn a_failed_write_keeps_the_mode_in_force() {
    let dir = tempfile::tempdir().unwrap();
    let blocker = dir.path().join("file");
    std::fs::write(&blocker, b"").unwrap();
    let mut settings = AppSettings::new(Some(blocker.join("app-settings.json")));
    assert!(
        settings
            .set_transcript_display(TranscriptDisplayMode::Normal)
            .is_err()
    );
    assert_eq!(
        settings.transcript_display(),
        TranscriptDisplayMode::Compact
    );
}

struct Follower {
    seen: Vec<TranscriptDisplayMode>,
    _subscription: Option<Subscription>,
}

#[gpui::test]
fn observers_hear_only_real_changes(cx: &mut gpui::TestAppContext) {
    use gpui::AppContext as _;
    cx.update(|cx| cx.set_global(AppSettings::new(None)));
    let follower = cx.new(|cx| {
        let subscription = observe_transcript_display(cx, |follower: &mut Follower, mode, _| {
            follower.seen.push(mode)
        });
        Follower {
            seen: Vec::new(),
            _subscription: Some(subscription),
        }
    });
    cx.update(|cx| {
        assert_eq!(transcript_display(cx), TranscriptDisplayMode::Compact);
        cx.global_mut::<AppSettings>()
            .set_transcript_display(TranscriptDisplayMode::Normal)
            .unwrap();
    });
    cx.run_until_parked();
    cx.update(|cx| {
        cx.global_mut::<AppSettings>()
            .set_transcript_display(TranscriptDisplayMode::Normal)
            .unwrap();
    });
    cx.run_until_parked();
    cx.update(|cx| {
        assert_eq!(transcript_display(cx), TranscriptDisplayMode::Normal);
        assert_eq!(follower.read(cx).seen, [TranscriptDisplayMode::Normal]);
    });
}
