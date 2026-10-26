# PASTE-2: main-chat image paste — 0.1.131

Workstream `dev/a131-paste2`, based on `dev/next` `2d3825b9`.
Build and evidence root: `/Users/admin/Library/Caches/BelloSwiftWork/build-a131-paste2`.

The owner reports a flash on pasting images from several sources into a main
chat on released 0.1.130, no thumbnail or notice, and a message sent without
its image. This work follows `/Users/admin/Library/Caches/BelloSwiftWork/r131/rules.md`.

Generated images, private named pasteboards (the general getter is redirected
before production menu validation and `paste:`), isolated test host, scratch
stores, memory vaults and the synthetic loopback gateway only. No installed
app, real preferences, chat, Keychain, live capture or paid provider is used.
Focus and gallery runs acquire the shared full-lane lock. Text logs are the
evidence; no named result bundles.

## Reproduction and causes

All reproduction enters the main composer's actual `paste:` action through
the installed Edit menu or its Command-V key equivalent. It does not call
`pasteAttachments` directly. The test supplies private pasteboard flavors;
these represent source applications' data shapes, not captures of the owner's
clipboard or recordings of other applications.

- **Send could overtake delivery of the clipboard bytes.** The import counter
  began after `fileURLs`/`pastedImage` read the pasteboard, and after HTML
  classification could request image bytes. A lazy provider can re-enter the
  main app while supplying them. The generated provider presses the real
  composer's Send button from that callback: for PNG, TIFF, image-only HTML
  and Finder file URLs, the counter is **0**, Send captures the typed draft,
  and the helper command contains **0 images**. The image finishes importing
  into the next draft instead. This is a valid-image reproduction without any
  malformed data. The existing import tests held a second import open, or
  pressed Send only after `paste:` returned, so they covered background
  conversion but missed byte delivery.
- **An unavailable file-URL flavor discarded a valid image.** `imageFiles`
  could find no usable file URL, then `imageIsWhatWasCopied` refused the bitmap
  merely because `public.file-url` appeared in the type list. Paste fell
  through to `NSTextView`: no attachment, no refusal, and Send could send only
  the text. An empty file-URL representation can also make AppKit throw while
  trying to paste it; a malformed relative URL can append its string to the
  draft. A valid PNG accompanies both generated reproductions.
- **Unavailable imports returned silently.** The initial `isCurrent` guards
  in `pasteAttachments` and `attachImageFiles` returned without invoking the
  refusal destination. This happens if installation preparation has made the
  destination unavailable, including preparation starting during conversion.
- **An import waiting behind recovery could be dropped silently.** After
  recovery replaced the draft (for example with an earlier-message edit),
  `receiveAttachments` did nothing when its import token was no longer current.
  Refusing a different draft is correct; omitting the reason was not.
- **There was no thumbnail renderer.** The main composer made a `PiKit.Chip`
  with the static `photo` symbol and private filename. It never read or drew
  the attachment's pixels.

These failures reproduce on the `dev/next` base and the `v0.1.130` tag's
production sources, built as the isolated test host. The tag was extracted to
`/Users/admin/Library/Caches/BelloSwiftWork/src-a131-paste2-v130`; its helper is
built from the tag as well. Both builds reuse this workstream's one
`native-tests` DerivedData directory. Only the new tests and the image-capable
test oracle are overlaid on the tag; no production fix is overlaid.

The owner's exact clipboard formats and timing are unknown. Re-entrant Send
reproduces a text-only command for valid images, and the unavailable-URL case
reproduces an empty paste. Ordinary, non-re-entrant PNG/TIFF pastes do work on
0.1.130. The normal-source matrix also checks draft writes, refresh, generation
checks, storage and the image file's readability.

The matrix has ten source shapes: 400 × 300 PNG and TIFF screenshots/app
copies; detailed 5120 × 2880 PNG and TIFF screenshots over 8 MiB; PNG + TIFF
like a copied region screenshot; `public.jpeg`; text-first HTML containing an
image and its PNG; and Finder file URLs to PNG, JPEG and HEIC. Each runs in
new/cold, new/warm, saved/cold, saved/warm, during-run and after-run chats,
each with an empty composer and with "Keep this draft" already in it. Saved
history, runs and twelve image submissions use the packaged helper and the
strict loopback gateway. The re-entrant Send test uses a generated command
transport to inspect the actual `turn.submit` fields independently of the
provider's timing.

## Changes

The paste snapshots its attachment destination and begins its import before
any pasteboard data read, including file URLs and HTML classification. That
same import stays held through conversion and inspection. Classification
that returns to text paste finishes its reservation synchronously; Send still
requires a fresh press after an image import, and never submits automatically.

Only resolved file URLs take precedence over bitmap data. A real non-image
file URL still keeps its icon out of the message; text/document classification,
HTML budgets and promised-file transfer policy are unchanged. All import
refusals above use the existing persistent error strip and keep the draft.
Initial unavailability explains whether the app is preparing to close or the
draft is no longer available; a changed recovery destination says to attach
again.

