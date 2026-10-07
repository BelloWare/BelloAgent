//! Source RowActionsView / ConversationPane.copyMessage: copy current plain text
//! by stable chat/message identity, never a render-time streaming snapshot.
use crate::{AgentView, Palette};
use bello_agent_core::{Controller, Session};
use gpui::{prelude::*, *};
use std::sync::{Arc, Weak};

pub(crate) const ACTION_BAND_HEIGHT: f32 = 22.;
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct MessageKey {
    chat_id: String,
    message_id: String,
}
impl MessageKey {
    pub(crate) fn new(chat_id: String, message_id: String) -> Self {
        Self {
            chat_id,
            message_id,
        }
    }
    pub(crate) fn hover_group(&self) -> SharedString {
        format!("transcript-row-{}-{}", self.chat_id, self.message_id).into()
    }
}
fn copy_text(session: &Session, key: &MessageKey) -> Option<String> {
    if session.id != key.chat_id {
        return None;
    }
    let mut matches = session
        .messages
        .iter()
        .filter(|message| message.id == key.message_id);
    let message = matches.next()?;
    // Legacy text snapshots can contain duplicate IDs. Never resolve an
    // ambiguous live identity to the first row's text after a reorder.
    if matches.next().is_some() {
        return None;
    }
    Some(message.text.clone())
}
fn write_current_copy(session: &Session, key: &MessageKey, cx: &mut App) {
    if let Some(text) = copy_text(session, key) {
        cx.write_to_clipboard(ClipboardItem::new_string(text));
    }
}
impl AgentView {
    pub(crate) fn active_transcript_matches(
        &self,
        chat_id: &str,
        controller: &Weak<Controller>,
    ) -> bool {
        self.record.id == chat_id
            && self.session.id == chat_id
            && controller
                .upgrade()
                .is_some_and(|controller| Arc::ptr_eq(&controller, &self.controller))
    }

    pub(crate) fn copy_transcript_message(
        &self,
        key: &MessageKey,
        controller: &Weak<Controller>,
        cx: &mut Context<Self>,
    ) {
        if !self.active_transcript_matches(&key.chat_id, controller) {
            return;
        }
        write_current_copy(&self.controller.snapshot_shared(), key, cx);
    }
}

// Rendering this band must not read the parent entity: doing so would make a
// retained transcript depend on unrelated composer/queue notifications.
pub(crate) fn transcript_copy_band(
    key: MessageKey,
    palette: Palette,
    parent: WeakEntity<AgentView>,
    controller: Weak<Controller>,
) -> Div {
    let group = key.hover_group();
    let dark = palette.dark;
    // Source TranscriptPalette tokens and TranscriptPillStyle spacing.
    let muted = rgb(if dark { 0xa9a59b } else { 0x6e6a61 });
    let text = rgb(if dark { 0xeceae4 } else { 0x1d1b17 });
    let border = rgba(if dark { 0xffffff29 } else { 0x00000024 });
    let hover_fill = rgba(if dark { 0xffffff14 } else { 0x0000000f });
    let selector = format!("copy-pill-{}", key.message_id);
    let band_selector = format!("copy-band-{}", key.message_id);
    let copy = div()
        .debug_selector(|| selector)
        .id(SharedString::from(format!(
            "copy-{}-{}",
            key.chat_id, key.message_id
        )))
        .relative()
        .text_size(px(11.))
        .line_height(px(14.))
        .font_weight(FontWeight::MEDIUM)
        .text_color(muted)
        .px(px(10.))
        .py(px(4.))
        .rounded_full()
        .cursor_pointer()
        .invisible()
        .group_hover(group, |style| style.visible())
        .hover(move |style| style.text_color(text).bg(hover_fill))
        .active(|style| style.opacity(0.7))
        .on_click(move |_, _, cx| {
            let _ = parent.update(cx, |view, cx| {
                view.copy_transcript_message(&key, &controller, cx);
            });
        })
        .child("Copy")
        // Swift strokes an overlay: the border must not add two pixels
        // to the 14px line + 8px padding inside the reserved 22px band.
        .child(
            div()
                .absolute()
                .inset_0()
                .rounded_full()
                .border_1()
                .border_color(border),
        );
    // Source puts a spacer before non-user actions; both role bands trail.
    div()
        .debug_selector(|| band_selector)
        .w_full()
        .h(px(ACTION_BAND_HEIGHT))
        .flex_shrink_0()
        .flex()
        .items_center()
        .justify_end()
        .gap(px(4.))
        .child(copy)
}

