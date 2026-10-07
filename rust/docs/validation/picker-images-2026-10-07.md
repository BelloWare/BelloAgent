# Picker-selected image attachments: 2026-10-07 acceptance

## Exact candidates and scope

Published preimage: `8498464d31778b14c7090c2a34835bac3319849c`, tree
`a3cfa620379fd0e5cf7fce50b0756ca9b10cbfba`. Snapshot schema is now **7** and
workspace catalog schema is **8**; previous versions remain readable without an
opening rewrite. The MCP outcome writer lease and saved factory/rebind changes
from that preimage are preserved.

- Candidate 1 binary SHA-256:
  `c45dc497e42ca7c71fbdb9cdb6cd08ce883ebbc3f12b1d62f4f4929a8b4e4df6`
- Candidate 1 Rust source manifest:
  `cd15758610c3ec6a85251068ba533269ff4094f3a1b0acf8f3e06a4ce841e5c0`
- Final candidate 2 binary SHA-256:
  `7c2dd607f1859f2a639305fccf03c6d125e7818407d26718819c5ee1b9f937fc`
- Final candidate 2 Rust source manifest:
  `b5a38875edff8551bd9ed31e9804d152fa3233e16985897005f788ada5bff50f`

Candidate 2 adds only the independently reviewed chip-open/propagation guards and
held-edit picker gate to candidate 1's compiled Rust. Both binaries were copied
before GUI use and remained immutable. Candidate 2 was rebuilt from the main
worktree after package-scoped cleaning of Agent core/app; its log names the exact
main source paths. Shared dependency and BelloBox artifacts were not cleaned.
Documentation/evidence packaging happened after the last GUI run; it changes no
compiled Rust. The full per-Rust-file blob map is in the adjacent LOC report.

## Automated evidence

All results below are Linux cloud results, not native macOS GUI acceptance.
Core source was identical between the final rebased core tests and candidate 2.

| Suite | Result |
| --- | --- |
| Core default | 346 unit + 107 integration passed |
| Core synthetic-authority | 470 unit + 107 integration passed |
| Core all-features library | 484 unit passed |
| Core strict all-target Clippy, default and synthetic | Passed |
| Candidate 2 app default | 430 passed, 1 native test ignored |
| Candidate 2 app synthetic-authority | 531 passed, 3 native tests ignored |
| Candidate 2 focused composer attachments | 19 passed, including 7 final regressions |
| App strict all-target Clippy, default and synthetic | Passed |
| rustfmt, diff whitespace and exact LOC/source verifier | Passed |

The independent core reviewer added three passing UserContent admission tests:
exact 20 MiB JSON acceptance and one-byte rejection with escaping, strict image
base64 size/canonical tails/MIME, and metadata/text/image/block counts. Physical
worker tests cover retirement racing registration and dropped awaiting callers.
Receipt recovery review/reruns covered existing files, symlink/FIFO/directory,
identity/CAS and unverified draft-only extraction. Source review and tests retain
committed tool-boundary settlement and refuse uncertain settlement.

Four meaningful mutation controls failed as intended: source digest comparison,
prepared-candidate attachment equality, user-image compaction safety, and Context
attachment freshness. These were performed in isolated **pre-rebase staging**,
then exactly restored before positive suites. The 458-unit restored pre-rebase
count is not the final 470/484 count. A separate early recovery test compile error
was not a valid mutation-control result and is not counted here.

Final suite/build logs and mutation logs are in
[`picker-images-2026-10-07/`](picker-images-2026-10-07/).
Only terminal blank lines at EOF were removed from copied text logs; the manifest
retains their original hashes. Screenshot bytes are unchanged.

## Actual cloud GUI matrix

The application used its ordinary saved connection factory, explicit connection
selection, explicit project trust and the real GTK portal chooser. Only generated
one-pixel GIF fixtures and a numeric-loopback HTTP server were used. Every image
success here exercises the explicitly sealed Linux synthetic normalizer, not
portable ImageIO equivalence. Image-only means zero submitted text bytes.

