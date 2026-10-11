use super::*;
use crate::Lane;

fn profile() -> Profile {
    serde_json::from_str(r#"{"id":"connection-a","api":"openai-responses","providerId":"litellm","modelId":"connection-model","baseUrl":"http://127.0.0.1:3333","contextWindow":32000,"maxOutputTokens":4096,"thinkingLevel":"medium","reasoning":true}"#).unwrap()
}
fn descriptor(id: &str, reasoning: Option<&[&str]>) -> ModelDescriptor {
    ModelDescriptor {
        id: id.into(),
        name: String::new(),
        description: String::new(),
        context_window: None,
        max_output_tokens: None,
        reasoning: reasoning.map(|r| r.iter().map(|s| (*s).to_owned()).collect()),
        deprecated: false,
        order: None,
        input: None,
        mini: None,
    }
}

#[test]
fn levels_and_labels_match_swift_thinking_level() {
    let raws: Vec<_> = ThinkingLevel::ALL.iter().map(|l| l.raw()).collect();
    assert_eq!(
        raws,
        [
            "profile-default",
            "default",
            "off",
            "minimal",
            "low",
            "medium",
            "high",
            "xhigh",
            "max"
        ]
    );
    assert_eq!(ThinkingLevel::XHigh.label(), "Extra high");
    assert_eq!(ThinkingLevel::Default.label(), "Model default");
    assert_eq!(
        ThinkingLevel::ProfileDefault.pill_label(),
        "Effort · connection default"
    );
    assert_eq!(
        ThinkingLevel::Default.pill_label(),
        "Effort · model decides"
    );
    assert_eq!(ThinkingLevel::XHigh.pill_label(), "Effort · xhigh");
}

#[test]
fn normalization_follows_turn_overrides() {
    assert_eq!(
        normalized_model(Some("  alias  ")).as_deref(),
        Some("alias")
    );
    assert_eq!(normalized_model(Some("   ")), None);
    assert_eq!(normalized_model(Some(&"x".repeat(201))), None);
    assert!(normalized_model(Some(&"é".repeat(128))).is_some());
    assert_eq!(
        normalized_model(Some(&"é".repeat(200))),
        None,
        "over 256 bytes"
    );
    assert_eq!(normalized_model(Some("a\u{7}b")), None);
    assert_eq!(normalized_thinking_level(Some("profile-default")), None);
    assert_eq!(
        normalized_thinking_level(Some("default")).as_deref(),
        Some("default")
    );
    assert_eq!(normalized_thinking_level(Some("extreme")), None);
}

#[test]
fn offered_levels_follow_the_catalog() {
    let profile = profile();
    assert_eq!(offered_levels(&profile, None).len(), 9);
    assert_eq!(
        offered_levels(&profile, Some(&descriptor("m", None))).len(),
        9
    );
    // The connection's medium is offered, so its default stays.
    assert_eq!(
        offered_levels(&profile, Some(&descriptor("m", Some(&["low", "medium"])))),
        [
            ThinkingLevel::ProfileDefault,
            ThinkingLevel::Default,
            ThinkingLevel::Low,
            ThinkingLevel::Medium
        ]
    );
    // The connection's medium is not: its default cannot be chosen.
    assert_eq!(
        offered_levels(&profile, Some(&descriptor("m", Some(&["high"])))),
        [ThinkingLevel::Default, ThinkingLevel::High]
    );
    let mut plain = profile.clone();
    plain.thinking_level = "default".into();
    assert_eq!(
        offered_levels(&plain, Some(&descriptor("m", Some(&[])))),
        [ThinkingLevel::Default],
        "a reasoning connection on a model with no efforts"
    );
}

#[test]
fn choosing_a_model_keeps_only_an_effort_it_offers() {
    let profile = profile();
    let start = ModelChoice::default().choosing_level(ThinkingLevel::High);
    let kept = start.choosing_model(
        Some("listed"),
        &profile,
        Some(&descriptor("listed", Some(&["high"]))),
    );
    assert_eq!(kept.model.as_deref(), Some("listed"));
    assert_eq!(kept.thinking_level.as_deref(), Some("high"));
    let reset = start.choosing_model(
        Some("listed"),
        &profile,
        Some(&descriptor("listed", Some(&["low"]))),
    );
    assert_eq!(reset.thinking_level.as_deref(), Some("default"));
    // Inherited medium on a model without efforts.
    let none = ModelChoice::default().choosing_model(
        Some("plain"),
        &profile,
        Some(&descriptor("plain", Some(&[]))),
    );
    assert_eq!(none.thinking_level.as_deref(), Some("default"));
    // Unknown efforts change nothing; the connection default is None.
    let unknown = start.choosing_model(None, &profile, None);
    assert_eq!(
        unknown,
        ModelChoice::default().choosing_level(ThinkingLevel::High)
    );
    assert_eq!(
        start.choosing_level(ThinkingLevel::ProfileDefault),
        ModelChoice::default()
    );
}

#[test]
fn capture_sends_the_choice_or_the_connection() {
    let profile = profile();
    let mut item = Submission::new("hi".into(), Lane::FollowUp);
    capture(&mut item, &profile).unwrap();
    assert_eq!(item.model.as_deref(), Some("connection-model"));
    assert_eq!(item.effort.as_deref(), Some("medium"));
    let mut item = submission_with(&ModelChoice {
        model: Some(" chosen ".into()),
        thinking_level: Some("default".into()),
    });
    capture(&mut item, &profile).unwrap();
    assert_eq!(item.model.as_deref(), Some("chosen"));
    assert_eq!(item.effort.as_deref(), Some("default"));
    let chosen = crate::runtime::tool_runtime::effective_profile(&profile, Some(&item));
    assert_eq!(chosen.model_id, "chosen");
    assert_eq!(chosen.thinking_level, "default");
    assert!(
        !chosen.supports_images(),
        "a chosen model is text-only unless listed"
    );
    let mut bad = Submission::new("hi".into(), Lane::FollowUp);
    bad.effort = Some("extreme".into());
    assert!(capture(&mut bad, &profile).is_err());
    let mut bad = Submission::new("hi".into(), Lane::FollowUp);
    bad.model = Some("\u{1}".into());
    assert!(capture(&mut bad, &profile).is_err());
}

#[test]
fn store_saves_chat_and_default_together_and_reopens() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("chats").join("chat-models.json");
    let store = ModelChoiceStore::open(&path);
    assert_eq!(store.error(), None);
    assert_eq!(store.chat("one"), ModelChoice::default());
    assert_eq!(
        store.adopt_defaults("new", Some("a")),
        ModelChoice::default()
    );
    let choice = ModelChoice {
        model: Some("chosen".into()),
        thinking_level: Some("high".into()),
    };
    store.save("one", Some("a"), choice.clone()).unwrap();
    assert_eq!(store.chat("one"), choice);
    assert_eq!(store.default_for("a"), Some(choice.clone()));
    assert_eq!(store.adopt_defaults("new", Some("a")), choice);
    assert_eq!(
        store.adopt_defaults("new", Some("b")),
        ModelChoice::default()
    );
    // Choosing the connection's own model is remembered too.
    store
        .save("two", Some("a"), ModelChoice::default())
        .unwrap();
    assert_eq!(store.default_for("a"), Some(ModelChoice::default()));
    let reopened = ModelChoiceStore::open(&path);
    assert_eq!(reopened.chat("one"), choice);
    assert_eq!(reopened.default_for("a"), Some(ModelChoice::default()));
    reopened.forget("one").unwrap();
    assert!(!ModelChoiceStore::open(&path).has_chat("one"));
    assert!(
        std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .all(|entry| !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".tmp"))
    );
}

