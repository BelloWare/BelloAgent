# DRAW-1: complete gallery comparison — 0.1.131

Parent record: [cause, tests and commands](a131-blanktext-0.1.131.md).

Reference: `/Users/admin/Library/Caches/BelloSwiftWork/r131/gallery-0.1.130-gate`.
Fixed output: `/Users/admin/Library/Caches/BelloSwiftWork/build-a131-blanktext/gallery-fixed`.
Evidence below uses `$B` for `/Users/admin/Library/Caches/BelloSwiftWork/build-a131-blanktext`.

All **423** reference PNGs are present. **415** have same-size raw pixel
changes, **1** differs in height by one point, and **7** are pixel-identical.
There are **8 added** SIDEBAR-1 scenes. The output contains **430 window captures
plus the identical `retry-budget.png` fixture asset**. The separately requested
session-panel run adds **22 captures**, listed below; that gallery has no
counterpart in the supplied release-gate directory.

I visually inspected **every one of the 430 gallery captures and all 22
session-panel captures**, using named contact-sheet tiles and larger paired
views/crops for the flagged regions and largest differences. Review manifests
and notes are in `$B/evidence/visual-review.txt`; the review sheets are in
`review-main`, `review-subagents`, `review-steering`, and `review-session-panel`.
No additional blank or missing rendered text was found. The dark paused-child
task and reply are present at both release-gallery widths (and at all three
widths of the focused regression).

## Method and reasons

Pillow/NumPy compare **every RGBA pixel**, without masks, tolerance, alignment
or normalization. Different-size images are padded transparently to the larger
canvas at the same top-left origin before comparison. The table retains all
raw differences. `>8` is an extra diagnostic count of pixels with a channel
difference greater than 8/255, not an acceptance threshold. JSON with sizes,
raw bounding boxes and 128-pixel region counts is `$B/compare-final/pixels.json`;
paired originals are `pair-*.jpg`. Machine-readable classifications are
`$B/compare-final/classified.csv`.

| Code | Reason, verified against the captures |
| --- | --- |
| F | Generated fixture identity/content: `verify-gallery` → `gallery-fixed`, fresh project/turn/attempt UUIDs, skill hashes, loopback ports, repository IDs/file counts and paths. Longer workspace paths wrap differently in skill echoes, raw request JSON, dialogs and file previews. |
| T | Runtime values: capture date/time and report axes, latency/duration/output rates, relative ages, and the captured point in a live stream. Values differ while the intended scene and text remain present. |
| H | Native capture/raster phase: active/inactive traffic lights, caret, spinner, live fade/opacity, scroller and window-edge rasterization. Large raw differences in the working-indicator scenes are overwhelmingly small RGB changes, detailed below. |
| S | Intended SIDEBAR-1 UI: Flat project chips, clickable project tags, new filter/overflow menus and the resulting row placement/activity ordering. |
| G | Screen-constrained capture height: the 1100-point compact-report scene is captured at 1840×1812 versus 1840×1814 pixels (one point taller). Its content is present. The test requests a height greater than the screen; the exact one-point native clamping/capture variation is not changed by this workstream. |

Specific larger/flagged differences were examined as follows:

- `13a-working-indicator-*` and `13b-working-indicator-clock-*`: the text and
  geometry remain present. **98.8–99.1%** of differing pixels change by at most
  8 RGB levels; only 6,386–6,894 pixels exceed that value. Remaining visible
  differences include the fixture name, measured times and spinner/caret phase.
- `14f-sidebar-flat-all-normal-*` and `14g-sidebar-header-menu-normal-*`:
  the missing-ink detector flagged an old row's location. The chip row and Flat
  ordering put another row there; the former selected chat is visible lower in
  the list. Its title has not stopped drawing.
- `26b-terminals-light.png`: the shell prompt has the new generated working
  directory; the release capture has a preceding zsh end-of-line `%` marker
  and newline, while this capture shows the prompt on its first line. All
  current prompt text is drawn. Terminal tab numbers are also fixture state.
- `26e-mcp-remove-question-*`: the longer generated project path wraps to
  another line, changing the centered native question's size/placement.
- `11e-inspector-raw-search-*`, `11i-inspector-expanded-*`, and the skill/file
  scenes: generated paths/UUIDs change raw/source lines and wrapping. Complete
  text remains present, including in narrow file panes.
- `parallel-queued-*`: live/raster-phase differences also occur on the
  **pre-PERF-1** build (3.27–5.27% raw differences against the release gate).
  Four agent headers and their words remain visible; this is not a missing-text
  regression from this fix.
- Inspector capture-missing/outside-window scenes retain their explicit
  “request body is not available” notice, as intended for unretained bodies.

An additional 128×128 tile check found **8 tiles in 5 images** whose
text-colored pixel count fell below 25% of the reference (with at least 300
reference text pixels). These are exactly the four Flat scenes and the terminal
scene above. Every flagged crop was viewed (`flag-1.png` through `flag-5.png`);
none is missing rendered prose. This is a diagnostic alongside the full visual
review, not a substitute for it.

## Every differing reference image

Paths are relative to the reference/fixed gallery roots. Each image in this
table was visually inspected. The codes above explain the differences; there
are no unexplained missing-text regions.