| Executed case | Result and evidence |
| --- | --- |
| Candidate 1 system chooser and Cancel | Real chooser appeared through official portal; cancelling an empty draft sent nothing. `candidate1-system-picker.png` |
| Candidate 1 selection and image-only Send | Filename chip and enabled Send; delivered user label `Image`; gateway request 1 contained one `input_image`, no empty text block. |
| Candidate 1 idle Context | Prepared image-only request showed one image and no empty text; no provider request before Send. |
| Candidate 1 provider failure and Retry | Request 2 received fixture HTTP 503. Original retry file was renamed away. Explicit Retry request 3 had exactly the same retained user payload structures/hashes and succeeded. `candidate1-retry-verification.json` |
| Candidate 1 four-file picker/close | Selected four files together; four filename chips persisted on graceful close. |
| Candidate 2 process restart | History and the exact four draft records reappeared with the retry source still absent. Memory-only project authority was lost, so Send stayed blocked and no provider request occurred. `candidate2-process-reopen-verification.json` |
| Candidate 2 chip opening | Clicking `four.gif` explicitly opened the generated original in the desktop ImageMagick viewer; its window title identified the file. The 1×1 viewer was then closed. |
| Candidate 2 streaming and four-image Queue | Text+image stream remained live while picker accepted four new images. Return persisted an image-only follow-up with four metadata records; provider count stayed 1. |
| Stop | Explicit Stop closed the stream, paused the queue and preserved all four pending image records. |
| Held edit, image-only Save, parked draft | Ordinary `parked` text plus `changed.gif` was parked. Held queue retained its original four images. Empty-text Save succeeded and restored the ordinary draft with exact metadata. |
| Held-edit picker gate | Clicking the disabled photo control did not open a chooser; portal OpenFile count stayed 3. Headless tests additionally cover Begin/Save/Cancel/recovery resolving states and already-started late completion. |
| Navigation | New chat showed no originating chips/text; returning restored `parked` plus its image and the paused four-image queue. |
| Delivery revalidation | Renamed one queued original away, then Resume. Delivery failed, all pending metadata remained, and no new provider request occurred. Restored exact bytes and resumed: request 2 delivered four ordered image blocks and zero text bytes. |
| Acceptance revalidation | Changed one draft source byte without changing its length, then Send. `Selected image changed` error restored exact text/metadata, left no receipt and produced no new provider request. |
| Invalid picker content | Selecting text named `invalid.png` reported the supported-format error and preserved the original draft. |
| Chip removal | × removed only the selected draft record, retained the text, and did not open a viewer. Encoded path/stale callback/duplicate-path UUID behavior has focused event tests. |
| Image-only Steer | During a second stream, explicit Steer persisted lane `steering`, zero text and one image. Stop retained it; Resume delivered it in request 4. |
| Active Context | Temporarily removed the selected draft's source. Active Context still prepared successfully and explicitly excluded the draft. No extra provider request; source restored before Steer acceptance. |
| Compaction with originals absent | Removed all six delivered-image source paths. Explicit Compact Now sent retained image groups 1/4/1, completed in one HTTP attempt, and durably adopted a checkpoint. Every stored UserContent remained byte-for-byte structurally equal. |
| Replay after compaction | With originals still absent, a subsequent text Send replayed the retained active-tail image and succeeded as request 6. Originals were restored after this recorded check. |

The candidate 1 gateway recorded three requests. Candidate 2's fresh catalog
recorded six; two explicit Stop operations produced client-closed events.
Gateway evidence stores content types, lengths and SHA-256 values rather than
raw captions, keys or image bytes. All success-path fixture images deliberately
share the known generated bytes: GUI evidence checks counts/shapes/routing;
distinct-content ordering and adjacent-only placeholders are covered by core
projection tests.

This is not an exhaustive native GUI matrix. Resolving Save/Cancel races, late
picker completion after window/controller replacement, eight-record recovery,
strict limit edges, special-file races and uncertain writes use deterministic
headless/fake-file tests. Cancellation with a populated draft and native IME,
VoiceOver, owning-window sheet behavior, clipboard/TIFF and drag/drop were not
claimed from this cloud run.

## Repeatable cloud environment recipe

1. Use the already extracted official `xdg-desktop-portal` and GTK backend in an
   isolated `dbus-run-session`, with private HOME/XDG config/data/cache paths.
2. Use private portal configuration with default `none` and FileChooser `gtk`;
   start permission-store, GTK backend and portal frontend. Probe the FileChooser
   version before launch; observed version was 4. Do not change the shared
   desktop's portal configuration.
3. Launch the immutable debug synthetic-authority binary with the explicit
   `--synthetic-connections --synthetic-attachment-fixture PROFILE` flags and
   generated project/session paths. The profile declares text+image input and
   `http://127.0.0.1:47883`; no custom headers or real credential is supplied.
4. Select the seeded saved connection and trust the generated project through
   normal UI. Seed does not select, trust, open a runtime or dispatch.
5. The separate QA-only gateway copy changes its streaming loop from 60 to 600
   half-second events so human-paced queue checks can explicitly Stop it. Its
   hash is in `artifact-manifest.json`; checked-in production fixture is unchanged.
6. Prefer full-desktop CUA move → fresh screenshot → separate click → fresh
   screenshot/inventory. The measured desktop was 1364×1024 and Agent client
   1180×812 at (92,120). Bound snapshots may show an obscured original window or
   a previous frame. Initial duration/+28px guesses were inconclusive, not a
   portable coordinate rule. A delayed Chromium foreground event was unattributed;
   queue acceptance was verified from durable metadata, not inferred from focus.
7. Never treat a whole-process synthetic-vault restart as restored authority.
   Candidate 2 correctly refused the lost project UUID; a separate fresh catalog
   with normal UI trust was used for later execution checks. Original drafts and
   history were left intact. Desktop was explicitly released after closing Agent,
   chooser, Inspector and fixture viewer windows at 12:44:31 UTC.

## Closed gates and remaining scope

Generated-fixture Apple CI must run the checked-in Swift selection/loadImages
oracle and the existing full native PiImage oracle on the published attachment
checkpoint. That CI is pending at this local checkpoint. A real macOS acceptance
run is still required for system picker filtering/sheet ownership, focus/IME,
accessibility and native normalization. Native credential/signing/release gates
remain closed. No owner images, real API keys, paid provider or owner Mac was used.
Full model catalog/input Settings, skills and clipboard/TIFF/drag-drop remain
separate scope. The stricter Rust 16,777,216-pixel predecode guard and image-only
Context empty-text difference are documented in the implementation guide.

A wording-only header in `attachments.rs` says “only delivery reads files.” The
actual implementation and this evidence inspect on selection and revalidate on
both acceptance and delivery. Correct that comment at the next skills/input
preparation checkpoint; candidate 2 compiled source stays immutable here.

The adjacent artifact manifest hashes the original screenshots and logs. The LOC
report/verifier records source volume only: 38,771 production, 52,812 tests/support,
1,189 benchmark/example lines, 92,772 total across 175 Rust files. This is not a
parity percentage or performance result.
