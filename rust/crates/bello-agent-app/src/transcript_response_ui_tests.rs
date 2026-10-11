//! Swift's response header line and the display modes: one strip above each
//! response saying what it did, which folds the response to that line; the
//! Normal display keeps finished turns loose, Compact folds them.
use super::turn_fold_ui::{bounds, finished_turns, host_rows, with_calls};
use super::*;
use crate::transcript_view::TranscriptDisplayMode;

fn headers(child: &Entity<TranscriptView>, cx: &TestAppContext) -> Vec<(String, String, bool)> {
    cx.read(|cx| child.read(cx).response_headers())
}

fn normal(child: &Entity<TranscriptView>, visual: &mut VisualTestContext) {
    visual.update(|window, cx| {
        child.update(cx, |view, cx| {
            view.set_display_mode(TranscriptDisplayMode::Normal, window, cx)
        })
    });
    visual.run_until_parked();
}

const WORKING: &str = "transcript-response-Message(\"working\")";

#[gpui::test]
fn each_response_says_what_it_did_on_its_own_strip(cx: &mut TestAppContext) {
    let (_directory, mut visual, child, _) = host_rows(finished_turns(), RunState::Paused, cx);
    normal(&child, &mut visual);
    assert_eq!(
        headers(&child, cx),
        vec![
            (
                "Message(\"working\")".to_owned(),
                "Reasoned · 3 tool calls".to_owned(),
                false
            ),
            (
                "Message(\"answer\")".to_owned(),
                "Reasoned".to_owned(),
                false
            ),
            (
                "Message(\"welcome\")".to_owned(),
                "Answered".to_owned(),
                false
            ),
        ]
    );
    // A response with work inside has a 20-point strip 4 under its top; a
    // plain answer's is 14 points, at the top.
    let strip = bounds(&mut visual, WORKING).expect("the working reply's strip");
    assert_eq!(strip.size.height, px(20.));
    let row = bounds(&mut visual, "transcript-row-working").unwrap();
    assert_eq!(strip.top() - row.top(), px(4.));
    let plain = bounds(&mut visual, "transcript-response-Message(\"welcome\")").unwrap();
    assert_eq!(plain.size.height, px(14.));
    assert_eq!(
        plain.top(),
        bounds(&mut visual, "transcript-row-welcome").unwrap().top()
    );
    // The words stand under the strip, where the row's top room was.
    let words = bounds(&mut visual, "transcript-text-welcome").unwrap();
    assert!(words.top() >= plain.bottom());
}

#[gpui::test]
fn pressing_the_strip_folds_the_response_to_one_line_and_back(cx: &mut TestAppContext) {
    let (_directory, mut visual, child, _) = host_rows(finished_turns(), RunState::Paused, cx);
    normal(&child, &mut visual);
    let cards = cx.read(|cx| child.read(cx).tool_card_selectors()).len();
    assert_eq!(cards, 3);
    let answer = bounds(&mut visual, "transcript-row-answer").unwrap();
    let strip = bounds(&mut visual, WORKING).unwrap();
    visual.simulate_click(strip.center(), Modifiers::none());
    cx.run_until_parked();
    assert_eq!(
        headers(&child, cx)[0],
        (
            "Message(\"working\")".to_owned(),
            "Reasoned · 3 tool calls · 5 parts folded".to_owned(),
            true
        )
    );
    // The reply's words, thought and cards are gone; its strip is the row.
    assert!(
        cx.read(|cx| child.read(cx).tool_card_selectors())
            .is_empty()
    );
    assert!(
        !row_ids(&child, cx)
            .iter()
            .any(|id| id.starts_with("@tool:Message(\"working\")"))
    );
    let row = bounds(&mut visual, "transcript-row-working").unwrap();
    assert_eq!(row.size.height, px(4. + 20. + 10.));
    let folded = bounds(&mut visual, "transcript-row-answer").unwrap();
    assert!(folded.top() < answer.top() - px(3. * 24.));

    let strip = bounds(&mut visual, WORKING).unwrap();
    visual.simulate_click(strip.center(), Modifiers::none());
    cx.run_until_parked();
    assert!(!headers(&child, cx)[0].2);
    assert_eq!(cx.read(|cx| child.read(cx).tool_card_selectors()).len(), 3);
    assert_eq!(
        bounds(&mut visual, "transcript-row-answer").unwrap().top(),
        answer.top(),
        "opening gives the room back"
    );
}

