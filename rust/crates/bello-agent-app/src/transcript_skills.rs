//! Sent pills use the recorded selection, never a new discovery as authority.
//! They are a display projection; ordinary Copy remains Message.text.
use crate::{
    Palette,
    composer_skills::{SkillHint, policy_label},
};
use bello_agent_core::Message;
use gpui::{prelude::*, *};

pub(crate) fn pills(message: &Message, palette: Palette) -> Option<Div> {
    let content = message.user_content.as_ref()?;
    if content.skills.is_empty() {
        return None;
    }
    let mut row = div()
        .debug_selector(|| "transcript-skill-pills".into())
        .flex()
        .flex_wrap()
        .gap(px(5.));
    for (index, skill) in content.skills.iter().enumerate() {
        let policy = skill
            .policy
            .map(policy_label)
            .unwrap_or("Policy not recorded");
        let detail = format!(
            "{}\n{}\n{}\n{}\nRecorded version {}\nArguments: {}\nExplicit for this message. This grants no additional tools.",
            skill.name,
            skill.description.as_deref().unwrap_or(""),
            skill.path,
            policy,
            skill
                .selection
                .content_hash
                .chars()
                .take(8)
                .collect::<String>(),
            skill.selection.arguments
        );
        let id = message.id.clone();
        row = row.child(
            div()
                .id(SharedString::from(format!(
                    "sent-skill-{}-{index}",
                    message.id
                )))
                .debug_selector(move || format!("sent-skill-{id}-{index}"))
                .px(px(7.))
                .py(px(4.))
                .rounded(px(7.))
                .bg(palette.fill())
                .text_size(px(12.))
                .max_w(px(480.))
                .truncate()
                .child(format!(
                    "/{}{}",
                    skill.name,
                    if skill.selection.arguments.is_empty() {
                        String::new()
                    } else {
                        format!(
                            " {}",
                            skill
                                .selection
                                .arguments
                                .chars()
                                .take(48)
                                .collect::<String>()
                        )
                    }
                ))
                .tooltip(move |_, cx| {
                    cx.new(|_| SkillHint {
                        text: detail.clone(),
                        palette,
                    })
                    .into()
                }),
        );
    }
    Some(row)
}
