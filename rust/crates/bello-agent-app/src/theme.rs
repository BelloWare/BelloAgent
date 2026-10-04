//! Tokens copied from apps/macos/PiApp/Design/DesignSystem.swift.
use gpui::{Hsla, WindowAppearance, rgb, rgba};
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Palette {
    pub dark: bool,
    pub window: u32,
    pub content: u32,
    pub surface: u32,
    pub sunken: u32,
    pub ink: u32,
    pub secondary: u32,
    pub tertiary: u32,
    pub accent: u32,
    pub brand: u32,
    pub danger: u32,
    pub user: u32,
}
impl Palette {
    pub fn for_appearance(appearance: WindowAppearance) -> Self {
        if matches!(
            appearance,
            WindowAppearance::Dark | WindowAppearance::VibrantDark
        ) {
            Self {
                dark: true,
                window: 0x1e1b18,
                content: 0x26221e,
                surface: 0x2e2925,
                sunken: 0x211d1a,
                ink: 0xf1ece5,
                secondary: 0xb0a79c,
                tertiary: 0x7c7469,
                accent: 0xf0a052,
                brand: 0xf0a052,
                danger: 0xea7c7c,
                user: 0x3a3129,
            }
        } else {
            Self {
                dark: false,
                window: 0xf6f1ea,
                content: 0xfcf9f5,
                surface: 0xffffff,
                sunken: 0xf7f2ec,
                ink: 0x1f1b17,
                secondary: 0x6f675e,
                tertiary: 0x9e958a,
                accent: 0x984709,
                brand: 0xd67520,
                danger: 0xc03a3a,
                user: 0xf8ecdf,
            }
        }
    }
    pub fn hairline(self) -> Hsla {
        rgba(if self.dark { 0xffffff17 } else { 0x00000012 }).into()
    }
    pub fn fill(self) -> Hsla {
        rgba(if self.dark { 0xffffff0d } else { 0x0000000b }).into()
    }
    pub fn accent_soft(self) -> Hsla {
        rgba(if self.dark { 0xf0a0522e } else { 0xd675201f }).into()
    }
    pub fn on_accent(self) -> Hsla {
        rgb(if self.dark { 0x1e1b18 } else { 0xffffff }).into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn source_light_and_dark_tokens() {
        let light = Palette::for_appearance(WindowAppearance::Light);
        assert_eq!(
            (
                light.window,
                light.content,
                light.surface,
                light.ink,
                light.accent
            ),
            (0xf6f1ea, 0xfcf9f5, 0xffffff, 0x1f1b17, 0x984709)
        );
        let dark = Palette::for_appearance(WindowAppearance::Dark);
        assert_eq!(
            (
                dark.window,
                dark.content,
                dark.surface,
                dark.ink,
                dark.accent
            ),
            (0x1e1b18, 0x26221e, 0x2e2925, 0xf1ece5, 0xf0a052)
        );
    }
}