#[gpui::test]
fn a_response_folded_from_inside_draws_its_cards_closed_and_keeps_them(cx: &mut TestAppContext) {
    let (_directory, mut visual, child, _) = host_rows(finished_turns(), RunState::Paused, cx);
    normal(&child, &mut visual);
    let card = cx.read(|cx| child.read(cx).tool_card_selectors()[0].clone());
    let line = bounds(&mut visual, &format!("{card}-disclosure")).unwrap();
    visual.simulate_click(line.center(), Modifiers::none());
    cx.run_until_parked();
    assert!(bounds(&mut visual, &format!("{card}-card")).is_some());
    let fold = |folded: bool, visual: &mut VisualTestContext| {
        visual.update(|window, cx| {
            child.update(cx, |view, cx| {
                view.set_every_turn_folded(folded, window, cx)
            })
        })
    };
    // Normal display: no turn folds, but every response folds inside.
    let answer = bounds(&mut visual, "transcript-row-answer").unwrap();
    assert_eq!(fold(true, &mut visual), 0);
    cx.run_until_parked();
    let closed = bounds(&mut visual, "transcript-row-answer").unwrap();
    assert!(closed.top() < answer.top() - px(40.), "the card closed");
    assert_eq!(
        cx.read(|cx| child.read(cx).tool_card_selectors()).len(),
        3,
        "the cards keep their lines"
    );
    fold(false, &mut visual);
    cx.run_until_parked();
    assert_eq!(
        bounds(&mut visual, "transcript-row-answer").unwrap().top(),
        answer.top(),
        "what the reader opened comes back"
    );
}

#[gpui::test]
fn the_display_mode_switches_between_loose_and_folded_turns(cx: &mut TestAppContext) {
    let (_directory, mut visual, child, _) = host_rows(finished_turns(), RunState::Paused, cx);
    assert_eq!(
        cx.read(|cx| child.read(cx).display_mode()),
        TranscriptDisplayMode::Compact
    );
    assert_eq!(cx.read(|cx| child.read(cx).fold_lines()).len(), 1);
    // Folded, the answer's own strip goes with its work.
    assert_eq!(
        headers(&child, cx),
        vec![(
            "Message(\"welcome\")".to_owned(),
            "Answered".to_owned(),
            false
        )]
    );
    assert!(bounds(&mut visual, "transcript-text-working").is_none());
    normal(&child, &mut visual);
    assert!(cx.read(|cx| child.read(cx).fold_lines()).is_empty());
    assert!(bounds(&mut visual, "transcript-text-working").is_some());
    assert_eq!(headers(&child, cx).len(), 3);
    visual.update(|window, cx| {
        child.update(cx, |view, cx| {
            view.set_display_mode(TranscriptDisplayMode::Compact, window, cx)
        })
    });
    cx.run_until_parked();
    assert_eq!(cx.read(|cx| child.read(cx).fold_lines()).len(), 1);
    assert!(!row_ids(&child, cx).contains(&"working".to_owned()));
}

#[gpui::test]
fn fold_this_turn_follows_the_reader_and_unfolds_the_response_too(cx: &mut TestAppContext) {
    let (_directory, mut visual, child, _) = host_rows(finished_turns(), RunState::Paused, cx);
    // The page's one turn is the one to fold.
    let turn = |folded: bool, visual: &mut VisualTestContext| {
        visual.update(|window, cx| {
            child.update(cx, |view, cx| {
                view.set_focused_turn_folded(folded, window, cx)
            })
        })
    };
    assert!(turn(false, &mut visual));
    cx.run_until_parked();
    assert!(cx.read(|cx| child.read(cx).fold_lines())[0].1);
    assert!(bounds(&mut visual, "transcript-text-working").is_some());
    assert!(turn(true, &mut visual));
    cx.run_until_parked();
    assert!(!cx.read(|cx| child.read(cx).fold_lines())[0].1);
    // Folding the reader's response to its line, then unfolding the turn,
    // leaves the response open.
    let response = |collapsed: bool, visual: &mut VisualTestContext| {
        visual.update(|window, cx| {
            child.update(cx, |view, cx| {
                view.set_focused_response_collapsed(collapsed, window, cx)
            })
        })
    };
    // The whole page in view follows its end: the newest is the reader's.
    normal(&child, &mut visual);
    assert!(response(true, &mut visual));
    cx.run_until_parked();
    let collapsed: Vec<bool> = headers(&child, cx).iter().map(|h| h.2).collect();
    assert_eq!(collapsed, [false, false, true]);
    assert!(turn(false, &mut visual));
    cx.run_until_parked();
    assert!(headers(&child, cx).iter().all(|h| !h.2));
}

