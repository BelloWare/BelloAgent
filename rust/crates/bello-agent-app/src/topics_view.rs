//! Explicit topic editor/move sheet. The target chat is captured on open;
//! keyboard ownership never falls through to the conversation composer.
use crate::{AgentView, topics::TopicAction};
use bello_workbench_ui::{EditorEvent, EditorView};
use gpui::{prelude::*, *};
use std::collections::BTreeMap;

#[derive(Clone)]
pub(crate) enum TopicControl {
    Save,
    Close,
    Rename(String),
    Delete(String),
    ConfirmDelete(String, u64),
    Move(Option<String>, u64),
    New,
}
pub(crate) struct TopicPanel {
    pub token: uuid::Uuid,
    pub editor: Entity<EditorView>,
    pub renaming: Option<(String, u64)>,
    pub deleting: Option<(String, u64)>,
    pub notice: Option<String>,
    target: String,
    project: std::path::PathBuf,
    binding: Option<crate::workspace_lifetime::WindowBinding>,
    focuses: BTreeMap<String, FocusHandle>,
    actions: Vec<(TopicControl, FocusHandle)>,
    _events: Subscription,
}
impl AgentView {
    pub(crate) fn open_topics(
        &mut self,
        target: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.shutting_down
            || self.project_actions_blocked()
            || !self.records.iter().any(|r| r.id == target)
        {
            return;
        }
        if let Some(menu) = self.sidebar_menu.take() {
            self.sidebar_activity_hold.end_menu(menu.token);
        }
        self.compaction_menu = None;
        self.skill_picker = None;
        let editor = cx.new(|cx| {
            let mut editor = EditorView::new(String::new(), window, cx);
            editor.set_composer_mode(cx);
            editor.set_appearance(Self::composer_style(self.palette), cx);
            editor.set_read_only(self.topic_write.is_some(), cx);
            editor
        });
        editor.read(cx).focus(window);
        let events = cx.subscribe(&editor, |_, _, event, cx| {
            if matches!(event, EditorEvent::Changed) {
                cx.notify();
            }
        });
        self.topic_panel = Some(TopicPanel {
            token: uuid::Uuid::new_v4(),
            editor,
            renaming: None,
            deleting: None,
            notice: None,
            target: target.into(),
            project: self.project.clone(),
            binding: self.window_binding,
            focuses: BTreeMap::new(),
            actions: Vec::new(),
            _events: events,
        });
        cx.notify();
    }
    pub(crate) fn activate_topic_control(
        &mut self,
        token: uuid::Uuid,
        control: TopicControl,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(panel) = self.topic_panel.as_ref().filter(|panel| {
            panel.token == token
                && panel.project == self.project
                && panel.binding == self.window_binding
        }) else {
            return;
        };
        if matches!(control, TopicControl::Close) {
            self.topic_panel = None;
            self.focus_visible_composer(window, cx);
            cx.notify();
            return;
        }
        if self.topic_write.is_some() {
            return;
        }
        let target = panel.target.clone();
        let action = match control {
            TopicControl::Save => {
                if panel.editor.read(cx).has_marked_text() {
                    return;
                }
                let title = panel.editor.read(cx).text().to_owned();
                Some(if let Some((id, revision)) = &panel.renaming {
                    TopicAction::Rename(id.clone(), title, *revision)
                } else {
                    TopicAction::Create(title)
                })
            }
            TopicControl::Rename(id) => {
                let Some(topic) = self.topics.iter().find(|topic| topic.id == id).cloned() else {
                    return;
                };
                let panel = self.topic_panel.as_mut().unwrap();
                panel.token = uuid::Uuid::new_v4();
                panel.renaming = Some((id, topic.revision));
                panel.deleting = None;
                panel
                    .editor
                    .update(cx, |editor, cx| editor.set_text(topic.title, cx));
                panel.editor.read(cx).focus(window);
                None
            }
            TopicControl::New => {
                let panel = self.topic_panel.as_mut().unwrap();
                panel.token = uuid::Uuid::new_v4();
                panel.renaming = None;
                panel.deleting = None;
                panel
                    .editor
                    .update(cx, |editor, cx| editor.set_text(String::new(), cx));
                panel.editor.read(cx).focus(window);
                None
            }
            TopicControl::Delete(id) => {
                if let Some(topic) = self.topics.iter().find(|topic| topic.id == id) {
                    let panel = self.topic_panel.as_mut().unwrap();
                    panel.token = uuid::Uuid::new_v4();
                    panel.deleting = Some((id, topic.revision));
                }
                None
            }
            TopicControl::ConfirmDelete(id, revision) => {
                if panel.deleting.as_ref() != Some(&(id.clone(), revision)) {
                    return;
                }
                Some(TopicAction::Delete(id, revision))
            }
            TopicControl::Move(destination, revision) => self
                .records
                .iter()
                .find(|record| record.id == target)
                .map(|_| TopicAction::Move(target, destination, revision)),
            TopicControl::Close => None,
        };
        if let Some(action) = action {
            self.apply_topic_action(action, cx);
        }
        cx.notify();
    }
    pub(crate) fn topics_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(panel) = &self.topic_panel else {
            return;
        };
        let token = panel.token;
        let key = &event.keystroke;
        if key.key == "enter" && panel.editor.read(cx).has_marked_text() {
            return;
        }
        let command =
            key.modifiers.platform || (cfg!(target_os = "linux") && key.modifiers.control);
        if key.key == "escape" || (command && key.key == "w") {
            self.activate_topic_control(token, TopicControl::Close, window, cx);
            self.cancelled_prompt_key = Some(key.key.clone());
            cx.stop_propagation();
        } else if key.key == "tab" {
            let mut focuses = vec![panel.editor.read(cx).focus_handle(cx)];
            focuses.extend(panel.actions.iter().map(|(_, focus)| focus.clone()));
            let index = focuses
                .iter()
                .position(|focus| focus.is_focused(window))
                .unwrap_or(0);
            let next = if key.modifiers.shift {
                (index + focuses.len() - 1) % focuses.len()
            } else {
                (index + 1) % focuses.len()
            };
            focuses[next].focus(window);
            cx.stop_propagation();
        } else if !command && matches!(key.key.as_str(), "enter" | "space") {
            if let Some(action) = panel
                .actions
                .iter()
                .find(|(_, focus)| focus.is_focused(window))
                .map(|(action, _)| action.clone())
            {
                if !event.is_held {
                    self.activate_topic_control(token, action, window, cx);
                }
                self.cancelled_prompt_key = Some(key.key.clone());
                cx.stop_propagation();
            } else if key.key == "enter" {
                if !event.is_held && !panel.editor.read(cx).has_marked_text() {
                    self.activate_topic_control(token, TopicControl::Save, window, cx);
                }
                self.cancelled_prompt_key = Some(key.key.clone());
                cx.stop_propagation();
            }
        }
    }
    pub(crate) fn topics_element(
        &mut self,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<Div> {
        let mut panel = self.topic_panel.take()?;
        if panel.project != self.project || panel.binding != self.window_binding {
            return None;
        }
        let p = self.palette;
        let enabled = self.topic_write.is_none() && !self.known_catalog_uncertainty;
        panel.actions.clear();
        let mut body = div()
            .id("topics-panel")
            .debug_selector(|| "topics-panel".into())
            .w(px(620.))
            .max_w(px((f32::from(window.viewport_size().width) - 32.).max(200.)))
            .max_h(px(
                (f32::from(window.viewport_size().height) - 40.).max(200.)
            ))
            .p(px(18.))
            .rounded(px(12.))
            .bg(rgb(p.surface))
            .border_1()
            .border_color(p.hairline())
            .flex()
            .flex_col()
            .gap(px(10.))
            .occlude()
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation());
        let close = panel.button(
            "topics-close".into(),
            "Close",
            TopicControl::Close,
            true,
            self.palette,
            cx,
        );
        body = body.child(
            div()
                .flex()
                .items_center()
                .child(div().flex_1().text_size(px(18.)).child("Project topics"))
                .child(close),
        );
        let target_title = self
            .records
            .iter()
            .find(|record| record.id == panel.target)
            .map(|record| self.sidebar_title(record).to_owned())
            .unwrap_or_else(|| "Chat no longer available".into());
        body = body.child(div().debug_selector(|| "topics-chat-title".into()).text_size(px(12.)).truncate().child(format!("Move chat: {}", target_title.replace('\n', " "))))
            .child(div().text_size(px(12.)).child("Topics organize this project's chats. Deleting a topic keeps its chats at project top level."));
        let save_label = if panel.renaming.is_some() {
            "Save name"
        } else {
            "Create topic"
        };
        let save = panel.button(
            "topics-save".into(),
            save_label,
            TopicControl::Save,
            enabled,
            p,
            cx,
        );
        let new = panel.button(
            "topics-new".into(),
            "New topic",
            TopicControl::New,
            enabled,
            p,
            cx,
        );
        body = body
            .child(
                div()
                    .text_size(px(12.))
                    .child("Topic title (up to 120 characters)"),
            )
            .child(
                div()
                    .id("topics-title")
                    .debug_selector(|| "topics-title".into())
                    .h(px(48.))
                    .border_1()
                    .border_color(p.hairline())
                    .child(panel.editor.clone()),
            )
            .child(div().flex().gap(px(8.)).child(save).child(new));
        let target_revision = self
            .records
            .iter()
            .find(|record| record.id == panel.target)
            .map_or(0, |record| record.topic_revision);
        let top = panel.button(
            "topics-top-level".into(),
            "Move to project top level",
            TopicControl::Move(None, target_revision),
            enabled,
            p,
            cx,
        );
        let mut list = div()
            .id("topics-list")
            .overflow_y_scroll()
            .min_h_0()
            .flex()
            .flex_col()
            .gap(px(8.))
            .child(top);
        for topic in &self.topics {
            let rename = panel.button(
                format!("topic-rename-{}", topic.id),
                "Rename",
                TopicControl::Rename(topic.id.clone()),
                enabled,
                p,
                cx,
            );
            let delete = panel.button(
                format!("topic-delete-{}", topic.id),
                "Delete…",
                TopicControl::Delete(topic.id.clone()),
                enabled,
                p,
                cx,
            );
            let move_here = panel.button(
                format!("topic-move-{}", topic.id),
                "Move here",
                TopicControl::Move(Some(topic.id.clone()), target_revision),
                enabled,
                p,
                cx,
            );
            list = list.child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(5.))
                    .p(px(8.))
                    .border_1()
                    .border_color(p.hairline())
                    .child(div().text_size(px(13.)).child(topic.title.clone()))
                    .child(
                        div()
                            .flex()
                            .gap(px(8.))
                            .child(move_here)
                            .child(rename)
                            .child(delete),
                    ),
            );
        }
        body = body.child(list);
        if let Some((id, revision)) = panel.deleting.clone() {
            let confirm = panel.button(
                "topics-confirm-delete".into(),
                "Delete topic, keep chats",
                TopicControl::ConfirmDelete(id, revision),
                enabled,
                p,
                cx,
            );
            body = body.child(confirm);
        }
        if let Some(notice) = &panel.notice {
            body = body.child(div().text_size(px(12.)).child(notice.clone()));
        }
        self.topic_panel = Some(panel);
        Some(
            div()
                .absolute()
                .inset_0()
                .bg(rgba(0x00000088))
                .flex()
                .items_center()
                .justify_center()
                .occlude()
                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .child(body),
        )
    }
}
impl TopicPanel {
    fn button(
        &mut self,
        id: String,
        label: &'static str,
        action: TopicControl,
        enabled: bool,
        p: crate::Palette,
        cx: &mut Context<AgentView>,
    ) -> Stateful<Div> {
        let focus = self
            .focuses
            .entry(id.clone())
            .or_insert_with(|| cx.focus_handle())
            .clone();
        if enabled {
            self.actions.push((action.clone(), focus.clone()));
        }
        let token = self.token;
        let selector = id.clone();
        div()
            .id(SharedString::from(id))
            .debug_selector(move || selector.clone())
            .px(px(8.))
            .py(px(5.))
            .rounded(px(5.))
            .border_1()
            .border_color(p.hairline())
            .text_size(px(12.))
            .child(label)
            .when(enabled, |button| {
                button
                    .track_focus(&focus)
                    .tab_index(0)
                    .cursor_pointer()
                    .focus(|style| style.border_color(rgb(p.accent)))
            })
            .when(!enabled, |button| button.opacity(0.45))
            .on_click(cx.listener(move |view, _, window, cx| {
                if enabled {
                    view.activate_topic_control(token, action.clone(), window, cx);
                }
            }))
    }
}
