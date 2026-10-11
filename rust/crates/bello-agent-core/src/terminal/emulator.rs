//! A terminal emulator written for the app, ported from Swift 0.1.122
//! Terminal/TerminalEmulator.swift (with TerminalEmulatorReplies.swift and
//! TerminalScreenReading.swift): an xterm-style VT parser over a cell grid
//! with scrollback, an alternate screen, scroll regions, tab stops, the usual
//! modes and the replies programs ask for. It knows nothing about drawing or
//! processes; the panel draws it and the pseudo-terminal feeds it.
use super::screen::{
    CellStyle, CellText, TerminalCell, TerminalColor, TerminalCursor, TerminalCursorShape,
    TerminalHistoryLine,
};
use super::width::width;
use std::collections::BTreeSet;

/// What the emulator asks of its owner, in order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TerminalEvent {
    Bell,
    TitleChanged(String),
    DirectoryChanged(Option<String>),
    /// A cell's combining marks passed `CELL_TEXT_BYTE_LIMIT` (reported once).
    TextLimit,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Ground,
    Escape,
    EscapeIntermediate,
    CsiEntry,
    CsiParam,
    CsiIntermediate,
    CsiIgnore,
    OscString,
    DcsString,
    ApcString,
}

pub const CELL_TEXT_BYTE_LIMIT: usize = 64;
/// Cells the history may hold: a line costs as many cells as the terminal is wide.
pub const SCROLLBACK_CELL_LIMIT: usize = 2_000_000;
pub const SCROLLBACK_BYTE_LIMIT: usize = 16 * 1024 * 1024;

pub struct TerminalEmulator {
    columns: usize,
    rows: usize,
    screen: Vec<Vec<TerminalCell>>,
    scrollback: Vec<TerminalHistoryLine>,
    /// Lines dropped from the front of the scrollback since the start, so absolute line numbers stay stable.
    trimmed_lines: usize,
    scrollback_limit: usize,
    cursor: TerminalCursor,
    cursor_visible: bool,
    cursor_shape: TerminalCursorShape,
    title: String,
    current_directory: Option<String>,
    application_cursor_keys: bool,
    application_keypad: bool,
    bracketed_paste: bool,
    focus_reporting: bool,
    alternate_screen: bool,
    mouse_reporting: bool,
    origin_mode: bool,
    autowrap: bool,
    insert_mode: bool,
    newline_mode: bool,
    style: CellStyle,
    scroll_top: usize,
    scroll_bottom: usize,
    /// Rows of the screen that changed since the last `clear_dirty`; None means everything.
    dirty_rows: Option<BTreeSet<usize>>,
    last_dirty_row: Option<usize>,
    /// One cell's size in points (XTWINOPS 14); replies round the totals.
    pub cell_pixel_size: (f64, f64),
    /// The colours a program gets when it asks for the defaults (OSC 10/11).
    pub default_foreground_rgb: (u8, u8, u8),
    pub default_background_rgb: (u8, u8, u8),
    output: Vec<u8>,
    events: Vec<TerminalEvent>,

    state: State,
    parameters: Vec<Vec<i64>>,
    parameter_value: i64,
    parameter_digits: usize,
    sub_parameters: Vec<i64>,
    intermediates: Vec<u8>,
    private_marker: u8,
    osc_buffer: Vec<u8>,
    string_escape: bool,
    utf8_pending: Vec<u8>,
    utf8_needed: usize,

    wrap_next: bool,
    tab_stops: BTreeSet<usize>,
    saved_cursor: TerminalCursor,
    saved_style: CellStyle,
    saved_origin: bool,
    saved_autowrap: bool,
    saved_wrap_next: bool,
    saved_charset: usize,
    saved_charsets: [u8; 2],
    saved_main_screen: Option<Vec<Vec<TerminalCell>>>,
    saved_main_cursor: TerminalCursor,
    /// G0 and G1 designations: 0 ASCII, 1 DEC special graphics. `charset` picks the active one (SI/SO).
    charsets: [u8; 2],
    charset: usize,
    last_printed: Option<char>,
    reported_text_limit: bool,
    scrollback_bytes: usize,
    scrollback_cells: usize,
}

impl Default for TerminalEmulator {
    fn default() -> Self {
        Self::new(80, 24, 10_000)
    }
}

impl TerminalEmulator {
    pub fn new(columns: usize, rows: usize, scrollback_limit: usize) -> Self {
        let columns = columns.max(2);
        let rows = rows.max(1);
        let mut emulator = Self {
            columns,
            rows,
            screen: vec![vec![TerminalCell::BLANK; columns]; rows],
            scrollback: Vec::new(),
            trimmed_lines: 0,
            scrollback_limit,
            cursor: TerminalCursor::default(),
            cursor_visible: true,
            cursor_shape: TerminalCursorShape::Block,
            title: String::new(),
            current_directory: None,
            application_cursor_keys: false,
            application_keypad: false,
            bracketed_paste: false,
            focus_reporting: false,
            alternate_screen: false,
            mouse_reporting: false,
            origin_mode: false,
            autowrap: true,
            insert_mode: false,
            newline_mode: false,
            style: CellStyle::PLAIN,
            scroll_top: 0,
            scroll_bottom: rows - 1,
            dirty_rows: None,
            last_dirty_row: None,
            cell_pixel_size: (8., 16.),
            default_foreground_rgb: (0x1d, 0x1b, 0x17),
            default_background_rgb: (0xf7, 0xf2, 0xec),
            output: Vec::new(),
            events: Vec::new(),
            state: State::Ground,
            parameters: Vec::new(),
            parameter_value: 0,
            parameter_digits: 0,
            sub_parameters: Vec::new(),
            intermediates: Vec::new(),
            private_marker: 0,
            osc_buffer: Vec::new(),
            string_escape: false,
            utf8_pending: Vec::new(),
            utf8_needed: 0,
            wrap_next: false,
            tab_stops: BTreeSet::new(),
            saved_cursor: TerminalCursor::default(),
            saved_style: CellStyle::PLAIN,
            saved_origin: false,
            saved_autowrap: true,
            saved_wrap_next: false,
            saved_charset: 0,
            saved_charsets: [0, 0],
            saved_main_screen: None,
            saved_main_cursor: TerminalCursor::default(),
            charsets: [0, 0],
            charset: 0,
            last_printed: None,
            reported_text_limit: false,
            scrollback_bytes: 0,
            scrollback_cells: 0,
        };
        emulator.reset_tab_stops();
        emulator
    }

    // MARK: State readers