#[cfg(test)]
mod tests {
    use super::{MessageKey, copy_text};
    use bello_agent_core::{Message, Session};
    fn message(id: &str, role: &str, text: &str) -> Message {
        Message {
            user_content: None,
            id: id.into(),
            role: role.into(),
            text: text.into(),
            reasoning: "not clipboard text".into(),
            replay_eligible: true,
            state: "complete".into(),
            usage: serde_json::Value::Null,
            model: None,
            tool_record: None,
            compaction: None,
        }
    }
    #[test]
    fn copies_exact_unicode_whitespace_and_markdown_source_for_each_role() {
        for role in ["user", "assistant", "system"] {
            let mut session = Session::new();
            let original = "  **source**\n你好 👩🏽‍💻 e\u{301}\r\n\t";
            session.messages.push(message("message", role, original));
            let key = MessageKey::new(session.id.clone(), "message".into());
            assert_eq!(copy_text(&session, &key).as_deref(), Some(original));
        }
    }
    #[test]
    fn image_only_copy_never_exposes_retained_payload_or_attachment_path() {
        let mut session = Session::new();
        let mut row = message("image-row", "user", "");
        row.user_content = Some(std::sync::Arc::new(
            bello_agent_core::user_content::UserContent::new(
                "",
                vec![bello_agent_core::attachments::AttachmentRecord {
                    id: uuid::Uuid::new_v4().to_string(),
                    path: "/private/selected.gif".into(),
                    sha256: "a".repeat(64),
                    bytes: 3,
                    mime_type: "image/gif".into(),
                }],
                vec![bello_agent_core::tool_content::ContentBlock::Image {
                    data: "YWJj".into(),
                    mime_type: "image/gif".into(),
                }],
            )
            .unwrap(),
        ));
        assert_eq!(crate::composer_attachments::message_label(&row), "Image");
        session.messages.push(row);
        let key = MessageKey::new(session.id.clone(), "image-row".into());
        assert_eq!(copy_text(&session, &key).as_deref(), Some(""));
    }
    #[test]
    fn same_key_reads_latest_streaming_text_and_empty_text_is_not_placeholder() {
        let mut session = Session::new();
        session.messages.push(message("reply", "assistant", ""));
        session.messages[0].state = "streaming".into();
        let key = MessageKey::new(session.id.clone(), "reply".into());
        assert_eq!(copy_text(&session, &key).as_deref(), Some(""));
        session.messages[0].text = "first".into();
        assert_eq!(copy_text(&session, &key).as_deref(), Some("first"));
        session.messages[0].text.push_str(" then latest");
        assert_eq!(
            copy_text(&session, &key).as_deref(),
            Some("first then latest")
        );
    }
    #[test]
    fn chat_switch_and_removed_message_never_copy_another_identity() {
        let mut session = Session::new();
        session
            .messages
            .push(message("same-id", "user", "original"));
        let key = MessageKey::new(session.id.clone(), "same-id".into());
        let mut other = Session::new();
        other
            .messages
            .push(message("same-id", "user", "another chat"));
        assert_eq!(copy_text(&other, &key), None);
        session.messages.clear();
        assert_eq!(copy_text(&session, &key), None);
        session
            .messages
            .push(message("replacement", "user", "replacement text"));
        assert_eq!(copy_text(&session, &key), None);
    }
    #[test]
    fn duplicate_live_identity_never_copies_another_rows_text() {
        let mut session = Session::new();
        session.messages = vec![
            message("duplicate", "user", "first"),
            message("unique", "assistant", "exact unique"),
            message("duplicate", "assistant", "second 日本語"),
        ];
        let ambiguous = MessageKey::new(session.id.clone(), "duplicate".into());
        assert_eq!(copy_text(&session, &ambiguous), None);
        session.messages.reverse();
        assert_eq!(copy_text(&session, &ambiguous), None);
        let unique = MessageKey::new(session.id.clone(), "unique".into());
        assert_eq!(
            copy_text(&session, &unique).as_deref(),
            Some("exact unique")
        );
    }
    #[gpui::test]
    fn clipboard_uses_latest_text_and_missing_identity_leaves_existing_clipboard(
        cx: &mut gpui::TestAppContext,
    ) {
        let mut session = Session::new();
        session
            .messages
            .push(message("reply", "assistant", "first"));
        let key = MessageKey::new(session.id.clone(), "reply".into());
        cx.update(|cx| super::write_current_copy(&session, &key, cx));
        assert_eq!(
            cx.read(|cx| cx.read_from_clipboard().unwrap().text()),
            Some("first".into())
        );
        session.messages[0].text = "latest 你好\n👩🏽‍💻".into();
        cx.update(|cx| super::write_current_copy(&session, &key, cx));
        let latest = cx.read(|cx| cx.read_from_clipboard().unwrap().text());
        assert_eq!(latest.as_deref(), Some("latest 你好\n👩🏽‍💻"));
        session.messages.push(message("reply", "user", "ambiguous"));
        cx.update(|cx| super::write_current_copy(&session, &key, cx));
        assert_eq!(
            cx.read(|cx| cx.read_from_clipboard().unwrap().text()),
            latest
        );
        session.messages.clear();
        cx.update(|cx| super::write_current_copy(&session, &key, cx));
        assert_eq!(
            cx.read(|cx| cx.read_from_clipboard().unwrap().text()),
            latest
        );
    }
    #[gpui::test]
    fn minimum_window_keeps_multiline_assistant_visible_after_resize(
        cx: &mut gpui::TestAppContext,
    ) {
        use crate::{AgentView, LaunchState};
        use bello_agent_core::{
            Controller, SessionStore,
            workspace::{ChatRecord, DraftRecord, WorkspaceStore},
        };
        use std::sync::{Arc, Mutex};
        let dir = tempfile::tempdir().unwrap();
        let project = std::fs::canonicalize(dir.path()).unwrap();
        let path = project.join("session.json");
        let mut store = SessionStore::open(&path).unwrap();
        store
            .transact(|session| {
                session.messages = vec![
                    message("user", "user", "User copy: hello 你好 👩🏽‍💻\nsecond line"),
                    message(
                        "assistant",
                        "assistant",
                        "**Copy source**\nAssistant reply with é and 日本語.\nTrailing spaces  ",
                    ),
                ];
                Ok(())
            })
            .unwrap();
        let snapshot = store.snapshot();
        let draft = snapshot.messages[1].text.clone();
        let launch = LaunchState {
            controller: Controller::new(store, None).unwrap(),
            project: project.clone(),
            workspace: Arc::new(Mutex::new(
                WorkspaceStore::open(project.join("session.workspace.json"), &project).unwrap(),
            )),
            record: ChatRecord {
                materialization:
                    bello_agent_core::workspace::ChatMaterialization::CheckpointRequired,
                sidebar_order: None,
                pinned_at: None,
                archived_at: None,
                tool_mode: Default::default(),
                connection_id: None,
                id: snapshot.id,
                title: snapshot.title,
                snapshot: path,
            },
            draft: DraftRecord {
                attachments: Vec::new(),
                text: draft,
                ..Default::default()
            },
            pending: false,
        };
        let window = cx.add_window(|window, cx| AgentView::new(launch, window, cx));
        let mut visual = gpui::VisualTestContext::from_window(window.into(), cx);
        for (width, height) in [(1180., 812.), (920., 600.), (1280., 900.), (920., 600.)] {
            visual.simulate_resize(gpui::size(gpui::px(width), gpui::px(height)));
            cx.run_until_parked();
            let text = visual.debug_bounds("transcript-text-assistant").unwrap();
            let user = visual.debug_bounds("transcript-row-user").unwrap();
            let band = visual.debug_bounds("copy-band-user").unwrap();
            let pill = visual.debug_bounds("copy-pill-user").unwrap();
            assert!(
                text.size.height >= gpui::px(63.),
                "assistant lines clipped: {text:?}"
            );
            assert!(
                text.bottom() < gpui::px(400.),
                "assistant displaced outside visible transcript at {width}x{height}: {text:?}"
            );
            assert_eq!(
                user.bottom(),
                band.bottom(),
                "row retains phantom intrinsic height: {user:?}, {band:?}"
            );
            assert_eq!(band.size.height, gpui::px(super::ACTION_BAND_HEIGHT));
            assert_eq!(pill.size.height, gpui::px(super::ACTION_BAND_HEIGHT));
        }
    }
}
