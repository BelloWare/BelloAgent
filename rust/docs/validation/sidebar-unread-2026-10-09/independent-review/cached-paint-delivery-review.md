# Cached-paint delivery delta review

Scoped PASS at 2026-10-09 04:15 UTC. No blocking defect found in the delta from immutable unread-native-r5/source (intermediate candidate766) to freeze manifest SHA256 2f4acc3d00ce73fbc7145f652df10181aaca9b51640065e17052cfecaa4ca87a. Verified all33 frozen file hashes and unchanged12 core/catalog review hashes. No Cargo, product edits or remote writes by reviewer. Earlier findings and failure diagnostics preserved.

## Delivery and stale work

- Selected transcript child is explicitly invalidated after accepted metadata changes, explicit opening, successful write/retry completion, and actual grace release. The helper only requests fresh layout/paint when automatic unread or failure debt exists; it does not manufacture visibility or acknowledge debt. Manual-only markers remain outside automatic acknowledgement.
- In-app cover-to-readable transition stores its ready flag and defers child invalidation until after parent render, preventing the cached child's dirty notification from being absorbed. Deferred work verifies exact Workspace Arc, window binding, selected chat ID, weak Controller identity and current reading route. Window rebinding resets the ready flag. Unchanged parent renders do not repeatedly schedule reveal work.
- Grace release remains workspace-owned and matches path plus unique hold token. Replaced/cancelled holds reject old callbacks. Coordinator lock is dropped before child invalidation, avoiding reentrant acquisition. Release reveals existing debt and schedules repaint only; it neither writes catalog state nor advances baseline.
- New metadata invalidation is on accepted checkpoint observation, not streamed tokens. Child painting still requires the authoritative target/revision/generation and finite post-layout viewport/end evidence; deferred acknowledgement rechecks current window size, presentation, scroll, end visibility and readable native surface. A repaint request cannot bypass those gates. A successful acknowledgement clears debt, so its resulting write completion does not establish a repaint/write feedback loop.

## Inspected execution evidence

Paths are relative to rust/docs/validation/sidebar-unread-2026-10-09/app/:

- cache-proof-test.log:1/1 PASS, actual GPUI cached-child delivery for late accepted metadata and in-app reveal; unchanged redraw remains cached.
- grace-timer-test.log:1/1 PASS, replacement and manual cancellation fencing, durable counts unchanged and catalog bytes unchanged on timer reveal.
- r5-default-app-tests.log:575 PASS,1 ignored,0 failed; includes both tests above.
- r5-default-clippy.log and r5-all-features-clippy.log: completed successfully.

Logs were produced by owner and independently read here; reviewer did not execute Cargo. All-feature aggregate and cleanseal were ongoing at review time, so this document does not certify them.

## Limits

This delta establishes delivery of a new geometry check, not native visibility. In-app route reveal and platform-native activation/occlusion are distinct. No new macOS/native acceptance, Dock behavior, full Swift parity or performance claim follows. Intermediate r5 native766 remains intermediate. Historical discarded timeline-only partials and abrupt-crash failure occurrence limits from earlier review remain unchanged.
