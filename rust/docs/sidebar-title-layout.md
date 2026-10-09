# Single-line chat title presentation and future initial titles

This bounded correction builds on Find-notice commit
`570b34eac3fb5c1de9615dc645f79da7b1eff682` (tree
`1766b54d9ef2209a6bba0a37eba4d8308d21c62f`). It fixes the actual Linux GUI-found
sidebar growth when a retained title contains LF. It does not rewrite old titles,
change storage versions, or implement background/generated/edited-title lifecycle.

## Immutable Swift specification

Comparison source is Swift `6319e368c6ddb7c3ef18605e78f23b1a5b69e63a`:

- [WorkspaceRun.swift, 265–275](https://github.com/BelloWare/BelloAgent/blob/6319e368c6ddb7c3ef18605e78f23b1a5b69e63a/apps/macos/PiApp/Workspaces/WorkspaceRun.swift#L265-L275)
  chooses nonempty text, otherwise slash-prefixed skill names joined by one space;
  takes 60 Swift Characters, then replaces LF with a space. The surrounding Swift
  edited/generated/default-title guards are not added by this bounded change.
- [SidebarEntryViews.swift, 133–147](https://github.com/BelloWare/BelloAgent/blob/6319e368c6ddb7c3ef18605e78f23b1a5b69e63a/apps/macos/PiApp/Workspaces/SidebarEntryViews.swift#L133-L147)
  and [SidebarChatRows.swift, 308–373](https://github.com/BelloWare/BelloAgent/blob/6319e368c6ddb7c3ef18605e78f23b1a5b69e63a/apps/macos/PiApp/Workspaces/SidebarChatRows.swift#L308-L373)
  pass the raw title to a trailing-truncated PiKit.TextLine.
- [PiKitFoundation.swift, 64–114](https://github.com/BelloWare/BelloAgent/blob/6319e368c6ddb7c3ef18605e78f23b1a5b69e63a/apps/macos/PiApp/DesignKit/PiKitFoundation.swift#L64-L114)
  uses one Core Text line with a font-derived line height.
  [PiKitControls.swift, 377–398](https://github.com/BelloWare/BelloAgent/blob/6319e368c6ddb7c3ef18605e78f23b1a5b69e63a/apps/macos/PiApp/DesignKit/PiKitControls.swift#L377-L398)
  retains raw line.text for accessibility. Native control-character rendering and
  accessibility equivalence have not been executed or established here.

## Implementation boundary

The actual shared sidebar chat-title renderer replaces only LF for display and
keeps width truncation. The actual Move-chat heading does the same and gains width
truncation. GPUI 0.2.2 `truncate` prevents soft wrapping but still shapes physical
LF lines; adding a line clamp alone is insufficient. Raw `sidebar_title` remains
unchanged for filtering and identity consumers. No normalized title is written
back to the record, session, catalog, transcript, draft, clipboard or journal.
No accessibility adapter is introduced; the raw source remains available to a
future native accessibility implementation rather than being migrated away.

Only future first retained-message delivery uses `initial_submission_title`:
select raw text (or the existing Rust skill/image label), take 60 extended grapheme
clusters with the already-pinned unicode-segmentation 1.13.3, then replace LF.
Queue `submission_label` is unchanged. This is not trimming, newline canonicalization,
or general whitespace collapse. CR, TAB, NEL, LS, PS and multiple/edge spaces remain.
In particular CRLF is one cluster; at the 60th cluster it becomes CR + SPACE after
prefixing. Replacing before prefixing gives a different result and is rejected.

Rust's pinned Unicode tables and the deployed Swift runtime are not proven
identical. Combining-mark, ZWJ-family, skin-tone and flag vectors are portable
source-derived checks, not an executed Swift oracle. Rust's image-only `Image` /
`N images` fallback is deliberately retained; Swift's no-text/no-skills expression
is empty. Existing-title reads and later-message delivery remain unchanged.

## Validation scope

Focused TestPlatform regressions mount the actual AgentView sidebar and actual
Move panel, force paint through debug bounds, compare single-line/LF-rich/long-word
heights at ordinary and narrow viewport/sidebar sizes, exercise live/loading/failed,
topic/archived/pinned and unselected retained title sources, and preserve following
row/footer geometry. They check raw LF-sensitive filtering, retained raw accessor,
unchanged persisted session bytes and no transcript edits. Core vectors exercise
real first delivery, intact messages/active input, bounded joined skill titles,
unchanged queue labels, old-title reopen and later delivery.

These are Linux portable/layout regressions. Actual cloud GUI acceptance of the
new immutable binary, exact CI, Swift runtime Unicode/Core Text behavior, native
macOS keyboard/IME/AX and same-hardware performance are separate gates. Valid long
topic names may still soft-wrap; topic-title layout is outside this chat-title fix.
No provider, tools, capture, vault, native authority or credential gate changes.
Synthetic fixtures only, zero provider spend. Wall durations are validation/build
time, not inference latency; inference timing is unavailable.

### Portable validation, 2026-10-09

- Locked full default workspace: App 628 passed / 1 existing ignored; Core 572
  unit and 147 integration passed.
- Locked full all-feature workspace: App 773 passed / 3 existing ignored; Core
  757 unit and 147 integration passed. Nested subprocess tests are included in
  the parent Core count rather than added again.
- Three new actual-layout tests and three new Core title tests passed. Five
  reversible negative controls failed at their targeted assertions and restored
  byte-identical source: sidebar LF removal (988.5px versus 21px control), Move
  LF removal (509.5px versus 19.5px), scalar prefixing, missing LF replacement,
  and replacement before prefixing. Those are TestPlatform layout observations,
  not native pixels or latency measurements.
- Independent source review found no substantive defect. Swift reference copies
  were checked byte-for-byte against all five immutable Git source objects.
- Formatting and strict workspace all-target Clippy passed in default and all-feature
  configurations. The pre-existing dependency future-incompatibility notice for
  proc-macro-error2 2.0.1 is not a workspace Clippy failure.
