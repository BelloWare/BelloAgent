//! Swift 0.1.122's response header (`TranscriptNativeResponseRow`, with
//! `TaskTranscriptPlan.responseLine` and `TranscriptDisclosure`'s `response`
//! and `responseLine` parts): one strip above each response saying what it
//! did ("Reasoned · 3 tool calls", "Answered"), whose button folds the whole
//! response down to that strip. A plain answer has nothing inside to fold, so
//! its strip is short and says nothing until the pointer is over it.
//!
//! Rust draws the strip at the top of the response's first row rather than
//! as a row of its own, so a response's rows keep their places in the list.
use super::{LogicalRow, ProjectedRow, RowKey, tool_presentation, tool_row, work_line};
use bello_agent_core::Session;
use gpui::{
    Animation, AnimationExt, App, AppContext, FontWeight, InteractiveElement, IntoElement,
    ParentElement, SharedString, StatefulInteractiveElement, Styled, Transformation, Window, div,
    prelude::FluentBuilder, px, radians, svg,
};
use std::{
    collections::{HashMap, HashSet},
    time::Duration,
};

/// The one line a response reads as (Swift's `ResponseLine`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Line {
    /// "Reasoned · 2 tool calls", "Answered" or "Response".
    pub work: String,
    /// The request's duration, when the host measured it. Rust's history
    /// keeps no per-request clock yet, so this is always empty.
    pub duration: Option<String>,
    /// Tokens, cost and model, when the gateway reported them. Rust's
    /// history keeps no gateway accounting yet, so this is always empty.
    pub figures: Option<String>,
    /// How many rows of content the line hides when the response is folded.
    pub parts: usize,
    /// Whether the response holds anything but its words: a thought, a call.
    pub foldable: bool,
}

/// Swift's `TaskTranscriptPlan.visible`: anything but whitespace.
fn visible(text: &str) -> bool {
    text.chars().any(|c| !c.is_whitespace())
}

impl Line {
    /// `TaskTranscriptPlan.responseLine` over one reply: its thought, its
    /// words and its calls by their helper states.
    pub(super) fn of<'a>(
        reasoning: &str,
        text: &str,
        calls: impl IntoIterator<Item = &'a str>,
    ) -> Self {
        let mut summary = tool_row::CallSummary::default();
        let states: Vec<&str> = calls.into_iter().collect();
        let count = states.len();
        summary.add_reply(states, None, false);
        let work = summary.label(visible(reasoning)).unwrap_or_else(|| {
            if visible(text) {
                "Answered".into()
            } else {
                "Response".into()
            }
        });
        // Swift shows a part whose text is not empty (whitespace included)
        // and every call's arguments.
        let parts = usize::from(!reasoning.is_empty()) + usize::from(!text.is_empty()) + count;
        Self {
            work,
            duration: None,
            figures: None,
            parts,
            foldable: !reasoning.is_empty() || count > 0,
        }
    }
}

/// A response's strip, as the row that carries it draws it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Header {
    /// The response's own key: the reply's row key.
    pub owner: RowKey,
    pub line: Line,
    /// The response is still streaming: a spinner leads the strip.
    pub live: bool,
    /// Folded to this one line (`responseLine`).
    pub collapsed: bool,
    /// Everything inside drawn closed (`response`, or `responseLine`).
    pub folded: bool,
}

/// The strip's faces and boxes (`TranscriptNativeResponseRow`).
pub(super) const FONT: f32 = 12.5;
pub(super) const COMPACT_FONT: f32 = 11.;
pub(super) const SPINNER: f32 = 11.;
const SPINNER_PERIOD: Duration = Duration::from_millis(800);

