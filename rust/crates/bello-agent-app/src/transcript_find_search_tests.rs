use super::*;
use unicode_normalization::UnicodeNormalization;
fn page(text: &str, needle: &str) -> RangePage {
    let cancel = AtomicBool::new(false);
    Query::new(needle, &cancel)
        .unwrap()
        .ranges(text, 0, MAX_RANGE_PAGE, &cancel)
        .unwrap()
}
#[test]
fn canonical_lowercase_hangul_and_expansion_ranges() {
    for (text, needle, expected) in [
        ("Cafe\u{301} CAFÉ", "café", vec![0..6, 7..12]),
        ("İ", "i", std::iter::once(0..2).collect::<Vec<_>>()),
        ("İ", "\u{307}", std::iter::once(0..2).collect::<Vec<_>>()),
        (
            "\u{1100}\u{1161}\u{11a8}",
            "각",
            std::iter::once(0..9).collect::<Vec<_>>(),
        ),
        ("😀A😀", "😀", vec![0..4, 5..9]),
        ("aaa", "aa", std::iter::once(0..2).collect::<Vec<_>>()),
        (
            "a\u{315}\u{300}",
            "à",
            std::iter::once(0..5).collect::<Vec<_>>(),
        ),
        (
            "a\u{315}\u{300}",
            "\u{315}",
            std::iter::once(1..3).collect::<Vec<_>>(),
        ),
    ] {
        assert_eq!(page(text, needle).ranges, expected, "{text:?} {needle:?}");
    }
}
#[test]
fn differential_normalized_counts_and_utf8_boundaries() {
    let atoms = [
        "A",
        "a",
        "é",
        "e\u{301}",
        "İ",
        "\u{307}",
        "\u{315}\u{300}",
        "\u{1100}",
        "\u{1161}",
        "\u{11a8}",
        "😀",
        "中",
        "ß",
        " ",
    ];
    let normalize = |s: &str| {
        s.nfc()
            .flat_map(char::to_lowercase)
            .nfc()
            .collect::<String>()
    };
    for a in atoms {
        for b in atoms {
            for c in atoms {
                let text = format!("{a}{b}{c}");
                let normalized = normalize(&text);
                for needle in atoms {
                    let expected = normalized.matches(&normalize(needle)).count();
                    let result = page(&text, needle);
                    assert_eq!(
                        result.total, expected,
                        "text={text:?}, needle={needle:?}, normalized={normalized:?}"
                    );
                    assert_eq!(result.ranges.len(), expected);
                    for range in result.ranges {
                        assert!(
                            range.start < range.end
                                && text.is_char_boundary(range.start)
                                && text.is_char_boundary(range.end)
                        );
                    }
                }
            }
        }
    }
}
#[test]
fn range_paging_is_bounded_and_counts_are_not_deduplicated() {
    let cancel = AtomicBool::new(false);
    let query = Query::new("a", &cancel).unwrap();
    let result = query.ranges(&"a".repeat(20_000), 123, 7, &cancel).unwrap();
    assert_eq!(result.total, 20_000);
    assert_eq!(result.next, Some(130));
    assert_eq!(
        result.ranges,
        (123..130).map(|n| n..n + 1).collect::<Vec<_>>()
    );
    assert!(query.ranges("a", 0, 0, &cancel).is_err());
    assert!(query.ranges("a", 0, MAX_RANGE_PAGE + 1, &cancel).is_err());
    assert_eq!(query.ranges("a", 5, 1, &cancel).unwrap().next, None);
}
#[test]
fn limits_cancellation_empty_and_exact_whitespace() {
    let cancel = AtomicBool::new(false);
    assert!(Query::new(&"x".repeat(257), &cancel).is_err());
    assert!(Query::new(&format!("a{}", "\u{301}".repeat(9000)), &cancel).is_err());
    assert!(Query::new(&"x".repeat(256), &cancel).is_ok());
    assert!(
        Query::new("a", &cancel)
            .unwrap()
            .ranges(&format!("a{}", "\u{301}".repeat(16385)), 0, 1, &cancel)
            .is_err()
    );
    assert_eq!(page("a  b", "a b").total, 0);
    assert_eq!(page("abc", "").total, 0);
    cancel.store(true, Ordering::Release);
    assert!(Query::new("a", &cancel).is_err());
    assert!(
        Query::new("a", &AtomicBool::new(false))
            .unwrap()
            .ranges("abc", 0, 1, &cancel)
            .is_err()
    );
}
#[test]
fn reordered_nonoverlapping_matches_may_have_overlapping_source_envelopes() {
    // Two normalized dots originate from one composed scalar plus a reordered
    // source mark. Ranges retain every normalized hit rather than deduplicating.
    let result = page("İ\u{323}", "\u{307}");
    assert_eq!(result.total, 1);
    assert_eq!(result.ranges, std::iter::once(0..2).collect::<Vec<_>>());
}

