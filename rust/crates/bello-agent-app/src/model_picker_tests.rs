use super::*;

fn row(id: &str, name: &str, context: Option<u32>, output: Option<u32>) -> ModelDescriptor {
    ModelDescriptor {
        id: id.into(),
        name: name.into(),
        description: "Fast drafts".into(),
        context_window: context,
        max_output_tokens: output,
        reasoning: None,
        deprecated: false,
        order: None,
        input: None,
    }
}

#[test]
fn labels_follow_model_descriptor_and_menu_title() {
    let mut item = row("gpt-5.1", "GPT-5.1", Some(400_000), Some(128_000));
    assert_eq!(context_label(&item).as_deref(), Some("400K ctx"));
    assert_eq!(
        output_limit_label(&item).as_deref(),
        Some("up to 128,000 output")
    );
    assert_eq!(menu_title(&item), "GPT-5.1 · gpt-5.1 · 400K ctx");
    item.context_window = Some(1_000_000);
    assert_eq!(context_label(&item).as_deref(), Some("1M ctx"));
    item.context_window = Some(1_500_000);
    assert_eq!(context_label(&item).as_deref(), Some("1.5M ctx"));
    item.context_window = Some(512);
    assert_eq!(context_label(&item).as_deref(), Some("512 ctx"));
    item.max_output_tokens = Some(999);
    assert_eq!(
        output_limit_label(&item).as_deref(),
        Some("up to 999 output")
    );
    item.max_output_tokens = Some(1_234_567);
    assert_eq!(
        output_limit_label(&item).as_deref(),
        Some("up to 1,234,567 output")
    );
    let mut bare = row("alias", "", None, None);
    bare.deprecated = true;
    assert_eq!(menu_title(&bare), "alias · deprecated");
}

#[test]
fn source_labels_never_show_a_query() {
    assert_eq!(source_label(None), "Included with Bello Agent");
    assert_eq!(
        source_label(Some("https://models.example/v1/catalog?token=secret")),
        "models.example/v1/catalog"
    );
    assert_eq!(
        source_label(Some("http://127.0.0.1:4100/catalog")),
        "127.0.0.1:4100/catalog"
    );
    assert_eq!(source_label(Some("not a url")), "Saved connection source");
}

#[test]
fn search_matches_id_name_or_description_ignoring_case() {
    let rows = [
        row("gpt-5.1", "GPT-5.1", None, None),
        row("claude", "Sonnet", None, None),
    ];
    let all: Vec<_> = rows.iter().collect();
    assert_eq!(filtered(all.clone(), "  ").len(), 2);
    assert_eq!(filtered(all.clone(), "SONN")[0].id, "claude");
    assert_eq!(filtered(all.clone(), "gpt")[0].id, "gpt-5.1");
    assert_eq!(filtered(all.clone(), "drafts").len(), 2);
    assert!(filtered(all, "nothing").is_empty());
}

#[test]
fn clock_time_reads_hours_minutes_and_seconds() {
    let text = clock_time(SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000));
    let (time, meridiem) = text.split_once('\u{202f}').unwrap();
    assert!(meridiem == "AM" || meridiem == "PM");
    let parts: Vec<_> = time.split(':').collect();
    assert_eq!(parts.len(), 3);
    assert!((1..=12).contains(&parts[0].parse::<u32>().unwrap()));
    assert_eq!(parts[1].len(), 2);
}
