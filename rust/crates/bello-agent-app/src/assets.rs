//! Original BelloAgent branding; geometric Linux equivalents of the source's
//! SF Symbol controls. No replacement branding or welcome artwork.
use gpui::{AssetSource, SharedString};
use std::borrow::Cow;
pub struct Assets;
impl AssetSource for Assets {
    fn load(&self, path: &str) -> gpui::Result<Option<Cow<'static, [u8]>>> {
        if path == "bello-agent.png" {
            return Ok(Some(Cow::Borrowed(include_bytes!(
                "../../../../assets/branding/bello-agent-icon-128.png"
            ))));
        }
        let body = match path {
            "folder" => r#"<path d="M3 6h7l2 2h9v11H3z"/>"#,
            "pencil" => r#"<path d="m5 16-1 4 4-1L20 7l-3-3zM14 7l3 3"/>"#,
            "new-chat" => r#"<path d="M12 4H4v16h16v-8M10 14l1-4 9-9 3 3-9 9z"/>"#,
            "plus" => r#"<path d="M12 5v14M5 12h14"/>"#,
            "search" => r#"<circle cx="10" cy="10" r="6"/><path d="m15 15 6 6"/>"#,
            "branch" => {
                r#"<circle cx="6" cy="5" r="2"/><circle cx="18" cy="5" r="2"/><circle cx="6" cy="19" r="2"/><path d="M6 7v10M18 7c0 7-12 3-12 9"/>"#
            }
            "chat" => r#"<path d="M3 4h18v13H9l-5 4v-4H3z"/>"#,
            "chevron" => r#"<path d="m8 5 7 7-7 7"/>"#,
            "down" => r#"<path d="m5 8 7 7 7-7"/>"#,
            "steering" => r#"<path d="M5 20V10a4 4 0 0 1 4-4h10m-5-4 5 4-5 4"/>"#,
            "info" => r#"<circle cx="12" cy="12" r="9"/><path d="M12 10v7M12 6v1"/>"#,
            "dots" => {
                r#"<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>"#
            }
            "gear" => {
                r#"<circle cx="12" cy="12" r="3"/><path d="m10 3 4 0 1 3 3 1 3 3v4l-3 1-1 3-3 3h-4l-1-3-3-1-3-3v-4l3-1 1-3z"/>"#
            }
            "chart" => r#"<path d="M3 3v18h18M6 16l5-6 4 3 6-9"/>"#,
            "book" => r#"<path d="M4 4h14v16H4c-3-2 0-4 0-4h14M4 4v12"/>"#,
            "bug" => {
                r#"<rect x="7" y="7" width="10" height="13" rx="5"/><path d="M9 7V4h6v3M3 8l4 2M3 14h4M3 20l4-3M17 10l4-2M17 14h4M17 17l4 3M12 8v12"/>"#
            }
            "archive" => r#"<path d="M4 7h16v13H4zM3 3h18v4H3zM9 11h6"/>"#,
            "sparkles" => {
                r#"<path d="m9 3 2 6 6 2-6 2-2 6-2-6-6-2 6-2zM19 2v6M16 5h6M19 16v6M16 19h6"/>"#
            }
            "photo" => {
                r#"<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="8" cy="9" r="2"/><path d="m3 18 6-5 4 3 4-5 4 5"/>"#
            }
            "command" => {
                r#"<path d="M8 8h8v8H8zM8 8H5a3 3 0 1 1 3-3v14a3 3 0 1 1-3-3h14a3 3 0 1 1-3 3V5a3 3 0 1 1 3 3z"/>"#
            }
            "send" => r#"<path d="M12 20V4m-6 6 6-6 6 6"/>"#,
            "stop" => r#"<rect x="6" y="6" width="12" height="12" rx="1" fill="black"/>"#,
            "close" => r#"<path d="m6 6 12 12M6 18 18 6"/>"#,
            "terminal" => {
                r#"<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m6 8 4 4-4 4M13 16h5"/>"#
            }
            "cpu" => {
                r#"<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 3v3M15 3v3M9 18v3M15 18v3M3 9h3M3 15h3M18 9h3M18 15h3"/>"#
            }
            "antenna" => {
                r#"<circle cx="12" cy="12" r="2"/><path d="m12 14-3 7h6zM7 6a8 8 0 0 0 0 12M17 6a8 8 0 0 1 0 12M4 3a12 12 0 0 0 0 18M20 3a12 12 0 0 1 0 18"/>"#
            }
            _ => return Ok(None),
        };
        Ok(Some(Cow::Owned(format!(r#"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="black" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">{body}</svg>"#).into_bytes())))
    }
    fn list(&self, _: &str) -> gpui::Result<Vec<SharedString>> {
        Ok(Vec::new())
    }
}
