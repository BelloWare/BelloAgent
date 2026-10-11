//! Settings' sections and the transcript display preference: drafts, Save All,
//! Cancel and the unsaved-close question, as ProfileSettings.swift.
use super::*;
use crate::app_settings::{TranscriptDisplayMode as Mode, transcript_display};
use crate::connection_settings_view::{ConnectionConfirmation, SettingsSection};

fn presentation(
    root: &Entity<AgentView>,
    cx: &TestAppContext,
) -> crate::connection_settings_view::ConnectionSettingsPresentation {
    cx.read(|cx| root.read(cx).connections.presentation.clone())
}

#[gpui::test]
fn transcript_display_is_a_draft_until_save_all(cx: &mut TestAppContext) {
    let (_dir, _control, window, root) = fixture(cx);
    assert_eq!(
        presentation(&root, cx).section,
        SettingsSection::Connections
    );
    assert!(
        !presentation(&root, cx).allows(&Intent::SetTranscriptDisplay(Mode::Normal)),
        "only the Chats section sets it"
    );
    act(window, Intent::SelectSection(SettingsSection::Chats), cx);
    let shown = presentation(&root, cx);
    assert_eq!(shown.section, SettingsSection::Chats);
    assert_eq!(shown.transcript_display, Mode::Compact);
    assert!(!shown.allows(&Intent::SetTranscriptDisplay(Mode::Compact)));
    act(window, Intent::SetTranscriptDisplay(Mode::Normal), cx);
    let shown = presentation(&root, cx);
    assert!(shown.transcript_display_dirty && shown.dirty);
    cx.read(|cx| assert_eq!(transcript_display(cx), Mode::Compact, "not saved yet"));
    // Closing with the draft asks first; Keep Editing keeps it.
    act(window, Intent::RequestClose, cx);
    assert_eq!(
        presentation(&root, cx).confirmation,
        ConnectionConfirmation::Close
    );
    act(window, Intent::KeepEditing, cx);
    assert!(cx.read(|cx| root.read(cx).connections.open));
    // Cancel drops it; Settings opens next time on what was saved.
    act(window, Intent::Cancel, cx);
    assert!(cx.read(|cx| !root.read(cx).connections.open));
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    cx.run_until_parked();
    let shown = presentation(&root, cx);
    assert_eq!(
        shown.section,
        SettingsSection::Chats,
        "the open section is kept"
    );
    assert_eq!(shown.transcript_display, Mode::Compact);
    assert!(!shown.dirty);
    // Save All writes it and closes.
    act(window, Intent::SetTranscriptDisplay(Mode::Normal), cx);
    act(window, Intent::SaveAll, cx);
    assert!(cx.read(|cx| !root.read(cx).connections.open));
    cx.read(|cx| assert_eq!(transcript_display(cx), Mode::Normal));
    window
        .update(cx, |view, window, cx| view.open_connections(window, cx))
        .unwrap();
    cx.run_until_parked();
    let shown = presentation(&root, cx);
    assert_eq!(shown.transcript_display, Mode::Normal);
    assert!(!shown.dirty);
    // Discard on the close question restores the saved mode.
    act(window, Intent::SetTranscriptDisplay(Mode::Compact), cx);
    act(window, Intent::RequestClose, cx);
    act(window, Intent::DiscardAndClose, cx);
    cx.read(|cx| {
        assert_eq!(transcript_display(cx), Mode::Normal);
        assert_eq!(
            root.read(cx).connections.presentation.transcript_display,
            Mode::Normal
        );
    });
}

#[gpui::test]
fn sections_draw_their_own_content_and_mark_unsaved_edits(cx: &mut TestAppContext) {
    use gpui::{Modifiers, VisualTestContext, px, size};
    let (_dir, _control, window, root) = fixture(cx);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    visual.simulate_resize(size(px(1180.), px(840.)));
    cx.run_until_parked();
    for row in [
        "settings-section-connections",
        "settings-section-usage",
        "settings-section-chats",
        "settings-section-app",
    ] {
        assert!(visual.debug_bounds(row).is_some(), "{row}");
    }
    assert!(visual.debug_bounds("settings-connection-tabs").is_some());
    let click = |visual: &mut VisualTestContext, selector: &'static str| {
        let bounds = visual.debug_bounds(selector).expect(selector);
        visual.simulate_click(bounds.center(), Modifiers::none());
    };
    click(&mut visual, "settings-section-usage");
    cx.run_until_parked();
    assert_eq!(presentation(&root, cx).section, SettingsSection::Usage);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert!(visual.debug_bounds("settings-usage-notice").is_some());
    click(&mut visual, "settings-section-app");
    cx.run_until_parked();
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert!(visual.debug_bounds("settings-app-notice").is_some());
    click(&mut visual, "settings-section-chats");
    cx.run_until_parked();
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert!(visual.debug_bounds("settings-transcript-display").is_some());
    click(&mut visual, "settings-transcript-normal");
    cx.run_until_parked();
    let shown = presentation(&root, cx);
    assert_eq!(shown.transcript_display, Mode::Normal);
    assert!(shown.dirty);
    let mut visual = VisualTestContext::from_window(window.into(), cx);
    assert!(visual.debug_bounds("settings-unsaved").is_some());
    click(&mut visual, "settings-save");
    cx.run_until_parked();
    cx.read(|cx| {
        assert_eq!(transcript_display(cx), Mode::Normal);
        assert!(!root.read(cx).connections.open);
    });
}
