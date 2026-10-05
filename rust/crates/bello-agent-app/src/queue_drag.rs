//! QueuePanel.swift's follow-up-only move gesture and captured-order contract.
use crate::{AgentView, theme::Palette, workspace_lifetime::WindowBinding};
use bello_agent_core::{Controller, Lane};
use gpui::{prelude::*, *};
use std::{path::PathBuf, sync::Arc, time::Duration};

#[derive(Clone)]
pub(crate) struct QueueDrag {
    pub(crate) token: uuid::Uuid,
    pub(crate) chat_id: String,
    pub(crate) project: PathBuf,
    pub(crate) controller: Arc<Controller>,
    pub(crate) binding: Option<WindowBinding>,
    pub(crate) ids: Vec<String>,
    pub(crate) source: String,
    pub(crate) text: String,
    pub(crate) number: usize,
    pub(crate) palette: Palette,
    pub(crate) promotion: bool,
}

pub(crate) struct QueueDragState {
    drag: QueueDrag,
    pointer: Point<Pixels>,
    pub(crate) target: Option<(String, bool)>,
}

pub(crate) fn reordered(
    ids: &[String],
    source: &str,
    target: &str,
    after: bool,
) -> Option<Vec<String>> {
    let from = ids.iter().position(|id| id == source)?;
    let destination = ids.iter().position(|id| id == target)? + usize::from(after);
    let mut result = ids.to_vec();
    let item = result.remove(from);
    result.insert(destination - usize::from(from < destination), item);
    Some(result)
}

pub(crate) fn edge_step(pointer: Point<Pixels>, bounds: Bounds<Pixels>) -> Pixels {
    if !bounds.contains(&pointer) {
        return px(0.);
    }
    if pointer.y < bounds.top() + px(12.) {
        px(5.)
    } else if pointer.y > bounds.bottom() - px(12.) {
        px(-5.)
    } else {
        px(0.)
    }
}

impl AgentView {
    pub(crate) fn accepts_queue_drag(&self, drag: &QueueDrag) -> bool {
        self.record.id == drag.chat_id
            && self.project == drag.project
            && self.window_binding == drag.binding
            && Arc::ptr_eq(&self.controller, &drag.controller)
            && self.session.edit.is_none()
            && !self.shutting_down
    }

    pub(crate) fn queue_drag_payload(&self, source: &str, number: usize, text: &str) -> QueueDrag {
        QueueDrag {
            token: uuid::Uuid::new_v4(),
            chat_id: self.record.id.clone(),
            project: self.project.clone(),
            controller: self.controller.clone(),
            binding: self.window_binding,
            ids: self
                .session
                .pending
                .iter()
                .filter(|item| item.lane == Lane::FollowUp)
                .map(|item| item.id.clone())
                .collect(),
            source: source.into(),
            text: text
                .lines()
                .next()
                .unwrap_or("")
                .chars()
                .take(100)
                .collect(),
            number,
            palette: self.palette,
            promotion: crate::queue_actions::offers_promotion(&self.chat, source),
        }
    }