`ComposerImageAttachmentChip` draws a bounded 96-pixel, upright ImageIO
thumbnail beside the existing name and remove action. Its slot is reserved
before background decoding, and the displayed name is capped and truncated in
the middle. The image itself is never decoded on the main thread. File paths,
stored attachment records, helper limits and wire fields are unchanged.

The existing loopback oracle rejected every `input_image` block with HTTP 400.
It now validates the app's existing inline-image request shape, MIME, base64,
role and detail. It accepts no remote image URLs. An image-only message resets
the synthetic fixture's latest prompt rather than reusing an older text
prompt. This is test support, not a production wire change.

## Failing first

- `next-causes-failing-first.log`: the unmodified dev/next production build
  reproduces the unavailable URL, unavailable import, recovery-wait refusal
  and missing thumbnail. The matrix in that early run reached the old
  oracle's HTTP 400; that matrix attempt is excluded from pass counts.
- `tag-failing-first.log`: all five cause regressions fail on the tag. The
  initial matrix reached 80 successful pastes before a fixture request omitted
  its required `clientTurnId`; that matrix attempt is excluded. The corrected
  matrix also treats an explicitly stopped run as paused and accepts image
  requests through the strict oracle above.
- `gateway-image-failing-first.log`: the oracle's new image case failed
  `400 != 200` before its fix.
- `gateway-image-only-mutation.log`: omitting image-only prompt reset fails
  the fixture's new regression.
- `gateway-images-final.log`: **27 Python tests, 0 failures**.

`tag-reproduction.log`: the corrected full class on 0.1.130 runs **6 tests**.
The matrix passes (**120 pastes**, ten sources, twelve chat/draft states and
twelve actual image submissions). The five cause regressions fail with
**11 failures**, including **one unexpected AppKit exception** when the old
text-paste fallback tries to use an empty file URL. That exception is part of
the reproduced bug, not an unrelated failure.

The final tag build adds the lazy-provider regression and the stricter
open/closed-helper assertions (`tag-final-failing-first.log`): **7 tests,
6 expected failing cause tests, 23 failures (1 unexpected: the same old
AppKit empty-URL exception)**. The normal-source test passes all **120 pastes
and twelve image submissions**, with the requested helper state asserted
before every paste. The provider test again prints
`importsAtRead=0 sends=1 sentImages=0` for **all four source types**.

`fixed-causes.log`: the patched app passes **6 tests, 0 failures**. Its matrix
also completes all 120 pastes and twelve submissions. The thumbnail regression
checks both its 96-pixel limit and rendered red/blue pixels from the generated
image, not just the presence of a view or decoded image property.

The final matrix fixtures also disable automatic context previews and assert
the helper's requested open/closed state before every paste, so counting the
draft cannot turn a cold-helper case into a warm one behind the test.

The later byte-delivery regression is in `provider-failing-first.log`:
**1 test, 12 failures, 0 unexpected** on the code with the other fixes and
before moving the reservation. All four real menu/key routes print
`importsAtRead=0 sends=1 sentImages=0`. With the reservation moved,
`provider-fixed.log` passes **1/1**: each provider sees `importsAtRead=1`, its
Send captures nothing, and a new Send after import carries the image.

## Mutations

Each native mutation was built, the selected test executed and failed, and the
source restored exactly before the next mutation. `mutation-summary.log`
records completion of the first **6/6**; `read-reservation-mutation-summary.log`
records the seventh. **7/7 native mutations were caught**; no build failure is
counted as detection.

| Mutation | Method in `ComposerPasteLifecycleTests` | Failures |
| --- | --- | --- |
| `url`: type metadata alone vetoes the bitmap | `testAnUnavailableFileURLDoesNotSilentlyDiscardTheImage` | 4 (1 unexpected: the old AppKit exception) |
| `admission`: omit the initial paste refusal | `testAnUnavailableImportShowsWhyAndKeepsTheDraft` | 2 |
| `inspection`: omit refusal when preparation made the destination unavailable | `testAnImportBecomingUnavailableDuringConversionShowsWhy` | 2 |
| `recovery`: omit the recovery-wait refusal | `testAnImportInvalidatedWhileRecoveryWaitsShowsWhy` | 2 |
| `thumbnail-load`: discard the decoded preview | `testPastedImageHasAThumbnail` | 2 (1 unexpected: the intentionally unmet readiness wait) |
| `thumbnail-draw`: decode but draw only the photo symbol | `testPastedImageHasAThumbnail` | 2 (both pixel assertions) |
| `read-reservation`: finish the reservation before reading a flavor | `testSendCannotOvertakeALazyPasteboardRead` | 12 (all four sources again send zero images) |

Both fixture mutations were caught too: omitting `input_image` admission
returns HTTP 400 (`gateway-image-mutation.log`, 1 test, 1 failure); omitting
image-only prompt reset reuses the preceding text (`gateway-image-only-mutation.log`,
1 test, 1 failure). The restored oracle passes **27/27** in
`gateway-images-final.log`.