impl Header {
    /// A response with nothing inside to fold keeps a short strip.
    pub(super) fn compact(&self) -> bool {
        !self.line.foldable && !self.collapsed
    }
    /// A plain answer says nothing until the pointer is over it.
    pub(super) fn quiet(&self, hovering: bool) -> bool {
        self.compact() && !self.folded && !hovering
    }
    /// The strip's words: what it did, how long it took, how much a folded
    /// response hides, and what it cost once folded.
    pub(super) fn summary(&self, hovering: bool) -> String {
        if self.quiet(hovering) {
            return String::new();
        }
        let line = &self.line;
        let mut parts = vec![line.work.clone()];
        if let Some(duration) = line.duration.as_ref().filter(|d| !d.is_empty()) {
            parts.push(duration.clone());
        }
        if self.collapsed && line.parts > 0 {
            parts.push(format!(
                "{} {} folded",
                line.parts,
                if line.parts == 1 { "part" } else { "parts" }
            ));
        }
        if let Some(figures) = line.figures.as_ref().filter(|_| self.folded) {
            parts.push(figures.clone());
        }
        parts.join(" · ")
    }
    pub(super) fn strip_height(&self) -> f32 {
        if self.compact() { 14. } else { 20. }
    }
    pub(super) fn top(&self) -> f32 {
        if self.compact() { 0. } else { 4. }
    }
    /// The strip and its room: a line with nothing to say takes the room of
    /// paragraph spacing, never of a line of text.
    pub(super) fn height(&self) -> f32 {
        self.top()
            + self.strip_height()
            + if self.collapsed {
                10.
            } else if self.compact() {
                0.
            } else {
                2.
            }
    }
    /// The fold button's box.
    pub(super) fn button_height(&self) -> f32 {
        if self.compact() { 14. } else { 16. }
    }
    pub(super) fn help(&self) -> &'static str {
        if self.collapsed {
            "Show this response"
        } else {
            "Fold this response to one line"
        }
    }
    pub(super) fn icon(&self) -> &'static str {
        if self.collapsed {
            "arrow.down.left.and.arrow.up.right"
        } else {
            "arrow.up.right.and.arrow.down.left"
        }
    }
}

/// What a row of a response carries.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct RowResponse {
    /// The response this row belongs to.
    pub owner: Option<RowKey>,
    /// Set on the response's first row: the strip drawn above it.
    pub header: Option<Header>,
    /// The response is folded to its strip: this row draws nothing.
    pub line_hidden: bool,
    /// Everything inside the response draws closed; what the reader opened
    /// stays recorded and returns when the response opens again.
    pub inside_folded: bool,
}

/// The reply a row belongs to, and the reply's own key.
fn owner(session: &Session, row: &LogicalRow) -> Option<(usize, RowKey)> {
    match row.projected? {
        ProjectedRow::Message(index) => {
            let message = &session.messages[index];
            (message.role == "assistant" && message.compaction.is_none())
                .then(|| (index, row.key.clone()))
        }
        ProjectedRow::Call { assistant, .. } => match &row.key {
            RowKey::Tool { assistant: key, .. } => Some((assistant, (**key).clone())),
            _ => None,
        },
        ProjectedRow::Result(_) => None,
    }
}

/// Gives every response on the page its strip and its folds. `opened` holds
/// the reader's choices: `Response(owner)` folds a response to its line,
/// `ResponseInside(owner)` draws everything inside it closed.
pub(super) fn apply(rows: &mut [LogicalRow], session: &Session, opened: &HashSet<RowKey>) {
    // Each reply's rows, in page order, without a scan per reply.
    let mut order: Vec<(usize, RowKey)> = Vec::new();
    let mut members: HashMap<usize, Vec<usize>> = HashMap::new();
    for (at, row) in rows.iter().enumerate() {
        let Some((index, key)) = owner(session, row) else {
            continue;
        };
        let rows = members.entry(index).or_default();
        if rows.is_empty() {
            order.push((index, key));
        }
        rows.push(at);
    }
    for (index, key) in order {
        let message = &session.messages[index];
        let members = &members[&index];
        let states: Vec<&str> = members
            .iter()
            .filter_map(|&at| match rows[at].projected {
                Some(projected @ ProjectedRow::Call { .. }) => Some(tool_row::helper_state(
                    tool_presentation::status(session, projected),
                )),
                _ => None,
            })
            .collect();
        let line = Line::of(&message.reasoning, &message.text, states.iter().copied());
        // A reply that has said and done nothing yet is its waiting dots.
        if line.parts == 0 {
            continue;
        }
        let collapsed = opened.contains(&RowKey::Response(Box::new(key.clone())));
        let folded = collapsed || opened.contains(&RowKey::ResponseInside(Box::new(key.clone())));
        for (n, &at) in members.iter().enumerate() {
            rows[at].response = RowResponse {
                owner: Some(key.clone()),
                header: (n == 0).then(|| Header {
                    owner: key.clone(),
                    line: line.clone(),
                    live: message.state == "streaming",
                    collapsed,
                    folded,
                }),
                line_hidden: collapsed && n > 0,
                inside_folded: folded,
            };
        }
    }
}