#[test]
fn unreadable_store_is_reported_and_never_overwritten() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("chat-models.json");
    std::fs::write(&path, b"{not json").unwrap();
    let store = ModelChoiceStore::open(&path);
    assert!(store.error().is_some());
    assert_eq!(store.chat("one"), ModelChoice::default());
    assert!(
        store
            .save("one", Some("a"), ModelChoice::default())
            .is_err()
    );
    assert_eq!(std::fs::read(&path).unwrap(), b"{not json");
    std::fs::write(&path, br#"{"version":2,"chats":{}}"#).unwrap();
    assert!(ModelChoiceStore::open(&path).error().is_some());
}

#[test]
fn two_windows_on_the_same_chats_keep_each_others_choices() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("chat-models.json");
    let first = ModelChoiceStore::open(&path);
    let second = ModelChoiceStore::open(&path);
    let choice = |model: &str| ModelChoice {
        model: Some(model.into()),
        thinking_level: None,
    };
    first.save("one", Some("a"), choice("first")).unwrap();
    second.save("two", Some("b"), choice("second")).unwrap();
    let reopened = ModelChoiceStore::open(&path);
    assert_eq!(reopened.chat("one"), choice("first"));
    assert_eq!(reopened.chat("two"), choice("second"));
    assert_eq!(
        second.chat("one"),
        choice("first"),
        "the writer sees what it merged"
    );
}
