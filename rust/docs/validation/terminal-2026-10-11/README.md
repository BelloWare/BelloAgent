# Terminal panel (workstream D, 2026-10-11)

Branch `work/terminal`. Swift source of truth: 0.1.122
`apps/macos/PiApp/Terminal/*`, `Workspaces/TerminalPanel.swift`,
`Workspaces/TerminalPanelView.swift`, the Show/Hide Terminal command in
`Application/ApplicationMenus.swift`, the starter's Terminal button
(`ConversationPaneParts.swift`) and the pane placement in
`ConversationPane.swift`.

## Swift's terminal, feature by feature, and where Rust has it

| Swift feature (file) | Rust |
|---|---|
| xterm-style VT parser: C0 controls, ESC/CSI/OSC/DCS/APC/SOS/PM states, CAN/SUB, 32 params with colon sub-params, 2 intermediates, private markers (`TerminalEmulator.swift`) | `bello-agent-core/src/terminal/emulator.rs` (line-for-line port) |
| Cell grid with styles (fg/bg standard, 256, truecolor; bold, dim, italic, underline, inverse, strike, hidden), wide-character pairs and their repair, combining marks (64-byte cap, one notice), DEC special graphics G0/G1 with SI/SO, REP | same |
| Cursor movement (CUU…VPA, CUP/HVP, CHA/HPA, CNL/CPL, HPR/VPR), tab stops (HTS, TBC, CHT, CBT), DECSC/DECRC incl. charset, SCOSC/SCORC, origin mode, autowrap with pending wrap, insert and newline modes | same |
| Scroll regions (DECSTBM), IND/NEL/RI, IL/DL, ICH/DCH/ECH, ED 0-3 and `?3J`, EL, SU/SD, DECALN, RIS | same |
| Alternate screens 47/1047/1048/1049 (no scrollback there), cursor shapes (DECSCUSR), cursor visibility, bracketed paste, focus reporting, mouse-reporting flags, application cursor/keypad | same |
| Replies: DA1, DA2, DSR 5/6 (origin-relative), DECRQM private and ANSI, XTWINOPS 14/18, OSC 10/11 colour queries; titles OSC 0/1/2; OSC 7 directory (`TerminalEmulatorReplies.swift`) | same (`take_output`, `take_events`) |
| Scrollback: 10,000 lines, trailing blanks trimmed, 2 M cells and 16 MiB caps with 1/32 batch trimming, stable absolute line numbers; history kept as text + style runs (`TerminalScreen.swift`) | `screen.rs` `TerminalHistoryLine` |
| Resize: blank lines below the cursor dropped first, lines above pushed to history and brought back on growth, wide cut at the edge blanked, saved cursors clamped (`TerminalEmulator.resize`) | same |
| Character widths: Unicode 15.1 East Asian Width as zsh counts (`TerminalCharacterWidth.swift`) | `width.rs` + `width_table.rs`, **generated from Swift's own `width(of:)` over every scalar** |
| Key encoding incl. modifiers, application cursor mode, F1–F12, Option-Backspace (`TerminalKeyEncoder.swift`); Control and Option/Meta bytes (`TerminalView.keyDown`); bracketed paste without ESC/C1 (`TerminalView.pasteText`) | `keys.rs` |
| forkpty with every other descriptor closed, signal mask and dispositions reset, chdir, execve, `_exit(127)`; nonblocking master; 1 MiB output buffer with reader backpressure; 64 KiB deliveries; final drain capped at 100 ms / 1 MiB with its notice; reaping that never signals a recycled pid; SIGHUP then SIGKILL after 2 s; 2 MiB / 32-paste input cap with its notice (`PseudoTerminal.swift`) | `pty.rs` (reader, writer and watcher threads; `tokio::sync::Notify` wakes the GPUI task) |
| The shell: `$SHELL` (zsh when unset/empty) as `-name -l`, in the project folder, app environment plus `TERM=xterm-256color`, `COLORTERM=truecolor`, `LANG` default `en_US.UTF-8`, `TERM_PROGRAM=BelloAgent`, `TERM_PROGRAM_VERSION`, `BELLO_AGENT=1`, and `LITELLM*` / `*_API_KEY` removed (`TerminalSession.start`) | `pty::login_shell` |
| Sessions per project: "Terminal N" never reused, first shown gets Terminal 1, all-closed stays empty, select, rename (trimmed, 64 characters, empty = number back), restart in place (same id/number/name, generation+1, new scrollback), close shows the next then the previous, close project, shutdown; bell coalesced to 0.25 s; spawn failure as "Terminal error" (`TerminalPanel.swift`) | `session.rs` `TerminalRegistry`/`TerminalSession` |
| Ending questions: "Restart “N” in “project”?", "Close “N” in “project”?", Swift's details and action names, Cancel the default (Return cancels), asked only while the shell runs; Rename question "Rename “N”" / "Up to 64 characters. Leave it empty for “Terminal N”." | `session::ending_question`, `terminal_question.rs` |
| Drawing: SF Mono 12 (bold = its semibold), cell = advance of "M" × ceil(ascent+descent+2), baseline ascent+1, 8 pt inset, backgrounds in runs, selection at brand orange 22 %, ASCII runs on the grid and other glyphs at their own cell, underline at height−1.5, strike at half height, dim at 60 %, hidden, inverse; block/underline/bar cursor in brand orange, outline when unfocused, glyph under the block in the surface colour; marked (IME) text with 15 % wash and 2 pt underline; light/dark 16-colour palettes, 6×6×6 cube, grey ramp; `.piTerminalSurface` and `.piInk` defaults published for OSC 10/11 (`TerminalView.swift`) | `terminal_grid.rs` |
| Grid fitted to the view only when at least 2 × 1 cells fit; program told of the new size | `CellMetrics::grid`, `TerminalPanel::grid_laid_out` |
| Scrollback reading: wheel (pixel deltas accumulated per cell, lines × 3), alternate screen turns the wheel into ↑/↓ (≤20), a scrolled-back reader keeps their lines as output arrives, input returns to the bottom | `GridState`, `TerminalPanel::scrolled` |
| Selection: drag, double-click word (`_-./~` and alphanumerics), triple-click line, Select All (to the last line with content), copy text with trailing blanks trimmed; ⌘C/⌘V/⌘A and Edit menu Copy/Paste/Select All | `GridState`, `TerminalPanel::key_down` (`BelloEditor` key context so the Edit menu routes to it) |
| Focus in/out reports (`ESC[I`/`ESC[O`) | `TerminalPanel::focus_changed` |
| Panel: 1 pt line + header (12/5 padding, 8 spacing, `.piWindow`): terminal mark, tabs (`PiKit.Tabs`: 3 inset, 2 spacing, 12 pt medium, title+22, white capsule on the strong fill), New (+), shell title (caption), project folder (micro, tertiary, down to 40 pt, half the room up to 320), badge "Terminal error" (help = message) / "Shell exited", Rename, Restart, Close, Hide (22 pt icon buttons, Swift tooltips); tab row capped at 360 and the room the controls leave, scrolls with a 24 pt fade, reveals the chosen tab; empty state "No terminals in this project" + "New Terminal" (`TerminalPanelView.swift`) | `terminal_panel.rs` |
| Height: 240 default, 120–700, dragged on the 9 pt strip centred on the top line (18×2 grip, 35 % at rest), remembered; chrome 42 | `terminal_panel.rs` (saved to `terminal.json` beside `layout.json`) |
| Placement: between the queue and the composer; the terminal and the transcript share the room (terminal offered half, within its minimum and ideal); the queue's room reserves 120+42; composer field ceiling 88 while open (`ConversationPane.layout`) | `AgentView::terminal_slot` (flex basis 0 + min/max), `queue_geometry.rs`, `composer_ceiling` |
| Show/Hide Terminal ⌃` in View (retitled), enabled with a chat selected; hiding gives the composer the keyboard and keeps the shells; the starter's Terminal button; the panel's Hide | `application_menus.rs` `ToggleTerminal`, `global_key`, `main.rs` starter, `TerminalPanelEvent::Hide` |
| Shells end with the window/app | `TerminalRegistry`'s `Drop` → `terminate` |

No crate was added: nothing in `Cargo.lock` or BelloBox-rust offered a VT
parser (no `vte`/`alacritty_terminal`), so the emulator is a port of Swift's.
`libc` (already pinned) provides `forkpty`.

## How it was checked

- **Emulator oracle.** `oracle/emulator/main.swift` compiles the *unchanged*
  Swift `TerminalEmulator.swift`, `TerminalScreen.swift`,
  `TerminalEmulatorReplies.swift`, `TerminalScreenReading.swift` and
  `TerminalCharacterWidth.swift` and dumps, for each case, every line's cells
  (text, width, style, truncation), texts, cursor, shape, visibility, title,
  directory, all modes, scroll region, current style, replies, bells, title and
  directory events and dirty rows. `oracle/make_cases.py` writes 123 cases:
  hand-made sequences for every feature above (including split-byte feeding,
  invalid UTF-8, 40-parameter SGR, cancels inside CSI/OSC, resizes in both
  directions and on the alternate screen) and output recorded under
  `script(1)` from vim (open, edit, quit), less, `ls -G`, tput and zsh at 40×10
  (`oracle/recordings`). `emulator_tests::every_corpus_case_matches_swift`
  compares all 20 fields of all 123 cases: **all equal**. (A deliberate
  one-byte change to DA1 makes it fail, so the comparison bites.)
- **Widths.** `oracle/widths-main.swift` runs Swift's `width(of:)` over all
  1,114,112 scalars; the 474 non-1 ranges are `width_table.rs` verbatim.
- **Keys.** `oracle/keys/main.swift` prints Swift's bytes for all 27 keys × 8
  modifier mixes × both cursor modes; `key_encoder_matches_swift` matches all 432.
- **PTY lifecycle** (`pty_tests.rs`, `/bin/sh` scripts in temp dirs only):
  cwd, exit codes (3, 128+SIGTERM, 127 for a missing program), resize seen by
  `stty size`, echo, no inherited descriptor, SIGHUP then SIGKILL after 2 s,
  no process left after drop / close / restart / shutdown, 30,000 lines in
  order through backpressure, a descendant holding the tty not delaying the
  exit, the refused-paste notice, async wake-up, login-shell environment rules
  (unit and as seen by a real shell), registry numbering/selection/rename/
  restart/close, DSR answered through the session, bell coalescing, spawn
  failure text, Swift's question strings.
- **View** (`terminal_grid_tests.rs`, `terminal_panel_tests.rs`, GPUI test
  platform, real `/bin/sh` with no rc files in the fixture's temp project):
  cell metrics from Swift's measured SF Mono numbers (7.418 × 17, baseline
  12.60), palettes, selection/word/line/all text, reading position; ⌃`, the
  View menu and the starter button toggle it and move the keyboard; the slot
  is 282 pt between the queue and the composer (header 41, grid 240) and gives
  way to its minimum in a short window; keys (text, Return, ↑, ⌃C, ⌥B, Tab,
  Backspace) reach a raw-mode reader byte-exact; tabs/New/Rename/Restart
  (Escape and Return cancel)/Close (exited closes without asking)/empty state;
  drag to 340 and saved; copy, paste, wheel; closing the window ends the shell.