/// The strip: `[spinner] words ……… [fold]`, the whole strip one press
/// target. Under the pointer the words take the muted ink and the button
/// shows on its panel; a folded response keeps both lit.
pub(super) fn render(
    selector: &str,
    header: &Header,
    palette: &crate::Palette,
    toggle: impl Fn(&mut Window, &mut App) + 'static,
) -> impl IntoElement {
    let colors = work_line::card_colors(palette);
    let group = SharedString::from(format!("{selector}-group"));
    let lit = header.collapsed;
    let quiet = header.quiet(false);
    let (muted, faint, text, panel) = (colors.muted, colors.faint, colors.text, colors.panel);
    let mut strip = div()
        .id(SharedString::from(selector.to_owned()))
        .debug_selector({
            let selector = selector.to_owned();
            move || selector
        })
        .group(group.clone())
        .mt(px(header.top()))
        .h(px(header.strip_height()))
        .w_full()
        .min_w_0()
        .flex()
        .flex_row()
        .items_center()
        .gap(px(4.))
        .on_click(move |_, window, cx| toggle(window, cx));
    if header.live {
        strip = strip.child(spinner(selector, palette));
    }
    let label = header.summary(true);
    strip = strip
        .child(
            div()
                .debug_selector({
                    let selector = format!("{selector}-label");
                    move || selector
                })
                .min_w_0()
                .truncate()
                .text_size(px(if header.compact() { COMPACT_FONT } else { FONT }))
                .font_weight(FontWeight::MEDIUM)
                .text_color(if lit { muted } else { faint })
                .when(quiet, |label| label.opacity(0.))
                .group_hover(group.clone(), move |label| {
                    label.text_color(muted).opacity(1.)
                })
                .child(label),
        )
        .child(div().flex_1().min_w_0())
        .child(
            div()
                .id(SharedString::from(format!("{selector}-button")))
                .debug_selector({
                    let selector = format!("{selector}-button");
                    move || selector
                })
                .flex_none()
                .w(px(18.))
                .h(px(header.button_height()))
                .rounded(px(5.))
                .flex()
                .items_center()
                .justify_center()
                .cursor_pointer()
                .when(!lit, |button| button.opacity(0.))
                .group_hover(group.clone(), move |button| button.opacity(1.).bg(panel))
                .tooltip({
                    let help = header.help();
                    let palette = *palette;
                    move |_, cx| {
                        cx.new(|_| crate::composer_skills::SkillHint {
                            text: help.into(),
                            palette,
                        })
                        .into()
                    }
                })
                .child(
                    svg()
                        .path(header.icon())
                        .size(px(10.))
                        .text_color(faint)
                        .group_hover(group, move |icon| icon.text_color(text)),
                ),
        );
    div()
        .w_full()
        .h(px(header.height()))
        .flex()
        .flex_col()
        .child(strip)
}

/// Swift's `TranscriptSpinner`: an 11-point ring in the strong hairline with
/// a fifth of it in the accent, turning once every 0.8 s.
fn spinner(selector: &str, palette: &crate::Palette) -> impl IntoElement {
    let colors = work_line::card_colors(palette);
    let turn = |path: &'static str, color, name: &str| {
        svg()
            .absolute()
            .inset_0()
            .size(px(SPINNER))
            .path(path)
            .text_color(color)
            .with_animation(
                SharedString::from(format!("{selector}-{name}")),
                Animation::new(SPINNER_PERIOD).repeat(),
                |icon, delta| {
                    icon.with_transformation(Transformation::rotate(radians(
                        delta * std::f32::consts::TAU,
                    )))
                },
            )
    };
    div()
        .relative()
        .flex_none()
        .size(px(SPINNER))
        .child(turn("spinner.track", colors.hair_strong, "spinner-track"))
        .child(turn("spinner.arc", colors.accent, "spinner-arc"))
}