    pub fn columns(&self) -> usize {
        self.columns
    }
    pub fn rows(&self) -> usize {
        self.rows
    }
    pub fn screen(&self) -> &[Vec<TerminalCell>] {
        &self.screen
    }
    pub fn scrollback(&self) -> &[TerminalHistoryLine] {
        &self.scrollback
    }
    pub fn scrollback_len(&self) -> usize {
        self.scrollback.len()
    }
    pub fn trimmed_lines(&self) -> usize {
        self.trimmed_lines
    }
    pub fn scrollback_bytes(&self) -> usize {
        self.scrollback_bytes
    }
    pub fn cursor(&self) -> TerminalCursor {
        self.cursor
    }
    pub fn cursor_visible(&self) -> bool {
        self.cursor_visible
    }
    pub fn cursor_shape(&self) -> TerminalCursorShape {
        self.cursor_shape
    }
    pub fn title(&self) -> &str {
        &self.title
    }
    pub fn current_directory(&self) -> Option<&str> {
        self.current_directory.as_deref()
    }
    pub fn application_cursor_keys(&self) -> bool {
        self.application_cursor_keys
    }
    pub fn application_keypad(&self) -> bool {
        self.application_keypad
    }
    pub fn bracketed_paste(&self) -> bool {
        self.bracketed_paste
    }
    pub fn focus_reporting(&self) -> bool {
        self.focus_reporting
    }
    pub fn alternate_screen(&self) -> bool {
        self.alternate_screen
    }
    pub fn mouse_reporting(&self) -> bool {
        self.mouse_reporting
    }
    pub fn origin_mode(&self) -> bool {
        self.origin_mode
    }
    pub fn autowrap(&self) -> bool {
        self.autowrap
    }
    pub fn insert_mode(&self) -> bool {
        self.insert_mode
    }
    pub fn newline_mode(&self) -> bool {
        self.newline_mode
    }
    pub fn style(&self) -> CellStyle {
        self.style
    }
    pub fn scroll_region(&self) -> (usize, usize) {
        (self.scroll_top, self.scroll_bottom)
    }
    /// Rows changed since the last `clear_dirty`; None means everything.
    pub fn dirty_rows(&self) -> Option<&BTreeSet<usize>> {
        self.dirty_rows.as_ref()
    }
    /// The bytes programs asked to have sent back (replies), since last taken.
    pub fn take_output(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.output)
    }
    pub fn take_events(&mut self) -> Vec<TerminalEvent> {
        std::mem::take(&mut self.events)
    }

    // MARK: Dirty rows

    pub fn clear_dirty(&mut self) {
        self.dirty_rows = Some(BTreeSet::new());
        self.last_dirty_row = None;
    }
    fn mark_dirty(&mut self, row: usize) {
        if self.last_dirty_row == Some(row) {
            return;
        }
        if let Some(rows) = self.dirty_rows.as_mut() {
            rows.insert(row);
            self.last_dirty_row = Some(row);
        }
    }
    fn mark_all_dirty(&mut self) {
        self.dirty_rows = None;
        self.last_dirty_row = None;
    }

    // MARK: Feeding bytes

    pub fn feed(&mut self, bytes: &[u8]) {
        let mut index = 0;
        while index < bytes.len() {
            let byte = bytes[index];
            // Printable ASCII in the ground state, which is nearly everything a terminal sees, prints a run at a time.
            if (0x20..0x7f).contains(&byte)
                && self.state == State::Ground
                && self.utf8_needed == 0
                && !self.insert_mode
                && self.charsets[self.charset] == 0
            {
                index += self.print_run(bytes, index);
            } else {
                self.process(byte);
                index += 1;
            }
        }
    }
    pub fn feed_str(&mut self, text: &str) {
        self.feed(text.as_bytes());
    }
    /// Prints the printable ASCII run starting at `start`, as far as the current line takes it; returns the bytes consumed.
    fn print_run(&mut self, bytes: &[u8], start: usize) -> usize {
        if self.wrap_next {
            if self.autowrap {
                self.cursor.x = 0;
                self.line_feed();
            } else {
                self.cursor.x = self.columns - 1;
            }
            self.wrap_next = false;
        }
        let y = self.cursor.y;
        let columns = self.columns;
        let style = self.style;
        let mut x = self.cursor.x;
        let mut index = start;
        let row = &mut self.screen[y];
        while index < bytes.len() && x < columns {
            let byte = bytes[index];
            if !(0x20..0x7f).contains(&byte) {
                break;
            }
            // Overwriting one half of a wide character clears the other half.
            let existing_width = row[x].width;
            if existing_width == 2 && x + 1 < columns {
                row[x + 1] = TerminalCell::space(row[x].style);
            } else if existing_width == 0 && x > 0 {
                row[x - 1] = TerminalCell::space(row[x - 1].style);
            }
            row[x] = TerminalCell::new(CellText::Char(byte as char), 1, style);
            x += 1;
            index += 1;
        }
        self.last_printed = Some(bytes[index - 1] as char);
        self.mark_dirty(y);
        if x >= columns {
            self.cursor.x = columns - 1;
            self.wrap_next = true;
        } else {
            self.cursor.x = x;
        }
        index - start
    }

    fn process(&mut self, byte: u8) {
        // C0 controls act in every state except inside strings, where they mostly end the string.
        match self.state {
            State::Ground => {
                if byte >= 0x80 || self.utf8_needed > 0 {
                    self.decode_utf8(byte);
                    return;
                }
                if byte < 0x20 || byte == 0x7f {
                    self.control(byte);
                    return;
                }
                // Printable ASCII: one cell, no Unicode lookups.
                if self.charsets[self.charset] == 0 {
                    self.print_width(byte as char, 1);
                } else {
                    self.print(byte as char);
                }
            }
            State::Escape => {
                self.utf8_pending.clear();
                self.utf8_needed = 0;
                match byte {
                    0x5b => {
                        self.state = State::CsiEntry;
                        self.parameters.clear();
                        self.intermediates.clear();
                        self.private_marker = 0;
                        self.parameter_value = 0;
                        self.parameter_digits = 0;
                        self.sub_parameters.clear();
                    }
                    0x5d => {
                        self.state = State::OscString;
                        self.osc_buffer.clear();
                        self.string_escape = false;
                    }
                    0x50 => {
                        self.state = State::DcsString;
                        self.string_escape = false;
                    }
                    0x58 | 0x5e | 0x5f => {
                        self.state = State::ApcString;
                        self.string_escape = false;
                    }
                    0x20..=0x2f => {
                        self.intermediates = vec![byte];
                        self.state = State::EscapeIntermediate;
                    }
                    0x18 | 0x1a => self.state = State::Ground,
                    0x1b => {}
                    _ => {
                        if byte < 0x20 {
                            self.control(byte);
                        } else {
                            self.escape(byte, &[]);
                            self.state = State::Ground;
                        }
                    }
                }
            }
            State::EscapeIntermediate => {
                if (0x20..=0x2f).contains(&byte) {
                    if self.intermediates.len() < 2 {
                        self.intermediates.push(byte);
                    }
                } else if byte < 0x20 {
                    self.control(byte);
                } else {
                    let intermediates = std::mem::take(&mut self.intermediates);
                    self.escape(byte, &intermediates);
                    self.intermediates = intermediates;
                    self.state = State::Ground;
                }
            }
            State::CsiEntry | State::CsiParam | State::CsiIntermediate | State::CsiIgnore => {
                self.csi(byte)
            }
            State::OscString => match byte {
                0x07 => {
                    self.finish_osc();
                    self.state = State::Ground;
                }
                0x1b => self.string_escape = true,
                0x5c if self.string_escape => {
                    self.finish_osc();
                    self.state = State::Ground;
                }
                0x18 | 0x1a => self.state = State::Ground,
                _ => {
                    if self.string_escape {
                        self.string_escape = false;
                        if self.osc_buffer.len() < 65_536 {
                            self.osc_buffer.push(0x1b);
                        }
                    }
                    if self.osc_buffer.len() < 65_536 {
                        self.osc_buffer.push(byte);
                    }
                }
            },
            State::DcsString | State::ApcString => match byte {
                0x07 => self.state = State::Ground,
                0x1b => self.string_escape = true,
                0x5c if self.string_escape => self.state = State::Ground,
                0x18 | 0x1a => self.state = State::Ground,
                _ => self.string_escape = false,
            },
        }
    }

    fn decode_utf8(&mut self, byte: u8) {
        if self.utf8_needed == 0 {
            if byte & 0xe0 == 0xc0 {
                self.utf8_needed = 1;
            } else if byte & 0xf0 == 0xe0 {
                self.utf8_needed = 2;
            } else if byte & 0xf8 == 0xf0 {
                self.utf8_needed = 3;
            } else {
                self.print('\u{fffd}');
                return;
            }
            self.utf8_pending.clear();
            self.utf8_pending.push(byte);
            return;
        }
        if byte & 0xc0 != 0x80 {
            // A broken sequence: show the replacement character and reinterpret this byte.
            self.utf8_pending.clear();
            self.utf8_needed = 0;
            self.print('\u{fffd}');
            self.process(byte);
            return;
        }
        self.utf8_pending.push(byte);
        self.utf8_needed -= 1;
        if self.utf8_needed == 0 {
            let scalar = std::str::from_utf8(&self.utf8_pending)
                .ok()
                .and_then(|text| text.chars().next())
                .unwrap_or('\u{fffd}');
            self.utf8_pending.clear();
            self.print(scalar);
        }
    }

    // MARK: Controls and escapes

    fn control(&mut self, byte: u8) {
        match byte {
            0x07 => self.events.push(TerminalEvent::Bell),
            0x08 => {
                if self.cursor.x > 0 {
                    self.cursor.x -= 1;
                }
                self.wrap_next = false;
                self.mark_dirty(self.cursor.y);
            }
            0x09 => self.tab(),
            0x0a..=0x0c => {
                self.line_feed();
                if self.newline_mode {
                    self.cursor.x = 0;
                }
            }
            0x0d => {
                self.cursor.x = 0;
                self.wrap_next = false;
                self.mark_dirty(self.cursor.y);
            }
            0x0e => self.charset = 1,
            0x0f => self.charset = 0,
            0x1b => self.state = State::Escape,
            _ => {}
        }
    }

    fn escape(&mut self, final_byte: u8, intermediates: &[u8]) {
        if let Some(&first) = intermediates.first() {
            match (first, final_byte) {
                (0x28, _) => self.charsets[0] = u8::from(final_byte == 0x30), // ESC ( X designates G0
                (0x29, _) => self.charsets[1] = u8::from(final_byte == 0x30), // ESC ) X designates G1
                (0x23, 0x38) => self.alignment_pattern(),                     // DECALN
                _ => {}
            }
            return;
        }
        match final_byte {
            0x37 => self.save_cursor(),    // DECSC
            0x38 => self.restore_cursor(), // DECRC
            0x44 => self.line_feed(),      // IND
            0x45 => {
                // NEL
                self.line_feed();
                self.cursor.x = 0;
            }
            0x48 => {
                // HTS
                self.tab_stops.insert(self.cursor.x);
            }
            0x4d => self.reverse_index(),            // RI
            0x3d => self.application_keypad = true,  // DECKPAM
            0x3e => self.application_keypad = false, // DECKPNM
            0x63 => self.reset(),                    // RIS
            _ => {}
        }
    }

    fn csi(&mut self, byte: u8) {
        match byte {
            0x30..=0x3b => {
                if self.state == State::CsiIgnore {
                    return;
                }
                if self.state == State::CsiIntermediate {
                    self.state = State::CsiIgnore;
                    return;
                }
                self.state = State::CsiParam;
                if byte == 0x3b {
                    self.push_parameter();
                } else if byte == 0x3a {
                    if self.sub_parameters.len() >= 32 {
                        self.state = State::CsiIgnore;
                        return;
                    }
                    self.sub_parameters.push(if self.parameter_digits > 0 {
                        self.parameter_value
                    } else {
                        0
                    });
                    self.parameter_value = 0;
                    self.parameter_digits = 0;
                } else if self.parameter_digits < 16 {
                    self.parameter_value = self.parameter_value * 10 + i64::from(byte - 0x30);
                    self.parameter_digits += 1;
                }
            }
            0x3c..=0x3f => {
                if self.state == State::CsiEntry {
                    self.private_marker = byte;
                    self.state = State::CsiParam;
                } else {
                    self.state = State::CsiIgnore;
                }
            }
            0x20..=0x2f => {
                if self.state != State::CsiIgnore {
                    if self.intermediates.len() >= 2 {
                        self.state = State::CsiIgnore;
                        return;
                    }
                    self.intermediates.push(byte);
                    self.state = State::CsiIntermediate;
                }
            }
            0x40..=0x7e => {
                if self.state != State::CsiIgnore {
                    self.push_parameter();
                    self.dispatch_csi(byte);
                }
                self.state = State::Ground;
            }
            0x18 | 0x1a => self.state = State::Ground,
            0x1b => self.state = State::Escape,
            0x00..=0x1f => self.control(byte),
            _ => self.state = State::CsiIgnore,
        }
    }
    fn push_parameter(&mut self) {
        if !(self.parameter_digits > 0
            || !self.sub_parameters.is_empty()
            || !self.parameters.is_empty()
            || self.state == State::CsiParam)
        {
            return;
        }
        let mut parts = std::mem::take(&mut self.sub_parameters);
        parts.push(if self.parameter_digits > 0 {
            self.parameter_value
        } else {
            0
        });
        self.parameters.push(parts);
        self.parameter_value = 0;
        self.parameter_digits = 0;
        if self.parameters.len() > 32 {
            self.parameters.pop();
        }
    }
    fn parameter(&self, index: usize, default: i64) -> i64 {
        match self.parameters.get(index).and_then(|group| group.first()) {
            Some(&first) if first != 0 => first,
            _ => default,
        }
    }
    fn first_parameter(&self) -> i64 {
        self.parameters
            .first()
            .and_then(|group| group.first())
            .copied()
            .unwrap_or(0)
    }

    fn dispatch_csi(&mut self, final_byte: u8) {
        let p0 = self.parameter(0, 1);
        let columns = self.columns as i64;
        if self.private_marker == 0x3f {
            match final_byte {
                0x68 | 0x6c => {
                    let modes: Vec<i64> = self
                        .parameters
                        .iter()
                        .map(|g| g.first().copied().unwrap_or(0))
                        .collect();
                    for mode in modes {
                        self.set_private_mode(mode, final_byte == 0x68);
                    }
                }
                0x70 if self.intermediates == [0x24] => {
                    self.report_private_mode(self.first_parameter()) // DECRQM
                }
                // xterm erases saved lines via ?3J too
                0x4a if self.parameter(0, 0) == 3 => {
                    self.clear_scrollback();
                    self.mark_all_dirty();
                }
                _ => {}
            }
            return;
        }
        if self.private_marker == 0x3e {
            if final_byte == 0x63 {
                self.respond("\u{1b}[>1;10;0c"); // secondary DA
            }
            return;
        }
        if self.private_marker != 0 {
            return;
        }
        if self.intermediates == [0x20] {
            if final_byte == 0x71 {
                // DECSCUSR
                self.cursor_shape = match self.parameter(0, 0) {
                    3 | 4 => TerminalCursorShape::Underline,
                    5 | 6 => TerminalCursorShape::Bar,
                    _ => TerminalCursorShape::Block,
                };
                self.mark_dirty(self.cursor.y);
            }
            return;
        }
        if self.intermediates == [0x24] {
            if final_byte == 0x70 {
                self.report_mode(self.first_parameter());
            }
            return;
        }
        if !self.intermediates.is_empty() {
            return;
        }
        match final_byte {
            0x40 => self.insert_blanks(p0),         // ICH
            0x41 => self.move_cursor(0, -p0),       // CUU
            0x42 | 0x65 => self.move_cursor(0, p0), // CUD, VPR
            0x43 | 0x61 => self.move_cursor(p0, 0), // CUF, HPR
            0x44 => self.move_cursor(-p0, 0),       // CUB
            0x45 => {
                // CNL
                self.move_cursor(0, p0);
                self.cursor.x = 0;
            }
            0x46 => {
                // CPL
                self.move_cursor(0, -p0);
                self.cursor.x = 0;
            }
            0x47 | 0x60 => self.set_cursor(p0 - 1, self.cursor.y as i64, false), // CHA, HPA
            0x48 | 0x66 => self.set_cursor(self.parameter(1, 1) - 1, p0 - 1, true), // CUP, HVP
            0x49 => {
                // CHT: further tabs stay at the edge
                for _ in 0..p0.min(columns) {
                    self.tab();
                }
            }
            0x4a => self.erase_in_display(self.parameter(0, 0)), // ED
            0x4b => self.erase_in_line(self.parameter(0, 0)),    // EL
            0x4c => self.insert_lines(p0),                       // IL
            0x4d => self.delete_lines(p0),                       // DL
            0x50 => self.delete_characters(p0),                  // DCH
            0x53 => self.scroll_up(p0),                          // SU
            0x54 => self.scroll_down(p0),                        // SD
            0x58 => self.erase_characters(p0),                   // ECH
            0x5a => {
                // CBT
                for _ in 0..p0.min(columns) {
                    self.back_tab();
                }
            }
            0x62 => self.repeat_last(p0),           // REP
            0x63 => self.respond("\u{1b}[?62;22c"), // DA1
            0x64 => self.set_cursor(self.cursor.x as i64, p0 - 1, true), // VPA
            0x67 => {
                // TBC
                match self.parameter(0, 0) {
                    3 => self.tab_stops.clear(),
                    0 => {
                        self.tab_stops.remove(&self.cursor.x);
                    }
                    _ => {}
                }
            }
            0x68 | 0x6c => {
                // SM, RM
                let modes: Vec<i64> = self
                    .parameters
                    .iter()
                    .map(|g| g.first().copied().unwrap_or(0))
                    .collect();
                for mode in modes {
                    self.set_mode(mode, final_byte == 0x68);
                }
            }
            0x6d => self.select_graphic_rendition(), // SGR
            0x6e => self.device_status(self.parameter(0, 0)), // DSR
            0x72 => self.set_scroll_region(
                self.parameter(0, 1) - 1,
                self.parameter(1, self.rows as i64) - 1,
            ), // DECSTBM
            0x73 => self.saved_cursor = self.cursor, // SCOSC
            0x74 => self.window_operation(self.parameter(0, 0)), // XTWINOPS
            0x75 => {
                // SCORC
                let previous = self.cursor.y;
                self.cursor = self.saved_cursor;
                self.wrap_next = false;
                self.clamp_cursor();
                self.mark_dirty(previous);
                self.mark_dirty(self.cursor.y);
            }
            _ => {}
        }
    }

    fn finish_osc(&mut self) {
        let content = String::from_utf8_lossy(&self.osc_buffer).into_owned();
        let separator = match content.find(';') {
            Some(index) => index,
            None if content.chars().all(char::is_numeric) => content.len(),
            None => return,
        };
        let code: i64 = content[..separator].parse().unwrap_or(-1);
        let argument = if separator < content.len() {
            content[separator + 1..].to_owned()
        } else {
            String::new()
        };
        match code {
            0 | 2 => {
                self.title = argument.clone();
                self.events.push(TerminalEvent::TitleChanged(argument));
            }
            1 => {
                if self.title.is_empty() {
                    self.title = argument.clone();
                    self.events.push(TerminalEvent::TitleChanged(argument));
                }
            }
            7 => {
                let directory = file_url_path(&argument);
                self.current_directory = directory.clone();
                self.events.push(TerminalEvent::DirectoryChanged(directory));
            }
            10 | 11 => {
                if argument != "?" {
                    return;
                }
                let (r, g, b) = if code == 10 {
                    self.default_foreground_rgb
                } else {
                    self.default_background_rgb
                };
                let reply = format!(
                    "\u{1b}]{code};rgb:{r:02x}{r:02x}/{g:02x}{g:02x}/{b:02x}{b:02x}\u{1b}\\"
                );
                self.respond(&reply);
            }
            _ => {}
        }
    }

    // MARK: Modes

    fn set_mode(&mut self, mode: i64, on: bool) {
        match mode {
            4 => self.insert_mode = on,
            20 => self.newline_mode = on,
            _ => {}
        }
    }
    fn set_private_mode(&mut self, mode: i64, on: bool) {
        match mode {
            1 => self.application_cursor_keys = on,
            6 => {
                self.origin_mode = on;
                self.set_cursor(0, 0, true);
            }
            7 => self.autowrap = on,
            25 => {
                self.cursor_visible = on;
                self.mark_dirty(self.cursor.y);
            }
            47 | 1047 => self.switch_screen(on, false),
            1048 => {
                if on {
                    self.save_cursor()
                } else {
                    self.restore_cursor()
                }
            }
            1049 => self.switch_screen(on, true),
            1000 | 1002 | 1003 | 1006 => self.mouse_reporting = on,
            1004 => self.focus_reporting = on,
            2004 => self.bracketed_paste = on,
            _ => {}
        }
    }
    fn switch_screen(&mut self, alternate: bool, save: bool) {
        if alternate == self.alternate_screen {
            return;
        }
        if alternate {
            if save {
                self.save_cursor();
            }
            let blank = vec![vec![TerminalCell::BLANK; self.columns]; self.rows];
            self.saved_main_screen = Some(std::mem::replace(&mut self.screen, blank));
            self.saved_main_cursor = self.cursor;
            self.alternate_screen = true;
        } else {
            if let Some(main) = self.saved_main_screen.take() {
                self.screen = fit(main, self.columns, self.rows);
            }
            self.cursor = self.saved_main_cursor;
            self.clamp_cursor();
            self.alternate_screen = false;
            if save {
                self.restore_cursor();
            }
        }
        self.wrap_next = false;
        self.mark_all_dirty();
    }

    // MARK: Replies (TerminalEmulatorReplies.swift)

    fn report_private_mode(&mut self, mode: i64) {
        let flag = |on: bool| if on { 1 } else { 2 };
        let value = match mode {
            1 => flag(self.application_cursor_keys),
            6 => flag(self.origin_mode),
            7 => flag(self.autowrap),
            25 => flag(self.cursor_visible),
            47 | 1047 | 1049 => flag(self.alternate_screen),
            1004 => flag(self.focus_reporting),
            2004 => flag(self.bracketed_paste),
            2026 => 2,
            _ => 0,
        };
        self.respond(&format!("\u{1b}[?{mode};{value}$y"));
    }
    fn report_mode(&mut self, mode: i64) {
        let value = match mode {
            4 => {
                if self.insert_mode {
                    1
                } else {
                    2
                }
            }
            20 => {
                if self.newline_mode {
                    1
                } else {
                    2
                }
            }
            _ => 0,
        };
        self.respond(&format!("\u{1b}[{mode};{value}$y"));
    }
    fn device_status(&mut self, kind: i64) {
        match kind {
            5 => self.respond("\u{1b}[0n"),
            6 => {
                let top = if self.origin_mode { self.scroll_top } else { 0 };
                let reply = format!(
                    "\u{1b}[{};{}R",
                    self.cursor.y as i64 - top as i64 + 1,
                    self.cursor.x + 1
                );
                self.respond(&reply);
            }
            _ => {}
        }
    }
    fn window_operation(&mut self, operation: i64) {
        match operation {
            14 => {
                let height = swift_round(self.rows as f64 * self.cell_pixel_size.1);
                let width = swift_round(self.columns as f64 * self.cell_pixel_size.0);
                self.respond(&format!("\u{1b}[4;{height};{width}t"));
            }
            18 => {
                let reply = format!("\u{1b}[8;{};{}t", self.rows, self.columns);
                self.respond(&reply);
            }
            _ => {}
        }
    }
    fn respond(&mut self, text: &str) {
        self.output.extend_from_slice(text.as_bytes());
    }

    // MARK: Cursor

    fn clamp_cursor(&mut self) {
        self.cursor.x = self.cursor.x.min(self.columns - 1);
        self.cursor.y = self.cursor.y.min(self.rows - 1);
    }
    fn move_cursor(&mut self, dx: i64, dy: i64) {
        let previous = self.cursor.y;
        self.wrap_next = false;
        if dx != 0 {
            self.cursor.x = clamp(self.cursor.x as i64 + dx, 0, self.columns as i64 - 1);
        }
        if dy != 0 {
            // Movement never leaves the scroll region when the cursor is inside it.
            let top = if self.cursor.y >= self.scroll_top {
                self.scroll_top
            } else {
                0
            };
            let bottom = if self.cursor.y <= self.scroll_bottom {
                self.scroll_bottom
            } else {
                self.rows - 1
            };
            self.cursor.y = clamp(self.cursor.y as i64 + dy, top as i64, bottom as i64);
        }
        self.mark_dirty(previous);
        self.mark_dirty(self.cursor.y);
    }
    fn set_cursor(&mut self, x: i64, y: i64, origin: bool) {
        let previous = self.cursor.y;
        self.wrap_next = false;
        self.cursor.x = clamp(x, 0, self.columns as i64 - 1);
        if origin && self.origin_mode {
            let top = self.scroll_top as i64;
            self.cursor.y = clamp(y.saturating_add(top), top, self.scroll_bottom as i64);
        } else {
            self.cursor.y = clamp(y, 0, self.rows as i64 - 1);
        }
        self.mark_dirty(previous);
        self.mark_dirty(self.cursor.y);
    }
    fn save_cursor(&mut self) {
        self.saved_cursor = self.cursor;
        self.saved_style = self.style;
        self.saved_origin = self.origin_mode;
        self.saved_autowrap = self.autowrap;
        self.saved_wrap_next = self.wrap_next;
        self.saved_charset = self.charset;
        self.saved_charsets = self.charsets;
    }
    fn restore_cursor(&mut self) {
        let previous = self.cursor.y;
        self.cursor = self.saved_cursor;
        self.style = self.saved_style;
        self.origin_mode = self.saved_origin;
        self.autowrap = self.saved_autowrap;
        self.wrap_next = self.saved_wrap_next;
        self.charset = self.saved_charset;
        self.charsets = self.saved_charsets;
        self.clamp_cursor();
        self.mark_dirty(previous);
        self.mark_dirty(self.cursor.y);
    }
    fn tab(&mut self) {
        self.wrap_next = false;
        let next = self
            .tab_stops
            .range(self.cursor.x + 1..)
            .next()
            .copied()
            .unwrap_or(self.columns - 1);
        self.cursor.x = next.min(self.columns - 1);
        self.mark_dirty(self.cursor.y);
    }
    fn back_tab(&mut self) {
        self.wrap_next = false;
        self.cursor.x = self
            .tab_stops
            .range(..self.cursor.x)
            .next_back()
            .copied()
            .unwrap_or(0);
        self.mark_dirty(self.cursor.y);
    }
    fn reset_tab_stops(&mut self) {
        self.tab_stops = (8..self.columns.max(9)).step_by(8).collect();
    }

    // MARK: Printing

    fn print(&mut self, scalar: char) {
        let mut scalar = scalar;
        if self.charsets[self.charset] == 1
            && let Some(mapped) = special_graphics(scalar)
        {
            scalar = mapped;
        }
        self.print_width(scalar, width(scalar));
    }
    fn print_width(&mut self, scalar: char, width: u8) {
        self.last_printed = Some(scalar);
        let columns = self.columns;
        if width == 0 {
            // A combining mark joins the cell before the cursor.
            let mut x = self.cursor.x as i64 - if self.wrap_next { 0 } else { 1 };
            if x < 0 {
                return;
            }
            let y = self.cursor.y;
            if self.screen[y][x as usize].width == 0 {
                x -= 1;
            }
            if x < 0 {
                return;
            }
            let cell = &mut self.screen[y][x as usize];
            if cell.combining_truncated {
                return;
            }
            if cell.text.len_utf8() + scalar.len_utf8() > CELL_TEXT_BYTE_LIMIT {
                cell.text = CellText::Char('\u{fffd}');
                cell.combining_truncated = true;
                self.mark_dirty(y);
                if !self.reported_text_limit {
                    self.reported_text_limit = true;
                    self.events.push(TerminalEvent::TextLimit);
                }
                return;
            }
            cell.text.push_scalar(scalar);
            self.mark_dirty(y);
            return;
        }
        if self.wrap_next {
            if self.autowrap {
                self.cursor.x = 0;
                self.line_feed();
            } else {
                self.cursor.x = columns - 1;
            }
            self.wrap_next = false;
        }
        if width == 2 && self.cursor.x == columns - 1 {
            // A wide character never splits: leave a blank in the last column and start a new line.
            let blank = self.blank();
            let (x, y) = (self.cursor.x, self.cursor.y);
            self.screen[y][x] = blank;
            self.mark_dirty(y);
            if self.autowrap {
                self.cursor.x = 0;
                self.line_feed();
            } else {
                return;
            }
        }
        if self.insert_mode {
            self.insert_blanks(i64::from(width));
        }
        // Overwriting one half of a wide character clears the other half.
        self.clear_wide_neighbour(self.cursor.x);
        if width == 2 {
            self.clear_wide_neighbour(self.cursor.x + 1);
        }
        let (x, y) = (self.cursor.x, self.cursor.y);
        let style = self.style;
        self.screen[y][x] = TerminalCell::new(CellText::Char(scalar), width, style);
        if width == 2 {
            self.screen[y][x + 1] = TerminalCell::new(CellText::Empty, 0, style);
        }
        self.mark_dirty(y);
        self.cursor.x += usize::from(width);
        if self.cursor.x >= columns {
            self.cursor.x = columns - 1;
            self.wrap_next = true;
        }
    }
    fn clear_wide_neighbour(&mut self, x: usize) {
        if x >= self.columns {
            return;
        }
        let row = &mut self.screen[self.cursor.y];
        let cell_width = row[x].width;
        let cell_style = row[x].style;
        if cell_width == 2 && x + 1 < self.columns {
            row[x + 1] = TerminalCell::space(cell_style);
        }
        if cell_width == 0 && x > 0 {
            row[x - 1] = TerminalCell::space(row[x - 1].style);
        }
    }
    fn repeat_last(&mut self, count: i64) {
        let Some(scalar) = self.last_printed else {
            return;
        };
        for _ in 0..count.min((self.columns * self.rows) as i64) {
            self.print(scalar);
        }
    }
    fn blank_style(&self) -> CellStyle {
        CellStyle {
            background: self.style.background,
            ..CellStyle::PLAIN
        }
    }
    fn blank(&self) -> TerminalCell {
        TerminalCell::space(self.blank_style())
    }
    fn blank_row(&self) -> Vec<TerminalCell> {
        vec![self.blank(); self.columns]
    }

    // MARK: Scrolling and lines

    fn line_feed(&mut self) {
        self.wrap_next = false;
        if self.cursor.y == self.scroll_bottom {
            self.scroll_up(1);
        } else if self.cursor.y < self.rows - 1 {
            self.cursor.y += 1;
            self.mark_dirty(self.cursor.y - 1);
            self.mark_dirty(self.cursor.y);
        }
    }
    fn reverse_index(&mut self) {
        self.wrap_next = false;
        if self.cursor.y == self.scroll_top {
            self.scroll_down(1);
        } else if self.cursor.y > 0 {
            self.cursor.y -= 1;
            self.mark_dirty(self.cursor.y + 1);
            self.mark_dirty(self.cursor.y);
        }
    }
    fn region_height(&self) -> i64 {
        (self.scroll_bottom - self.scroll_top + 1) as i64
    }
    /// Lines leaving the top of the scroll region go to the scrollback when the region starts at the top of the main screen.
    fn scroll_up(&mut self, count: i64) {
        let count = count.max(1).min(self.region_height());
        for _ in 0..count {
            let line = self.screen.remove(self.scroll_top);
            if self.scroll_top == 0 && !self.alternate_screen {
                self.push_scrollback(&line);
            }
            let blank = self.blank_row();
            self.screen.insert(self.scroll_bottom, blank);
        }
        if self.scroll_top == 0 && self.scroll_bottom == self.rows - 1 {
            self.mark_all_dirty();
        } else {
            for row in self.scroll_top..=self.scroll_bottom {
                self.mark_dirty(row);
            }
        }
    }
    fn scroll_down(&mut self, count: i64) {
        let count = count.max(1).min(self.region_height());
        for _ in 0..count {
            self.screen.remove(self.scroll_bottom);
            let blank = self.blank_row();
            self.screen.insert(self.scroll_top, blank);
        }
        for row in self.scroll_top..=self.scroll_bottom {
            self.mark_dirty(row);
        }
    }
    fn push_scrollback(&mut self, line: &[TerminalCell]) {
        let mut end = line.len();
        while end > 0 && line[end - 1].is_blank() && line[end - 1].style == CellStyle::PLAIN {
            end -= 1;
        }
        let history = TerminalHistoryLine::new(&line[..end]);
        self.scrollback_bytes += history.retained_bytes();
        self.scrollback.push(history);
        self.scrollback_cells += end;
        if self.scrollback.len() > self.scrollback_limit {
            // Shifting the whole history for every line would cost more than the line: the oldest go in batches.
            let excess = self.scrollback.len() - self.scrollback_limit + self.scrollback_limit / 32;
            self.drop_oldest(excess);
        } else if self.scrollback_cells > SCROLLBACK_CELL_LIMIT {
            let (mut excess, mut freed) = (0, 0);
            while excess < self.scrollback.len()
                && freed
                    < self.scrollback_cells - SCROLLBACK_CELL_LIMIT + SCROLLBACK_CELL_LIMIT / 32
            {
                freed += self.scrollback[excess].cell_count;
                excess += 1;
            }
            self.drop_oldest(excess);
        }
        if self.scrollback_bytes > SCROLLBACK_BYTE_LIMIT {
            let (mut excess, mut freed) = (0, 0);
            while excess < self.scrollback.len()
                && freed
                    < self.scrollback_bytes - SCROLLBACK_BYTE_LIMIT + SCROLLBACK_BYTE_LIMIT / 32
            {
                freed += self.scrollback[excess].retained_bytes();
                excess += 1;
            }
            self.drop_oldest(excess);
        }
    }
    fn clear_scrollback(&mut self) {
        self.scrollback.clear();
        self.scrollback_cells = 0;
        self.scrollback_bytes = 0;
        self.trimmed_lines = 0;
    }
    /// Gives up the oldest lines of the history, keeping the counts with them.
    fn drop_oldest(&mut self, count: usize) {
        let count = count.min(self.scrollback.len());
        if count == 0 {
            return;
        }
        for line in &self.scrollback[..count] {
            self.scrollback_cells -= line.cell_count;
            self.scrollback_bytes -= line.retained_bytes();
        }
        self.scrollback.drain(..count);
        self.trimmed_lines += count;
    }
    fn insert_lines(&mut self, count: i64) {
        if self.cursor.y < self.scroll_top || self.cursor.y > self.scroll_bottom {
            return;
        }
        self.wrap_next = false;
        for _ in 0..count.min((self.scroll_bottom - self.cursor.y + 1) as i64) {
            self.screen.remove(self.scroll_bottom);
            let blank = self.blank_row();
            self.screen.insert(self.cursor.y, blank);
        }
        for row in self.cursor.y..=self.scroll_bottom {
            self.mark_dirty(row);
        }
    }
    fn delete_lines(&mut self, count: i64) {
        if self.cursor.y < self.scroll_top || self.cursor.y > self.scroll_bottom {
            return;
        }
        self.wrap_next = false;
        for _ in 0..count.min((self.scroll_bottom - self.cursor.y + 1) as i64) {
            self.screen.remove(self.cursor.y);
            let blank = self.blank_row();
            self.screen.insert(self.scroll_bottom, blank);
        }
        for row in self.cursor.y..=self.scroll_bottom {
            self.mark_dirty(row);
        }
    }
    fn insert_blanks(&mut self, count: i64) {
        self.wrap_next = false;
        let count = (count.max(0) as usize).min(self.columns - self.cursor.x);
        let blank = self.blank();
        let x = self.cursor.x;
        let row = &mut self.screen[self.cursor.y];
        row.truncate(row.len() - count);
        row.splice(x..x, std::iter::repeat_n(blank, count));
        repair_wide_pairs(row);
        self.mark_dirty(self.cursor.y);
    }
    fn delete_characters(&mut self, count: i64) {
        self.wrap_next = false;
        let count = (count.max(0) as usize).min(self.columns - self.cursor.x);
        let blank = self.blank();
        let x = self.cursor.x;
        let row = &mut self.screen[self.cursor.y];
        row.drain(x..x + count);
        row.extend(std::iter::repeat_n(blank, count));
        repair_wide_pairs(row);
        self.mark_dirty(self.cursor.y);
    }
    fn erase_characters(&mut self, count: i64) {
        self.wrap_next = false;
        let blank = self.blank();
        let end = (self.cursor.x as i64)
            .saturating_add(count)
            .min(self.columns as i64)
            .max(self.cursor.x as i64) as usize;
        let row = &mut self.screen[self.cursor.y];
        for cell in &mut row[self.cursor.x..end] {
            *cell = blank.clone();
        }
        repair_wide_pairs(row);
        self.mark_dirty(self.cursor.y);
    }
    fn erase_in_line(&mut self, mode: i64) {
        self.wrap_next = false;
        let range = match mode {
            1 => 0..self.columns.min(self.cursor.x + 1),
            2 => 0..self.columns,
            _ => self.cursor.x..self.columns,
        };
        let blank = self.blank();
        let row = &mut self.screen[self.cursor.y];
        for cell in &mut row[range] {
            *cell = blank.clone();
        }
        repair_wide_pairs(row);
        self.mark_dirty(self.cursor.y);
    }
    fn erase_in_display(&mut self, mode: i64) {
        self.wrap_next = false;
        match mode {
            1 => {
                for row in 0..self.cursor.y {
                    self.screen[row] = self.blank_row();
                    self.mark_dirty(row);
                }
                self.erase_in_line(1);
            }
            2 => {
                for row in 0..self.rows {
                    self.screen[row] = self.blank_row();
                }
                self.mark_all_dirty();
            }
            3 => {
                self.clear_scrollback();
                self.mark_all_dirty();
            }
            _ => {
                self.erase_in_line(0);
                for row in self.cursor.y + 1..self.rows {
                    self.screen[row] = self.blank_row();
                    self.mark_dirty(row);
                }
            }
        }
    }
    fn set_scroll_region(&mut self, top: i64, bottom: i64) {
        let last = self.rows as i64 - 1;
        let top = clamp(top, 0, last);
        let bottom = clamp(bottom, 0, last);
        if bottom <= top {
            return;
        }
        self.scroll_top = top;
        self.scroll_bottom = bottom;
        self.set_cursor(0, 0, true);
    }
    fn alignment_pattern(&mut self) {
        for row in 0..self.rows {
            self.screen[row] =
                vec![TerminalCell::new(CellText::Char('E'), 1, CellStyle::PLAIN); self.columns];
        }
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        self.set_cursor(0, 0, false);
        self.mark_all_dirty();
    }

    // MARK: SGR

    fn select_graphic_rendition(&mut self) {
        if self.parameters.is_empty() {
            self.style = CellStyle::PLAIN;
            return;
        }
        let mut index = 0;
        while index < self.parameters.len() {
            let group = &self.parameters[index];
            let code = group.first().copied().unwrap_or(0);
            let style = &mut self.style;
            match code {
                0 => *style = CellStyle::PLAIN,
                1 => style.bold = true,
                2 => style.dim = true,
                3 => style.italic = true,
                4 => style.underline = if group.len() > 1 { group[1] != 0 } else { true },
                5 | 6 => {}
                7 => style.inverse = true,
                8 => style.hidden = true,
                9 => style.strikethrough = true,
                21 => style.underline = true,
                22 => {
                    style.bold = false;
                    style.dim = false;
                }
                23 => style.italic = false,
                24 => style.underline = false,
                27 => style.inverse = false,
                28 => style.hidden = false,
                29 => style.strikethrough = false,
                30..=37 => style.foreground = TerminalColor::Indexed((code - 30) as u8),
                39 => style.foreground = TerminalColor::Standard,
                40..=47 => style.background = TerminalColor::Indexed((code - 40) as u8),
                49 => style.background = TerminalColor::Standard,
                90..=97 => style.foreground = TerminalColor::Indexed((code - 90 + 8) as u8),
                100..=107 => style.background = TerminalColor::Indexed((code - 100 + 8) as u8),
                38 | 48 | 58 => {
                    // Either colon-separated within the group or semicolon-separated across groups.
                    let mut arguments: Vec<i64> = group[1..].to_vec();
                    let mut consumed = 0;
                    if arguments.is_empty() {
                        let rest: Vec<i64> = self.parameters[index + 1..]
                            .iter()
                            .map(|g| g.first().copied().unwrap_or(0))
                            .collect();
                        if rest.first() == Some(&5) {
                            arguments = rest.iter().take(2).copied().collect();
                            consumed = 2;
                        } else if rest.first() == Some(&2) {
                            arguments = rest.iter().take(4).copied().collect();
                            consumed = 4;
                        }
                    }
                    let mut colour = None;
                    if arguments.first() == Some(&5) && arguments.len() >= 2 {
                        colour = Some(TerminalColor::Indexed(clamp_u8(arguments[1])));
                    } else if arguments.first() == Some(&2) && arguments.len() >= 4 {
                        // 38:2::r:g:b carries a colour-space id; 38;2;r;g;b does not.
                        let rgb = if arguments.len() >= 5 {
                            &arguments[2..5]
                        } else {
                            &arguments[1..4]
                        };
                        colour = Some(TerminalColor::Rgb(
                            clamp_u8(rgb[0]),
                            clamp_u8(rgb[1]),
                            clamp_u8(rgb[2]),
                        ));
                    }
                    if let Some(colour) = colour {
                        if code == 38 {
                            self.style.foreground = colour;
                        } else if code == 48 {
                            self.style.background = colour;
                        }
                    }
                    index += consumed;
                }
                _ => {}
            }
            index += 1;
        }
    }

    // MARK: Resize and reset

    /// Fits the screen to a new size: columns are cut or padded, and when the
    /// screen shrinks the lines above the cursor go to the scrollback, coming
    /// back when it grows again.
    pub fn resize(&mut self, columns: usize, rows: usize) {
        let new_columns = columns.max(2);
        let new_rows = rows.max(1);
        if new_columns == self.columns && new_rows == self.rows {
            return;
        }
        // Swift's cursor.y may go negative while lines leave; it is clamped below.
        let mut cursor_y = self.cursor.y as i64;
        if new_rows < self.rows {
            let mut remove = self.rows - new_rows;
            // Prefer dropping blank lines below the cursor; then push lines from the top into the scrollback.
            while remove > 0
                && self.screen.len() as i64 > cursor_y + 1
                && text_of(&self.screen[self.screen.len() - 1]).is_empty()
            {
                self.screen.pop();
                remove -= 1;
            }
            while remove > 0 && !self.screen.is_empty() {
                let line = self.screen.remove(0);
                if !self.alternate_screen {
                    self.push_scrollback(&line);
                }
                cursor_y -= 1;
                remove -= 1;
            }
        } else if new_rows > self.rows {
            let mut add = new_rows - self.rows;
            while add > 0 && !self.alternate_screen {
                let Some(line) = self.scrollback.pop() else {
                    break;
                };
                self.scrollback_cells -= line.cell_count;
                self.scrollback_bytes -= line.retained_bytes();
                self.screen.insert(0, line.cells()); // fitted to the new columns below
                cursor_y += 1;
                add -= 1;
            }
            while add > 0 {
                self.screen.push(vec![TerminalCell::BLANK; self.columns]);
                add -= 1;
            }
        }
        self.columns = new_columns;
        self.rows = new_rows;
        self.screen = fit(std::mem::take(&mut self.screen), self.columns, self.rows);
        if let Some(main) = self.saved_main_screen.take() {
            self.saved_main_screen = Some(fit(main, self.columns, self.rows));
        }
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        self.cursor.y = cursor_y.max(0) as usize;
        self.clamp_cursor();
        self.saved_cursor.x = self.saved_cursor.x.min(self.columns - 1);
        self.saved_cursor.y = self.saved_cursor.y.min(self.rows - 1);
        self.saved_main_cursor.x = self.saved_main_cursor.x.min(self.columns - 1);
        self.saved_main_cursor.y = self.saved_main_cursor.y.min(self.rows - 1);
        self.wrap_next = false;
        self.reset_tab_stops();
        self.mark_all_dirty();
    }
    pub fn reset(&mut self) {
        self.screen = vec![vec![TerminalCell::BLANK; self.columns]; self.rows];
        self.saved_main_screen = None;
        self.alternate_screen = false;
        self.cursor = TerminalCursor::default();
        self.saved_cursor = TerminalCursor::default();
        self.style = CellStyle::PLAIN;
        self.saved_style = CellStyle::PLAIN;
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        self.cursor_visible = true;
        self.cursor_shape = TerminalCursorShape::Block;
        self.origin_mode = false;
        self.autowrap = true;
        self.insert_mode = false;
        self.newline_mode = false;
        self.application_cursor_keys = false;
        self.application_keypad = false;
        self.bracketed_paste = false;
        self.focus_reporting = false;
        self.mouse_reporting = false;
        self.charsets = [0, 0];
        self.charset = 0;
        self.wrap_next = false;
        self.reset_tab_stops();
        self.mark_all_dirty();
    }

    // MARK: Reading (TerminalScreenReading.swift)

    /// Every line the reader can see, oldest first: the scrollback then the screen.
    pub fn line_count(&self) -> usize {
        self.scrollback.len() + self.rows
    }
    pub fn line(&self, index: usize) -> Vec<TerminalCell> {
        if index < self.scrollback.len() {
            return self.scrollback[index].cells();
        }
        self.screen
            .get(index - self.scrollback.len())
            .cloned()
            .unwrap_or_default()
    }
    /// The text of one line without building its cells.
    pub fn text_at_line(&self, index: usize) -> String {
        if index >= self.scrollback.len() {
            let row = index - self.scrollback.len();
            return if row < self.rows {
                self.text_of_row(row)
            } else {
                String::new()
            };
        }
        self.scrollback[index].text.trim_end_matches(' ').to_owned()
    }
    /// The text of one screen row without trailing blanks.
    pub fn text_of_row(&self, row: usize) -> String {
        text_of(&self.screen[row])
    }
    /// The whole screen as text, rows joined by newlines, for accessibility and tests.
    pub fn screen_text(&self) -> String {
        (0..self.rows)
            .map(|row| self.text_of_row(row))
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// A line's text without trailing blanks.
pub fn text_of(cells: &[TerminalCell]) -> String {
    let mut end = cells.len();
    while end > 0
        && (cells[end - 1].is_blank()
            || (cells[end - 1].width == 0 && cells[end - 1].text.is_empty() && end == cells.len()))
    {
        end -= 1;
    }
    let mut text = String::new();
    for cell in &cells[..end] {
        cell.text.push_to(&mut text);
    }
    text
}

/// Blanks the half of a wide character that an insert, delete or erase
/// separated from its other half.
pub fn repair_wide_pairs(row: &mut [TerminalCell]) {
    let mut x = 0;
    while x < row.len() {
        let width = row[x].width;
        if width == 2 {
            if x + 1 < row.len() && row[x + 1].width == 0 {
                x += 2;
                continue;
            }
            row[x] = TerminalCell::space(row[x].style);
        } else if width == 0 {
            row[x] = TerminalCell::space(row[x].style);
        }
        x += 1;
    }
}

fn fit(lines: Vec<Vec<TerminalCell>>, columns: usize, rows: usize) -> Vec<Vec<TerminalCell>> {
    let mut result: Vec<Vec<TerminalCell>> = lines
        .into_iter()
        .take(rows)
        .map(|mut row| {
            row.truncate(columns);
            if row.last().is_some_and(|cell| cell.width == 2) {
                let last = row.len() - 1;
                row[last] = TerminalCell::BLANK;
            }
            row.resize(columns, TerminalCell::BLANK);
            row
        })
        .collect();
    while result.len() < rows {
        result.push(vec![TerminalCell::BLANK; columns]);
    }
    result
}

fn clamp(value: i64, low: i64, high: i64) -> usize {
    value.max(low).min(high).max(0) as usize
}
fn clamp_u8(value: i64) -> u8 {
    value.clamp(0, 255) as u8
}
/// Swift's `Double.rounded()`: half away from zero.
fn swift_round(value: f64) -> i64 {
    value.round() as i64
}

/// The path of a `file:` URL (OSC 7), as Foundation's `URL.path` reads it:
/// percent-decoded, any host ignored, no trailing slash.
fn file_url_path(argument: &str) -> Option<String> {
    let url = url::Url::parse(argument).ok()?;
    if url.scheme() != "file" {
        return None;
    }
    let raw = url.path();
    let mut bytes = Vec::with_capacity(raw.len());
    let source = raw.as_bytes();
    let mut index = 0;
    while index < source.len() {
        if source[index] == b'%'
            && index + 2 < source.len()
            && let Ok(byte) = u8::from_str_radix(&raw[index + 1..index + 3], 16)
        {
            bytes.push(byte);
            index += 3;
            continue;
        }
        bytes.push(source[index]);
        index += 1;
    }
    let mut path = String::from_utf8(bytes).ok()?;
    while path.len() > 1 && path.ends_with('/') {
        path.pop();
    }
    Some(path)
}

/// DEC special graphics, so line-drawing programs draw boxes rather than letters.
fn special_graphics(scalar: char) -> Option<char> {
    Some(match scalar {
        '`' => '\u{25c6}',
        'a' => '\u{2592}',
        'b' => '\u{2409}',
        'c' => '\u{240c}',
        'd' => '\u{240d}',
        'e' => '\u{240a}',
        'f' => '\u{00b0}',
        'g' => '\u{00b1}',
        'h' => '\u{2424}',
        'i' => '\u{240b}',
        'j' => '\u{2518}',
        'k' => '\u{2510}',
        'l' => '\u{250c}',
        'm' => '\u{2514}',
        'n' => '\u{253c}',
        'o' => '\u{23ba}',
        'p' => '\u{23bb}',
        'q' => '\u{2500}',
        'r' => '\u{23bc}',
        's' => '\u{23bd}',
        't' => '\u{251c}',
        'u' => '\u{2524}',
        'v' => '\u{2534}',
        'w' => '\u{252c}',
        'x' => '\u{2502}',
        'y' => '\u{2264}',
        'z' => '\u{2265}',
        '{' => '\u{03c0}',
        '|' => '\u{2260}',
        '}' => '\u{00a3}',
        '~' => '\u{00b7}',
        _ => return None,
    })
}
