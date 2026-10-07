//! Metadata-only ordered draft selections. Recovery preserves exact variants;
//! it never substitutes a current source or silently overwrites newer arguments.
use crate::{AgentView, project_skills_controller::SkillTarget};
use bello_agent_core::{
    Error, Result, Submission,
    skills::{SkillChip, SkillPolicy},
};
use gpui::{prelude::*, *};
use std::{borrow::Cow, collections::HashSet};

pub(crate) fn validate_fresh(chips: &[SkillChip]) -> Result<()> {
    if chips.len() > 8 {
        return Err(Error::Invalid("Choose at most eight skills before sending. Recovered selections are preserved for review.".into()));
    }
    let mut ids = HashSet::new();
    for chip in chips {
        chip.validate()?;
        if !ids.insert(&chip.selection.id) {
            return Err(Error::Invalid("Conflicting versions or arguments of a skill were recovered. Remove the unwanted variant before sending.".into()));
        }
        if chip.selection.arguments.len() > 16 * 1024 {
            return Err(Error::Invalid(
                "Skill arguments are limited to 16 KiB of UTF-8 text.".into(),
            ));
        }
    }
    Ok(())
}
pub(crate) fn restore_chips(
    captured: &[SkillChip],
    current: &[SkillChip],
) -> Result<Vec<SkillChip>> {
    bello_agent_core::skills::restore_chips(captured, current)
}
pub(crate) fn input_label<'a, 'b>(
    text: &'a str,
    images: usize,
    names: impl IntoIterator<Item = &'b str>,
) -> Cow<'a, str> {
    if !text.is_empty() {
        return Cow::Borrowed(text);
    }
    let mut names: Vec<_> = names.into_iter().map(|name| format!("/{name}")).collect();
    if names.is_empty() {
        return crate::composer_attachments::input_label(text, images);
    }
    if images != 0 {
        names.push(crate::composer_attachments::input_label("", images).into_owned());
    }
    Cow::Owned(names.join(" · "))
}
pub(crate) fn submission_label(item: &Submission) -> Cow<'_, str> {
    input_label(
        &item.text,
        item.attachments.len(),
        item.frozen_skills.iter().map(|skill| skill.name.as_str()),
    )
}
pub(crate) fn policy_label(policy: SkillPolicy) -> &'static str {
    match policy {
        SkillPolicy::ImplicitAllowed => "Implicit allowed",
        SkillPolicy::ExplicitOnly => "Explicit only",
        SkillPolicy::Disabled => "Disabled",
        SkillPolicy::NeedsAttention => "Needs attention",
    }
}
pub(crate) struct SkillHint {
    pub text: String,
    pub palette: crate::Palette,
}
impl Render for SkillHint {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .max_w(px(560.))
            .p(px(10.))
            .rounded(px(7.))
            .bg(rgb(self.palette.surface))
            .text_color(rgb(self.palette.ink))
            .text_size(px(12.))
            .child(self.text.clone())
    }
}
impl AgentView {
    pub(crate) fn skill_chips(&self, cx: &Context<Self>) -> Div {
        let mut row = div()
            .debug_selector(|| "composer-skill-chips".into())
            .flex()
            .flex_col()
            .gap(px(6.))
            .px(px(12.))
            .pt(px(8.));
        if let Err(error) = validate_fresh(&self.skills) {
            row = row.child(
                div()
                    .text_size(px(12.))
                    .text_color(rgb(self.palette.danger))
                    .child(error.to_string()),
            );
        }
        let mut chips = div().flex().flex_wrap().gap(px(6.));
        for (index, chip) in self.skills.iter().enumerate() {
            let edit_target = SkillTarget::capture(self);
            let remove_target = edit_target.clone();
            let edit_chip = chip.clone();
            let remove_chip = chip.clone();
            let palette = self.palette;
            let hint = format!(
                "{}\n{}\n{}\n{}\nVersion {}\nArguments: {}\nThis grants no additional tools.",
                chip.name,
                chip.description,
                chip.path,
                policy_label(chip.policy),
                chip.selection
                    .content_hash
                    .chars()
                    .take(8)
                    .collect::<String>(),
                chip.selection.arguments
            );
            chips = chips.child(
                div()
                    .id(SharedString::from(format!("skill-chip-{index}")))
                    .debug_selector(move || format!("skill-chip-{index}"))
                    .flex()
                    .items_center()
                    .gap(px(5.))
                    .px(px(7.))
                    .py(px(4.))
                    .rounded(px(7.))
                    .bg(palette.fill())
                    .text_size(px(12.))
                    .max_w(px(320.))
                    .tooltip(move |_, cx| {
                        cx.new(|_| SkillHint {
                            text: hint.clone(),
                            palette,
                        })
                        .into()
                    })
                    .child(div().truncate().child(format!(
                        "/{}{}",
                        chip.name,
                        if chip.selection.arguments.is_empty() {
                            String::new()
                        } else {
                            format!(
                                " {}",
                                chip.selection
                                    .arguments
                                    .chars()
                                    .take(48)
                                    .collect::<String>()
                            )
                        }
                    )))
                    .child(
                        self.button(
                            SharedString::from(format!("skill-arguments-{index}")),
                            "Arguments",
                        )
                        .debug_selector(move || format!("skill-arguments-{index}"))
                        .on_click(cx.listener(
                            move |view, _, window, cx| {
                                view.edit_skill_arguments(&edit_target, &edit_chip, window, cx)
                            },
                        )),
                    )
                    .child(
                        self.button(SharedString::from(format!("skill-remove-{index}")), "×")
                            .debug_selector(move || format!("skill-remove-{index}"))
                            .on_click(cx.listener(move |view, _, _, cx| {
                                view.remove_presented_skill(&remove_target, &remove_chip, cx)
                            })),
                    ),
            );
        }
        row.child(chips)
    }
}
#[cfg(test)]
#[path = "composer_skills_tests.rs"]
pub(crate) mod tests;
