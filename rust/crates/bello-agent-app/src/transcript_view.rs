//! Retained per-chat projection of the populated transcript. Only explicit
//! presentation inputs invalidate it; parent access is reserved for events.
use crate::{AgentView, Palette, layout, transcript_actions};
use bello_agent_core::{Controller, Session};
use gpui::{prelude::*, *};
use std::sync::{Arc, Weak};

pub(crate) struct TranscriptInput {
    pub controller: Weak<Controller>,
    pub chat_id: String,
    pub session: Arc<Session>,
    pub visible_messages: usize,
    pub palette: Palette,
    pub pane_width: f32,
    pub loading: bool,
    pub load_failed: bool,
}

pub(crate) struct TranscriptView {
    parent: WeakEntity<AgentView>,
    input: TranscriptInput,
    scroll: ScrollHandle,
    #[cfg(test)]
    render_count: usize,
}

impl TranscriptView {
    pub(crate) fn new(parent: WeakEntity<AgentView>, input: TranscriptInput) -> Self {
        Self {
            parent,
            input,
            scroll: ScrollHandle::new(),
            #[cfg(test)]
            render_count: 0,
        }
    }

    pub(crate) fn update_inputs(&mut self, input: TranscriptInput, cx: &mut Context<Self>) {
        if Weak::ptr_eq(&self.input.controller, &input.controller)
            && self.input.chat_id == input.chat_id
            && Arc::ptr_eq(&self.input.session, &input.session)
            && self.input.visible_messages == input.visible_messages
            && self.input.palette == input.palette
            && self.input.pane_width == input.pane_width
            && self.input.loading == input.loading
            && self.input.load_failed == input.load_failed
        {
            return;
        }
        self.input = input;
        cx.notify();
    }

    #[cfg(test)]
    pub(crate) fn render_count(&self) -> usize {
        self.render_count
    }

    #[cfg(test)]
    pub(crate) fn scroll_handle(&self) -> ScrollHandle {
        self.scroll.clone()
    }

    // Same tokens as AgentView::button, without reading the parent entity.
    fn button(&self, id: impl Into<ElementId>, label: impl Into<SharedString>) -> Stateful<Div> {
        let p = self.input.palette;
        div()
            .id(id)
            .px(px(10.))
            .py(px(5.))
            .rounded(px(8.))
            .border_1()
            .border_color(p.hairline())
            .bg(rgb(p.surface))
            .text_size(px(11.5))
            .text_color(rgb(p.secondary))
            .cursor_pointer()
            .hover(move |d| d.bg(p.fill()))
            .child(label.into())
    }
}

impl Render for TranscriptView {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        #[cfg(test)]
        {
            self.render_count += 1;
        }
        let p = self.input.palette;
        // The parent's cached outer element owns flex sizing. The scroll root
        // fills that allocated viewport and keeps the original content geometry.
        let mut transcript = div()
            .id("transcript")
            .debug_selector(|| "queue-measured-transcript".into())
            .w_full()
            .h_full()
            .min_h_0()
            .overflow_y_scroll()
            .track_scroll(&self.scroll)
            .px(px(24.))
            .pb(px(13.))
            .flex()
            .flex_col()
            .gap(px(16.));
        if self.input.loading {
            transcript = transcript.child(
                div()
                    .py(px(24.))
                    .text_color(rgb(p.secondary))
                    .child("Preparing…"),
            );
        } else if self.input.load_failed {
            let parent = self.parent.clone();
            let controller = self.input.controller.clone();
            let chat_id = self.input.chat_id.clone();
            transcript = transcript.child(
                self.button("retry-chat-load", "Retry opening chat")
                    .on_click(move |_, _, cx| {
                        let _ = parent.update(cx, |view, cx| {
                            if view.active_transcript_matches(&chat_id, &controller) {
                                view.load_chat(&chat_id, cx);
                            }
                        });
                    }),
            );
        }
        let start = self
            .input
            .session
            .messages
            .len()
            .saturating_sub(self.input.visible_messages);
        if start > 0 {
            let parent = self.parent.clone();
            let controller = self.input.controller.clone();
            let chat_id = self.input.chat_id.clone();
            transcript = transcript.child(
                self.button("earlier", format!("Show earlier messages ({start})"))
                    .on_click(move |_, _, cx| {
                        let _ = parent.update(cx, |view, cx| {
                            if view.active_transcript_matches(&chat_id, &controller) {
                                view.visible_messages = view.visible_messages.saturating_add(100);
                                cx.notify();
                            }
                        });
                    }),
            );
        }
        for message in self.input.session.messages.iter().skip(start) {
            let user = message.role == "user";
            let mut body = div()
                .min_w_0()
                .when(!user, |d| d.w_full())
                .max_w(px(640.))
                .flex()
                .flex_col()
                .gap(px(6.))
                .when(user, |d| {
                    d.w(px(layout::user_bubble_width(self.input.pane_width)))
                        .px(px(14.))
                        .py(px(9.))
                        .rounded(px(14.))
                        .bg(rgb(p.user))
                });
            if !message.reasoning.is_empty() {
                body = body.child(
                    div()
                        .text_size(px(12.))
                        .text_color(rgb(p.secondary))
                        .child(message.reasoning.clone()),
                );
            }
            body = body.child(
                div()
                    .debug_selector(|| format!("transcript-text-{}", message.id))
                    .min_w_0()
                    .max_w_full()
                    .text_size(px(14.5))
                    .line_height(px(21.))
                    .child(if message.text.is_empty() && message.state == "streaming" {
                        "Generating response…".into()
                    } else {
                        message.text.clone()
                    }),
            );
            if message.state == "interrupted" {
                body = body.child(
                    div()
                        .text_size(px(11.5))
                        .text_color(rgb(p.secondary))
                        .child("Interrupted"),
                );
            }
            let key =
                transcript_actions::MessageKey::new(self.input.chat_id.clone(), message.id.clone());
            let group = key.hover_group();
            let actions = transcript_actions::transcript_copy_band(
                key,
                p,
                self.parent.clone(),
                self.input.controller.clone(),
            );
            transcript = transcript.child(
                div()
                    .group(group)
                    .debug_selector(|| format!("transcript-row-{}", message.id))
                    // Keep a single content-sized scroll row. A nested
                    // auto-height flex wrapper can retain an oversized intrinsic
                    // height after resize and push subsequent messages away.
                    .w_full()
                    .max_w(px(840.))
                    .mx_auto()
                    .min_w_0()
                    .flex_shrink_0()
                    .pt(px(12.))
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .child(
                        div()
                            .w_full()
                            .min_w_0()
                            .flex()
                            .when(user, |d| d.justify_end().pl(px(40.)))
                            .child(body),
                    )
                    .child(actions),
            );
        }
        transcript
    }
}
