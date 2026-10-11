//! The cell grid a terminal emulator writes into: one cell per column, the
//! style it carries, and the history line it becomes when it scrolls off
//! (Swift 0.1.122 Terminal/TerminalScreen.swift).

/// A cell's colour: the terminal's own, one of the 256 indexed, or 24-bit.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum TerminalColor {
    #[default]
    Standard,
    Indexed(u8),
    Rgb(u8, u8, u8),
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct CellStyle {
    pub foreground: TerminalColor,
    pub background: TerminalColor,
    pub bold: bool,
    pub dim: bool,
    pub italic: bool,
    pub underline: bool,
    pub inverse: bool,
    pub strikethrough: bool,
    pub hidden: bool,
}
impl CellStyle {
    pub const PLAIN: Self = Self {
        foreground: TerminalColor::Standard,
        background: TerminalColor::Standard,
        bold: false,
        dim: false,
        italic: false,
        underline: false,
        inverse: false,
        strikethrough: false,
        hidden: false,
    };
}

/// One grapheme: a base scalar with any combining marks, or nothing for the
/// trailing half of a wide character. A single scalar, nearly every cell,
/// is kept inline.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum CellText {
    Empty,
    Char(char),
    Long(Box<str>),
}
impl CellText {
    pub fn is_empty(&self) -> bool {
        matches!(self, Self::Empty)
    }
    pub fn is_space(&self) -> bool {
        matches!(self, Self::Char(' '))
    }
    pub fn first_char(&self) -> Option<char> {
        match self {
            Self::Empty => None,
            Self::Char(c) => Some(*c),
            Self::Long(s) => s.chars().next(),
        }
    }
    /// Its size in UTF-8 bytes.
    pub fn len_utf8(&self) -> usize {
        match self {
            Self::Empty => 0,
            Self::Char(c) => c.len_utf8(),
            Self::Long(s) => s.len(),
        }
    }
    /// Whether it is exactly one scalar.
    pub fn is_single(&self) -> bool {
        match self {
            Self::Char(_) => true,
            Self::Long(s) => s.chars().count() == 1,
            Self::Empty => false,
        }
    }
    pub fn push_to(&self, out: &mut String) {
        match self {
            Self::Empty => {}
            Self::Char(c) => out.push(*c),
            Self::Long(s) => out.push_str(s),
        }
    }
    pub fn as_string(&self) -> String {
        let mut out = String::new();
        self.push_to(&mut out);
        out
    }
    /// The text with one more scalar joined on (a combining mark).
    pub fn push_scalar(&mut self, scalar: char) {
        let mut text = self.as_string();
        text.push(scalar);
        *self = Self::Long(text.into_boxed_str());
    }
    pub fn from_text(text: &str) -> Self {
        let mut chars = text.chars();
        match (chars.next(), chars.next()) {
            (None, _) => Self::Empty,
            (Some(c), None) => Self::Char(c),
            _ => Self::Long(text.into()),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TerminalCell {
    pub text: CellText,
    /// 1 for a normal cell, 2 for the leading half of a wide character, 0 for the trailing half.
    pub width: u8,
    pub style: CellStyle,
    pub combining_truncated: bool,
}
impl TerminalCell {
    pub const BLANK: Self = Self {
        text: CellText::Char(' '),
        width: 1,
        style: CellStyle::PLAIN,
        combining_truncated: false,
    };
    pub fn new(text: CellText, width: u8, style: CellStyle) -> Self {
        Self {
            text,
            width,
            style,
            combining_truncated: false,
        }
    }
    pub fn space(style: CellStyle) -> Self {
        Self::new(CellText::Char(' '), 1, style)
    }
    pub fn is_blank(&self) -> bool {
        self.width == 1 && self.text.is_space()
    }
}

/// One line that has left the screen, kept as its characters and the runs of
/// style over them rather than as one cell per column, so ten thousand lines
/// of history stay small. Swift keeps the cells' pieces only when joining
/// their characters could merge two into one grapheme; this keeps them
/// whenever a cell holds anything but one scalar, which reads back the same.
#[derive(Clone, Debug)]
pub struct TerminalHistoryLine {
    /// One character per cell that starts one; the trailing half of a wide
    /// character carries no text and none is stored for it.
    pub text: String,
    /// Styles over the cells, the trailing halves included.
    pub styles: Vec<(u32, CellStyle)>,
    /// Cells the line occupies, a wide character counting twice.
    pub cell_count: usize,
    exact: Option<Vec<Box<str>>>,
}
/// Swift's `MemoryLayout<StyleRun>.stride` and `MemoryLayout<String>.stride`.
const STYLE_RUN_STRIDE: usize = 20;
const STRING_STRIDE: usize = 16;
impl TerminalHistoryLine {
    pub fn new(cells: &[TerminalCell]) -> Self {
        let mut text = String::with_capacity(cells.len() + 16);
        let mut runs: Vec<(u32, CellStyle)> = Vec::new();
        let mut multi = false;
        for cell in cells {
            if cell.width != 0 {
                if !cell.text.is_single() {
                    multi = true;
                }
                cell.text.push_to(&mut text);
            }
            match runs.last_mut() {
                Some((length, style)) if *style == cell.style && *length < u32::MAX => *length += 1,
                _ => runs.push((1, cell.style)),
            }
        }
        let exact = multi.then(|| {
            cells
                .iter()
                .filter(|cell| cell.width != 0)
                .map(|cell| cell.text.as_string().into_boxed_str())
                .collect()
        });
        Self {
            text,
            styles: runs,
            cell_count: cells.len(),
            exact,
        }
    }
    pub fn retained_bytes(&self) -> usize {
        self.text.len()
            + self.styles.len() * STYLE_RUN_STRIDE
            + self.exact.as_ref().map_or(0, |pieces| {
                pieces.iter().map(|p| p.len() + STRING_STRIDE).sum()
            })
            + 128
    }
    /// The line as the screen held it. Widths come back from the characters
    /// themselves, which is where they came from when the line was printed.
    pub fn cells(&self) -> Vec<TerminalCell> {
        let mut result: Vec<TerminalCell> = Vec::with_capacity(self.cell_count);
        let mut run = 0usize;
        let mut used = 0u32;
        let mut next_style = || {
            while run < self.styles.len() && used >= self.styles[run].0 {
                run += 1;
                used = 0;
            }
            if run >= self.styles.len() {
                return CellStyle::PLAIN;
            }
            used += 1;
            self.styles[run].1
        };
        let count = self.cell_count;
        let mut append = |result: &mut Vec<TerminalCell>, piece: CellText| {
            if result.len() >= count {
                return;
            }
            let width = piece
                .first_char()
                .map_or(1, |c| super::width::width(c).max(1));
            result.push(TerminalCell::new(piece, width, next_style()));
            if width == 2 && result.len() < count {
                result.push(TerminalCell::new(CellText::Empty, 0, next_style()));
            }
        };
        match &self.exact {
            Some(pieces) => {
                for piece in pieces {
                    append(&mut result, CellText::from_text(piece));
                }
            }
            None => {
                for c in self.text.chars() {
                    append(&mut result, CellText::Char(c));
                }
            }
        }
        while result.len() < count {
            let style = next_style();
            result.push(TerminalCell::space(style));
        }
        result
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TerminalCursor {
    pub x: usize,
    pub y: usize,
}

/// The cursor shape a program asked for through DECSCUSR.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum TerminalCursorShape {
    #[default]
    Block,
    Underline,
    Bar,
}
