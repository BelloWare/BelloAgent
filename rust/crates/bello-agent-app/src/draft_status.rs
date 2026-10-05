//! Revision fences and exact-message ownership for asynchronous draft saves.

#[derive(Debug)]
pub(crate) struct DraftSaveStatus {
    confirmed_revision: u64,
    failure: Option<DraftSaveFailure>,
}

#[derive(Debug)]
struct DraftSaveFailure {
    revision: u64,
    message: String,
}

impl DraftSaveStatus {
    pub(crate) fn new(confirmed_revision: u64) -> Self {
        Self {
            confirmed_revision,
            failure: None,
        }
    }

    /// A durable acknowledgement also covers older saves, even if their
    /// callbacks have not arrived. Only retire an error this save owns.
    pub(crate) fn confirm(&mut self, revision: u64, visible_error: &mut Option<String>) {
        self.confirmed_revision = self.confirmed_revision.max(revision);
        if self
            .failure
            .as_ref()
            .is_some_and(|failure| failure.revision <= self.confirmed_revision)
        {
            let failure = self.failure.take().expect("covered draft failure");
            if visible_error.as_ref() == Some(&failure.message) {
                *visible_error = None;
            }
        }
    }

    /// Keep the latest unconfirmed failure without replacing an unrelated
    /// notice that appeared after this save was scheduled.
    pub(crate) fn fail(
        &mut self,
        revision: u64,
        raw_error: String,
        visible_error: &mut Option<String>,
        expected_visible: &Option<String>,
    ) {
        if revision <= self.confirmed_revision
            || self
                .failure
                .as_ref()
                .is_some_and(|failure| revision < failure.revision)
        {
            return;
        }
        let owns_visible = self
            .failure
            .as_ref()
            .is_some_and(|failure| visible_error.as_ref() == Some(&failure.message));
        let message = format!("Draft could not be saved: {raw_error}");
        if visible_error.is_none() || visible_error == expected_visible || owns_visible {
            *visible_error = Some(message.clone());
        }
        self.failure = Some(DraftSaveFailure { revision, message });
    }
}

#[cfg(test)]
mod tests {
    use super::DraftSaveStatus;

    fn notice(error: &str) -> Option<String> {
        Some(format!("Draft could not be saved: {error}"))
    }

    #[test]
    fn confirmation_clears_the_matching_covered_error() {
        let mut status = DraftSaveStatus::new(3);
        let mut visible = None;
        status.fail(4, "disk full".into(), &mut visible, &None);
        assert_eq!(visible, notice("disk full"));

        status.confirm(5, &mut visible);

        assert_eq!(visible, None);
        assert_eq!(status.confirmed_revision, 5);
        assert!(status.failure.is_none());
    }

    #[test]
    fn newer_confirmation_fences_a_delayed_old_failure() {
        let mut status = DraftSaveStatus::new(3);
        let mut visible = None;
        status.confirm(5, &mut visible);

        status.fail(4, "delayed failure".into(), &mut visible, &None);

        assert_eq!(visible, None);
        assert!(status.failure.is_none());
    }

    #[test]
    fn newer_failure_survives_an_older_confirmation() {
        let mut status = DraftSaveStatus::new(3);
        let mut visible = None;
        status.fail(5, "new failure".into(), &mut visible, &None);

        status.confirm(4, &mut visible);

        assert_eq!(visible, notice("new failure"));
        assert_eq!(status.failure.as_ref().unwrap().revision, 5);
        assert_eq!(status.confirmed_revision, 4);
    }

    #[test]
    fn confirmation_does_not_clear_an_unrelated_error() {
        let mut status = DraftSaveStatus::new(3);
        let mut visible = None;
        status.fail(4, "disk full".into(), &mut visible, &None);
        visible = Some("Provider disconnected".into());

        status.confirm(4, &mut visible);

        assert_eq!(visible.as_deref(), Some("Provider disconnected"));
        assert!(status.failure.is_none());
    }

    #[test]
    fn confirmation_does_not_clear_a_message_with_the_same_prefix() {
        let mut status = DraftSaveStatus::new(3);
        let mut visible = None;
        status.fail(4, "disk full".into(), &mut visible, &None);
        visible = notice("another operation failed");

        status.confirm(4, &mut visible);

        assert_eq!(visible, notice("another operation failed"));
        assert!(status.failure.is_none());
    }

