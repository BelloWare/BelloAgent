# Bello Agent UI preservation review

Review date: 2026-10-04. Contract: preserve the existing app's UI; a new generic chat/editor layout is not an acceptable substitute. This checklist is not a claim that all original functionality is implemented.

## Evidence and current verdict

- Baseline: existing Swift implementation under `apps/macos/PiApp`, read from checkout at `435c4c8`.
- The actual Rust capture `belloagent-welcome-native-20261004-0305.png` was inspected. It fails preservation: cold dark palette, branded sidebar header, full-width Conversation / Files & Git tabs, invented “Room to think” welcome copy/layout, code gutter/status in the message composer and separate rectangular Send button.
- Native Swift reference screenshots have not yet been inspected. Source-backed geometry and structure below are sufficient to reject those mismatches, but pixel parity remains unverified.
- Revised Rust screenshots and macOS appearance/interaction checks remain required; compiling successfully is not visual acceptance.

## Revised capture review: 03:29 UTC

Actual revised Rust screenshot `belloagent-source-layout-20261004-0329.png` was inspected in an isolated empty local-fixture chat.

- Verified visual restoration: source warm light colors;300pt Projects sidebar with filter and compact footer icons; no generic top navigation/header; real48pt brand icon in the top-centered560pt starter card; plain proportional composer without code gutter/status; rounded16pt composer with bottom action row and circular Send.
- Still mismatched/limited: sidebar width is fixed and lacks the original resize handle; starter action labels omit their original icons; metrics footer is plain text instead of source pills. Main source error strip belongs at the top of content, while current implementation places errors above the composer.
- Interaction parity is incomplete: several project/sidebar/terminal/skills/sides controls are disabled, Settings reports unimplemented, and model/effort display pills are not selectors. Their current unavailable state is preferable to pretending they work, but is still a parity gap.
- Pending: populated transcript, dark appearance, minimum920×600 with Changes pane, global welcome (no selected chat), and macOS typography/window chrome. Source has responsive composer forms and adjustable split; minimum-width behavior needs direct testing.

## Populated chat and final verification boundary

- Actual `belloagent-source-chat-20261004-0333.png` was inspected. It confirms the right-aligned warm user bubble, assistant text without an enclosing bubble, no invented main header, and plain bottom composer. QA verified typing and Return submitted to a local HTTP/SSE fixture and displayed its completed response; no real AI service was contacted.
- That capture predates the worker’s03:37 refinements: persisted sidebar/split resizing, starter action icons, footer pill chrome, top-of-content error strip,640pt prose/840pt page constraints and compact model/effort forms. These were reviewed in code but are **not visually verified**.
- Native CUA transport disconnected at03:41:54 UTC; subsequent same-route checks returned no apps / connection refused. The desktop had maximized windows to1180×812. Dark appearance, intended920×600 minimum, split-pane overflow and final-binary recaptures remain **not verified**.
- No native Swift Agent reference screenshot was available. The review uses the actual current Swift source and actual Rust pixels; it does not claim a screenshot-to-screenshot pixel match.
- Final verdict for this review pass: **Selected-chat shell/composer structural restoration verified; full visual and interaction parity not accepted.** Disabled/unported destinations and model controls remain capability gaps.

## Shared visual language

Source: `Design/DesignSystem.swift`.

- [ ] Exact warm palette (light / dark): window `#F6F1EA / #1E1B18`, content `#FCF9F5 / #26221E`, raised surface `#FFFFFF / #2E2925`, sunken `#F7F2EC / #211D1A`, ink `#1F1B17 / #F1ECE5`, secondary `#6F675E / #B0A79C`, tertiary `#9E958A / #7C7469`, accent `#984709 / #F0A052`. Terminal has distinct `#EDE4D8 / #15120F` canvas.
- [ ] Preserve hairline borders, subtle tinted icon badges and orange action hierarchy. Spacing tokens are 4/8/12/16/24pt; radii 8/12/16/22pt.
- [ ] System proportional type: body13, caption11.5, micro10.5 medium, heading14 semibold, title17 semibold; monospace12 for actual code only.
- [ ] Use shipped BelloAgentIcon artwork for welcome/starter, and the original outline-icon language elsewhere. Do not replace icons with arbitrary Unicode or emoji.
- [ ] Follow system light/dark appearance. Do not hardcode the entire app to the dark prototype palette.

## Shell and sidebar

Sources: `Application/WindowPresentation.swift`, `Workspaces/WorkspaceView.swift`, `WorkspaceSidebarView.swift`, `SidebarGroups.swift`, `SidebarChatRows.swift`.