Logs are `evidence/mutation-<name>.log`. The private runner calls:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a131-paste2
PASTE_XCODE_ARGS=(-project PiApp.xcodeproj -scheme PiApp \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PI_BUILD_ROOT/native-tests" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO)
xcodegen generate --quiet
xcodebuild build-for-testing "${PASTE_XCODE_ARGS[@]}"
# Under the shared full-lane lock, held only for the test run:
xcodebuild test-without-building "${PASTE_XCODE_ARGS[@]}" \
  -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ComposerPasteLifecycleTests/<method>
```

`python3 scripts/build-bundle.py` stages each version's Release helper before
its first app build. The runner waits while a shared lock owner contains
`perf` or `soak`; no heavyweight build or test starts in those windows.

## Final covering classes

The final production source (including the byte-delivery reservation) passes
**189 native tests: 187 passed, 2 existing skips, 0 failures**. Classes in the
parallel lane ran separately from serial-lane classes; both invocations use
`-parallel-testing-enabled NO`. Serial and gallery runs hold the shared lock.

| Class | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| ClipboardImageTests | 19 | 0 | 0 |
| ComposerAttachmentDestinationTests | 2 | 0 | 0 |
| ComposerImportSubmissionTests | 11 | 0 | 0 |
| ComposerSubmissionTests | 6 | 1 | 0 |
| ImageFormatImportTests | 12 | 1 | 0 |
| PastedAttachmentTests | 8 | 0 | 0 |
| PastedImageLeaseTests | 13 | 0 | 0 |
| QueuedAttachmentLimitTests | 2 | 0 | 0 |
| ComposerBarLayoutTests | 7 | 0 | 0 |
| ComposerPasteGalleryTests | 4 | 0 | 0 |
| ComposerPasteLifecycleTests | 7 | 0 | 0 |
| ComposerPasteRoutingTests | 6 | 0 | 0 |
| ConversationPaneTests | 85 | 0 | 0 |
| ShellComposerTests | 5 | 0 | 0 |

`focused-parallel-final.log`: **75 executed, 73 passed, 2 skipped**. The skips
are `ComposerSubmissionTests`' pre-existing absent Conversation-menu case and
`ImageFormatImportTests.testMeasureConvertedPhotos` (opt-in measurement).
`focused-serial-final.log`: **114/114 passed**. Exact selections, following the
common build/test commands above:

```sh
python3 "$PI_BUILD_ROOT/run-paste-check.py" focused-parallel-final \
  ClipboardImageTests ComposerAttachmentDestinationTests \
  ComposerImportSubmissionTests ComposerSubmissionTests PastedAttachmentTests \
  PastedImageLeaseTests ImageFormatImportTests QueuedAttachmentLimitTests
TEST_RUNNER_PI_APP_PASTE_GALLERY="$PI_BUILD_ROOT/gallery-fixed" \
  python3 "$PI_BUILD_ROOT/run-paste-check.py" focused-serial-final \
  ConversationPaneTests ShellComposerTests ComposerBarLayoutTests \
  ComposerPasteRoutingTests ComposerPasteGalleryTests ComposerPasteLifecycleTests
python3 -m unittest scripts.tests.test_ui_gateway
```

The first gallery attempt looked for its chip before the composer's queued
observer refreshed it (113 tests, one failure: `testPastedImageThumbnail`,
`XCTUnwrap` of `ComposerImageAttachmentChip`, then at line 27;
`focused-serial-runner.log` records that run's exit 65). The capture now waits
for the view as well as its pixels. The final four gallery cases pass.
Earlier fixture setup attempts (key-window readiness, the oracle's HTTP
400 and the missing turn ID above) are not counted as passing validation.

No helper/wire production source changed, so no full helper, native lane or
wire/concurrent/acceptance suite was run. The existing lease tests pass all
13 cases: no lease/sweep defect was found in this workstream. The same-edit
generation fix from EDIT-1 round 3 is kept; changing to a genuinely different
draft still refuses the image, now visibly even after recovery.

## Gallery

`gallery-fixed/` contains **12 regenerated PNGs, all visually inspected**, in
light and dark at 1240 points and narrow at 920 points:

- `pasted-image-{light,dark,narrow}.png`: a real menu/Command-V paste, a drawn
  thumbnail, readable truncated filename, remove control and the kept draft.
- `image-chip-{light,dark,narrow}.png`: converted HEIC and original PNG, both
  thumbnails with their original names and remove controls.
- `paste-refusal-{light,dark,narrow}.png` and
  `image-file-refusal-{light,dark,narrow}.png`: complete notices with Copy and
  Dismiss, usable composer and kept draft. The narrow footer still truncates
  its duplicate notice; the persistent top strip shows it in full.

Primary captures:
`/Users/admin/Library/Caches/BelloSwiftWork/build-a131-paste2/gallery-fixed/pasted-image-light.png`,
`pasted-image-dark.png`, `pasted-image-narrow.png` in that same directory.

No generated fixture or owner-source sample remains unresolved. The owner's
original clipboard/timing was not inspected; the record identifies the
reproduced mechanisms rather than claiming that every paste on 0.1.130 fails.
The temporary tag source is removed after validation; evidence and captures
remain under this workstream's build root.