| Image | Raw changed pixels | Raw % | >8 pixels | Reason |
| --- | ---: | ---: | ---: | --- |
| `screenshots/01-main-dark.png` | 8,834 | 0.1704 | 8,356 | F, T, H |
| `screenshots/01-main-light.png` | 9,036 | 0.1743 | 8,301 | F, T, H |
| `screenshots/01a-activity-dark.png` | 4,898 | 0.0945 | 4,698 | F, T, H |
| `screenshots/01a-activity-light.png` | 4,673 | 0.0901 | 4,501 | F, T, H |
| `screenshots/01b-terminal-dark.png` | 13,415 | 0.2588 | 12,546 | F, T, H |
| `screenshots/01b-terminal-light.png` | 13,092 | 0.2525 | 12,309 | F, T, H |
| `screenshots/01c-token-shares-dark.png` | 8,549 | 0.1649 | 8,089 | F, T, H |
| `screenshots/01c-token-shares-light.png` | 8,774 | 0.1693 | 8,049 | F, T, H |
| `screenshots/02-side-dark.png` | 9,937 | 0.1917 | 9,333 | F, T, H |
| `screenshots/02-side-light.png` | 13,777 | 0.2658 | 12,603 | F, T, H |
| `screenshots/03-report-dark.png` | 20,564 | 0.3967 | 16,815 | F, T, H |
| `screenshots/03-report-light.png` | 21,731 | 0.4192 | 19,343 | F, T, H |
| `screenshots/03b-report-expanded-dark.png` | 20,564 | 0.3967 | 16,815 | F, T, H |
| `screenshots/03b-report-expanded-light.png` | 21,731 | 0.4192 | 19,343 | F, T, H |
| `screenshots/03c-report-compact-controls-dark.png` | 19,642 | 0.5891 | 15,877 | F, T, H |
| `screenshots/03c-report-compact-controls-light.png` | 33,782 | 1.0121 | 28,917 | F, T, H, G |
| `screenshots/03c-report-compact-dark.png` | 19,642 | 0.7213 | 15,877 | F, T, H |
| `screenshots/03c-report-compact-light.png` | 21,438 | 0.7872 | 19,714 | F, T, H |
| `screenshots/03c-report-sessions-dark.png` | 20,564 | 0.3967 | 16,815 | F, T, H |
| `screenshots/03c-report-sessions-light.png` | 21,731 | 0.4192 | 19,343 | F, T, H |
| `screenshots/03d-report-compact-filters-dark.png` | 15,611 | 0.5733 | 14,106 | F, T, H |
| `screenshots/03d-report-compact-filters-light.png` | 18,395 | 0.6755 | 17,045 | F, T, H |
| `screenshots/03e-report-models-dark.png` | 20,564 | 0.3967 | 16,815 | F, T, H |
| `screenshots/03e-report-models-light.png` | 21,731 | 0.4192 | 19,343 | F, T, H |
| `screenshots/05-profiles-dark.png` | 9,347 | 0.1803 | 8,195 | F, T, H |
| `screenshots/05-profiles-light.png` | 8,702 | 0.1679 | 7,584 | F, T, H |
| `screenshots/05b-settings-window-dark.png` | 129 | 0.0045 | 0 | H |
| `screenshots/05b-settings-window-light.png` | 130 | 0.0046 | 0 | H |
| `screenshots/05c-settings-app-dark.png` | 8,701 | 0.1678 | 7,709 | F, T, H |
| `screenshots/05c-settings-app-light.png` | 7,979 | 0.1539 | 7,110 | F, T, H |
| `screenshots/05c-settings-chats-dark.png` | 9,268 | 0.1788 | 7,709 | F, T, H |
| `screenshots/05c-settings-chats-light.png` | 7,986 | 0.1541 | 7,110 | F, T, H |
| `screenshots/05c-settings-usage-dark.png` | 8,657 | 0.1670 | 7,709 | F, T, H |
| `screenshots/05c-settings-usage-light.png` | 7,924 | 0.1529 | 7,110 | F, T, H |
| `screenshots/06-resources-dark.png` | 14,411 | 0.2780 | 12,361 | F, T, H |
| `screenshots/06-resources-light.png` | 14,088 | 0.2718 | 12,759 | F, T, H |
| `screenshots/07-search-dark.png` | 7,811 | 0.1507 | 6,058 | F, T, H |
| `screenshots/07-search-light.png` | 7,924 | 0.1529 | 7,110 | F, T, H |
| `screenshots/08-workspaces-dark.png` | 19,546 | 0.3770 | 16,655 | F, T, H |
| `screenshots/08-workspaces-light.png` | 19,390 | 0.3740 | 17,448 | F, T, H |
| `screenshots/09-message-details-dark.png` | 1,221 | 0.0296 | 1,109 | T, H |
| `screenshots/09-message-details-light.png` | 1,198 | 0.0290 | 1,084 | T, H |
| `screenshots/10-changes-dark.png` | 56,075 | 1.0817 | 34,923 | F, T, H |
| `screenshots/10-changes-light.png` | 55,764 | 1.0757 | 53,582 | F, T, H |
| `screenshots/10b-changes-window-dark.png` | 41,095 | 1.1162 | 33,552 | F, T, H |
| `screenshots/10b-changes-window-light.png` | 40,472 | 1.0993 | 34,533 | F, T, H |
| `screenshots/10c-changes-window-narrow-dark.png` | 22,540 | 1.0737 | 18,614 | F, T, H |
| `screenshots/10c-changes-window-narrow-light.png` | 22,187 | 1.0569 | 19,326 | F, T, H |
| `screenshots/10d-changes-commit-unticked-dark.png` | 28,837 | 1.3060 | 22,228 | F, T, H |
| `screenshots/10d-changes-commit-unticked-light.png` | 28,749 | 1.3020 | 23,572 | F, T, H |
| `screenshots/10e-changes-commit-staged-amend-dark.png` | 28,897 | 1.3087 | 22,269 | F, T, H |
| `screenshots/10e-changes-commit-staged-amend-light.png` | 28,656 | 1.2978 | 23,481 | F, T, H |
| `screenshots/11-inspector-overview-dark.png` | 10,479 | 0.2539 | 9,366 | T, H |
| `screenshots/11-inspector-overview-light.png` | 10,335 | 0.2504 | 9,425 | T, H |
| `screenshots/11b-inspector-turn-dark.png` | 5,130 | 0.1243 | 4,691 | T, H |
| `screenshots/11b-inspector-turn-light.png` | 5,005 | 0.1212 | 4,592 | T, H |
| `screenshots/11c-inspector-conversation-dark.png` | 1,091 | 0.0264 | 962 | T, H |
| `screenshots/11c-inspector-conversation-light.png` | 1,051 | 0.0255 | 941 | T, H |
| `screenshots/11d-inspector-response-dark.png` | 1,091 | 0.0264 | 962 | T, H |
| `screenshots/11d-inspector-response-light.png` | 1,051 | 0.0255 | 941 | T, H |
| `screenshots/11e-inspector-raw-search-dark.png` | 116,244 | 2.8160 | 106,151 | F, T, H |
| `screenshots/11e-inspector-raw-search-light.png` | 108,395 | 2.6258 | 97,536 | F, T, H |
| `screenshots/11g-inspector-running-dark.png` | 1,302 | 0.0315 | 975 | T, H |
| `screenshots/11g-inspector-running-light.png` | 1,664 | 0.0403 | 836 | T, H |
| `screenshots/11h-inspector-narrow-dark.png` | 1,091 | 0.0513 | 962 | T, H |
| `screenshots/11h-inspector-narrow-light.png` | 1,052 | 0.0494 | 940 | T, H |
| `screenshots/11i-inspector-expanded-dark.png` | 204,583 | 4.9560 | 192,013 | F, T, H |
| `screenshots/11i-inspector-expanded-light.png` | 195,671 | 4.7401 | 183,404 | F, T, H |
| `screenshots/11j-inspector-expanded-end-dark.png` | 1,091 | 0.0264 | 962 | F, T, H |
| `screenshots/11j-inspector-expanded-end-light.png` | 1,051 | 0.0255 | 941 | F, T, H |
| `screenshots/12-turns-open-dark.png` | 7,276 | 0.1404 | 6,764 | F, T, H |
| `screenshots/12-turns-open-light.png` | 7,183 | 0.1386 | 6,724 | F, T, H |
| `screenshots/12b-turns-folded-dark.png` | 7,276 | 0.1404 | 6,764 | F, T, H |
| `screenshots/12b-turns-folded-light.png` | 7,183 | 0.1386 | 6,724 | F, T, H |
| `screenshots/12c-back-to-bottom-dark.png` | 6,618 | 0.1277 | 6,223 | F, T, H |
| `screenshots/12c-back-to-bottom-light.png` | 6,538 | 0.1261 | 6,186 | F, T, H |
| `screenshots/13-running-with-queue-dark.png` | 7,107 | 0.1371 | 6,326 | F, T, H |
| `screenshots/13-running-with-queue-light.png` | 7,768 | 0.1498 | 6,933 | F, T, H |
| `screenshots/13a-working-indicator-dark.png` | 597,727 | 11.5302 | 6,714 | F, T, H |
| `screenshots/13a-working-indicator-light.png` | 572,998 | 11.0532 | 6,894 | F, T, H |
| `screenshots/13b-working-indicator-clock-dark.png` | 593,187 | 11.4427 | 6,603 | F, T, H |
| `screenshots/13b-working-indicator-clock-light.png` | 685,117 | 13.2160 | 6,386 | F, T, H |
| `screenshots/13c-queued-rewrite-dark.png` | 6,489 | 0.1252 | 6,109 | F, T, H |
| `screenshots/13c-queued-rewrite-light.png` | 6,249 | 0.1205 | 5,911 | F, T, H |
| `screenshots/14-sidebar-topic-marks-dark.png` | 6,329 | 0.1221 | 5,948 | F, T, H |
| `screenshots/14-sidebar-topic-marks-light.png` | 6,681 | 0.1289 | 5,910 | F, T, H |
| `screenshots/14b-sidebar-narrow-dark.png` | 4,068 | 0.0785 | 3,791 | F, T, H |
| `screenshots/14b-sidebar-narrow-light.png` | 4,009 | 0.0773 | 3,790 | F, T, H |
| `screenshots/14c-sidebar-archive-dark.png` | 6,329 | 0.1221 | 5,949 | F, T, H |
| `screenshots/14c-sidebar-archive-light.png` | 6,409 | 0.1236 | 6,071 | F, T, H |
| `screenshots/14d-sidebar-search-dark.png` | 2,084 | 0.0944 | 1,845 | F, T, H |
| `screenshots/14d-sidebar-search-light.png` | 2,228 | 0.1009 | 1,991 | F, T, H |
| `screenshots/14e-sidebar-search-opened-dark.png` | 2,664 | 0.1207 | 2,369 | F, T, H |
| `screenshots/14e-sidebar-search-opened-light.png` | 2,633 | 0.1192 | 2,333 | F, T, H |
| `screenshots/14f-sidebar-flat-all-narrow-dark.png` | 46,792 | 2.1192 | 42,619 | S, F, T, H |
| `screenshots/14f-sidebar-flat-all-narrow-light.png` | 45,733 | 2.0712 | 42,374 | S, F, T, H |
| `screenshots/14f-sidebar-flat-all-normal-dark.png` | 369,820 | 7.1339 | 361,297 | S, F, T, H |
| `screenshots/14f-sidebar-flat-all-normal-light.png` | 371,136 | 7.1593 | 364,359 | S, F, T, H |
| `screenshots/14g-sidebar-header-menu-narrow-dark.png` | 42,380 | 1.9194 | 38,342 | S, F, T, H |
| `screenshots/14g-sidebar-header-menu-narrow-light.png` | 41,371 | 1.8737 | 38,187 | S, F, T, H |
| `screenshots/14g-sidebar-header-menu-normal-dark.png` | 364,953 | 7.0400 | 356,654 | S, F, T, H |
| `screenshots/14g-sidebar-header-menu-normal-light.png` | 366,319 | 7.0663 | 359,817 | S, F, T, H |
| `screenshots/15-error-strip-dark.png` | 2,670 | 0.0515 | 2,454 | F, T, H |
| `screenshots/15-error-strip-light.png` | 2,794 | 0.0539 | 2,599 | F, T, H |
| `screenshots/16-window-narrow-dark.png` | 2,830 | 0.1225 | 2,614 | F, T, H |
| `screenshots/16-window-narrow-light.png` | 2,634 | 0.1140 | 2,437 | F, T, H |
| `screenshots/16b-window-wide-dark.png` | 2,830 | 0.0444 | 2,614 | F, T, H |
| `screenshots/16b-window-wide-light.png` | 2,635 | 0.0413 | 2,433 | F, T, H |
| `screenshots/17-skills-composer-dark.png` | 2,670 | 0.0515 | 2,454 | F, T, H |
| `screenshots/17-skills-composer-light.png` | 2,635 | 0.0508 | 2,435 | F, T, H |
| `screenshots/17b-skills-message-dark.png` | 141,738 | 2.7341 | 132,903 | F, T, H |
| `screenshots/17b-skills-message-light.png` | 135,996 | 2.6234 | 129,606 | F, T, H |
| `screenshots/17c-skills-card-dark.png` | 139,872 | 2.6981 | 130,894 | F, T, H |
| `screenshots/17c-skills-card-light.png` | 134,454 | 2.5936 | 127,885 | F, T, H |
| `screenshots/17d-skills-popover-dark.png` | 83,076 | 1.6025 | 77,638 | F, T, H |
| `screenshots/17d-skills-popover-light.png` | 79,612 | 1.5357 | 75,615 | F, T, H |
| `screenshots/17e-skills-slash-dark.png` | 113,276 | 2.1851 | 106,240 | F, T, H |
| `screenshots/17e-skills-slash-light.png` | 108,982 | 2.1023 | 103,791 | F, T, H |
| `screenshots/17f-skills-changed-dark.png` | 87,186 | 1.6818 | 81,487 | F, T, H |
| `screenshots/17f-skills-changed-light.png` | 83,685 | 1.6143 | 79,525 | F, T, H |
| `screenshots/18-cost-limit-notice-dark.png` | 3,550 | 0.0685 | 3,250 | F, T, H |
| `screenshots/18-cost-limit-notice-light.png` | 3,943 | 0.0761 | 3,218 | F, T, H |
| `screenshots/18a-cost-limit-overview-dark.png` | 15,068 | 0.3650 | 13,845 | T, H |
| `screenshots/18a-cost-limit-overview-light.png` | 15,142 | 0.3668 | 14,177 | T, H |
| `screenshots/18b-cost-limit-editor-dark.png` | 3,710 | 0.0716 | 3,410 | F, T, H |
| `screenshots/18b-cost-limit-editor-light.png` | 3,508 | 0.0677 | 3,218 | F, T, H |
| `screenshots/18c-cost-limit-raised-dark.png` | 3,550 | 0.0685 | 3,250 | F, T, H |
| `screenshots/18c-cost-limit-raised-light.png` | 3,508 | 0.0677 | 3,218 | F, T, H |
| `screenshots/18d-cost-limit-settings-dark.png` | 1,971 | 0.0380 | 1,704 | F, T, H |
| `screenshots/18d-cost-limit-settings-light.png` | 2,285 | 0.0441 | 1,671 | F, T, H |
| `screenshots/19-webhook-settings-dark.png` | 2,258 | 0.0436 | 1,919 | F, T, H |
| `screenshots/19-webhook-settings-light.png` | 2,236 | 0.0431 | 1,889 | F, T, H |
| `screenshots/19a-version-earlier-dark.png` | 2,125 | 0.0410 | 1,990 | F, T, H |
| `screenshots/19a-version-earlier-light.png` | 2,275 | 0.0439 | 1,991 | F, T, H |
| `screenshots/19a-webhook-settings-end-dark.png` | 2,258 | 0.0436 | 1,919 | F, T, H |
| `screenshots/19a-webhook-settings-end-light.png` | 2,236 | 0.0431 | 1,889 | F, T, H |
| `screenshots/19b-fork-from-here-dark.png` | 2,125 | 0.0410 | 1,990 | F, T, H |
| `screenshots/19b-fork-from-here-light.png` | 2,103 | 0.0406 | 1,991 | F, T, H |
| `screenshots/19b-webhook-preview-dark.png` | 7,002 | 0.1351 | 6,218 | F, T, H |
| `screenshots/19b-webhook-preview-light.png` | 6,843 | 0.1320 | 6,091 | F, T, H |
| `screenshots/20-compaction-requests-dark.png` | 2,093 | 0.0507 | 1,849 | T, H |
| `screenshots/20-compaction-requests-light.png` | 69,442 | 1.6822 | 1,834 | T, H |
| `screenshots/21-background-requests-dark.png` | 56,534 | 1.0905 | 51,536 | F, T, H |
| `screenshots/21-background-requests-light.png` | 56,292 | 1.0859 | 51,429 | F, T, H |
| `screenshots/21-literal-message-dark.png` | 3,746 | 0.0723 | 3,370 | F, T, H |
| `screenshots/21-literal-message-light.png` | 12,242 | 0.2361 | 3,341 | F, T, H |
| `screenshots/21b-background-request-detail-dark.png` | 33,642 | 0.6490 | 30,499 | F, T, H |
| `screenshots/21b-background-request-detail-light.png` | 33,308 | 0.6425 | 30,258 | F, T, H |
| `screenshots/21b-reply-raw-dark.png` | 3,737 | 0.0721 | 3,370 | F, T, H |
| `screenshots/21b-reply-raw-light.png` | 3,665 | 0.0707 | 3,346 | F, T, H |
| `screenshots/21c-background-requests-compact-dark.png` | 19,725 | 0.7243 | 18,014 | F, T, H |
| `screenshots/21c-background-requests-compact-light.png` | 19,531 | 0.7172 | 17,841 | F, T, H |
| `screenshots/21c-long-paste-source-dark.png` | 2,420 | 0.0467 | 2,246 | F, T, H |
| `screenshots/21c-long-paste-source-light.png` | 2,398 | 0.0463 | 2,249 | F, T, H |
| `screenshots/21d-background-request-compact-detail-dark.png` | 16,007 | 0.5878 | 14,690 | F, T, H |
| `screenshots/21d-background-request-compact-detail-light.png` | 15,845 | 0.5819 | 14,549 | F, T, H |
| `screenshots/24-tabs-file-dark.png` | 149,624 | 2.8863 | 139,767 | F, T, H |
| `screenshots/24-tabs-file-light.png` | 143,991 | 2.7776 | 136,612 | F, T, H |
| `screenshots/24a-tabs-side-dark.png` | 143,241 | 2.7631 | 134,231 | F, T, H |
| `screenshots/24a-tabs-side-light.png` | 137,476 | 2.6519 | 130,921 | F, T, H |
| `screenshots/24b-tabs-window-dark.png` | 7,128 | 0.3881 | 6,238 | F, H |
| `screenshots/24b-tabs-window-light.png` | 7,081 | 0.3855 | 6,208 | F, H |
| `screenshots/24c-file-blame-dark.png` | 24,335 | 1.0530 | 21,331 | F, T, H |
| `screenshots/24c-file-blame-light.png` | 24,166 | 1.0457 | 21,507 | F, T, H |
| `screenshots/24c-tabs-find-dark.png` | 149,624 | 2.8863 | 139,767 | F, T, H |
| `screenshots/24c-tabs-find-light.png` | 143,831 | 2.7745 | 136,452 | F, T, H |
| `screenshots/24d-changes-from-blame-dark.png` | 19,344 | 0.8370 | 16,875 | F, T, H |
| `screenshots/24d-changes-from-blame-light.png` | 19,301 | 0.8352 | 17,258 | F, T, H |
| `screenshots/24d-tabs-go-to-line-dark.png` | 150,099 | 2.8954 | 140,243 | F, T, H |
| `screenshots/24d-tabs-go-to-line-light.png` | 144,318 | 2.7839 | 136,937 | F, T, H |
| `screenshots/24e-chat-file-link-dark.png` | 2,658 | 0.0513 | 2,439 | F, T, H |
| `screenshots/24e-chat-file-link-light.png` | 4,054 | 0.0782 | 2,603 | F, T, H |
| `screenshots/24f-image-preview-dark.png` | 147,642 | 2.8480 | 138,090 | F, T, H |
| `screenshots/24f-image-preview-light.png` | 141,885 | 2.7370 | 134,807 | F, T, H |
| `screenshots/24g-pdf-preview-dark.png` | 147,569 | 2.8466 | 138,033 | F, T, H |
| `screenshots/24g-pdf-preview-light.png` | 141,814 | 2.7356 | 134,742 | F, T, H |
| `screenshots/24h-reply-file-link-dark.png` | 3,354 | 0.0647 | 3,100 | F, T, H |
| `screenshots/24h-reply-file-link-light.png` | 5,016 | 0.0968 | 2,922 | F, T, H |
| `screenshots/24i-file-folder-tree-dark.png` | 151,809 | 2.9284 | 141,799 | F, T, H |
| `screenshots/24i-file-folder-tree-light.png` | 146,064 | 2.8176 | 138,487 | F, T, H |
| `screenshots/24i-file-folder-tree-narrow-dark.png` | 25,292 | 1.1455 | 23,553 | F, T, H |
| `screenshots/24i-file-folder-tree-narrow-light.png` | 24,483 | 1.1088 | 23,060 | F, T, H |
| `screenshots/24j-file-folder-menu-dark.png` | 169,519 | 3.2700 | 156,537 | F, T, H |
| `screenshots/24j-file-folder-menu-light.png` | 163,399 | 3.1520 | 154,762 | F, T, H |
| `screenshots/24j-file-folder-menu-narrow-dark.png` | 23,985 | 1.0677 | 22,354 | F, T, H |
| `screenshots/24j-file-folder-menu-narrow-light.png` | 23,193 | 1.0325 | 21,869 | F, T, H |
| `screenshots/24k-file-folder-long-path-dark.png` | 144,118 | 2.7801 | 135,009 | F, T, H |
| `screenshots/24k-file-folder-long-path-light.png` | 138,363 | 2.6690 | 131,739 | F, T, H |
| `screenshots/24k-file-folder-long-path-narrow-dark.png` | 23,582 | 1.0680 | 21,997 | F, T, H |
| `screenshots/24k-file-folder-long-path-narrow-light.png` | 22,789 | 1.0321 | 21,510 | F, T, H |
| `screenshots/25-quick-open-dark.png` | 3,221 | 0.0621 | 2,962 | F, T, H |
| `screenshots/25-quick-open-light.png` | 3,204 | 0.0618 | 2,952 | F, T, H |
| `screenshots/25a-quick-open-recent-dark.png` | 5,799 | 0.1119 | 5,175 | F, T, H |
| `screenshots/25a-quick-open-recent-light.png` | 5,731 | 0.1106 | 5,129 | F, T, H |
| `screenshots/26-settings-unsaved-dark.png` | 562 | 0.0196 | 486 | F, H |
| `screenshots/26-settings-unsaved-light.png` | 542 | 0.0189 | 474 | F, H |
| `screenshots/26a-settings-close-question-dark.png` | 562 | 0.0196 | 412 | F, H |
| `screenshots/26a-settings-close-question-light.png` | 532 | 0.0185 | 414 | F, H |
| `screenshots/26b-terminals-dark.png` | 7,498 | 0.3244 | 6,893 | F, T, H |
| `screenshots/26b-terminals-light.png` | 14,779 | 0.6395 | 13,919 | F, T, H |
| `screenshots/26c-terminal-restart-question-dark.png` | 25,685 | 1.1114 | 14,853 | F, T, H |
| `screenshots/26c-terminal-restart-question-light.png` | 17,431 | 0.7542 | 15,685 | F, T, H |
| `screenshots/26d-terminal-close-question-dark.png` | 12,452 | 0.5388 | 7,960 | F, T, H |
| `screenshots/26d-terminal-close-question-light.png` | 10,494 | 0.4541 | 9,308 | F, T, H |
| `screenshots/26e-mcp-remove-question-dark.png` | 207,896 | 8.9958 | 122,420 | F, T, H |
| `screenshots/26e-mcp-remove-question-light.png` | 137,984 | 5.9706 | 130,193 | F, T, H |
| `screenshots/27-sidebar-marked-unread-dark.png` | 2,830 | 0.1282 | 2,614 | F, T, H |
| `screenshots/27-sidebar-marked-unread-light.png` | 4,045 | 0.1832 | 2,437 | F, T, H |
| `screenshots/27a-paused-after-restart-row-dark.png` | 21,464 | 0.9721 | 20,104 | F, T, H |
| `screenshots/27a-paused-after-restart-row-light.png` | 20,645 | 0.9350 | 19,668 | F, T, H |
| `screenshots/27b-paused-after-restart-chat-dark.png` | 3,426 | 0.1552 | 3,104 | F, T, H |
| `screenshots/27b-paused-after-restart-chat-light.png` | 3,420 | 0.1549 | 3,125 | F, T, H |
| `screenshots/28-sidebar-recently-opened-dark.png` | 2,670 | 0.1209 | 2,454 | F, T, H |
| `screenshots/28-sidebar-recently-opened-light.png` | 2,635 | 0.1193 | 2,435 | F, T, H |
| `screenshots/29-sidebar-row-states-dark.png` | 5,464 | 0.2475 | 5,096 | F, T, H |
| `screenshots/29-sidebar-row-states-light.png` | 5,462 | 0.2474 | 5,064 | F, T, H |
| `screenshots/29a-sidebar-working-rows-dark.png` | 3,172 | 0.1437 | 2,687 | F, T, H |
| `screenshots/29a-sidebar-working-rows-light.png` | 3,266 | 0.1479 | 2,762 | F, T, H |
| `screenshots/30-retry-settings-dark.png` | 2,258 | 0.0436 | 1,919 | F, T, H |
| `screenshots/30-retry-settings-light.png` | 2,236 | 0.0431 | 1,889 | F, T, H |
| `screenshots/30a-paused-chat-resume-dark.png` | 1,954 | 0.0885 | 1,832 | F, T, H |
| `screenshots/30a-paused-chat-resume-light.png` | 1,933 | 0.0875 | 1,831 | F, T, H |
| `screenshots/30b-update-pause-question-dark.png` | 4,244 | 0.1922 | 1,898 | F, T, H |
| `screenshots/30b-update-pause-question-light.png` | 2,268 | 0.1027 | 1,858 | F, T, H |
| `steering/background-expanded-dark-1240x800.png` | 46,326 | 1.1280 | 18,574 | F, H |
| `steering/background-expanded-dark-920x600.png` | 25,269 | 1.0934 | 10,477 | F, H |
| `steering/background-expanded-light-1240x800.png` | 42,603 | 1.0374 | 19,480 | F, H |
| `steering/background-expanded-light-920x600.png` | 32,830 | 1.4206 | 13,550 | F, H |
| `steering/background-folded-dark-1240x800.png` | 30,356 | 0.7391 | 10,288 | F, H |
| `steering/background-folded-dark-920x600.png` | 26,549 | 1.1488 | 10,075 | F, H |
| `steering/background-folded-light-1240x800.png` | 38,341 | 0.9336 | 14,891 | F, H |
| `steering/background-folded-light-920x600.png` | 43,636 | 1.8882 | 20,382 | F, H |
| `steering/child-report-dark-1240x800.png` | 3,318 | 0.0808 | 2,766 | F, H |
| `steering/child-report-dark-920x600.png` | 3,384 | 0.1464 | 2,773 | F, H |
| `steering/child-report-light-1240x800.png` | 3,574 | 0.0870 | 3,039 | F, H |
| `steering/child-report-light-920x600.png` | 3,905 | 0.1690 | 3,282 | F, H |
| `steering/coordination-paused-dark-1240x800.png` | 2,661 | 0.0648 | 2,422 | F, H |
| `steering/coordination-paused-dark-920x600.png` | 2,666 | 0.1154 | 2,405 | F, H |
| `steering/coordination-paused-light-1240x800.png` | 2,658 | 0.0647 | 2,401 | F, H |
| `steering/coordination-paused-light-920x600.png` | 2,663 | 0.1152 | 2,415 | F, H |
| `steering/delivered-blocker-dark-1240x800.png` | 3,266 | 0.0795 | 2,763 | F, H |
| `steering/delivered-blocker-dark-920x600.png` | 3,660 | 0.1584 | 2,875 | F, H |
| `steering/delivered-blocker-light-1240x800.png` | 3,435 | 0.0836 | 2,946 | F, H |
| `steering/delivered-blocker-light-920x600.png` | 3,124 | 0.1352 | 2,671 | F, H |
| `steering/delivered-question-dark-1240x800.png` | 3,541 | 0.0862 | 2,881 | F, H |
| `steering/delivered-question-dark-920x600.png` | 3,346 | 0.1448 | 2,724 | F, H |
| `steering/delivered-question-light-1240x800.png` | 3,486 | 0.0849 | 3,018 | F, H |
| `steering/delivered-question-light-920x600.png` | 3,438 | 0.1488 | 2,977 | F, H |
| `steering/delivered-result-dark-1240x800.png` | 3,484 | 0.0848 | 2,754 | F, H |
| `steering/delivered-result-dark-920x600.png` | 3,155 | 0.1365 | 2,646 | F, H |
| `steering/delivered-result-light-1240x800.png` | 3,368 | 0.0820 | 2,872 | F, H |
| `steering/delivered-result-light-920x600.png` | 3,438 | 0.1488 | 2,907 | F, H |
| `steering/family-cost-limit-dark-1240x800.png` | 46,722 | 1.1377 | 19,239 | F, H |
| `steering/family-cost-limit-dark-920x600.png` | 2,678 | 0.1159 | 2,428 | F, H |
| `steering/family-cost-limit-light-1240x800.png` | 56,263 | 1.3700 | 25,696 | F, H |
| `steering/family-cost-limit-light-920x600.png` | 2,783 | 0.1204 | 2,524 | F, H |
| `steering/final-wait-dark-1240x800.png` | 41,909 | 1.0205 | 19,403 | F, H |
| `steering/final-wait-dark-920x600.png` | 3,450 | 0.1493 | 2,684 | F, H |
| `steering/final-wait-light-1240x800.png` | 57,230 | 1.3935 | 26,253 | F, H |
| `steering/final-wait-light-920x600.png` | 3,167 | 0.1370 | 2,689 | F, H |
| `steering/follow-up-card-dark-1240x800.png` | 21,123 | 0.5143 | 9,230 | F, H |
| `steering/follow-up-card-dark-920x600.png` | 38,310 | 1.6577 | 17,242 | F, H |
| `steering/follow-up-card-light-1240x800.png` | 32,344 | 0.7876 | 15,865 | F, H |
| `steering/follow-up-card-light-920x600.png` | 32,545 | 1.4082 | 13,748 | F, H |
| `steering/follow-up-three-dark-1240x800.png` | 3,446 | 0.0839 | 2,768 | F, H |
| `steering/follow-up-three-dark-920x600.png` | 3,416 | 0.1478 | 2,778 | F, H |
| `steering/follow-up-three-light-1240x800.png` | 3,573 | 0.0870 | 3,022 | F, H |
| `steering/follow-up-three-light-920x600.png` | 3,477 | 0.1505 | 3,038 | F, H |
| `steering/follow-up-two-dark-1240x800.png` | 3,530 | 0.0860 | 2,825 | F, H |
| `steering/follow-up-two-dark-920x600.png` | 3,247 | 0.1405 | 2,684 | F, H |
| `steering/follow-up-two-light-1240x800.png` | 3,571 | 0.0870 | 3,078 | F, H |
| `steering/follow-up-two-light-920x600.png` | 3,664 | 0.1585 | 3,139 | F, H |
| `steering/inspector-capture-missing-dark-1240x800.png` | 8,589 | 0.2165 | 8,008 | T, H |
| `steering/inspector-capture-missing-dark-920x600.png` | 5,825 | 0.2638 | 5,434 | T, H |
| `steering/inspector-capture-missing-light-1240x800.png` | 8,319 | 0.2097 | 7,737 | T, H |
| `steering/inspector-capture-missing-light-920x600.png` | 5,641 | 0.2555 | 5,238 | T, H |
| `steering/inspector-outside-window-dark-1240x800.png` | 10,206 | 0.2572 | 9,496 | T, H |
| `steering/inspector-outside-window-dark-920x600.png` | 4,468 | 0.2024 | 4,176 | T, H |
| `steering/inspector-outside-window-light-1240x800.png` | 9,877 | 0.2489 | 9,178 | T, H |
| `steering/inspector-outside-window-light-920x600.png` | 4,307 | 0.1951 | 4,024 | T, H |
| `steering/inspector-turns-dark-1240x800.png` | 7,579 | 0.1910 | 7,086 | T, H |
| `steering/inspector-turns-dark-920x600.png` | 4,815 | 0.2181 | 4,512 | T, H |
| `steering/inspector-turns-light-1240x800.png` | 7,326 | 0.1846 | 6,845 | T, H |
| `steering/inspector-turns-light-920x600.png` | 4,648 | 0.2105 | 4,346 | T, H |
| `steering/long-text-keyboard-dark-1240x800.png` | 2,701 | 0.0658 | 2,412 | F, H |
| `steering/long-text-keyboard-dark-920x600.png` | 2,743 | 0.1187 | 2,437 | F, H |
| `steering/long-text-keyboard-light-1240x800.png` | 2,680 | 0.0653 | 2,394 | F, H |
| `steering/long-text-keyboard-light-920x600.png` | 2,683 | 0.1161 | 2,500 | F, H |
| `steering/message-delivered-card-dark-1240x800.png` | 39,819 | 0.9696 | 17,877 | F, H |
| `steering/message-delivered-card-dark-920x600.png` | 3,620 | 0.1566 | 2,852 | F, H |
| `steering/message-delivered-card-light-1240x800.png` | 29,468 | 0.7175 | 13,685 | F, H |
| `steering/message-delivered-card-light-920x600.png` | 3,055 | 0.1322 | 2,572 | F, H |
| `steering/parent-steering-dark-1240x800.png` | 3,483 | 0.0848 | 2,787 | F, H |
| `steering/parent-steering-dark-920x600.png` | 3,363 | 0.1455 | 2,747 | F, H |
| `steering/parent-steering-light-1240x800.png` | 3,813 | 0.0928 | 3,237 | F, H |
| `steering/parent-steering-light-920x600.png` | 3,279 | 0.1419 | 2,857 | F, H |
| `steering/pending-blocker-dark-1240x800.png` | 3,315 | 0.0807 | 2,735 | F, H |
| `steering/pending-blocker-dark-920x600.png` | 3,297 | 0.1427 | 2,696 | F, H |
| `steering/pending-blocker-light-1240x800.png` | 3,457 | 0.0842 | 2,976 | F, H |
| `steering/pending-blocker-light-920x600.png` | 3,687 | 0.1595 | 3,136 | F, H |
| `steering/pending-question-dark-1240x800.png` | 3,528 | 0.0859 | 2,881 | F, H |
| `steering/pending-question-dark-920x600.png` | 3,275 | 0.1417 | 2,715 | F, H |
| `steering/pending-question-light-1240x800.png` | 3,925 | 0.0956 | 3,289 | F, H |
| `steering/pending-question-light-920x600.png` | 3,631 | 0.1571 | 3,113 | F, H |
| `steering/pending-result-dark-1240x800.png` | 3,364 | 0.0819 | 2,666 | F, H |
| `steering/pending-result-dark-920x600.png` | 3,258 | 0.1410 | 2,648 | F, H |
| `steering/pending-result-light-1240x800.png` | 3,721 | 0.0906 | 3,121 | F, H |
| `steering/pending-result-light-920x600.png` | 3,694 | 0.1598 | 3,095 | F, H |
| `steering/resume-undelivered-dark-1240x800.png` | 2,540 | 0.0618 | 2,386 | F, H |
| `steering/resume-undelivered-dark-920x600.png` | 2,671 | 0.1156 | 2,427 | F, H |
| `steering/resume-undelivered-light-1240x800.png` | 2,659 | 0.0647 | 2,392 | F, H |
| `steering/resume-undelivered-light-920x600.png` | 2,744 | 0.1187 | 2,511 | F, H |
| `steering/user-stopped-hold-dark-1240x800.png` | 3,357 | 0.0817 | 2,816 | F, H |
| `steering/user-stopped-hold-dark-920x600.png` | 3,386 | 0.1465 | 2,746 | F, H |
| `steering/user-stopped-hold-light-1240x800.png` | 3,496 | 0.0851 | 3,007 | F, H |
| `steering/user-stopped-hold-light-920x600.png` | 4,118 | 0.1782 | 3,476 | F, H |
| `subagents/cancelled-dark-1240x800.png` | 2,739 | 0.0667 | 2,547 | F, H |
| `subagents/cancelled-dark-920x600.png` | 2,721 | 0.1177 | 2,519 | F, H |
| `subagents/cancelled-light-1240x800.png` | 2,724 | 0.0663 | 2,528 | F, H |
| `subagents/cancelled-light-920x600.png` | 3,079 | 0.1332 | 2,765 | F, H |
| `subagents/child-cost-paused-dark-1240x800.png` | 2,630 | 0.0640 | 2,509 | F, H |
| `subagents/child-cost-paused-dark-920x600.png` | 2,630 | 0.1138 | 2,509 | F, H |
| `subagents/child-cost-paused-light-1240x800.png` | 2,604 | 0.0634 | 2,472 | F, H |
| `subagents/child-cost-paused-light-920x600.png` | 2,732 | 0.1182 | 2,600 | F, H |
| `subagents/child-dark-1240x800.png` | 2,764 | 0.0673 | 2,558 | F, H |
| `subagents/child-dark-920x600.png` | 2,744 | 0.1187 | 2,542 | F, H |
| `subagents/child-light-1240x800.png` | 2,734 | 0.0666 | 2,514 | F, H |
| `subagents/child-light-920x600.png` | 2,869 | 0.1241 | 2,662 | F, H |
| `subagents/completed-dark-1240x800.png` | 2,729 | 0.0664 | 2,521 | F, H |
| `subagents/completed-dark-920x600.png` | 2,747 | 0.1189 | 2,545 | F, H |
| `subagents/completed-light-1240x800.png` | 2,717 | 0.0662 | 2,510 | F, H |
| `subagents/completed-light-920x600.png` | 3,628 | 0.1570 | 3,169 | F, H |
| `subagents/failed-dark-1240x800.png` | 2,731 | 0.0665 | 2,525 | F, H |
| `subagents/failed-dark-920x600.png` | 2,729 | 0.1181 | 2,520 | F, H |
| `subagents/failed-light-1240x800.png` | 2,725 | 0.0664 | 2,523 | F, H |
| `subagents/failed-light-920x600.png` | 3,145 | 0.1361 | 2,773 | F, H |
| `subagents/family-cost-limit-dark-1240x800.png` | 24,929 | 0.6070 | 10,564 | F, H |
| `subagents/family-cost-limit-dark-920x600.png` | 39,744 | 1.7197 | 18,332 | F, H |
| `subagents/family-cost-limit-light-1240x800.png` | 35,276 | 0.8589 | 13,180 | F, H |
| `subagents/family-cost-limit-light-920x600.png` | 31,696 | 1.3715 | 14,720 | F, H |
| `subagents/family-cost-limit-raised-dark-1240x800.png` | 40,797 | 0.9934 | 18,345 | F, H |
| `subagents/family-cost-limit-raised-dark-920x600.png` | 32,282 | 1.3969 | 11,908 | F, H |
| `subagents/family-cost-limit-raised-light-1240x800.png` | 43,489 | 1.0589 | 20,887 | F, H |
| `subagents/family-cost-limit-raised-light-920x600.png` | 28,851 | 1.2484 | 13,457 | F, H |
| `subagents/family-inspector-child-dark-1240x800.png` | 616 | 0.0155 | 562 | T, H |
| `subagents/family-inspector-child-dark-920x600.png` | 616 | 0.0279 | 562 | T, H |
| `subagents/family-inspector-child-light-1240x800.png` | 604 | 0.0152 | 549 | T, H |
| `subagents/family-inspector-child-light-920x600.png` | 604 | 0.0274 | 549 | T, H |
| `subagents/family-inspector-dark-1240x800.png` | 734 | 0.0185 | 611 | T, H |
| `subagents/family-inspector-dark-920x600.png` | 734 | 0.0332 | 611 | T, H |
| `subagents/family-inspector-light-1240x800.png` | 716 | 0.0180 | 607 | T, H |
| `subagents/family-inspector-light-920x600.png` | 716 | 0.0324 | 607 | T, H |
| `subagents/flat-expanded-dark-1240x800.png` | 25,590 | 0.6231 | 11,340 | F, H |
| `subagents/flat-expanded-dark-920x600.png` | 38,090 | 1.6482 | 17,060 | F, H |
| `subagents/flat-expanded-light-1240x800.png` | 35,127 | 0.8553 | 13,263 | F, H |
| `subagents/flat-expanded-light-920x600.png` | 33,282 | 1.4401 | 15,036 | F, H |
| `subagents/flat-folded-dark-1240x800.png` | 45,070 | 1.0974 | 18,636 | F, H |
| `subagents/flat-folded-dark-920x600.png` | 24,261 | 1.0498 | 10,202 | F, H |
| `subagents/flat-folded-light-1240x800.png` | 39,031 | 0.9504 | 15,911 | F, H |
| `subagents/flat-folded-light-920x600.png` | 50,808 | 2.1985 | 26,242 | F, H |
| `subagents/interrupted-dark-1240x800.png` | 2,742 | 0.0668 | 2,546 | F, H |
| `subagents/interrupted-dark-920x600.png` | 2,717 | 0.1176 | 2,521 | F, H |
| `subagents/interrupted-light-1240x800.png` | 2,731 | 0.0665 | 2,527 | F, H |
| `subagents/interrupted-light-920x600.png` | 3,454 | 0.1495 | 3,001 | F, H |
| `subagents/long-label-keyboard-reduced-motion-dark-1240x800.png` | 2,734 | 0.0666 | 2,528 | F, H |
| `subagents/long-label-keyboard-reduced-motion-dark-920x600.png` | 2,736 | 0.1184 | 2,531 | F, H |
| `subagents/long-label-keyboard-reduced-motion-light-1240x800.png` | 2,695 | 0.0656 | 2,487 | F, H |
| `subagents/long-label-keyboard-reduced-motion-light-920x600.png` | 2,720 | 0.1177 | 2,517 | F, H |
| `subagents/missing-parent-dark-1240x800.png` | 2,630 | 0.0640 | 2,509 | F, H |
| `subagents/missing-parent-dark-920x600.png` | 2,630 | 0.1138 | 2,509 | F, H |
| `subagents/missing-parent-light-1240x800.png` | 2,604 | 0.0634 | 2,472 | F, H |
| `subagents/missing-parent-light-920x600.png` | 2,604 | 0.1127 | 2,472 | F, H |
| `subagents/output-limited-dark-1240x800.png` | 2,753 | 0.0670 | 2,548 | F, H |
| `subagents/output-limited-dark-920x600.png` | 2,743 | 0.1187 | 2,535 | F, H |
| `subagents/output-limited-light-1240x800.png` | 2,733 | 0.0665 | 2,521 | F, H |
| `subagents/output-limited-light-920x600.png` | 3,597 | 0.1556 | 3,132 | F, H |
| `subagents/parallel-queued-dark-1240x800.png` | 134,505 | 3.2751 | 51,752 | F, H |
| `subagents/parallel-queued-dark-920x600.png` | 122,456 | 5.2987 | 39,200 | F, H |
| `subagents/parallel-queued-light-1240x800.png` | 162,147 | 3.9482 | 72,444 | F, H |
| `subagents/parallel-queued-light-920x600.png` | 96,399 | 4.1712 | 34,696 | F, H |
| `subagents/parent-unread-draft-dark-1240x800.png` | 43,068 | 1.0487 | 18,492 | F, H |
| `subagents/parent-unread-draft-dark-920x600.png` | 34,678 | 1.5005 | 13,586 | F, H |
| `subagents/parent-unread-draft-light-1240x800.png` | 44,737 | 1.0893 | 21,346 | F, H |
| `subagents/parent-unread-draft-light-920x600.png` | 30,540 | 1.3215 | 14,718 | F, H |
| `subagents/recovery-error-dark-1240x800.png` | 2,700 | 0.0657 | 2,516 | F, H |
| `subagents/recovery-error-dark-920x600.png` | 2,720 | 0.1177 | 2,521 | F, H |
| `subagents/recovery-error-light-1240x800.png` | 2,700 | 0.0657 | 2,484 | F, H |
| `subagents/recovery-error-light-920x600.png` | 2,707 | 0.1171 | 2,490 | F, H |
| `subagents/relaunch-paused-dark-1240x800.png` | 2,630 | 0.0640 | 2,509 | F, H |
| `subagents/relaunch-paused-dark-920x600.png` | 2,630 | 0.1138 | 2,509 | F, H |
| `subagents/relaunch-paused-light-1240x800.png` | 2,604 | 0.0634 | 2,472 | F, H |
| `subagents/relaunch-paused-light-920x600.png` | 2,604 | 0.1127 | 2,472 | F, H |
| `subagents/running-collapsed-dark-1240x800.png` | 43,352 | 1.0556 | 18,322 | F, H |
| `subagents/running-collapsed-dark-920x600.png` | 34,886 | 1.5095 | 14,382 | F, H |
| `subagents/running-collapsed-light-1240x800.png` | 37,470 | 0.9124 | 21,077 | F, H |
| `subagents/running-collapsed-light-920x600.png` | 38,301 | 1.6573 | 18,411 | F, H |
| `subagents/running-expanded-dark-1240x800.png` | 25,066 | 0.6103 | 10,981 | F, H |
| `subagents/running-expanded-dark-920x600.png` | 41,270 | 1.7858 | 18,293 | F, H |
| `subagents/running-expanded-light-1240x800.png` | 29,855 | 0.7270 | 13,393 | F, H |
| `subagents/running-expanded-light-920x600.png` | 26,394 | 1.1421 | 12,265 | F, H |
| `subagents/search-child-dark-1240x800.png` | 31,316 | 0.7625 | 10,802 | F, H |
| `subagents/search-child-dark-920x600.png` | 25,421 | 1.1000 | 11,259 | F, H |
| `subagents/search-child-light-1240x800.png` | 57,477 | 1.3995 | 25,774 | F, H |
| `subagents/search-child-light-920x600.png` | 30,789 | 1.3323 | 13,558 | F, H |
| `subagents/topics-expanded-dark-1240x800.png` | 39,692 | 0.9665 | 18,280 | F, H |
| `subagents/topics-expanded-dark-920x600.png` | 30,819 | 1.3336 | 10,285 | F, H |
| `subagents/topics-expanded-light-1240x800.png` | 33,898 | 0.8254 | 15,292 | F, H |
| `subagents/topics-expanded-light-920x600.png` | 54,160 | 2.3435 | 26,346 | F, H |
| `subagents/topics-folded-dark-1240x800.png` | 26,822 | 0.6531 | 10,963 | F, H |
| `subagents/topics-folded-dark-920x600.png` | 30,223 | 1.3078 | 10,958 | F, H |
| `subagents/topics-folded-light-1240x800.png` | 55,505 | 1.3515 | 26,611 | F, H |
| `subagents/topics-folded-light-920x600.png` | 36,171 | 1.5651 | 13,568 | F, H |
| `subagents/truncated-dark-1240x800.png` | 2,761 | 0.0672 | 2,569 | F, H |
| `subagents/truncated-dark-920x600.png` | 2,756 | 0.1193 | 2,563 | F, H |
| `subagents/truncated-light-1240x800.png` | 2,738 | 0.0667 | 2,532 | F, H |
| `subagents/truncated-light-920x600.png` | 2,990 | 0.1294 | 2,688 | F, H |