/// The fold commands (Swift's `WorkspaceCommands`: Fold This Turn, Fold
/// Every Turn, Fold This Response to One Line and their opposites), the
/// response strip's own press, and the display mode.
impl super::TranscriptView {
    /// How finished turns read. The Settings control hands its choice here.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn display_mode(&self) -> super::TranscriptDisplayMode {
        self.display
    }
    /// Reads the page in `mode`, keeping everything the reader opened.
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn set_display_mode(
        &mut self,
        mode: super::TranscriptDisplayMode,
        window: &mut Window,
        cx: &mut gpui::Context<Self>,
    ) {
        if self.display != mode {
            self.display = mode;
            self.refold(window, cx);
        }
    }
    /// A transcript that reads in Settings' display mode and follows it as
    /// Settings changes it.
    pub(crate) fn following_settings(
        parent: gpui::WeakEntity<crate::AgentView>,
        input: super::TranscriptInput,
        cx: &mut gpui::Context<Self>,
    ) -> Self {
        let mut view = Self::new(parent, input);
        if super::initial_display() == super::TranscriptDisplayMode::Compact {
            view.show_display(crate::app_settings::transcript_display(cx), cx);
        }
        view._display = Some(crate::app_settings::observe_transcript_display(
            cx,
            |view: &mut Self, mode, cx| view.show_display(mode, cx),
        ));
        view
    }
    /// Reads the page in `mode` without a window at hand; a focused card the
    /// change hides gives the keyboard back on the next frame.
    fn show_display(&mut self, mode: super::TranscriptDisplayMode, cx: &mut gpui::Context<Self>) {
        if self.display == mode {
            return;
        }
        self.display = mode;
        self.presentation = std::rc::Rc::new(super::Presentation::with_disclosure(
            self.presentation.input.clone(),
            &self.opened,
            &self.expanded_reads,
            self.display,
        ));
        self.invalidate_sidebar_geometry(cx);
        cx.notify();
    }
    /// The strip's press: the response folds to its line, or opens again.
    pub(super) fn toggle_response(
        &mut self,
        owner: RowKey,
        chat_id: &str,
        controller: &std::sync::Weak<bello_agent_core::Controller>,
        window: &mut Window,
        cx: &mut gpui::Context<Self>,
    ) {
        if self.presentation.input.chat_id != chat_id
            || !std::sync::Weak::ptr_eq(&self.presentation.input.controller, controller)
            || !self.presentation.rows.iter().any(|row| {
                row.response
                    .header
                    .as_ref()
                    .is_some_and(|h| h.owner == owner)
            })
        {
            return;
        }
        let line = RowKey::Response(Box::new(owner));
        if !self.opened.remove(&line) {
            self.opened.insert(line);
        }
        self.refold(window, cx);
    }
    /// The list row the reader is on: none while the page follows its end,
    /// which Swift reads as the newest.
    fn anchor(&self) -> Option<usize> {
        if self.follows_bottom() {
            return None;
        }
        let viewport = self.viewport.borrow();
        let top = viewport.list.logical_scroll_top().item_ix;
        let key = &viewport.presentation.rows.get(top)?.key;
        self.presentation
            .rows
            .iter()
            .position(|row| &row.key == key)
    }
    /// `turnFold(holding:)`: the fold of the turn the reader's latest
    /// question at or above the anchor opened, else the newest fold.
    fn focused_turn_fold(&self) -> Option<RowKey> {
        let rows = &self.presentation.rows;
        let folds: Vec<&RowKey> = rows
            .iter()
            .filter(|row| row.fold.control.is_some())
            .map(|row| &row.key)
            .collect();
        let last = folds.last().map(|key| (*key).clone())?;
        let Some(anchor) = self.anchor() else {
            return Some(last);
        };
        let session = &self.presentation.input.session;
        let question = rows[..=anchor].iter().rev().find(|row| {
            matches!(row.projected, Some(ProjectedRow::Message(index))
                if session.messages[index].role == "user")
        })?;
        let fold = RowKey::Fold(Box::new(question.key.clone()));
        folds.contains(&&fold).then_some(fold)
    }
    /// `focusedResponse(holding:)`: the response at or under the anchor,
    /// else the last one above it; the newest without an anchor.
    fn focused_response(&self) -> Option<RowKey> {
        let rows = &self.presentation.rows;
        let owner = |row: &LogicalRow| row.response.header.as_ref().map(|h| h.owner.clone());
        let Some(anchor) = self.anchor() else {
            return rows.iter().rev().find_map(owner);
        };
        // A row of a response is that response's.
        if let Some(own) = rows[anchor].response.owner.clone() {
            return Some(own);
        }
        rows[anchor..]
            .iter()
            .find_map(owner)
            .or_else(|| rows[..anchor].iter().rev().find_map(owner))
    }
    fn set_response_folded(&mut self, owner: RowKey, folded: bool) {
        let inside = RowKey::ResponseInside(Box::new(owner.clone()));
        if folded {
            self.opened.insert(inside);
        } else {
            self.opened.remove(&inside);
            // Unfolding also clears the one-line fold, so ⌥⌘] always leaves
            // the response open.
            self.opened.remove(&RowKey::Response(Box::new(owner)));
        }
    }
    /// Whether a turn has work to fold at all, so the menu can say so.
    pub(crate) fn can_fold_turns(&self) -> bool {
        let input = &self.presentation.input;
        !input.loading
            && (input.session.state == bello_agent_core::RunState::Running
                || input.session.messages.iter().any(|message| {
                    message.role == "assistant"
                        && (!message.reasoning.is_empty()
                            || made_calls(message)
                            || visible(&message.text))
                }))
    }
    /// Whether the chat has a response with a header line to fold.
    pub(crate) fn can_fold_responses(&self) -> bool {
        let input = &self.presentation.input;
        !input.loading
            && input.session.messages.iter().any(|message| {
                message.role == "assistant"
                    && message.compaction.is_none()
                    && (!message.reasoning.is_empty()
                        || !message.text.is_empty()
                        || made_calls(message))
            })
    }
    /// Fold This Turn / Unfold This Turn: the turn's end-of-turn fold, and
    /// everything inside the response the reader is on.
    pub(crate) fn set_focused_turn_folded(
        &mut self,
        folded: bool,
        window: &mut Window,
        cx: &mut gpui::Context<Self>,
    ) -> bool {
        let response = self.focused_response();
        let fold = self.focused_turn_fold();
        if response.is_none() && fold.is_none() {
            return false;
        }
        if let Some(owner) = response {
            self.set_response_folded(owner, folded);
        }
        if let Some(fold) = fold {
            if folded {
                self.opened.remove(&fold);
            } else {
                self.opened.insert(fold);
            }
        }
        self.refold(window, cx);
        true
    }
    /// Fold Every Turn / Unfold Every Turn. Answers how many turn folds the
    /// page has.
    pub(crate) fn set_every_turn_folded(
        &mut self,
        folded: bool,
        window: &mut Window,
        cx: &mut gpui::Context<Self>,
    ) -> usize {
        let owners: Vec<RowKey> = self
            .presentation
            .all_rows()
            .filter_map(|row| row.response.header.as_ref().map(|h| h.owner.clone()))
            .collect();
        let folds: Vec<RowKey> = self
            .presentation
            .rows
            .iter()
            .filter(|row| row.fold.control.is_some())
            .map(|row| row.key.clone())
            .collect();
        for owner in &owners {
            self.set_response_folded(owner.clone(), folded);
        }
        for fold in &folds {
            if folded {
                self.opened.remove(fold);
            } else {
                self.opened.insert(fold.clone());
            }
        }
        if !owners.is_empty() || !folds.is_empty() {
            self.refold(window, cx);
        }
        folds.len()
    }
    /// Fold This Response to One Line / Show This Response.
    pub(crate) fn set_focused_response_collapsed(
        &mut self,
        collapsed: bool,
        window: &mut Window,
        cx: &mut gpui::Context<Self>,
    ) -> bool {
        let Some(owner) = self.focused_response() else {
            return false;
        };
        let line = RowKey::Response(Box::new(owner.clone()));
        if collapsed {
            self.opened.insert(line);
        } else {
            self.opened.remove(&line);
            self.opened.remove(&RowKey::ResponseInside(Box::new(owner)));
        }
        self.refold(window, cx);
        true
    }
    /// Each response strip on the page: its reply's key, what it says under
    /// the pointer, and whether it is folded to its line.
    #[cfg(test)]
    pub(crate) fn response_headers(&self) -> Vec<(String, String, bool)> {
        self.presentation
            .rows
            .iter()
            .filter_map(super::drawn_header)
            .map(|header| {
                (
                    format!("{:?}", header.owner),
                    header.summary(true),
                    header.collapsed,
                )
            })
            .collect()
    }
}