#[test]
fn all_unicode_scalars_differential_normalization() {
    // Chunking by ASCII separators prevents unrelated scalars from composing;
    // dedicated combination/reordering/Hangul tests cover cross-scalar cases.
    let cancel = AtomicBool::new(false);
    for start in (0..=0x10ffff).step_by(1024) {
        let text: String = (start..(start + 1024).min(0x110000))
            .filter_map(char::from_u32)
            .flat_map(|ch| [ch, ' '])
            .collect();
        let source = text.char_indices().flat_map(|(start, ch)| {
            let mut out = Vec::new();
            decompose_canonical(ch, |part| {
                out.push(Mapped {
                    ch: part,
                    span: start..start + ch.len_utf8(),
                })
            });
            out
        });
        let lowered = Nfc::new(source).flat_map(|part| {
            let mut out = Vec::new();
            for lower in part.ch.to_lowercase() {
                decompose_canonical(lower, |ch| {
                    out.push(Mapped {
                        ch,
                        span: part.span.clone(),
                    })
                });
            }
            out
        });
        let actual: String = Nfc::new(lowered).map(|part| part.ch).collect();
        let expected: String = text.nfc().flat_map(char::to_lowercase).nfc().collect();
        assert_eq!(actual, expected, "scalar chunk {start:x}");
        search_check_cancel(&cancel).unwrap();
    }
}

#[test]
fn range_counts_match_existing_search_copy_snapshot_counts() {
    use crate::conversation_content::Snapshot;
    use bello_agent_core::{Message, Session};
    use std::sync::Arc;
    for text in [
        "aaa",
        "İİ",
        "Cafe\u{301} CAFÉ",
        "a\u{315}\u{300}",
        "\u{1100}\u{1161}\u{11a8}",
        "😀 a  a",
    ] {
        let mut session = Session::new();
        session.messages.push(Message {
            task_root_id: None,
            user_content: None,
            id: "record".into(),
            role: "assistant".into(),
            text: text.into(),
            reasoning: String::new(),
            replay_eligible: true,
            state: "complete".into(),
            usage: serde_json::Value::Null,
            model: None,
            tool_record: None,
            compaction: None,
        });
        let snapshot = Snapshot::new(Arc::new(session));
        for query in ["a", "aa", "i", "\u{307}", "café", "à", "각", "😀", "a a"] {
            let search = snapshot.search(query, 0).unwrap();
            let count = search.hits.first().and_then(|hit| hit.count).unwrap_or(0);
            assert_eq!(page(text, query).total, count, "{text:?} {query:?}");
        }
    }
}

#[test]
fn randomized_multiscalar_normalization_matches_library() {
    let mut seed = 0x87c341af94d28731u64;
    let mut random = || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    let special = [
        'a', 'A', 'İ', 'é', '\u{315}', '\u{300}', '\u{307}', '\u{323}', '\u{0344}', '\u{0345}',
        '\u{1100}', '\u{1161}', '\u{11a8}', '\u{0f73}', '\u{0f77}', '\u{0301}',
    ];
    for _ in 0..25_000 {
        let mut text = String::new();
        for _ in 0..20 {
            let n = random();
            let ch = if n % 3 == 0 {
                char::from_u32((n % 0x110000) as u32).unwrap_or('x')
            } else {
                special[(n as usize) % special.len()]
            };
            text.push(ch);
        }
        let source = text.char_indices().flat_map(|(start, ch)| {
            let mut out = Vec::new();
            decompose_canonical(ch, |part| {
                out.push(Mapped {
                    ch: part,
                    span: start..start + ch.len_utf8(),
                })
            });
            out
        });
        let lowered = Nfc::new(source).flat_map(|part| {
            let mut out = Vec::new();
            for lower in part.ch.to_lowercase() {
                decompose_canonical(lower, |ch| {
                    out.push(Mapped {
                        ch,
                        span: part.span.clone(),
                    })
                });
            }
            out
        });
        let actual: String = Nfc::new(lowered).map(|part| part.ch).collect();
        let expected: String = text.nfc().flat_map(char::to_lowercase).nfc().collect();
        assert_eq!(actual, expected, "{text:?}");
    }
}