## Added project-filter scenes

All eight were visually inspected. These have no reference image because they
exercise the approved SIDEBAR-1 filter and overflow menu.

- `screenshots/14h-sidebar-flat-project-narrow-dark.png` — S; added validation scene.
- `screenshots/14h-sidebar-flat-project-narrow-light.png` — S; added validation scene.
- `screenshots/14h-sidebar-flat-project-normal-dark.png` — S; added validation scene.
- `screenshots/14h-sidebar-flat-project-normal-light.png` — S; added validation scene.
- `screenshots/14i-sidebar-flat-overflow-narrow-dark.png` — S; added validation scene.
- `screenshots/14i-sidebar-flat-overflow-narrow-light.png` — S; added validation scene.
- `screenshots/14i-sidebar-flat-overflow-normal-dark.png` — S; added validation scene.
- `screenshots/14i-sidebar-flat-overflow-normal-light.png` — S; added validation scene.

## Pixel-identical images

- `retry-budget.png`
- `screenshots/00-onboarding-dark.png`
- `screenshots/00-onboarding-light.png`
- `screenshots/11f-inspector-next-request-dark.png`
- `screenshots/11f-inspector-next-request-light.png`
- `screenshots/23-table-window-dark.png`
- `screenshots/23-table-window-light.png`

