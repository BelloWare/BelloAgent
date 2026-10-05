//! The source QueuedMessageDetail popover in Workspaces/QueuePanel.swift.
//! Reading a queued message does not acquire a hold or touch its composer.
use crate::{AgentView, theme::Palette};
use bello_agent_core::{Lane, Session};
use bello_workbench_ui::{EditorAppearance, EditorView};
use gpui::{prelude::*, *};

pub(crate) const WIDTH: f32 = 340.;
pub(crate) const MAX_TEXT_HEIGHT: f32 = 220.;
pub(crate) const GONE_TEXT: &str = "This message is no longer waiting.";

#[derive(Debug, PartialEq, Eq)]
struct Content {
    title: &'static str,
    text: String,
    model: String,
    reasoning: String,
}

fn content(session: &Session, chat_id: &str, turn_id: &str) -> Option<Content> {
    if session.id != chat_id {
        return None;
    }
    let item = session.pending.iter().find(|item| item.id == turn_id)?;
    Some(Content {
        title: if item.lane == Lane::Steering {
            "Steering message"
        } else {
            "Follow-up"
        },
        text: item.text.clone(),
        model: item
            .model
            .clone()
            .unwrap_or_else(|| "Connection default".into()),
        reasoning: match item.effort.as_deref() {
            None => "Connection default".into(),
            Some("default") => "Model default".into(),
            Some(value) => {
                let mut chars = value.chars();
                chars.next().map_or_else(String::new, |first| {
                    first.to_uppercase().collect::<String>() + chars.as_str()
                })
            }
        },
    })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DetailKey {
    pub(crate) chat_id: String,
    turn_id: String,
    presentation: uuid::Uuid,
}
impl DetailKey {
    fn new(chat_id: String, turn_id: String) -> Self {
        Self {
            chat_id,
            turn_id,
            presentation: uuid::Uuid::new_v4(),
        }
    }
}

pub(crate) struct QueueDetail {
    pub(crate) key: DetailKey,
    pub(crate) anchor: Point<Pixels>,
    reader: Entity<EditorView>,
    previous_focus: Option<FocusHandle>,
    shown_text: String,
    palette: Palette,
}

impl QueueDetail {
    pub(crate) fn new(
        session: &Session,
        turn_id: String,
        anchor: Point<Pixels>,
        palette: Palette,
        window: &mut Window,
        cx: &mut Context<AgentView>,
    ) -> Self {
        let shown_text = content(session, &session.id, &turn_id)
            .map(|v| v.text)
            .unwrap_or_default();
        let previous_focus = window.focused(cx);
        let reader = cx.new(|cx| {
            let mut reader = EditorView::new(shown_text.clone(), window, cx);
            reader.set_appearance(Self::appearance(palette), cx);
            reader.set_read_only(true, cx);
            reader
        });
        reader.read(cx).focus(window);
        Self {
            key: DetailKey::new(session.id.clone(), turn_id),
            anchor,
            reader,
            previous_focus,
            shown_text,
            palette,
        }
    }

    fn appearance(p: Palette) -> EditorAppearance {
        EditorAppearance {
            font_family: if cfg!(target_os = "macos") {
                ".SystemUIFont"
            } else {
                "DejaVu Sans"
            }
            .into(),
            padding_x: 0.,
            padding_y: 0.,
            text: rgb(p.ink).into(),
            selection: p.accent_soft(),
            caret: rgb(p.accent).into(),
            ..EditorAppearance::plain()
        }
    }

    pub(crate) fn restore_focus(&self, window: &mut Window, cx: &App) {
        // An outside click or a newer focus choice must never be undone.
        if self.reader.read(cx).focus_handle(cx).is_focused(window)
            && let Some(previous) = &self.previous_focus
        {
            previous.focus(window);
        }
    }

    pub(crate) fn render(
        &mut self,
        session: &Session,
        p: Palette,
        window: &mut Window,
        cx: &mut Context<AgentView>,
    ) -> Div {
        let current = content(session, &self.key.chat_id, &self.key.turn_id);
        let text = current.as_ref().map(|v| v.text.as_str()).unwrap_or("");
        if text != self.shown_text {
            self.shown_text = text.to_owned();
            self.reader
                .update(cx, |reader, cx| reader.set_text(text.to_owned(), cx));
        }
        if self.palette != p {
            self.palette = p;
            self.reader.update(cx, |reader, cx| {
                reader.set_appearance(Self::appearance(p), cx)
            });
        }
        let mut body = div()
            .w(px(WIDTH))
            .p(px(16.))
            .rounded(px(12.))
            .bg(rgb(p.surface))
            .border_1()
            .border_color(p.hairline())
            .shadow_lg()
            .flex()
            .flex_col()
            .gap(px(8.));
        let Some(current) = current else {
            return body.child(
                div()
                    .text_size(px(13.))
                    .text_color(rgb(p.secondary))
                    .child(GONE_TEXT),
            );
        };
        let height = self
            .reader
            .update(cx, |reader, _| {
                reader.measured_content_height(WIDTH - 34., window)
            })
            .clamp(19., MAX_TEXT_HEIGHT);
        body = body
            .child(
                div()
                    .text_size(px(11.5))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(rgb(p.secondary))
                    .child(current.title),
            )
            .child(div().h(px(height)).child(self.reader.clone()))
            .child(div().h(px(1.)).bg(p.hairline()));
        for (label, value) in [("Model", current.model), ("Reasoning", current.reasoning)] {
            body = body.child(
                div()
                    .flex()
                    .items_start()
                    .gap(px(8.))
                    .text_size(px(11.5))
                    .child(div().text_color(rgb(p.secondary)).child(label))
                    .child(div().flex_1())
                    .child(div().max_w(px(220.)).text_color(rgb(p.ink)).child(value)),
            );
        }
        body
    }
}

#[cfg(test)]
mod tests {
    use super::{DetailKey, GONE_TEXT, MAX_TEXT_HEIGHT, WIDTH, content};
    use bello_agent_core::{Lane, Session, Submission};

    #[test]
    fn repeated_open_has_a_new_identity_for_escape_and_outside_dismissal() {
        let old = DetailKey::new("chat-a".into(), "turn-a".into());
        let reopened = DetailKey::new("chat-a".into(), "turn-a".into());
        let other_chat = DetailKey::new("chat-b".into(), "turn-a".into());
        assert_ne!(old, reopened);
        assert_ne!(old, other_chat);
        assert_eq!(reopened, reopened.clone());
    }

    #[test]
    fn reads_full_unicode_text_and_captured_choices_without_changing_session() {
        let mut session = Session::new();
        let mut item = Submission::new("世界 😀\n".repeat(2000), Lane::FollowUp);
        item.model = Some("captured-model".into());
        item.effort = Some("high".into());
        session.pending.push(item.clone());
        let before = serde_json::to_value(&session).unwrap();
        let shown = content(&session, &session.id, &item.id).unwrap();
        assert_eq!(shown.text, item.text);
        assert_eq!(shown.model, "captured-model");
        assert_eq!(shown.reasoning, "High");
        assert_eq!(shown.title, "Follow-up");
        assert_eq!(serde_json::to_value(&session).unwrap(), before);
    }

    #[test]
    fn stable_identity_survives_reorder_and_refreshes_rewrite() {
        let mut session = Session::new();
        let a = Submission::new("A".into(), Lane::FollowUp);
        let b = Submission::new("B".into(), Lane::FollowUp);
        session.pending = vec![a.clone(), b];
        session.pending.reverse();
        assert_eq!(content(&session, &session.id, &a.id).unwrap().text, "A");
        session.pending[1].text = "New A".into();
        assert_eq!(content(&session, &session.id, &a.id).unwrap().text, "New A");
        session.pending.pop();
        assert!(content(&session, &session.id, &a.id).is_none());
        assert_eq!(GONE_TEXT, "This message is no longer waiting.");
    }

    #[test]
    fn switching_chat_cannot_leak_a_same_id_message() {
        let mut first = Session::new();
        let mut second = Session::new();
        let item = Submission::new("First chat".into(), Lane::FollowUp);
        first.pending.push(item.clone());
        second.pending.push(item.clone());
        second.pending[0].text = "Other chat".into();
        assert!(content(&second, &first.id, &item.id).is_none());
        assert_eq!(
            content(&first, &first.id, &item.id).unwrap().text,
            "First chat"
        );
    }

    #[test]
    fn repeated_lookup_of_delivered_message_never_reuses_another_turn() {
        let mut session = Session::new();
        let item = Submission::new("Old".into(), Lane::FollowUp);
        session.pending.push(item.clone());
        assert!(content(&session, &session.id, &item.id).is_some());
        session.pending = vec![Submission::new("Replacement".into(), Lane::FollowUp)];
        for _ in 0..3 {
            assert!(content(&session, &session.id, &item.id).is_none());
        }
    }

    #[test]
    fn defaults_and_steering_are_honest_without_invented_capacity() {
        let mut session = Session::new();
        let item = Submission::new("Guide".into(), Lane::Steering);
        session.pending.push(item.clone());
        let shown = content(&session, &session.id, &item.id).unwrap();
        assert_eq!(shown.title, "Steering message");
        assert_eq!(shown.model, "Connection default");
        assert_eq!(shown.reasoning, "Connection default");
        session.pending[0].effort = Some("default".into());
        assert_eq!(
            content(&session, &session.id, &item.id).unwrap().reasoning,
            "Model default"
        );
        assert_eq!(WIDTH, 340.);
        assert_eq!(MAX_TEXT_HEIGHT, 220.);
    }
}
