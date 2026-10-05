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

pub(crate) fn list_height(rows: usize, sections: usize) -> f32 {
    // Match the original three-and-a-half row cap. The half row signals scroll.
    (rows as f32).min(3.5) * ROW_HEIGHT + sections as f32 * SECTION_HEIGHT
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
        assert_eq!(list_height(0, 0), 0.);
        assert_eq!(list_height(1, 1), 52.);
        assert_eq!(list_height(2, 2), 104.);
        assert_eq!(list_height(4, 1), 127.);
        assert_eq!(list_height(64, 2), 149.);
    }
}
