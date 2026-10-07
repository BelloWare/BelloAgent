# Bounded masked Connections replacement input

## Source and boundary

Swift `apps/macos/PiApp/Workspaces/ProfileSettings.swift:185–190` passes
`secure: true` for both the API key and custom-header JSON. `PiControls.swift:126–147`
uses a native `SecureField` and exposes no reveal or export affordance. Rust now
routes these two replacement fields to `connection_secure_input.rs`, instead of
the pinned shared plaintext editor. Other fields remain shared-editor entities.
The shared BelloBox revision remains unchanged.

This is a bounded GPUI privacy contract, not native secure-input parity or
production credential acceptance. GPUI 0.2.2's `EntityInputHandler` has no native
secure-keyboard/privacy flag. Real macOS keyboard, IME, accessibility and process
secure-event-input acceptance remain unopened gates. Signing, Keychain, native
vault composition and normal startup remain disabled. Tests use only fake data.

## Supported behavior

- API key input accepts at most 16,384 UTF-8 bytes; header JSON accepts at most
  262,144. A replacement is accepted in full or rejected in full. Rejection retains
  content, selection and marked text, and shows a generic content-free error.
- Key and header values are masked immediately, including marked/preedit text.
  The renderer shapes only a bounded viewport of at most 512 bullets. It never
  shapes or caches the original text. Cursor, selection and marked underline map
  through extended-grapheme byte boundaries. Boundary-only indices are cached
  on accepted edits and shared across repaint, focus and resize, rather than
  rescanning a maximum-sized value on every frame.
- Ordinary arrows, Shift-selection, Home/End, Select All, Backspace and Delete
  operate on Unicode grapheme boundaries. Command/control horizontal movement
  treats the secure field as a whole. Mouse click/Shift-click/drag selects masks;
  double-click selects the whole field. There is no text drag exporter.
- Paste replaces the selection and retains exact bytes, including JSON whitespace.
  Enter does not insert a line break. This is one visual line, rather than a JSON
  editor or a value-revealing validation preview.
- Copy, Cut, Ctrl+Insert, Shift+Delete, Undo and Redo are consumed without exporting
  or modifying the value. There is no secret Undo/Redo history. Select All plus
  Backspace/Delete clears typed replacement input; it does not remove a saved key.
  Blank still means preserve; `{}` remains the explicit header-clear operation.
- Platform surrounding-text requests receive only bullets, one per UTF-16 unit,
  with adjusted ranges. Selection, replacement and marked-text ranges use actual
  UTF-16 offsets and never split a Unicode scalar. Relative composition selection
  is resolved against inserted text. Commit replaces the marked text once; unmark
  publishes a completion event even when the value did not change.
- Settings Save/Close/New/tab actions remain blocked during composition. Busy,
  inactive and unavailable inputs cannot accept mutation. Final action capture,
  delayed acknowledgments, tab identity and blank saved-value placeholders keep
  their existing coordinator semantics. Out-of-contract oversized presentation
  values remain coordinator-owned until an accepted user edit; an empty bounded
  stand-in is never silently captured as deletion.

## Sensitive-data lifetime

The entity has custom redacted Debug output. Events contain only Changed/Rejected;
existing form/event Debug also redacts replacement fields. No plaintext is placed
in element IDs, debug selectors, rendered text, text runs, layout caches or platform
text retrieval. Accessibility receives no explicit secret value; this is not
proof of native accessibility parity or a secure-entry announcement.

The input-owned `Zeroizing<String>` and local paste string are zeroized when
replaced/dropped. No Undo history is retained. Existing coordinator form/event
strings, allocation copies made by GPUI/platform input and the OS clipboard are
outside this lifetime; complete memory erasure and protection against malicious
input methods, platform logging, screenshots or system compromise are not claimed.
The user's clipboard is not cleared or overwritten.

## Validation scope

Focused fake-platform tests cover masked shaping/platform retrieval/Debug, export
blocking, exact paste, clear without Undo, grapheme editing, surrogate-safe UTF-16
ranges, composition commit/unmark/cancel, atomic limits, read-only state, bounded
viewport/caret geometry and actual GPUI input dispatch. Connections-level tests
cover both secure field types, final capture, composition gates, delayed edit
acknowledgments, busy state and visible rejection.

Actual cloud Linux click/typing/paste/focus/cancel/close/reopen and fake save/preserve/
clear validation is a separate required checkpoint. Results will be appended after
the exact candidate is frozen and exercised. Neither automated contracts nor Linux
interaction establish native macOS secure keyboard/IME/accessibility acceptance.

## Cloud Linux validation — 2026-10-07

The actual cloud X11 desktop matrix passed on frozen synthetic binary SHA-256
`0c1539f98bdd0692e71f9d69787d9e0604938bd9f55a9df94c96d23ac82079a6`,
152-source/manifests digest
`fe301dbd9621eb7d1ad0ad35ca55b9995a3f6d545ea70a9ec16fe42aaf7d75f7`.
The secure-input source digest is
`4314eecbdd9c84ad29606f89034612dd7ffabf8ac1d77a6187e30b483fd9cb1c`.

Actual CUA mouse/keyboard actions verified masked typing in both fields, API-key
paste, Tab/ShiftTab, pointer selection and partial deletion, Copy/Cut retaining a
prior clipboard sentinel, clear without Undo recovery, Close → Keep Editing,
Save → reopen with blank replacement fields, and Cancel → reopen with saved values
still hidden. Fifteen original screenshots were retained locally. The fixture
notice intentionally names the public fixed fake values; entered fields remain
masked, and temporary clipboard-source text was removed before capture.
Eight [curated original screenshots, source manifest and boolean-only receipts](validation/secure-inputs-2026-10-07/README.md) are included in this repository.

An explicit loopback request after Cancel and a metadata-only blank-replacement
save confirmed both the expected fake key and custom header. A later masked `{}`
save kept the key while the next explicit request had no custom header. The
fixture logged only these booleans, never header/credential text. Save, trust,
selection, cancellation and reopening made no requests. Exactly two explicit
requests reached the local fixture; the application log stayed empty.

Project creation changed the authority envelope between these saves. The initial
header-clear save correctly failed with a reload/review message, retained its
masked draft and sent nothing. Explicit Reload → Discard and Reload, followed by
re-entering `{}`, succeeded. The finished idle fixture closed without a draft or
running request. An unrelated stale Projects success label was reported for a
separate notice-only correction; this matrix is attributed to the binary above.

Thirty-eight focused secure-input/Connections-view contracts passed across the
focused suites and final added focus regression. Independent full app default and
synthetic suites include them. Strict app Clippy passed; final combined checkpoint
CI is recorded separately. Two temporary negative controls caused the intended
tests to fail (plaintext platform retrieval and omitted byte cap); exact source
bytes were restored before passing checks and the frozen GUI build.

This establishes the bounded Linux fixture behavior described here. Native macOS
secure keyboard, IME, accessibility, signing, Keychain and production startup
acceptance remain unopened.