## Additional session-panel gallery

All 22 images below were visually inspected: reply prose, headings/lists, file
and diff rows, agent/side labels, and the open side reply remain drawn in both
appearances and narrow/wide layouts. These are additional validation captures,
not differences against a matching release-gate file.

- `agents-1180x800-dark.png` — additional session-panel coverage.
- `agents-1180x800-light.png` — additional session-panel coverage.
- `agents-1440x900-dark.png` — additional session-panel coverage.
- `agents-1440x900-light.png` — additional session-panel coverage.
- `diff-1440x900-dark.png` — additional session-panel coverage.
- `diff-1440x900-light.png` — additional session-panel coverage.
- `diff-classification-1440x900-dark.png` — additional session-panel coverage.
- `diff-classification-1440x900-light.png` — additional session-panel coverage.
- `diff-no-renames-1440x900-dark.png` — additional session-panel coverage.
- `diff-no-renames-1440x900-light.png` — additional session-panel coverage.
- `diff-unavailable-1440x900-dark.png` — additional session-panel coverage.
- `diff-unavailable-1440x900-light.png` — additional session-panel coverage.
- `empty-1440x900-dark.png` — additional session-panel coverage.
- `empty-1440x900-light.png` — additional session-panel coverage.
- `files-1440x900-dark.png` — additional session-panel coverage.
- `files-1440x900-light.png` — additional session-panel coverage.
- `pill-960x700-dark.png` — additional session-panel coverage.
- `pill-960x700-light.png` — additional session-panel coverage.
- `repository-removed-1440x900-dark.png` — additional session-panel coverage.
- `repository-removed-1440x900-light.png` — additional session-panel coverage.
- `side-open-1600x900-dark.png` — additional session-panel coverage.
- `side-open-1600x900-light.png` — additional session-panel coverage.

## Reproduce the comparison

The analysis scripts and pinned runtime are retained under this workstream's
build root (Pillow 13.0.0, NumPy 2.5.4). Commands:

```sh
B=/Users/admin/Library/Caches/BelloSwiftWork/build-a131-blanktext
REF=/Users/admin/Library/Caches/BelloSwiftWork/r131/gallery-0.1.130-gate
"$B/venv/bin/python" "$B/compare-gallery.py" "$REF" "$B/gallery-fixed" "$B/compare-final"
"$B/venv/bin/python" "$B/check-missing-ink.py" "$REF" "$B/gallery-fixed" "$B/compare-final/missing-ink.json"
"$B/venv/bin/python" "$B/focus-diffs.py"
"$B/venv/bin/python" "$B/write-gallery-report.py"
```
