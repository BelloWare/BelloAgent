//! Source contract: apps/macos/PiApp/Workspaces/QueuePanel.swift.
//! Pure presentation policy; it never changes queue order or dispatches input.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum QueueTiming {
    Editing,
    Failed,
    Paused,
    Running,
    Idle,
}

impl QueueTiming {
    pub(crate) fn new(editing: bool, failed: bool, paused: bool, running: bool) -> Self {
        if editing {
            Self::Editing
        } else if failed {
            Self::Failed
        } else if paused {
            Self::Paused
        } else if running {
            Self::Running
        } else {
            Self::Idle
        }
    }

    pub(crate) fn header(self, count: usize) -> String {
        let status = match self {
            Self::Editing => "Paused while a message is edited",
            Self::Failed => "Paused after the run failed",
            Self::Paused => "Paused",
            Self::Running => "Waiting",
            Self::Idle => "Waiting to send",
        };
        format!("{status} · {count}")
    }

    pub(crate) fn steering(self) -> &'static str {
        match self {
            Self::Editing | Self::Failed | Self::Paused => "Steering · waits until resumed",
            // Rust has no production tool loop yet. Describe its actual
            // response boundary rather than promising the Swift tool batch.
            Self::Running | Self::Idle => "Steering · after current response boundary",
        }
    }

    pub(crate) fn follow_ups(self) -> &'static str {
        match self {
            Self::Editing | Self::Failed | Self::Paused => "Follow-ups · wait until resumed",
            Self::Running => "Follow-ups · when this run finishes",
            Self::Idle => "Follow-ups · next",
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct QueueRow {
    /// Index into the unchanged pending submissions, not the rendered order.
    pub(crate) source_index: usize,
    /// Only follow-ups are numbered, starting again at one after steering.
    pub(crate) follow_up_number: Option<usize>,
}

pub(crate) fn grouped_rows(steering: impl IntoIterator<Item = bool>) -> Vec<QueueRow> {
    let mut first = Vec::new();
    let mut follow_ups = Vec::new();
    for (source_index, is_steering) in steering.into_iter().enumerate() {
        if is_steering {
            first.push(QueueRow {
                source_index,
                follow_up_number: None,
            });
        } else {
            follow_ups.push(QueueRow {
                source_index,
                follow_up_number: Some(follow_ups.len() + 1),
            });
        }
    }
    first.extend(follow_ups);
    first
}

pub(crate) const ROW_HEIGHT: f32 = 30.;
pub(crate) const SECTION_HEIGHT: f32 = 22.;
const VISIBLE_ROWS: f32 = 3.5;
const TRANSCRIPT_RESERVE: f32 = 150.;
// QueuePanel.chrome is 58 + PiSpacing.sm; DesignSystem.swift defines sm as 8.
const CHROME_HEIGHT: f32 = 58. + 8.;
pub(crate) const FOOTER_HEIGHT: f32 = 36.;

/// Room left for the list after the measured composer, optional terminal,
/// transcript reserve, queue chrome, and footer. Zero terminal height means
/// no terminal. An unmeasured pane keeps the original unbounded initial layout.
/// Nonfinite measurements are likewise treated as unavailable.
pub(crate) fn room(pane: f32, composer: f32, terminal: f32) -> f32 {
    if pane <= 0. || !pane.is_finite() || !composer.is_finite() || !terminal.is_finite() {
        return f32::INFINITY;
    }
    pane - composer - terminal - TRANSCRIPT_RESERVE - CHROME_HEIGHT - FOOTER_HEIGHT
}

pub(crate) fn list_height(rows: usize, sections: usize, room: f32) -> f32 {
    let headings = sections as f32 * SECTION_HEIGHT;
    let content = rows as f32 * ROW_HEIGHT + headings;
    list_height_for_content(content, sections, room)
}

/// Approved narrow-row adaptation: only measured content changes; the source
/// three-and-a-half-row cap, available-room budget and52pt floor stay fixed.
pub(crate) fn list_height_for_content(content: f32, sections: usize, room: f32) -> f32 {
    let headings = sections as f32 * SECTION_HEIGHT;
    let content = if content.is_nan() {
        0.
    } else {
        content.max(0.)
    };
    // The half row signals scroll. Even with no available room, retain one
    // row and heading, but never grow a shorter list beyond its content.
    let cap = VISIBLE_ROWS * ROW_HEIGHT + headings;
    let room = if room.is_nan() { f32::INFINITY } else { room };
    content.min((ROW_HEIGHT + SECTION_HEIGHT).max(cap.min(room)))
}

/// Exact existing queue furniture: 16pt outer margins, 12pt padding and
/// 1pt borders on both sides, a 20pt collapse control and 8pt HStack gaps.
/// Inputs are shaped natural text widths, not character-count estimates.
pub(crate) fn header_label_widths(
    pane: f32,
    status: f32,
    hint: Option<f32>,
    action: Option<f32>,
) -> (f32, f32) {
    let safe = |value: f32| if value.is_finite() { value.max(0.) } else { 0. };
    let gaps = 2. + f32::from(hint.is_some()) + f32::from(action.is_some());
    let available = (safe(pane) - 58. - 20. - gaps * 8. - safe(action.unwrap_or(0.))).max(0.);
    let status = safe(status);
    let hint = safe(hint.unwrap_or(0.));
    let natural = status + hint;
    let scale = if natural > available && natural > 0. {
        available / natural
    } else {
        1.
    };
    (status * scale, hint * scale)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn holds_and_failures_override_running_for_every_flag_combination() {
        for flags in 0..16 {
            let edit = flags & 1 != 0;
            let failed = flags & 2 != 0;
            let paused = flags & 4 != 0;
            let running = flags & 8 != 0;
            let timing = QueueTiming::new(edit, failed, paused, running);
            let expected = if edit {
                QueueTiming::Editing
            } else if failed {
                QueueTiming::Failed
            } else if paused {
                QueueTiming::Paused
            } else if running {
                QueueTiming::Running
            } else {
                QueueTiming::Idle
            };
            assert_eq!(timing, expected);
            if edit || failed || paused {
                assert_eq!(timing.steering(), "Steering · waits until resumed");
                assert_eq!(timing.follow_ups(), "Follow-ups · wait until resumed");
            }
        }
    }

    #[test]
    fn status_copy_matches_original_states_without_promising_tools() {
        assert_eq!(
            QueueTiming::Editing.header(2),
            "Paused while a message is edited · 2"
        );
        assert_eq!(
            QueueTiming::Failed.header(2),
            "Paused after the run failed · 2"
        );
        assert_eq!(QueueTiming::Paused.header(2), "Paused · 2");
        assert_eq!(QueueTiming::Running.header(2), "Waiting · 2");
        assert_eq!(QueueTiming::Idle.header(2), "Waiting to send · 2");
        assert_eq!(
            QueueTiming::Running.follow_ups(),
            "Follow-ups · when this run finishes"
        );
        assert_eq!(QueueTiming::Idle.follow_ups(), "Follow-ups · next");
        assert!(
            QueueTiming::Running
                .steering()
                .contains("response boundary")
        );
        assert!(!QueueTiming::Running.steering().contains("tool"));
    }

    #[test]
    fn mixed_lanes_group_stably_without_mutating_pending_order() {
        let lanes = [false, true, false, true, false];
        let rows = grouped_rows(lanes);
        assert_eq!(
            rows.iter().map(|r| r.source_index).collect::<Vec<_>>(),
            [1, 3, 0, 2, 4]
        );
        assert_eq!(
            rows.iter().map(|r| r.follow_up_number).collect::<Vec<_>>(),
            [None, None, Some(1), Some(2), Some(3)]
        );
        assert_eq!(lanes, [false, true, false, true, false]);
    }

    #[test]
    fn empty_and_single_lane_queues_keep_identity_and_numbering() {
        assert!(grouped_rows([]).is_empty());
        assert_eq!(grouped_rows([true])[0].follow_up_number, None);
        assert_eq!(grouped_rows([false, false])[1].follow_up_number, Some(2));
        assert_eq!(grouped_rows([false, false])[1].source_index, 1);
    }

    #[test]
    fn list_cap_matches_original_row_and_section_geometry() {
        assert_eq!(ROW_HEIGHT, 30.);
        assert_eq!(SECTION_HEIGHT, 22.);
        assert_eq!(VISIBLE_ROWS, 3.5);
        assert_eq!(list_height(0, 0, f32::INFINITY), 0.);
        assert_eq!(list_height(1, 1, f32::INFINITY), 52.);
        assert_eq!(list_height(2, 2, f32::INFINITY), 104.);
        assert_eq!(list_height(4, 1, f32::INFINITY), 127.);
        assert_eq!(list_height(64, 2, f32::INFINITY), 149.);
    }

    #[test]
    fn room_preserves_the_original_transcript_chrome_and_footer_reserves() {
        assert_eq!(TRANSCRIPT_RESERVE, 150.);
        assert_eq!(CHROME_HEIGHT, 66.);
        assert_eq!(FOOTER_HEIGHT, 36.);
        assert_eq!(room(600., 0., 0.), 348.);
        assert_eq!(room(600., 96., 0.), 252.);
        assert_eq!(room(600., 220., 0.), 128.);
        assert_eq!(room(600., 220., 130.), -2.);
    }

    #[test]
    fn measured_room_limits_the_list_below_its_three_and_a_half_row_cap() {
        assert_eq!(list_height(64, 1, 500.), 127.);
        assert_eq!(list_height(64, 2, 500.), 149.);
        assert_eq!(list_height(64, 2, 128.), 128.);
        assert_eq!(list_height(64, 2, 100.), 100.);
        assert_eq!(list_height(64, 2, 52.), 52.);
        assert_eq!(list_height(64, 2, room(600., 220., 0.)), 128.);
    }

    #[test]
    fn tight_room_retains_a_row_and_heading_without_exceeding_content() {
        for room in [51., 0., -2., f32::NEG_INFINITY] {
            assert_eq!(list_height(64, 2, room), 52.);
            assert_eq!(list_height(1, 1, room), 52.);
            assert_eq!(list_height(1, 0, room), 30.);
            assert_eq!(list_height(0, 1, room), 22.);
            assert_eq!(list_height(0, 0, room), 0.);
        }
        assert_eq!(list_height(2, 1, 100.), 82.);
        assert_eq!(list_height(2, 2, 128.), 104.);
    }

    #[test]
    fn unmeasured_or_nonfinite_geometry_keeps_the_bounded_initial_list() {
        for pane in [0., -1., f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
            assert_eq!(room(pane, 96., 0.), f32::INFINITY);
            assert_eq!(list_height(64, 2, room(pane, 96., 0.)), 149.);
        }
        for invalid in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
            assert_eq!(room(600., invalid, 0.), f32::INFINITY);
            assert_eq!(room(600., 96., invalid), f32::INFINITY);
        }
        assert_eq!(list_height(64, 2, f32::NAN), 149.);
        assert_eq!(list_height(1, 1, f32::NAN), 52.);
        assert_eq!(list_height(0, 0, f32::NAN), 0.);
    }
    #[test]
    fn header_label_allocation_preserves_natural_width_and_counts_furniture_once() {
        assert_eq!(
            header_label_widths(800., 55., Some(80.), Some(82.)),
            (55., 80.)
        );
        let (status, hint) = header_label_widths(308., 55., Some(80.), Some(82.));
        assert!((status + hint - (308. - 58. - 20. - 32. - 82.)).abs() < 0.001);
        assert!((status / hint - 55. / 80.).abs() < 0.001);
        assert_eq!(header_label_widths(308., 55., None, Some(82.)), (55., 0.));
        assert_eq!(header_label_widths(308., 55., Some(80.), None), (55., 80.));
        assert_eq!(header_label_widths(0., 55., Some(80.), Some(82.)), (0., 0.));
        assert_eq!(header_label_widths(f32::NAN, 55., None, None), (0., 0.));
    }
    #[test]
    fn measured_wrapped_content_keeps_source_cap_room_and_floor() {
        assert_eq!(
            list_height_for_content(52., 1, f32::INFINITY),
            list_height(1, 1, f32::INFINITY)
        );
        assert_eq!(list_height_for_content(98., 1, f32::INFINITY), 98.);
        assert_eq!(list_height_for_content(98., 1, 80.), 80.);
        assert_eq!(list_height_for_content(98., 1, 0.), 52.);
        assert_eq!(list_height_for_content(900., 1, f32::INFINITY), 127.);
        assert_eq!(list_height_for_content(900., 2, f32::INFINITY), 149.);
        assert_eq!(list_height_for_content(0., 0, 0.), 0.);
    }
}
