//! Read-only operations on one loaded chat. Every completion is fenced by the
//! sheet, operation, navigation, controller, workspace and immutable content.
use crate::{AgentView, conversation_content::Snapshot, conversation_content_view::ContentSheet};
use bello_agent_core::Controller;
use gpui::{ClipboardItem, Context, Window};
use std::sync::{
    Arc, Weak,
    atomic::{AtomicBool, Ordering},
};

#[derive(Clone)]
pub(crate) struct Target {
    project: std::path::PathBuf,
    workspace: Weak<std::sync::Mutex<bello_agent_core::workspace::WorkspaceStore>>,
    window: Option<crate::workspace_lifetime::WindowBinding>,
    chat: String,
    controller: Weak<Controller>,
    navigation: u64,
    load: u64,
}
impl Target {
    pub(crate) fn capture(view: &AgentView) -> Self {
        Self {
            project: view.project.clone(),
            workspace: Arc::downgrade(&view.workspace),
            window: view.window_binding,
            chat: view.record.id.clone(),
            controller: Arc::downgrade(&view.controller),
            navigation: view.navigation_generation,
            load: view.load_generation,
        }
    }
    pub(crate) fn matches(&self, view: &AgentView) -> bool {
        !view.shutting_down
            && !view.close_ready
            && !view.loading
            && !view.load_failed
            && self.window.is_some()
            && self.window == view.window_binding
            && self.project == view.project
            && self.workspace.ptr_eq(&Arc::downgrade(&view.workspace))
            && self.chat == view.record.id
            && self.chat == view.session.id
            && self.navigation == view.navigation_generation
            && self.load == view.load_generation
            && self.controller.ptr_eq(&Arc::downgrade(&view.controller))
            && !view.controller.is_retired()
    }
}
#[derive(Clone)]
pub(crate) enum Control {
    Search,
    Next,
    CopyRange,
    CopyAll,
    Reveal,
    Start,
    End,
    Select(usize),
    Close,
}
impl AgentView {
    pub(crate) fn open_conversation_content(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let target = Target::capture(self);
        if !target.matches(self) || self.composer.read(cx).has_marked_text() {
            return;
        }
        self.clear_transcript_find(cx);
        self.conversation_content = Some(ContentSheet::new(target, self.palette, window, cx));
        let token = self.conversation_content.as_ref().unwrap().token;
        self.content_control(token, Control::Search, window, cx);
    }
    pub(crate) fn content_control(
        &mut self,
        token: uuid::Uuid,
        control: Control,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(sheet) = self.conversation_content.as_ref() else {
            return;
        };
        if sheet.token != token {
            return;
        }
        if matches!(control, Control::Close) {
            self.conversation_content = None;
            self.focus_visible_composer(window, cx);
            cx.notify();
            return;
        }
        if !sheet.target.matches(self) {
            self.conversation_content = None;
            cx.notify();
            return;
        }
        if sheet.busy {
            return;
        }
        match control {
            Control::Search | Control::Next => {
                self.search_content(matches!(control, Control::Next), cx)
            }
            Control::CopyRange | Control::CopyAll => {
                self.copy_content(matches!(control, Control::CopyAll), cx)
            }
            Control::Select(position) => {
                let sheet = self.conversation_content.as_mut().unwrap();
                if sheet
                    .result
                    .as_ref()
                    .is_some_and(|result| result.hits.iter().any(|hit| hit.position == position))
                {
                    sheet.selected = Some(position);
                }
            }
            Control::Start | Control::End => {
                let sheet = self.conversation_content.as_mut().unwrap();
                if let Some(position) = sheet.selected {
                    let editor = if matches!(control, Control::Start) {
                        &sheet.first
                    } else {
                        &sheet.last
                    };
                    editor.update(cx, |editor, cx| editor.set_text(position.to_string(), cx));
                }
            }
            Control::Reveal => self.reveal_content(window, cx),
            Control::Close => unreachable!(),
        }
        cx.notify();
    }
    fn search_content(&mut self, next: bool, cx: &mut Context<Self>) {
        let snapshot = Snapshot::new(self.controller.snapshot_shared());
        let sheet = self.conversation_content.as_mut().unwrap();
        if !next
            && sheet.query.read(cx).text().len() > crate::conversation_content::QUERY_BYTE_LIMIT
        {
            sheet.notice = Some("Search query exceeds the 16 KiB safety limit.".into());
            return;
        }
        let (query, start) = if next {
            let Some(start) = sheet.result.as_ref().and_then(|result| result.next) else {
                return;
            };
            (sheet.searched.clone(), start)
        } else {
            (sheet.query.read(cx).text().to_owned(), 0)
        };
        let worker = snapshot.clone();
        let (token, operation, cancel) = sheet.begin();
        let flag = cancel.clone();
        let task = cx.background_executor().spawn(async move {
            worker
                .search_cancelled(&query, start, &flag)
                .map(|result| (query, result))
        });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                if !view.content_completion_current(token, operation, &snapshot, &cancel) {
                    cx.notify();
                    return;
                }
                let sheet = view.conversation_content.as_mut().unwrap();
                sheet.busy = false;
                match result {
                    Ok((query, result)) => {
                        if sheet.result.is_none() {
                            sheet.last.update(cx, |editor, cx| {
                                editor.set_text(result.total.max(1).to_string(), cx)
                            });
                        }
                        sheet.snapshot = Some(snapshot);
                        sheet.result = Some(result);
                        sheet.searched = query;
                        sheet.selected = None;
                        sheet.notice = None;
                    }
                    Err(error) => sheet.notice = Some(error),
                }
                cx.notify();
            });
        })
        .detach();
    }
    fn copy_content(&mut self, all: bool, cx: &mut Context<Self>) {
        let sheet = self.conversation_content.as_mut().unwrap();
        let Some(snapshot) = sheet.snapshot.clone() else {
            return;
        };
        let total = sheet.result.as_ref().map_or(0, |result| result.total);
        let range = if all {
            Some((1, total))
        } else {
            sheet
                .first
                .read(cx)
                .text()
                .trim()
                .parse::<usize>()
                .ok()
                .zip(sheet.last.read(cx).text().trim().parse::<usize>().ok())
        };
        let Some((first, last)) = range else {
            sheet.notice = Some("Enter a valid inclusive message range.".into());
            return;
        };
        let (token, operation, cancel) = sheet.begin();
        let worker = snapshot.clone();
        let flag = cancel.clone();
        let task = cx
            .background_executor()
            .spawn(async move { worker.collect(first, last, &flag) });
        cx.spawn(async move |view, cx| {
            let result = task.await;
            let _ = view.update(cx, |view, cx| {
                if !view.content_completion_current(token, operation, &snapshot, &cancel) {
                    cx.notify();
                    return;
                }
                let sheet = view.conversation_content.as_mut().unwrap();
                sheet.busy = false;
                match result {
                    Ok(text) => {
                        let bytes = text.len();
                        cx.write_to_clipboard(ClipboardItem::new_string(text));
                        sheet.notice = Some(format!(
                            "Copied messages {first}–{last} ({bytes} UTF-8 bytes)."
                        ));
                    }
                    Err(error) => sheet.notice = Some(error),
                }
                cx.notify();
            });
        })
        .detach();
    }
    fn content_completion_current(
        &mut self,
        token: uuid::Uuid,
        operation: uuid::Uuid,
        snapshot: &Snapshot,
        cancel: &AtomicBool,
    ) -> bool {
        let Some(sheet) = self.conversation_content.as_ref() else {
            return false;
        };
        if sheet.token != token || sheet.operation != operation || cancel.load(Ordering::Acquire) {
            return false;
        }
        if !sheet.target.matches(self) {
            self.conversation_content = None;
            return false;
        }
        if !snapshot.matches(&self.controller.snapshot_shared()) {
            let sheet = self.conversation_content.as_mut().unwrap();
            sheet.busy = false;
            sheet.notice = Some(
                "The conversation changed. Search again. The clipboard was not changed.".into(),
            );
            return false;
        }
        true
    }
    fn reveal_content(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let sheet = self.conversation_content.as_ref().unwrap();
        let Some(position) = sheet.selected else {
            return;
        };
        let Some(snapshot) = sheet.snapshot.as_ref() else {
            return;
        };
        let fresh = self.controller.snapshot_shared();
        if !snapshot.matches(&fresh) {
            self.conversation_content.as_mut().unwrap().notice =
                Some("The conversation changed. Search again.".into());
            return;
        }
        let Some(hit) = sheet
            .result
            .as_ref()
            .and_then(|r| r.hits.iter().find(|hit| hit.position == position))
        else {
            return;
        };
        let id = hit.id.clone();
        if fresh
            .messages
            .iter()
            .filter(|message| message.id == id)
            .count()
            != 1
        {
            self.conversation_content.as_mut().unwrap().notice =
                Some("This message has an ambiguous identity and cannot be revealed.".into());
            return;
        }
        let Some(index) = fresh.messages.iter().position(|message| message.id == id) else {
            return;
        };
        self.session = fresh;
        self.visible_messages = self
            .visible_messages
            .max(self.session.messages.len() - index);
        self.sync_transcript_inputs(cx);
        if let Some(transcript) = self.transcript.clone() {
            let input = self.transcript_input();
            let revealed = transcript.update(cx, |view, cx| view.reveal_message(input, &id, cx));
            if revealed {
                self.conversation_content = None;
                self.focus_visible_composer(window, cx);
            }
        }
    }
}
#[cfg(test)]
#[path = "conversation_content_view_tests.rs"]
mod tests;