/// A Conversation menu fold command; `true` folds, `false` opens.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FoldCommand {
    /// Fold This Turn / Unfold This Turn (⌥⌘[ / ⌥⌘]).
    Turn(bool),
    /// Fold Every Turn / Unfold Every Turn (⇧⌥⌘[ / ⇧⌥⌘]).
    EveryTurn(bool),
    /// Fold This Response to One Line / Show This Response.
    Response(bool),
}

impl crate::AgentView {
    /// Whether the selected chat has a turn and a response to fold.
    pub(crate) fn fold_availability(&self, cx: &App) -> (bool, bool) {
        self.transcript
            .as_ref()
            .map_or((false, false), |transcript| {
                let view = transcript.read(cx);
                (view.can_fold_turns(), view.can_fold_responses())
            })
    }
    pub(crate) fn fold_command(
        &mut self,
        command: FoldCommand,
        window: &mut Window,
        cx: &mut gpui::Context<Self>,
    ) {
        let Some(transcript) = self.transcript.clone() else {
            return;
        };
        transcript.update(cx, |view, cx| match command {
            FoldCommand::Turn(folded) => {
                view.set_focused_turn_folded(folded, window, cx);
            }
            FoldCommand::EveryTurn(folded) => {
                view.set_every_turn_folded(folded, window, cx);
            }
            FoldCommand::Response(collapsed) => {
                view.set_focused_response_collapsed(collapsed, window, cx);
            }
        });
    }
}