#[gpui::test]
fn a_reply_that_only_called_carries_its_strip_on_its_first_card(cx: &mut TestAppContext) {
    crate::transcript_view::loose_turns_for_test();
    let mut rows = vec![message("question", "user", "Run it.")];
    rows.extend(with_calls(
        message("caller", "assistant", ""),
        &[("c0", "bash"), ("c1", "bash")],
    ));
    let (_directory, mut visual, child, _) = host_rows(rows, RunState::Paused, cx);
    assert_eq!(
        headers(&child, cx),
        vec![(
            "Message(\"caller\")".to_owned(),
            "2 tool calls".to_owned(),
            false
        )]
    );
    let strip = bounds(&mut visual, "transcript-response-Message(\"caller\")").unwrap();
    let card = cx.read(|cx| child.read(cx).tool_card_selectors()[0].clone());
    let line = bounds(&mut visual, &format!("{card}-disclosure")).unwrap();
    assert!(line.top() >= strip.bottom());
    visual.simulate_click(strip.center(), Modifiers::none());
    cx.run_until_parked();
    assert_eq!(
        headers(&child, cx)[0].1,
        "2 tool calls · 2 parts folded".to_owned()
    );
    // The first card's row is the strip alone; the second draws nothing.
    assert_eq!(cx.read(|cx| child.read(cx).tool_card_selectors()).len(), 1);
    let index = row_ids(&child, cx)
        .iter()
        .position(|id| id.starts_with("@tool"))
        .unwrap();
    let row = scroll(&child, cx).bounds_for_item(index).unwrap();
    assert_eq!(row.size.height, px(4. + 20. + 10.));
}

#[gpui::test]
fn a_streaming_reply_with_nothing_yet_has_no_strip(cx: &mut TestAppContext) {
    crate::transcript_view::loose_turns_for_test();
    let mut waiting = message("waiting", "assistant", "");
    waiting.state = "streaming".into();
    let rows = vec![message("question", "user", "Hello?"), waiting];
    let (_directory, _visual, child, _) = host_rows(rows, RunState::Running, cx);
    assert!(headers(&child, cx).is_empty());
}

/// `finished_turns` under other ids, so a page can hold it twice.
fn renamed(prefix: &str) -> Vec<Message> {
    finished_turns()
        .into_iter()
        .map(|mut message| {
            message.id = format!("{prefix}{}", message.id);
            if let Some(bello_agent_core::tool_history::ToolRecord::Result(result)) =
                &mut message.tool_record
            {
                result.assistant_id = format!("{prefix}{}", result.assistant_id);
            }
            message
        })
        .collect()
}

#[gpui::test]
fn the_fold_commands_act_on_the_turn_the_reader_is_on(cx: &mut TestAppContext) {
    let mut rows = finished_turns();
    rows.extend((0..30).map(|n| {
        message(
            &format!("filler-{n}"),
            if n % 2 == 0 { "user" } else { "assistant" },
            "Between the turns.",
        )
    }));
    rows.extend(renamed("b-"));
    let (_directory, mut visual, child, _) = host_rows(rows, RunState::Paused, cx);
    let open = |cx: &TestAppContext| -> Vec<bool> {
        cx.read(|cx| child.read(cx).fold_lines())
            .into_iter()
            .map(|(_, open)| open)
            .collect()
    };
    assert_eq!(open(cx), [false, false]);
    // Read from the top, the first turn is the reader's.
    visual.update(|window, cx| {
        child.update(cx, |view, cx| {
            view.set_focused_turn_folded(false, window, cx)
        })
    });
    cx.run_until_parked();
    assert_eq!(open(cx), [true, false]);
    // At the end of the page, the newest is.
    child.update(cx, |view, cx| view.follow_latest(cx));
    cx.run_until_parked();
    visual.update(|window, cx| {
        child.update(cx, |view, cx| {
            view.set_focused_turn_folded(false, window, cx)
        })
    });
    cx.run_until_parked();
    assert_eq!(open(cx), [true, true]);
    // Scrolled to the first answer, its question is the latest above: its
    // fold is the reader's.
    let at = |id: &str, cx: &TestAppContext| {
        row_ids(&child, cx)
            .iter()
            .position(|row| row == id)
            .unwrap()
    };
    jump_to(&child, at("answer", cx), 0., cx);
    visual.update(|window, cx| {
        child.update(cx, |view, cx| {
            view.set_focused_turn_folded(true, window, cx)
        })
    });
    cx.run_until_parked();
    assert_eq!(open(cx), [false, true]);
    // Under a question of the reader's that folded nothing, there is no
    // turn to fold, as in Swift.
    jump_to(&child, at("filler-10", cx), 0., cx);
    visual.update(|window, cx| {
        child.update(cx, |view, cx| {
            view.set_focused_turn_folded(true, window, cx)
        })
    });
    cx.run_until_parked();
    assert_eq!(open(cx), [false, true]);
}