    #[test]
    fn delayed_failure_preserves_a_new_unrelated_error_but_is_tracked() {
        let mut status = DraftSaveStatus::new(3);
        let expected = Some("Previous notice".into());
        let mut visible = Some("Provider disconnected".into());

        status.fail(4, "disk full".into(), &mut visible, &expected);

        assert_eq!(visible.as_deref(), Some("Provider disconnected"));
        let failure = status.failure.as_ref().unwrap();
        assert_eq!(failure.revision, 4);
        assert_eq!(Some(failure.message.clone()), notice("disk full"));
        status.confirm(4, &mut visible);
        assert_eq!(visible.as_deref(), Some("Provider disconnected"));
        assert!(status.failure.is_none());
    }

    #[test]
    fn failure_can_replace_the_unchanged_scheduled_error() {
        let mut status = DraftSaveStatus::new(3);
        let expected = Some("Previous notice".into());
        let mut visible = expected.clone();

        status.fail(4, "disk full".into(), &mut visible, &expected);

        assert_eq!(visible, notice("disk full"));
    }

    #[test]
    fn failure_can_fill_an_empty_error_after_the_scheduled_error_is_gone() {
        let mut status = DraftSaveStatus::new(3);
        let expected = Some("Previous notice".into());
        let mut visible = None;

        status.fail(4, "disk full".into(), &mut visible, &expected);

        assert_eq!(visible, notice("disk full"));
    }

    #[test]
    fn newer_failure_can_replace_an_owned_error_from_another_callback() {
        let mut status = DraftSaveStatus::new(3);
        let mut visible = None;
        status.fail(4, "old failure".into(), &mut visible, &None);

        status.fail(5, "new failure".into(), &mut visible, &None);

        assert_eq!(visible, notice("new failure"));
        assert_eq!(status.failure.as_ref().unwrap().revision, 5);
    }

    #[test]
    fn older_failure_does_not_replace_a_newer_failure() {
        let mut status = DraftSaveStatus::new(3);
        let mut visible = None;
        status.fail(5, "new failure".into(), &mut visible, &None);
        let expected = visible.clone();

        status.fail(4, "old failure".into(), &mut visible, &expected);

        assert_eq!(visible, notice("new failure"));
        assert_eq!(status.failure.as_ref().unwrap().revision, 5);
    }

    #[test]
    fn older_failure_does_not_replace_a_newer_hidden_failure() {
        let mut status = DraftSaveStatus::new(3);
        let mut visible = Some("Provider disconnected".into());
        status.fail(5, "new failure".into(), &mut visible, &None);
        visible = None;

        status.fail(4, "old failure".into(), &mut visible, &None);

        assert_eq!(visible, None);
        let failure = status.failure.as_ref().unwrap();
        assert_eq!(failure.revision, 5);
        assert_eq!(Some(failure.message.clone()), notice("new failure"));
    }

    #[test]
    fn same_revision_confirmation_wins_in_either_callback_order() {
        for confirm_first in [false, true] {
            let mut status = DraftSaveStatus::new(3);
            let mut visible = None;
            if confirm_first {
                status.confirm(4, &mut visible);
                status.fail(4, "disk full".into(), &mut visible, &None);
            } else {
                status.fail(4, "disk full".into(), &mut visible, &None);
                status.confirm(4, &mut visible);
            }

            assert_eq!(visible, None);
            assert_eq!(status.confirmed_revision, 4);
            assert!(status.failure.is_none());
        }
    }

    #[test]
    fn confirmation_revision_never_moves_backwards() {
        let mut status = DraftSaveStatus::new(3);
        let mut visible = None;
        status.confirm(6, &mut visible);
        status.confirm(4, &mut visible);
        status.fail(5, "already covered".into(), &mut visible, &None);

        assert_eq!(status.confirmed_revision, 6);
        assert_eq!(visible, None);
        assert!(status.failure.is_none());
    }

    #[test]
    fn initial_durable_revision_fences_older_and_equal_failures() {
        let mut status = DraftSaveStatus::new(3);
        let mut visible = None;
        status.fail(2, "old failure".into(), &mut visible, &None);
        status.fail(3, "already durable".into(), &mut visible, &None);
        assert_eq!(visible, None);
        assert!(status.failure.is_none());

        status.fail(4, "new failure".into(), &mut visible, &None);
        assert_eq!(visible, notice("new failure"));
    }

    #[test]
    fn revision_boundaries_do_not_require_incrementing() {
        let mut status = DraftSaveStatus::new(0);
        let mut visible = None;
        status.fail(0, "already durable".into(), &mut visible, &None);
        assert_eq!(visible, None);

        status.fail(u64::MAX, "last revision".into(), &mut visible, &None);
        assert_eq!(visible, notice("last revision"));
        status.confirm(u64::MAX, &mut visible);
        status.fail(u64::MAX, "late failure".into(), &mut visible, &None);
        assert_eq!(visible, None);
        assert_eq!(status.confirmed_revision, u64::MAX);
        assert!(status.failure.is_none());
    }
}