- **Native look.** Debug build launched with a scratch `HOME` and project
  (`screens/01-starter.jpg`, `screens/02-terminal-open.jpg`): the starter's
  Terminal button opens the panel with Terminal 1 running the login zsh.
- Gate: `cargo fmt --all`, `cargo clippy --workspace --all-targets -D warnings`,
  `cargo test -p bello-agent-core`, `cargo test -p bello-agent-app` (see the
  final report for counts).

## What still differs

- GPUI has no accessibility tree here: Swift's VoiceOver label/value
  ("Terminal N", screen text) and the spoken button labels are not exposed.
- The panel appears and leaves without Swift's slide-and-fade; the tab
  capsule moves without its glide.
- The project folder truncates at the end (GPUI), Swift truncates in the middle.
- Questions are the app's own overlay dialog (the style of Rust's other
  questions), not an NSAlert sheet.
- The remembered height is per window from launch; Swift's `UserDefaults`
  value also follows changes made in another window while open.
- `TERM_PROGRAM_VERSION` is the Rust crate version until packaging stamps one.
- OSC 7 parses with the `url` crate: a URL Foundation rejects (unescaped
  spaces) becomes a path here; nothing in the UI shows the directory.
- Linux CI only: the app's ⌃-commands (⌃N, ⌃W, ⌃F…) take precedence over the
  shell, and clipboard keys are ⇧⌃C/⇧⌃V/⇧⌃A; `forkpty` needs glibc ≥ 2.34.
