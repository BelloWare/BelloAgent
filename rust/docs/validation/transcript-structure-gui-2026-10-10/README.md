# Transcript structure: native check — 2026-10-10

Debug build of `rust-transcript` (dev profile; the shared disk could not hold a
second release tree), launched on this Mac with a scratch HOME and the session
`seed.py` writes from the long-chat template (one turn with a reply that reads,
runs, lists and searches, a reply that edits, fails a command, is stopped in a
build and skips a write, then the answer; a second plain turn). Window-only
captures with `harness/belloperf capture`.

- `01-closed.jpg` (before turn folds): every call a closed 24 pt work line; red dot
  for the failed command (its first output line as the summary), amber dots for
  the stopped build (`· outcome unknown`) and the skipped write; `+1 −0` after
  the edit; clocks from 0.1 s.
- `04-open-top.jpg`: the read, command and edit rows opened: numbered read
  window under its path and "Showing 12 of 20 lines", the terminal card, the
  diff card with its banner, path and `└ +1 −0`.
- `05-folded.jpg`: Swift's default compact display: the finished turn's work
  behind "8 tool calls · 1 message" above the answer; the plain turn untouched.
- `06-unfolded.jpg`: the same line opened (chevron down), the work as it ran.