- [ ] Window minimum 920×600. Sidebar defaults300pt, resizes200–420pt, persists its width; divider visibly reads as a resize handle.
- [ ] Only sidebar reserves the 36pt traffic-light/drag strip. No new full-width title/header bar above the main conversation.
- [ ] Sidebar top has NO app name/logo: uppercase micro “Projects”, New Chat icon and Add/manage projects icon, then “Filter chats and topics”.
- [ ] Projects/topics/chats remain a nested, collapsible, filterable hierarchy. Project header becomes compact below240pt. Chat rows show 13pt title and activity/subtitle with selection, unread, pin, archive and child disclosure states.
- [ ] Bottom icon bar preserves Usage Report, Session Inspector, project resources, Background requests, archive toggle and Settings destinations.
- [ ] There is NO main-chat header. Chat is named in sidebar; model/actions live in composer and live status below it.
- [ ] Files, Git and side conversations use the right pane/tab strip beside the chat; they do not replace chat with a top-level “Files & Git” page. Side split persists and clamps30–70%. Right-edge sides panel overlays content until pinned.
- [ ] Recoverable errors occupy a dismissible top-of-content strip without hiding the first message or stealing focus.

## Welcome, starter, transcript and composer

Sources: `Workspaces/WorkspaceView.swift`, `ConversationPane.swift`, `ComposerInput.swift`, `ComposerBarLayout.swift`, `Inspector/MetricsFooter.swift`, `Transcript/NativeTranscriptView.swift`.

- [ ] No selected chat: centered84pt real icon, “What are we working on?” 30pt bold, original13pt explanatory copy within460pt, and appropriate New Chat / Projects / Connections actions. No composer attached to this global welcome.
- [ ] Fresh selected chat: distinct top24pt StarterPanel, white12pt-radius card max560pt with48pt icon, project name/roots, connection/model/tool badges, exact first-message guidance and Changes / Terminal / Skills / Open a side buttons. Composer remains at bottom.
- [ ] Transcript rows are centered within min840pt or pane-width-minus48pt, with12pt top/13pt bottom inset. User literal14.5pt text is right-aligned in a14pt-radius bubble (14×9pt padding, max640pt prose, minimum40pt leading space), light `#F8ECDF` / dark `#3A3129`. Assistant14.5pt prose has no enclosing bubble. Preserve selectable text/Markdown and message actions; tool/reasoning work rows are24pt,16pt icon+6pt gap,22pt disclosure indent.
- [ ] Composer is an elevated16pt-radius card, 16pt horizontal margin, top8/bottom6. Plain proportional14pt message input and placeholder; no line numbers, editor mode label, file coordinates or Vim status bar.
- [ ] Composer bottom row order: Attach image, Skills, spacer, steering/run hints, Changes, Usage, conversation actions, connection/model/effort pills, circular30pt orange Send. Busy adds separate30pt red Stop. The row adapts by simplifying labels, not splitting words or hiding Send.
- [ ] Attached image chips, in-editor skill tokens, message-edit/queue-edit banners and disabled/resolving states remain inside the composer. Slash completion floats above without resizing transcript.
- [ ] Metrics below composer retain actual session readings, contextual run phase and capture badge. Empty/unknown values must not be invented to imitate a populated screen.
- [ ] Switching chats preserves drafts, scroll and live run. Queue panel and terminal take bounded space above composer; long queues scroll/collapse without covering transcript.

## Existing secondary surfaces

Sources: `Tabs/RightPane.swift`, `Workspaces/TerminalPanel.swift`, `Inspector/Session`, and `docs/reviews/BelloAgent-approved-UI-UX-handoff-2026-10-02.md`.

- [ ] Terminal retains resizable panel (default240pt, minimum120pt), differentiated canvas, project-scoped terminal tabs and create/switch/rename/restart/close controls.
- [ ] Settings is its own app-styled window with category navigation, Save All / Cancel, dirty-close Save / Discard / Keep Editing and guarded Reload. CLI configuration alone is not UI parity.
- [ ] Session Inspector, Usage Report, project resources, background requests, Git/History/file navigation remain reachable in their original places.
- [ ] Long/narrow states remain usable at920×600, sidebar200pt, and split-pane30/70 limits. Controls must not overflow, overlap or silently disappear.

## Required evidence before acceptance

- [ ] Compare equivalent Swift/Rust states at the same content size: global welcome, selected empty chat, populated chat, streaming/queue, Files/Git side pane, terminal and Settings. Review light and dark.
- [ ] Verify click/keyboard navigation, repeated chat switching, Enter/Shift-Enter send/edit intent, model/effort controls, Stop, queue editing/cancel, side-pane close/reopen and window resize.
- [ ] Capture actual revised builds after final edits and record exact limitations. Visual similarity of one welcome capture does not establish parity of the app.