fn made_calls(message: &bello_agent_core::Message) -> bool {
    matches!(&message.tool_record,
        Some(bello_agent_core::tool_history::ToolRecord::Assistant(record)) if !record.calls.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn header(line: Line, collapsed: bool, folded: bool) -> Header {
        Header {
            owner: RowKey::Message("reply".into()),
            line,
            live: false,
            collapsed,
            folded,
        }
    }

    #[test]
    fn a_response_line_says_what_the_reply_did_as_swift_says_it() {
        let line = Line::of("Plan.", "Done.", ["completed", "completed", "failed"]);
        assert_eq!(line.work, "Reasoned · 3 tool calls · 1 failed");
        assert_eq!((line.parts, line.foldable), (5, true));
        let line = Line::of("", "Done.", []);
        assert_eq!(line.work, "Answered");
        assert_eq!((line.parts, line.foldable), (1, false));
        // Whitespace counts as a part but says nothing.
        let line = Line::of("  ", " ", []);
        assert_eq!(line.work, "Response");
        assert_eq!((line.parts, line.foldable), (2, true));
        let line = Line::of("", "", ["running", "unknown", "cancelled"]);
        assert_eq!(line.work, "3 tool calls · 1 skipped · 1 outcome unknown");
    }

    #[test]
    fn the_strip_speaks_only_when_it_has_something_to_fold_or_is_pointed_at() {
        let plain = header(Line::of("", "Done.", []), false, false);
        assert!(plain.compact());
        assert_eq!(plain.summary(false), "");
        assert_eq!(plain.summary(true), "Answered");
        assert_eq!(
            (plain.top(), plain.strip_height(), plain.height()),
            (0., 14., 14.)
        );
        assert_eq!(plain.button_height(), 14.);

        let work = header(Line::of("Plan.", "Done.", ["completed"]), false, false);
        assert!(!work.compact());
        assert_eq!(work.summary(false), "Reasoned · 1 tool call");
        assert_eq!(
            (work.top(), work.strip_height(), work.height()),
            (4., 20., 26.)
        );
        assert_eq!(work.help(), "Fold this response to one line");
        assert_eq!(work.icon(), "arrow.up.right.and.arrow.down.left");

        let folded = header(Line::of("Plan.", "Done.", ["completed"]), true, true);
        assert_eq!(
            folded.summary(false),
            "Reasoned · 1 tool call · 3 parts folded"
        );
        assert_eq!(folded.height(), 4. + 20. + 10.);
        assert_eq!(folded.help(), "Show this response");
        assert_eq!(folded.icon(), "arrow.down.left.and.arrow.up.right");

        // A plain answer folded to its line is no longer compact.
        let plain = header(Line::of("", "Done.", []), true, true);
        assert!(!plain.compact());
        assert_eq!(plain.summary(false), "Answered · 1 part folded");
        // Folded from inside only, a plain answer speaks without a pointer.
        let plain = header(Line::of("", "Done.", []), false, true);
        assert_eq!(plain.summary(false), "Answered");
    }

    #[test]
    fn figures_show_only_on_a_folded_response_and_durations_always() {
        let mut line = Line::of("", "Done.", ["completed"]);
        line.duration = Some("1.2s".into());
        line.figures = Some("model · 10 in".into());
        assert_eq!(
            header(line.clone(), false, false).summary(false),
            "1 tool call · 1.2s"
        );
        assert_eq!(
            header(line.clone(), false, true).summary(false),
            "1 tool call · 1.2s · model · 10 in"
        );
        assert_eq!(
            header(line, true, true).summary(false),
            "1 tool call · 1.2s · 2 parts folded · model · 10 in"
        );
    }
}