    pub(crate) fn start_queue_drag(
        &mut self,
        drag: &QueueDrag,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.accepts_queue_drag(drag) || self.queue_operation.is_some() || drag.ids.len() < 2 {
            return;
        }
        self.queue_drag = Some(QueueDragState {
            drag: drag.clone(),
            pointer: window.mouse_position(),
            target: None,
        });
        let token = drag.token;
        self.queue_drag_task = Some(cx.spawn(async move |view, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(33))
                    .await;
                let keep = view
                    .update(cx, |view, cx| {
                        let Some(state) = view
                            .queue_drag
                            .as_ref()
                            .filter(|state| state.drag.token == token)
                        else {
                            return false;
                        };
                        if !cx.has_active_drag() || !view.accepts_queue_drag(&state.drag) {
                            view.clear_queue_drag_state(cx);
                            return false;
                        }
                        let pointer = state.pointer;
                        let step = edge_step(pointer, view.queue_scroll.bounds());
                        let old = view.queue_scroll.offset();
                        let next = point(
                            old.x,
                            (old.y + step).clamp(-view.queue_scroll.max_offset().height, px(0.)),
                        );
                        if old != next {
                            view.queue_scroll.set_offset(next);
                            cx.notify();
                        }
                        view.update_queue_drop_target(pointer, cx);
                        true
                    })
                    .unwrap_or(false);
                if !keep {
                    break;
                }
            }
        }));
        cx.notify();
    }

    fn queue_target_at(&self, pointer: Point<Pixels>) -> Option<(String, bool)> {
        if !self.queue_scroll.bounds().contains(&pointer) {
            return None;
        }
        let steering = self
            .session
            .pending
            .iter()
            .filter(|item| item.lane == Lane::Steering)
            .count();
        let first = steering + usize::from(steering > 0) + 1; // section headings are real rows
        for (index, item) in self
            .session
            .pending
            .iter()
            .filter(|item| item.lane == Lane::FollowUp)
            .enumerate()
        {
            let mut bounds = self.queue_scroll.bounds_for_item(first + index)?;
            bounds.origin += self.queue_scroll.offset();
            if bounds.contains(&pointer) {
                return Some((
                    item.id.clone(),
                    pointer.y >= bounds.top() + bounds.size.height / 2.,
                ));
            }
        }
        None
    }

    pub(crate) fn update_queue_drop_target(
        &mut self,
        pointer: Point<Pixels>,
        cx: &mut Context<Self>,
    ) {
        let target = self.queue_target_at(pointer);
        if let Some(state) = &mut self.queue_drag {
            state.pointer = pointer;
            if state.target != target {
                state.target = target;
                cx.notify();
            }
        }
    }

    pub(crate) fn drop_queued(
        &mut self,
        drag: &QueueDrag,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let target = self.queue_target_at(window.mouse_position());
        let valid = self.accepts_queue_drag(drag)
            && self
                .queue_drag
                .as_ref()
                .is_some_and(|state| state.drag.token == drag.token);
        self.clear_queue_drag_state(cx);
        if !valid {
            return;
        }
        if let Some((target, after)) = target {
            // A newly arrived target wasn't in the displayed drag snapshot.
            // Pass the old membership to the actor for its typed stale rejection.
            let order = reordered(&drag.ids, &drag.source, &target, after)
                .unwrap_or_else(|| drag.ids.clone());
            self.reorder_queued(drag, order, cx);
        }
    }

    pub(crate) fn clear_queue_drag_state(&mut self, cx: &mut Context<Self>) {
        let mut changed = false;
        for chat in std::iter::once(&mut self.chat).chain(self.inactive.values_mut()) {
            changed |= chat.queue_drag.take().is_some();
            chat.queue_drag_task = None;
        }
        if changed {
            cx.notify();
        }
    }

    pub(crate) fn cancel_queue_drag(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let active = self.queue_drag.is_some()
            || self.inactive.values().any(|chat| chat.queue_drag.is_some());
        if active {
            cx.stop_active_drag(window);
            self.clear_queue_drag_state(cx);
        }
        active
    }
}

pub(crate) struct QueueDragPreview {
    pub(crate) drag: QueueDrag,
    pub(crate) width: Pixels,
}
impl Render for QueueDragPreview {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        let p = self.drag.palette;
        let controls: Vec<&'static str> = if self.drag.promotion {
            vec!["info", "steering", "pencil", "close"]
        } else {
            vec!["info", "pencil", "close"]
        };
        div()
            .w(self.width)
            .h(px(30.))
            .flex()
            .items_center()
            .gap(px(8.))
            .opacity(0.85)
            .bg(rgb(p.sunken))
            .text_color(rgb(p.ink))
            .font_family(if cfg!(target_os = "macos") {
                ".SystemUIFont"
            } else {
                "DejaVu Sans"
            })
            .child(
                div()
                    .w(px(14.))
                    .text_size(px(11.5))
                    .text_color(rgb(p.tertiary))
                    .child(self.drag.number.to_string()),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .overflow_hidden()
                    .text_size(px(13.))
                    .child(self.drag.text.clone()),
            )
            .children(controls.into_iter().map(|name| {
                div()
                    .size(px(22.))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(svg().path(name).size(px(12.)).text_color(rgb(p.secondary)))
            }))
    }
}

#[cfg(test)]
mod tests {
    use super::{edge_step, reordered};
    #[test]
    fn captured_single_move_matches_swift_before_after_semantics() {
        let ids = ["a", "b", "c", "d"].map(str::to_owned);
        for (source, target, after, expected) in [
            ("a", "c", false, "bacd"),
            ("a", "c", true, "bcad"),
            ("d", "b", false, "adbc"),
            ("d", "b", true, "abdc"),
            ("b", "b", false, "abcd"),
            ("b", "b", true, "abcd"),
        ] {
            assert_eq!(
                reordered(&ids, source, target, after).unwrap().concat(),
                expected
            );
        }
        assert!(reordered(&ids, "gone", "a", false).is_none());
        assert!(reordered(&ids, "a", "new", false).is_none());
    }
    #[test]
    fn drag_edge_scroll_is_bounded_to_the_queue_viewport() {
        use gpui::{Bounds, point, px, size};
        let bounds = Bounds::new(point(px(10.), px(100.)), size(px(300.), px(120.)));
        assert_eq!(edge_step(point(px(20.), px(105.)), bounds), px(5.));
        assert_eq!(edge_step(point(px(20.), px(215.)), bounds), px(-5.));
        assert_eq!(edge_step(point(px(20.), px(160.)), bounds), px(0.));
        assert_eq!(edge_step(point(px(5.), px(215.)), bounds), px(0.));
    }
}

#[cfg(test)]
#[path = "queue_drag_tests.rs"]
mod integration_tests;
