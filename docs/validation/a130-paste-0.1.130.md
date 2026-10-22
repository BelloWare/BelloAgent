# Clipboard images — 0.1.130

Workstream: `dev/a130-paste`, based on `3249aa24c32ae29c83da6537dddf23f1fd6a6594`.
Build/evidence root: `/Users/admin/Library/Caches/BelloSwiftWork/build-a130-paste`.

## Boundaries and fixtures

All image bytes are generated. Tests use private named pasteboards. The menu
tests replace `NSPasteboard.general`'s getter before invoking it, so both AppKit
validation and the production `paste:` action use the private fixture board.
The repository test host independently isolates shared pasteboards and its
preferences/home and disables Keychain access. No installed app, owner clipboard,
real chat, real credential, capture, paid provider, or release operation is used.
Window activation and gallery runs hold the shared full-lane lock. Evidence is
text logs; no named result bundles are requested.

The matrix represents pasteboard flavor combinations, not recordings of the
owner's applications. Browser formats are grounded in
[WebKit's macOS pasteboard writer](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/mac/PasteboardMac.mm),
[Chromium's macOS clipboard implementation](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/ui/base/clipboard/clipboard_mac.mm),
and [Firefox's macOS clipboard implementation](https://searchfox.org/firefox-main/source/widget/cocoa/nsClipboard.mm).
Flavor order is meaningful: [WebKit documents it as fidelity order](https://webkit.org/blog/10855/async-clipboard-api/).
Safari's current image writer need not include the image URL; URL presence alone
therefore cannot identify every copied image.

## Clipboard and composer matrix

| Generated case | Required behavior |
| --- | --- |
| Screenshot PNG, TIFF, PNG + TIFF | Attach an image without inserting text |
| Detailed 5120 × 2880 Retina PNG (32,434,456 bytes) | Normalize in the background instead of rejecting at 8 MiB |
| Preview/Photos-style TIFF, JPEG-only, HEIC-only | Read the advertised bytes, decode upright off the main thread, store PNG |
| GIF/BMP image representations | Decode to PNG |
| Browser image + URL + HTML + text; image + HTML without URL | Attach the image |
| Chat image first + alt text; office image-only HTML + text | Attach the image |
| Rich text + picture of the text; HTML document + image; text-first ambiguous data | Preserve text paste |
| Finder PNG/JPEG, HEIC/TIFF, multiple images, mixed image/non-image files | Attach image files; do not substitute a file icon |
| Finder non-image file + icon | Preserve ordinary file-name/text paste |
| File promise with no image bytes | Explain how to save/attach the file; do not initiate a promised-file transfer |
| Malformed image, unavailable storage or attachment destination | Visible refusal, original draft retained |
| Locked composer | No attachment mutation |
| Main, pending, side, earlier-message edit | Real Edit-menu ⌘V reaches that composer's attachment destination |
| Queued-message edit | Real ⌘V puts images in the parked draft; queued rewrite stays text-only |
| Sub-agent/child reader | No input composer; preserve its read-only footer |

## Helper parity

`AttachmentRecord.inspect` and helper `loadImages` admit up to 8 MiB per image,
four images and 16 MiB per submission. `PiImage` subsequently enforces a maximum
of 2,000 × 2,000 pixels and strictly less than 4,718,592 base64 bytes, trying PNG,
then JPEG qualities, then smaller dimensions. These helper/provider limits and
permissions are unchanged by this work.

Small accepted PNGs retain their original bytes. Other encodings become upright
PNGs through ImageIO. A PNG over 8 MiB, or a conversion that exceeds 8 MiB, is
thumbnailed to at most 2,000 pixels on its longest side and reduced by quarters
until its PNG is below the helper's strict base64 bound. This keeps transparency
and avoids introducing lossy JPEG storage. The generated Retina case becomes
1500 × 844, 2,357,188 bytes (3,142,920 base64 bytes). Ordinary accepted Finder
PNG/JPEG/GIF/WebP files retain their original paths and bytes; only unsupported
encodings or oversized image files need a private PNG.

## Root causes and decisions

1. **Most likely owner failure: native menu validation.** The plain-text
   `NSTextView` disables Edit → Paste for an image-only board. AppKit consumes
   the shortcut without calling the image-paste override. The real menu test
   failed in main, pending, side, earlier-message edit and queued-message edit:
   disabled Paste and zero attachments in all five. The override now admits
   image metadata while respecting `isEditable`. It never fetches image bytes
   during menu validation.
2. **Detailed screenshots exceeded the admission limit.** The released code
   rejected the generated 32.4 MB Retina PNG with “could not be read,” although
   the helper can resize images after its 8 MiB input gate. Background
   normalization now bridges that gate.
3. **A text flavor incorrectly displaced a copied image.** Image-first captions
   and image-only HTML without a URL were treated as text. Their image now wins.
4. **JPEG/HEIC could invoke automatic TIFF conversion on the main thread.**
   On this Mac, even `public.jpeg`/`public.heic`-only writes advertise an AppKit
   synthesized `public.tiff`. Thus the old implementation sometimes appeared to
   support these formats, but requested a synchronous TIFF conversion. The
   regression compares the bytes read against the encoded source; JPEG, HEIC,
   GIF and BMP all failed before preferring their source formats ahead of TIFF.
5. **Finder HEIC/TIFF copies were filtered out.** File URLs now recognize image
   UTTypes and normalize encodings that the helper cannot admit directly.
6. **Some refusals vanished or silently fell through.** Conversion errors now
   reach the existing persistent error strip as well as the session notice.
   Missing attachment destinations and promise-only data explain the refusal.
   Locked editors reject attachment mutations.

The affected paste implementation is identical in `v0.1.129` and the workstream
base. Every editable production composer already uses `ComposerInputView`'s
attachment destination; no pane-specific missing wiring was found. An unwired
`NativeComposer` now has an optional destination instead of a silent no-op.

The heuristic is intentionally conservative:

- Explicit file URLs take precedence over any accompanying icon.
- The existing explicit URL + image case remains an image copy.
- HTML containing an image and no visible document text identifies an image
  copy, including an Office copy with a rich representation and alt text.
  Inspection uses a fixed-budget, forward-only byte scanner, with no HTML
  rendering or resource fetching. It can only add confidence after the other
  signals fail; oversized, malformed or unsupported HTML cannot veto an image.
- Rich text plus real text remains a text copy unless image-only HTML adds
  confidence. HTML with document text contributes no image confidence.
- Without those formats, an image preceding plain text in fidelity order wins;
  plain text preceding an image remains text.

**Known choice, confirmed by the lead during review:** an ambiguous text-first
image + caption with neither URL nor conclusive image-only HTML still pastes
text. There is no reliable universal “copied an image” flag. Automatically
preferring every such image would regress the preserved document-rendering
rule.

Promise-only files are not received automatically. This uses the conservative
existing transfer boundary, with a new actionable notice. A promise accompanied
by actual image bytes can use those bytes. Promise metadata never overrides a
document's text or an explicit file URL. Native-format file inspection failures
remain refusals; they are not retried as conversion. Queued edits retain their
existing parked-draft behavior, and sub-agent readers retain their read-only
footer.

## Validation

All commands below run from the worktree root with:

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-paste
```

Logs are under `$PI_BUILD_ROOT/evidence/`. Each focused invocation uses the same
build directory. No helper or wire code changed, so the full helper,
wire/concurrent/acceptance suites were not run; the lead owns the merged gate.

### Failing first

- `failing-first-formats-confirmed.log`: the generated clipboard matrix against
  the released paste implementation, **10 tests, 17 assertion failures, zero
  unexpected failures**. Seven cases failed and three controls passed. Failures
  cover source-format selection, mixed text/HTML, large screenshots, Finder
  HEIC/TIFF, visible errors, missing destinations/promises and locked editors.
- `failing-first-menu.log`: **6 tests, 10 assertion failures, zero unexpected
  failures**. All five editable composer kinds had disabled Paste and zero
  attached images; the child-reader control passed. A consumed key equivalent
  alone was insufficient evidence: these tests assert menu admission and the
  resulting destination's attachments.
- `failing-first-promised-document.log`: **1 test, 4 failures** caught an initial
  implementation that let promise metadata swallow document/file-name text.
- `failing-first-file-refusal.log`: **1 test, 3 failures** caught an initial
  conversion fallback that retried an ordinary file-inspection refusal.

Commands were `scripts/test-macos.sh
-only-testing:PiAppTests/ClipboardImageTests` for the original ten-case matrix,
and `scripts/test-macos.sh -parallel-testing-enabled NO
-only-testing:PiAppTests/ComposerPasteRoutingTests` for the menu matrix. The two
self-review regressions used the corresponding single method selectors listed
in the mutation table below.

### Focused regression results

`app-regressions-complete.log`: **76 executed, 75 passed, 1 skipped, 0 failures**.

```sh
scripts/test-macos.sh \
  -only-testing:PiAppTests/ClipboardImageTests \
  -only-testing:PiAppTests/ComposerAttachmentDestinationTests \
  -only-testing:PiAppTests/ComposerImportSubmissionTests \
  -only-testing:PiAppTests/ComposerSubmissionTests \
  -only-testing:PiAppTests/PastedAttachmentTests \
  -only-testing:PiAppTests/QueuedAttachmentLimitTests \
  -only-testing:PiAppTests/CatalogImageInputTests \
  -only-testing:PiAppTests/DraftSizeTests \
  -only-testing:PiAppTests/DraftMarkTests \
  -only-testing:PiAppTests/RecoveredDraftTests \
  -only-testing:PiAppTests/QueuedEditPresentationTests
```

| Class | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| ClipboardImageTests | 15 | 0 | 0 |
| ComposerAttachmentDestinationTests | 2 | 0 | 0 |
| ComposerImportSubmissionTests | 11 | 0 | 0 |
| ComposerSubmissionTests | 6 | 1 | 0 |
| PastedAttachmentTests | 8 | 0 | 0 |
| QueuedAttachmentLimitTests | 2 | 0 | 0 |
| CatalogImageInputTests | 2 | 0 | 0 |
| DraftSizeTests | 2 | 0 | 0 |
| DraftMarkTests | 5 | 0 | 0 |
| RecoveredDraftTests | 13 | 0 | 0 |
| QueuedEditPresentationTests | 9 | 0 | 0 |

The existing submission-menu test skips because this host has no Conversation
menu; the new routing class installs the real app menus explicitly. An earlier
broader run (`app-regressions-pre-final.log`) exposed four failures in
`PastedAttachmentTests` after unnecessary PNG decoding was added to the
small-PNG path. That extra validation was removed, preserving existing byte
pass-through behavior; all eight durable-paste tests pass in the final run.

The following focused classes ran alone with parallel testing disabled, while
holding the shared full-lane lock. All passed with no skips.

```sh
for class in ComposerPasteRoutingTests ConversationPaneTests ShellComposerTests \
  ComposerBarLayoutTests QueueEditInteractionTests ConversationPaneRetentionTests
do
  scripts/test-macos.sh -parallel-testing-enabled NO \
    "-only-testing:PiAppTests/$class"
done
TEST_RUNNER_PI_APP_PASTE_GALLERY="$PI_BUILD_ROOT/gallery" \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ComposerPasteGalleryTests
```

| Class | Passed / executed | Text log |
| --- | ---: | --- |
| ComposerPasteRoutingTests | 6 / 6 | menu-final.log |
| ConversationPaneTests | 81 / 81 | conversation-pane.log |
| ShellComposerTests | 5 / 5 | shell-composer.log |
| ComposerBarLayoutTests | 7 / 7 | composer-layout.log |
| QueueEditInteractionTests | 17 / 17 | queue-edit.log |
| ConversationPaneRetentionTests | 6 / 6 | pane-retention.log |
| ComposerPasteGalleryTests | 1 / 1 | gallery.log |

Initial implementation (`a588d6d4`): **199 executed, 198 passed, 1 existing
skip, 0 failures**.
`ConversationPaneTests` includes the input, error-strip, queue and run
extensions. The gallery generated and was visually reviewed in light and dark
at 1240 × 600 points, and narrow at 920 × 600 points:

- `$PI_BUILD_ROOT/gallery/paste-refusal-light.png`
- `$PI_BUILD_ROOT/gallery/paste-refusal-dark.png`
- `$PI_BUILD_ROOT/gallery/paste-refusal-narrow.png`

The complete refusal wraps to two readable lines with Copy and Dismiss visible,
and the draft and composer controls remain usable. The existing one-line
footer truncates at narrow width; the persistent strip preserves the full
message. The shared lock was released after the final gallery run.

### Mutation checks

Each change below was applied temporarily, the named focused test was run and
failed, and the production source was restored. Commands use
`scripts/test-macos.sh -only-testing:PiAppTests/ClipboardImageTests/<method>`.
Logs use `mutation-<name>.log`.

| Mutation name / deliberately broken behavior | Method | Failures |
| --- | --- | ---: |
| formats: prefer old PNG/TIFF-only read | testScreenshotPreviewAndPhotosRepresentations | 4 |
| mixed: restore text-displaces-image heuristic | testImageCopiesWithURLHTMLAndTextKeepTheirImage | 4 |
| large: reject over-8-MiB PNG | testRetinaScreenshotOverEightMiBAttachesWithinHelperLimits | 2 |
| files: restore original file-extension filter | testFinderImageFilesIncludeHEICAndTIFF | 2 |
| notice: omit persistent error strip | testMalformedImageHasAVisiblePersistentRejection | 1 |
| destination: silently fall through without destination | testMissingAttachmentDestinationAndFailedPromisesAreVisible | 2 |
| promise: silently fall through for promise-only input | testMissingAttachmentDestinationAndFailedPromisesAreVisible | 2 |
| editable: remove editable guard | testReadOnlyComposerDoesNotAttach | 1 |
| default-destination: restore silent no-op callback | testDefaultComposerDoesNotSilentlyDiscardAnImage | 2 |
| promised-document: ignore image intent for promise metadata | testFilePromisesDoNotOverrideDocumentTextOrFinderFileURLs | 4 |
| file-refusal: convert after any inspection error | testNativeFileInspectionRefusalsAreNotRetriedAsConversion | 3 |
| menu: remove image-aware menu validation | ComposerPasteRoutingTests (whole class, serial command below) | 10 |

All twelve mutations were caught. The menu mutation uses
`scripts/test-macos.sh -parallel-testing-enabled NO
-only-testing:PiAppTests/ComposerPasteRoutingTests`; all five editable composers
again lose both menu admission and their image. Restoring the override passes
all six tests (`menu-final.log`). The silent no-op mutation's two
failures include one expected `eventually` timeout reported by XCTest as an
unexpected failure; the other mutations fail assertions directly.

### Adversarial self-review

- Rechecked the actual responder chain, source-flavor order, synthesized TIFF,
  missing destination, malformed bytes, storage failure and editability.
- Kept HTML inspection inert: no attributed HTML parser, remote image request,
  promised-file receiver or URL fetch. The initial review incorrectly treated
  a byte-capped regular expression as runtime-bounded; the follow-up below
  reproduces and corrects that mistake.
- Rechecked explicit file URLs against Finder icons, mixed files, document
  renderings and promises. Added failing regressions for promise/document
  interference and conversion retry after a file refusal.
- Kept native accepted file paths and bytes unchanged; conversions use the
  existing private PNG storage. Existing model-capability, count/byte caps,
  stale-edit import tokens, queued drafts and recovery tests pass.
- No additional out-of-scope bug was changed. The lead subsequently confirmed
  the conservative text-first caption choice above.

## HTML classifier review follow-up — 2026-10-20

Review of `a588d6d4` identified two real regressions: oversized HTML vetoed an
otherwise valid image copy, and Foundation's tag-stripping regex could revisit
an unmatched suffix quadratically on the main actor. No UI, helper, wire,
permission, capture, vault or storage boundary changes are needed.

This revision checked file/type metadata and obtained encoded image bytes
before considering HTML. Image-first copies without rich text, explicit image
URLs, and absence of meaningful text decide without reading HTML. A missing
image flavor or unavailable image bytes never triggers an HTML read. Deferred
private pasteboard providers verify the request order and omitted reads.
The subsequent review below corrects the eager image read introduced here.

HTML supplies positive evidence only. The scanner accepts a conservative set
of ordinary image/container tags, quoted attributes, comments and hidden
head/style/script content. It moves one cursor forward, uses constant-size
lookahead and tag names capped at 16 bytes, and has no regex, recursion,
backtracking or resource loading. The existing **256 KiB** HTML inspection
budget is retained. Data larger than that is inconclusive before decoding or
scanning. Plain-text inspection is also capped at 256 KiB and checks Unicode
scalars, avoiding unbounded grapheme work; over-budget text is not evidence of
an empty document. Pasteboard byte delivery itself remains an AppKit/provider
operation; these bounds cover the app's inspection work.

### Failing first

- `html-failing-first.log`: **2 tests, 7 assertion failures, 0 unexpected**.
  The exactly **307,200-byte** generated data-URL HTML discarded its valid PNG
  both with image-first flavor order and with whitespace-only plain text.
  Lazy-flavor assertions also proved HTML was requested without image bytes
  and before the encoded PNG.
- `html-timing-failing-first.log`: **1 test, 3 assertion failures,
  0 unexpected**. `<img>` followed by 16,000 `<` bytes took **11,137.621 ms**
  with text-first order and **11,081.698 ms** with image-first order; the latter
  also incorrectly rejected the image.

Exact commands, with `PI_BUILD_ROOT` exported as above:

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ClipboardImageTests/testLargeDataURLHTMLCannotVetoAnImageCopy \
  -only-testing:PiAppTests/ClipboardImageTests/testHTMLIsReadOnlyAfterImageBytesAndCheapSignals
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ClipboardHTMLPerformanceTests
```

The initial fixed matrix passed **18/18** (`html-fixed.log`), including all
previous cases. The timing regression passed **1/1** (`html-timing-fixed.log`):
**1.215 ms** text-first and **0.172 ms** image-first, both below the enforced
50 ms limit. The timing class runs alone with parallel testing disabled.

### Mutation checks and final regression run

Each mutant was built and exercised, then restored before the next change.
All **6/6** were caught; all failures were assertions, not build failures or
unexpected errors. Logs are `html-mutation-<name>.log`.

| Mutation | Test selector after `PiAppTests/` | Assertion failures |
| --- | --- | ---: |
| veto: restore oversized-HTML rejection before fallback | ClipboardImageTests/testLargeDataURLHTMLCannotVetoAnImageCopy | 2 |
| regex: restore Foundation tag stripping | ClipboardHTMLPerformanceTests | 1 |
| eager-read: request HTML before eligibility/image bytes | ClipboardImageTests/testHTMLIsReadOnlyAfterImageBytesAndCheapSignals | 5 |
| missing-bytes: allow HTML without available image bytes | ClipboardImageTests/testHTMLIsReadOnlyAfterImageBytesAndCheapSignals | 1 |
| unbounded: remove the HTML byte budget | ClipboardImageTests/testHTMLConfidenceIsConservativeAndNeverVetoesFlavorOrder | 1 |
| no-confidence: disable positive HTML evidence | ClipboardImageTests/testImageCopiesWithURLHTMLAndTextKeepTheirImage | 2 |

Each command was `scripts/test-macos.sh -parallel-testing-enabled NO
-only-testing:PiAppTests/<selector>`. The regex mutant again stalled for
**10,877.807 ms** on the text-first malformed fragment; the 50 ms assertion
caught it.

After restoring the complete fix, the exact focused-regression command above
was rerun with `-parallel-testing-enabled NO` (`html-regressions-final.log`):
**79 executed, 78 passed, 1 existing skip, 0 failures**. Per-class passes:
ClipboardImage **18**, ComposerAttachmentDestination **2**,
ComposerImportSubmission **11**, ComposerSubmission **6** (+ **1** existing
missing-menu skip), PastedAttachment **8**, QueuedAttachmentLimit **2**,
CatalogImageInput **2**, DraftSize **2**, DraftMark **5**, RecoveredDraft **13**,
QueuedEditPresentation **9**.

The separate final `ClipboardHTMLPerformanceTests` run passed **1/1**
(`html-timing-final.log`): **1.233 ms** text-first, **0.160 ms** image-first.
No helper or wire code changed, so their full suites were not rerun.

The shared focus lock was acquired for the remaining UI checks on the same
production source, now committed as **`8507e20a`**, and released after both:

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ComposerPasteRoutingTests
TEST_RUNNER_PI_APP_PASTE_GALLERY="$PI_BUILD_ROOT/gallery-html-review" \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ComposerPasteGalleryTests
```

- `html-menu-final.log`: **6/6 passed**. Actual Edit-menu ⌘V attaches in main,
  pending, side, earlier-edit and queued-edit composers; the child reader
  remains read-only.
- `html-gallery-final.log`: **1/1 passed**. Regenerated and visually reviewed
  `gallery-html-review/paste-refusal-{light,dark,narrow}.png`. All three retain
  the complete, readable refusal strip and usable composer controls.

Follow-up total: **87 executed, 86 passed, 1 existing skip, 0 failures**.
All **6** new mutations were caught. Both HTML review findings were resolved; ambiguous
text-first image captions retain the lead-approved conservative behavior.

### Adversarial self-review

- Verified every HTML outcome is reached only after ordinary image signals
  fail. Oversized, unexpected, visible-text and malformed HTML all preserve
  image-first fallback; text-first captions retain the lead's known choice.
- Exercised 12 HTML fixtures in both flavor orders: comments, apparent images
  inside quoted attributes/scripts, quoted angle brackets, metadata/hidden
  content, Unicode whitespace/entities, unfinished tags/comments/quotes,
  unknown tags, and over-budget attributes.
- Checked cursor progress and bounded lookahead on every scanner branch.
  Tag-name allocation is capped at 16 bytes; the UTF-8 whitespace probe reads
  at most four bytes. There is no repeated suffix search or whole-input
  normalization.
- Verified missing image types and missing image bytes never request HTML,
  encoded image bytes precede any optional HTML read, and image-first copies
  skip HTML entirely. HTML is never rendered or fetched as a remote resource.
- Reran the existing document/Finder/promise, JPEG/HEIC, large screenshot,
  malformed-image notice, destination, edit-boundary, storage and durable-draft
  matrix. No additional out-of-scope bug was changed.

## Promised image read ordering review — 2026-10-20

Review of `8507e20a` found that the HTML fix requested encoded image bytes
before rejecting an ordinary text copy. A document's promised image rendering
could therefore delay the main actor even though its bytes would be discarded.

The image-byte check is now lazy. Classification first uses types and fidelity
order, then bounded plain-text inspection. Clear text with neither URL nor HTML
returns to ordinary text paste without requesting an image provider. Only an
undecided HTML copy requests image bytes during classification; unavailable
image bytes skip HTML, and available bytes precede the bounded HTML scan.
Copies identified by cheap signals fetch image bytes after resolving their
attachment destination, without reading unused text or HTML. Bytes obtained
for HTML classification are retained for the background import.

No classifier decision, HTML budget, normalization limit, refusal wording,
composer destination, helper or wire behavior changed. **Known choice confirmed
by the lead:** ambiguous text-first image captions remain text when neither
URL nor conclusive image-only HTML adds confidence.

### Failing first and mutation

The new regression uses generated image data and private named pasteboards
with an `NSPasteboardItemDataProvider` that counts requests. Both ordinary and
rich-text cases advertise nonempty text first, a promised PNG, and no HTML or
URL. Metadata inspection must not request data; text classification must return
false with **zero image-provider calls**. Counting calls proves the avoided
work without deliberately sleeping inside the provider.

The existing deferred-HTML test now promises the text flavor as well, asserting
the complete read sequence: image-first copies request **PNG only**; undecided
text-first copies request **text → PNG → HTML**, and both attach.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-paste
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ClipboardImageTests/testClearTextDoesNotRequestPromisedImageRendering \
  -only-testing:PiAppTests/ClipboardImageTests/testHTMLIsReadOnlyAfterImageBytesAndCheapSignals
```

`ordering-failing-first.log`: **2 tests, 3 assertion failures, 0 unexpected**.
Both text variants requested the PNG; the undecided case read PNG before text.
After the fix, the full clipboard matrix passed **19/19**
(`ordering-fixed.log`).

The mutation initialized the cached image by eagerly calling `pastedImage`
before classification. Running the same two selectors caught it with **3
assertion failures, 0 unexpected** (`ordering-mutation-eager-image.log`).
The passing source was restored byte-for-byte before final validation:
**1/1 new mutation caught**, with no build failure involved.

### Final focused regression results

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ClipboardImageTests \
  -only-testing:PiAppTests/ComposerAttachmentDestinationTests \
  -only-testing:PiAppTests/ComposerImportSubmissionTests \
  -only-testing:PiAppTests/ComposerSubmissionTests \
  -only-testing:PiAppTests/PastedAttachmentTests \
  -only-testing:PiAppTests/QueuedAttachmentLimitTests \
  -only-testing:PiAppTests/CatalogImageInputTests \
  -only-testing:PiAppTests/DraftSizeTests \
  -only-testing:PiAppTests/DraftMarkTests \
  -only-testing:PiAppTests/RecoveredDraftTests \
  -only-testing:PiAppTests/QueuedEditPresentationTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ClipboardHTMLPerformanceTests
```

`ordering-regressions-final.log`: **80 executed, 79 passed, 1 existing skip,
0 failures**. Per-class passes: ClipboardImage **19**,
ComposerAttachmentDestination **2**, ComposerImportSubmission **11**,
ComposerSubmission **6** (+ **1** existing missing-Conversation-menu skip),
PastedAttachment **8**, QueuedAttachmentLimit **2**, CatalogImageInput **2**,
DraftSize **2**, DraftMark **5**, RecoveredDraft **13**,
QueuedEditPresentation **9**.

`ordering-timing-final.log`: **1/1 passed**. The malformed fragment with
16,000 `<` characters took **1.336 ms** text-first and **0.180 ms** image-first,
both below the enforced 50 ms limit. No helper or wire code changed, so their
full suites were not rerun.

After acquiring the shared full-lane lock, these classes ran separately; the
lock was released after both completed:

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ComposerPasteRoutingTests
TEST_RUNNER_PI_APP_PASTE_GALLERY="$PI_BUILD_ROOT/gallery-ordering-review" \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ComposerPasteGalleryTests
```

- `ordering-menu-final.log`: **6/6 passed**. Actual Edit-menu ⌘V attaches in
  main, pending, side, earlier-edit and queued-edit composers; the child reader
  remains read-only.
- `ordering-gallery-final.log`: **1/1 passed**. Regenerated and visually
  reviewed `gallery-ordering-review/paste-refusal-{light,dark,narrow}.png`;
  the complete refusal strip is readable and composer controls remain usable.

Round-3 final total: **88 executed, 87 passed, 1 existing skip, 0 failures**.
No clone folders were left under this workstream's build root.

### Adversarial self-review

- Traced every flavor read: read-only editors, absent image types, explicit
  non-image file URLs and clear text do not request image bytes. Image-only
  signals omit unused text/HTML; undecided HTML reads bytes only after text.
- Verified the optional byte callback is nonescaping, invoked only once at
  the HTML decision, and cached for import. There is no repeated text scan or
  repeated provider request to obtain the same image.
- Checked the missing-data branch still skips HTML, and direct image copies
  still reach their visible refusal if the bytes are unreadable. Unavailable
  destinations can refuse an already-identified image without generating it.
- Compared the decision branches with the prior source: document renderings,
  Finder icons, file promises, oversized/malformed HTML, explicit URLs and the
  lead-approved text-first caption choice preserve their existing outcomes.
- The HTML scanner and normalization code are unchanged. No additional
  out-of-scope bug or owner decision was identified.

## Cross-instance pasted-image ownership — 2026-10-20

Assignment: **CONCURRENCY-LIFECYCLE-3 / PERSISTENCE-COMPAT-2**, based on merged
`dev/next` **`688f8751`**, continuing on `dev/a130-paste`.

### Cause and ownership

Every storage instance had a different generation UUID. The sweep excluded
only its own generation and checked only its own in-memory references and work.
A second instance therefore treated a live first instance's unsent paste as an
orphan. Pending New Chat drafts are deliberately absent from the database;
failure to acquire the separate capture archive writer lock does not prevent
the pasted-image sweep. Neither existing boundary establishes paste ownership.

`PastedImageStorage` now owns a shared reference to a generation lease. Before
publishing its first image it acquires an exclusive, nonblocking `flock` through
the existing `WorkspaceLock`, at `PastedImages/pasted-<generation>.lock`.
The descriptor is close-on-exec and the path is opened without following a
symlink. Copies passed to background conversion/import share that ownership
with the model. A small mutex serializes first acquisition; the lease remains
held until the last storage owner releases it. Process death releases the
kernel lock without needing application cleanup.

The sweeper groups candidate images by generation and tries each generation's
lock without waiting **before reading the reference inventory**. A busy or
unverifiable lease leaves the generation untouched. The existing inventory
still retains all database/journal/local-display references. Claims remain
held through every suspension and deletion, including early-return/error paths.
Competing sweepers tolerate files already collected. Empty lease sidecars stay
in place so all contenders use the same inode; they contain no image/user data.

The filenames, image bytes, attachment limits, pending/side-draft ephemerality,
restoration timing and persistent-reference policy are unchanged. Legacy
orphan generations without a sidecar remain collectable under the existing
reference inventory. Older application versions cannot advertise these new
leases; the live-generation guarantee applies to cooperating builds.

### Failing-first evidence

All new tests use generated PNG bytes, isolated state roots and memory vaults.
They never launch the installed app, use the real clipboard, or access actual
chats/preferences/Keychain. A generated Python child holds/probes real kernel
locks against the same fixture root; this is a process-boundary test, not a
mock lock or a claim to have run a second production app.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-paste
xcodegen generate --quiet
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/PastedImageLeaseTests
```

`lease-failing-first.log`: **5 tests, 6 assertion failures, 0 unexpected**.

| Regression | Before fix |
| --- | --- |
| Actual second-model restore/startup with a first model's pending, unpersisted draft | Image deleted while its attachment record remained |
| Real child holds the generation lock; sweep runs, then child is SIGKILLed and a new model sweeps | Live image deleted; legacy orphan control collected |
| Storage copied, original released, child probes; last copy then released | Child incorrectly acquired the live generation's lock |
| Generation lock cannot be created | Image published without protection (two failed assertions) |
| Generation lock is an unverifiable symlink | Image deleted instead of retaining it; generated sentinel remained intact |

After the fix, `lease-fixed.log` passed **13/13**: **5** lease tests and the
**8** existing `PastedAttachmentTests`. The latter now create old-generation
fixtures in a function whose storage owner has ended; tests claiming an
abandoned launch must not accidentally hold a live lease. Their persisted,
historical, queued, missing-journal and in-flight reference assertions remain.

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/PastedImageLeaseTests \
  -only-testing:PiAppTests/PastedAttachmentTests
```

### Initial mutations and adversarial review (`40cdb7ba`)

Both mutations were built and executed, then restored:

| Mutation | Selectors after `PiAppTests/PastedImageLeaseTests/` | Result |
| --- | --- | --- |
| Omit writer lease acquisition before image publication | `testSecondModelStartupKeepsAnUnpersistedPendingDraftImage`, `testStorageCopiesHoldOneLeaseUntilTheLastOwnerIsReleased`, `testLeaseFailureCannotPublishAnUnprotectedImage` | 3 tests, 4 assertion failures, 0 unexpected |
| Bypass the sweeper's generation lock | `testChildLeaseProtectsLiveImagesAndCrashMakesThemCollectable`, `testSecondModelStartupKeepsAnUnpersistedPendingDraftImage`, `testCleanupLeavesImagesWhenTheLeaseCannotBeVerified` | 3 tests, 3 assertion failures, 0 unexpected |

Commands use `scripts/test-macos.sh -parallel-testing-enabled NO` with one
`-only-testing:` argument per selector. Logs are `lease-mutation-writer.log`
and `lease-mutation-sweeper.log`: **2/2 mutations caught at runtime**. An
initial sweeper mutant had an unused-variable build error; that invalid attempt
is retained as `lease-mutation-sweeper-invalid-build.log`, excluded from the
mutation count, and was corrected before the runtime check.

- Publication cannot precede acquisition. Failure creates no unprotected PNG.
  The storage copy test probes the actual flock from another process, then
  proves it becomes available after the final storage reference ends.
- The initial collector held its claim from the final local reference check
  through unlink. Further review below moved acquisition before inventory
  reads to close a producer-commit/exit race.
- The child remains alive after the sweep, proving cleanup does not wait for
  its lease. SIGKILL exercises kernel release without application teardown.
- No cleaner removes a lease sidecar, avoiding replacement-lock inode races.
  A symlink/unavailable sidecar retains the candidate, and a failed inventory
  retains everything as before. Current generations and all durable-reference
  protections remain in force.

### Related-cleanup audit

| Path | Ownership / outcome |
| --- | --- |
| `NativeComposer.writePastedImage` and `preparePastedFiles` | Clipboard decoding, large screenshots and Finder-format conversion all publish through this same storage lease; no separate conversion-generation sweep |
| `HostService.swift:1028` recovery staging | Unique `.recover-<UUID>` path; only that operation's defer removes it |
| `SessionPersistence.swift:79,230,464` fork/side staging | Unique temporary paths with journal ownership; failed operations remove their own paths |
| `SessionJournal.swift:424` fork leftovers | Already acquires a nonblocking writer lock and checks file/lock identity before deleting abandoned staging |
| `JournalCheckpoint.swift:100` checkpoint temporaries | Called under the corresponding journal's writer lock (`SessionJournal.swift:76`) |
| `PayloadArchive.swift:94,800` retained capture garbage | Archive writer lock is acquired before database opening/reconciliation; failed ownership does not enter this sweep |
| `TraceArchive.swift:121` partial exports | Production exporter root is unique per model (`WorkspaceModel.swift:561`); reconciliation scans that root, not another model's or an explicit export destination |
| `HistoryIndexFiles.swift:17` temporary indexes | Already excludes live owner PIDs and open inodes; no pasted-generation assumption |
| `HistoryReader.swift:481,497` temporary byte storage | Removes only its own file, including unlinking its own open temporary file |
| `WorkspaceConnectionProbe.swift:81` probe directories | Unique probe session directory removed only after its own helper has stopped |

Separate helper migration finding for routing: `JournalSlimming.swift:155–161`
uses only a one-hour modification-age cutoff when deleting `.slim-` and
`.pre-slim-` files. A helper suspended beyond that cutoff can still own/use
those files; the sweep does not check its lock. The `.pre-slim-` hard link also
inherits its source journal's old modification time, so that staging path can
qualify immediately. This is separate journal-migration staging, outside the
pasted-generation fix, and remains unchanged pending coordination with the
helper workstream. No other shared per-launch image/import-generation sweep
was found.

### Initial focused validation (`40cdb7ba`)

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/PastedImageLeaseTests \
  -only-testing:PiAppTests/ClipboardImageTests \
  -only-testing:PiAppTests/ComposerAttachmentDestinationTests \
  -only-testing:PiAppTests/ComposerImportSubmissionTests \
  -only-testing:PiAppTests/ComposerSubmissionTests \
  -only-testing:PiAppTests/PastedAttachmentTests \
  -only-testing:PiAppTests/QueuedAttachmentLimitTests \
  -only-testing:PiAppTests/CatalogImageInputTests \
  -only-testing:PiAppTests/DraftSizeTests \
  -only-testing:PiAppTests/DraftMarkTests \
  -only-testing:PiAppTests/RecoveredDraftTests \
  -only-testing:PiAppTests/QueuedEditPresentationTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ClipboardHTMLPerformanceTests
```

`lease-regressions-final.log`: **85 executed, 84 passed, 1 existing skip,
0 failures**. Per-class passes: PastedImageLease **5**, ClipboardImage **19**,
ComposerAttachmentDestination **2**, ComposerImportSubmission **11**,
ComposerSubmission **6** (+ **1** existing missing-Conversation-menu skip),
PastedAttachment **8**, QueuedAttachmentLimit **2**, CatalogImageInput **2**,
DraftSize **2**, DraftMark **5**, RecoveredDraft **13**,
QueuedEditPresentation **9**.

`lease-timing-final.log`: **1/1 passed**. The malformed HTML case took
**1.357 ms** text-first and **0.397 ms** image-first, below the 50 ms limit.
No helper or wire source changed, so their full suites were not rerun.

The menu/gallery waiter was stopped before acquiring the shared focus lock
to finish the inventory-claim correction below. These counts cover the initial
implementation; no unrun UI checks are counted.

### Claim ownership before reading references

Further adversarial review found that acquiring a generation only immediately
before unlink leaves an ordering gap: a producer can persist a reference and
exit after the final inventory check but before the collector acquires its now
available lease. The final implementation claims abandoned generations before
inventory reads and retains those claims through cleanup using an explicit
`defer`/`withExtendedLifetime`. A live producer at candidate discovery is skipped
for the whole sweep, even if it subsequently exits; an already-abandoned
generation's committed references are read after ownership has been claimed.

`testSweepClaimsAbandonedGenerationsBeforeReadingReferences` pauses an actual
journal scan and starts a child process probing that generation's lock. This
checks the ownership ordering directly, rather than relying on a probabilistic
database-commit race.

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/PastedImageLeaseTests/testSweepClaimsAbandonedGenerationsBeforeReadingReferences
```

- `lease-inventory-failing-first.log`: **1 test, 1 assertion failure,
  0 unexpected** against `40cdb7ba`: the child acquired the supposedly claimed
  generation during the reference scan.
- `lease-inventory-fixed.log`: **14/14 passed**, using the two-class command
  above: **6** lease tests and **8** existing pasted-attachment tests.
- Repeated mutations against this final implementation:

| Mutation | Selectors after `PiAppTests/PastedImageLeaseTests/` | Result |
| --- | --- | --- |
| Omit producer lease acquisition | Same three writer selectors above | 3 tests, 4 assertion failures |
| Claim an unrelated lock instead of the generation's lock | Same three sweeper selectors above, plus `testSweepClaimsAbandonedGenerationsBeforeReadingReferences` | 4 tests, 4 assertion failures |
| Release candidate claims before returning them to the inventory reader | `testSweepClaimsAbandonedGenerationsBeforeReadingReferences` | 1 test, 1 assertion failure |

Logs: `lease-final-mutation-{writer,sweeper,early-release}.log`.
**3/3 final mutations caught at runtime; 0 unexpected errors.** All were
restored before final regression testing.

The full focused command above was rerun on the revised source:
`lease-inventory-regressions-final.log` — **86 executed, 85 passed, 1 existing
skip, 0 failures**. The per-class counts above are unchanged except
PastedImageLease now passes **6** tests.

`lease-inventory-timing-final.log` — **1/1 passed**; malformed HTML took
**1.243 ms** text-first and **0.187 ms** image-first.

The audit also found a storage-write call in `PendingChatProjectTests`, so
that full class was rerun to cover pending-chat project switches with
attachments. Each focus-dependent class below ran alone, under the shared
full-lane lock, using only this workstream's build root:

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/PendingChatProjectTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ComposerPasteRoutingTests
TEST_RUNNER_PI_APP_PASTE_GALLERY="$PI_BUILD_ROOT/gallery-lease-inventory-review" \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ComposerPasteGalleryTests
```

| Final run | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Focused paste/attachment/draft classes (`lease-inventory-regressions-final.log`) | 85 | 1 existing | 0 |
| HTML timing (`lease-inventory-timing-final.log`) | 1 | 0 | 0 |
| Pending-chat projects (`lease-pending-project-final.log`) | 24 | 0 | 0 |
| Real Edit-menu paste routing (`lease-inventory-menu-final.log`) | 6 | 0 | 0 |
| Refusal gallery (`lease-inventory-gallery-final.log`) | 1 | 0 | 0 |
| **Total** | **117** | **1** | **0** |

The routing run covers main, pending, side, earlier-message and queued-edit
composers, plus the read-only child reader. Regenerated and inspected
`gallery-lease-inventory-review/paste-refusal-{light,dark,narrow}.png`: the full
notice wraps visibly, Copy/Dismiss and composer controls remain usable, and
the draft stays intact. The narrow footer truncates its duplicate notice while
the complete top notice remains visible, as before.

All final runs used the source committed as `ff421bf1`; subsequent changes are
validation documentation only. Both focus-lock holders released their own
lock. No clone folders or workstream test lock remain in this build root.
No helper or wire code changed, so their full suites were not rerun. The
separate journal-migration staging finding above remains for lead routing.

## Round 5 — bounded sweep leases and sidecar retirement

Review of `c6723fa7` found that the collector retained one descriptor for every
old generation, including generations whose images all remained in saved
journals. The live-owner fix therefore allowed ordinary retained history to
consume the process's file-descriptor budget. Empty sidecars also remained
indefinitely after their images were collected.

The collector now lists generations without retaining lock descriptors, then
reads references once to exclude wholly retained generations. That pre-pass
can only skip cleanup; its result never authorizes deletion. The collector
claims at most **32** remaining generations without waiting, obtains a **fresh**
metadata/journal inventory while holding those claims, and retains the claims
through the existing revision/activity/local-draft checks and deletion.
Excess candidates wait for later startup sweeps. This deliberately caps a
launch at **two journal scans**, rather than repeating a full scan for every
32-generation batch. Retained-only generations do not consume the batch,
so ordinary saved history cannot repeatedly crowd garbage out of cleanup.

After deletion, a fresh directory listing determines whether any generation
files remain, including unrecognized files. An empty abandoned generation's
sidecar is unlinked while its lease is still held. Empty live generations
keep their sidecars; sidecars with retained images remain too. Sidecars left
without any PNG by a failed write or earlier cleanup are also discoverable.
This supersedes round 4's decision to keep every sidecar indefinitely.

Retiring a sidecar creates an inode race if an opener pauses between `open`
and `flock`: it could later acquire the old, unlinked inode. Producers and
collectors therefore compare the held descriptor's device/inode with the
named file after acquisition; deletion checks that identity again. A writer
whose existing sidecar was replaced cannot publish another unprotected image.
`WorkspaceLock.matchesFile` adds that check without changing its constructor's
behavior for other callers.

Pending/side drafts remain ephemeral. Reference retention, image limits,
permission/capture/vault boundaries and composer behavior are unchanged.
No helper or wire source changed. The separate helper migration finding from
round 4 remains recorded for the lead; no additional workstream was changed.

### Failing-first evidence and measurements

All fixtures are generated, with isolated roots, memory vaults and the existing
child-process flock probe. The descriptor test inspects `/dev/fd` with
`F_GETPATH` and counts only canonical paths to this fixture's `.lock` files
while the real journal scan is running and every candidate claim is held.
It does not mock lock counts or lower the Xcode test process's global limit.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-paste
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/PastedImageLeaseTests/testRetainedGenerationsDoNotConsumeSweepDescriptors \
  -only-testing:PiAppTests/PastedImageLeaseTests/testGarbageGenerationsAreClaimedInBoundedBatches \
  -only-testing:PiAppTests/PastedImageLeaseTests/testChildLeaseProtectsLiveImagesAndCrashMakesThemCollectable \
  -only-testing:PiAppTests/PastedImageLeaseTests/testEmptyLiveGenerationKeepsSidecarUntilOwnerEnds \
  -only-testing:PiAppTests/PastedImageLeaseTests/testWriterRejectsReplacedGenerationSidecar
```

`r5-lease-baseline-final.log`: the final regression tests against the original
`c6723fa7` production files produced **5 tests, 9 assertion failures,
0 unexpected**:

- **96 retained generations + 3 garbage generations:** **99** simultaneous
  sweep descriptors, exceeding both the 32 cap and the 3 useful candidates.
- **70 garbage generations:** **70** descriptors; all generations collected
  at once instead of deferring excess work.
- A real child held its live sidecar correctly, but the sidecar remained
  after SIGKILL and collection of the crashed generation's final image.
- A generation with no image still left its sidecar after its owner ended.
- Replacing a writer's sidecar allowed it to publish a second image under
  the unlinked descriptor.

The first probe (`r5-lease-failing-first.log`) omitted canonicalization of
descriptor paths and measured zero, which its own nonzero assertion caught.
That instrumentation attempt is excluded from descriptor evidence. The
corrected probe first reproduced **99 / 70** descriptors in
`r5-lease-failing-first-measured.log`, then the final baseline run above
repeated those measurements with all final assertions.

`r5-lease-fixed.log` passed **18/18** lease/attachment tests. After adding
the producer-commit race and unknown-file retention checks,
`r5-lease-race-fixed.log` passed **36/36**: PastedImageLease **11**,
PastedAttachment **8**, Workspace **17**.

Fixed measurements: **3** peak descriptors and **2** scans for 96 retained +
3 garbage generations; **32** peak descriptors and **6** scans over three
sweeps for 70 garbage generations (32, then 32, then 6 collected).

### Mutation checks and adversarial review

Each command uses `scripts/test-macos.sh -parallel-testing-enabled NO` and
`-only-testing:PiAppTests/PastedImageLeaseTests/<selector>` for the selectors
below. All mutations were restored before final regression runs.

| Mutation | Test selector(s) | Runtime result |
| --- | --- | --- |
| Raise the cap to 1024 | `testGarbageGenerationsAreClaimedInBoundedBatches` | 1 test, 3 assertion failures; peak 70 |
| Remove the retained-generation filter | `testRetainedGenerationsDoNotConsumeSweepDescriptors` | 1 test, 2 assertion failures; peak 32, garbage left behind |
| Reuse pre-pass names for deletion instead of scanning after claiming | `testProducerCommitAndExitAfterPrepassSurvivesClaimedRescan` | 1 test, 2 assertion failures; committed image and sidecar deleted |
| Omit sidecar unlink | `testChildLeaseProtectsLiveImagesAndCrashMakesThemCollectable`, `testEmptyLiveGenerationKeepsSidecarUntilOwnerEnds` | 2 tests, 2 assertion failures |
| Omit the writer's inode check | `testWriterRejectsReplacedGenerationSidecar` | 1 test, 2 assertion failures |

Logs: `r5-mutation-{bound,filter,inventory,sidecar,inode}.log`.
**5/5 mutations caught at runtime; 0 unexpected errors.**

The authoritative-inventory test still probes the held claim from a child
process; its pause now skips the non-authoritative pre-pass. The new producer
test pauses after that pre-pass has read an empty journal, persists the image
reference, releases the producer lease, then lets the collector continue.
Only the post-claim inventory can preserve that reference, as the mutation
demonstrates.

Busy or unverifiable leases remain nonblocking and fail closed. A failed
reference scan still retains files. Empty-sidecar collection requires a held,
current lease and checks all names, so an unrecognized generation file prevents
retirement. The generation UUID is not reused, and stale openers must validate
the named inode before they can act. Storage copies still share the producer
lease and process death still releases it.

### Final focused validation

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/PastedImageLeaseTests \
  -only-testing:PiAppTests/ClipboardImageTests \
  -only-testing:PiAppTests/ComposerAttachmentDestinationTests \
  -only-testing:PiAppTests/ComposerImportSubmissionTests \
  -only-testing:PiAppTests/ComposerSubmissionTests \
  -only-testing:PiAppTests/PastedAttachmentTests \
  -only-testing:PiAppTests/QueuedAttachmentLimitTests \
  -only-testing:PiAppTests/CatalogImageInputTests \
  -only-testing:PiAppTests/DraftSizeTests \
  -only-testing:PiAppTests/DraftMarkTests \
  -only-testing:PiAppTests/RecoveredDraftTests \
  -only-testing:PiAppTests/QueuedEditPresentationTests \
  -only-testing:PiAppTests/WorkspaceTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ClipboardHTMLPerformanceTests
```

`r5-regressions-final.log`: **108 executed, 107 passed, 1 existing skip,
0 failures**. Per-class passes: PastedImageLease **11**, ClipboardImage **19**,
ComposerAttachmentDestination **2**, ComposerImportSubmission **11**,
ComposerSubmission **6** (+ **1** existing missing-Conversation-menu skip),
PastedAttachment **8**, QueuedAttachmentLimit **2**, CatalogImageInput **2**,
DraftSize **2**, DraftMark **5**, RecoveredDraft **13**,
QueuedEditPresentation **9**, Workspace **17**. The final run repeats the
measured descriptor peaks (**3 / 32**) and scan counts (**2 / 6**).

`r5-timing-final.log`: **1/1 passed**; the malformed HTML case took **1.177 ms**
text-first and **0.149 ms** image-first.

The remaining classes each ran alone under the shared full-lane lock:

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/PendingChatProjectTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ComposerPasteRoutingTests
TEST_RUNNER_PI_APP_PASTE_GALLERY="$PI_BUILD_ROOT/gallery-r5-paste" \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ComposerPasteGalleryTests
```

| Final run | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Paste/attachment/draft/workspace classes (`r5-regressions-final.log`) | 107 | 1 existing | 0 |
| HTML timing (`r5-timing-final.log`) | 1 | 0 | 0 |
| Pending-chat projects (`r5-pending-project-final.log`) | 24 | 0 | 0 |
| Real Edit-menu paste routing (`r5-menu-final.log`) | 6 | 0 | 0 |
| Refusal gallery (`r5-gallery-final.log`) | 1 | 0 | 0 |
| **Total** | **139** | **1** | **0** |

Regenerated and inspected `gallery-r5-paste/paste-refusal-{light,dark,narrow}.png`.
The complete notice and Copy/Dismiss remain visible, the composer controls
remain usable, and the draft is preserved. The narrow footer still truncates
its duplicate notice while the full top notice wraps.

All final runs used the code committed as `43b4b54b`; the completion update
changes documentation only. The runner released its own shared lock. No clone
folders or workstream test lock remain. No helper or wire code changed, so
their full suites were not rerun. Neither round-5 issue remains unresolved.

## Round 6 — sweep selection progress

Review of `f32b6762` found that lexicographically early sidecars with only
unrecognized generation-prefixed files could consume all 32 claims every
launch. Those files correctly prevented sidecar retirement, but the same
unproductive batch then permanently blocked later orphan PNGs.

The existing directory pass now records occupied generation prefixes before
filtering by recognized image or regular-file type. A sidecar without
collectable images is eligible only when no generation-prefixed name remains;
unknown files, directories and symlinks all prevent eligibility. Generations
with images come first, followed by genuinely empty sidecars using only spare
capacity. The reference pre-pass still excludes wholly retained generations.
This fixes the reported orphan on the **first sweep**, without deleting or
following unrecognized files.

Selection remains advisory: acquisition is nonblocking, at most **32** claims
are held, and the authoritative metadata/journal inventory is still obtained
after acquisition and before deletion. No inventory/deletion or lifetime-lock
code changed. If directory contents change after selection, the existing fresh
listing before sidecar unlink preserves a newly added unknown file's sidecar;
the next selection excludes that group. If an unknown file disappears after
listing, retirement simply waits for the next sweep. Both cases defer work
without authorizing deletion from stale inventory. The inode checks, live and
crashed owner behavior, and two-journal-scan limit remain intact.

### Failing-first evidence

Only generated fixture roots, PNG bytes, sidecars, unknown files, a directory,
a symlink and memory vaults were used. The existing real descriptor probe
measures fixture leases during journal reads; no process descriptor limit was
changed. Text logs below are under
`/Users/admin/Library/Caches/BelloSwiftWork/build-a130-paste/evidence`.

```sh
export PI_BUILD_ROOT=/Users/admin/Library/Caches/BelloSwiftWork/build-a130-paste
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/PastedImageLeaseTests/testNonRetirableSidecarsCannotStarveOrphanImages \
  -only-testing:PiAppTests/PastedImageLeaseTests/testOrphanImagesTakePriorityOverRetirableSidecars
```

Against unchanged round-5 production code, `r6-failing-first.log` reports
**2 tests, 6 assertion failures, 0 unexpected errors**:

- **35 non-retirable sidecar groups** sort before an orphan PNG: 33 hold
  unknown regular files, one a directory, and one a symlink. The first sweep
  leaves the orphan behind. The fixed test also requires exactly one useful
  lease, so an implementation that merely sorts images first cannot hide
  wasted claims on the blocked sidecars.
- **33 genuinely empty sidecars** sort before an orphan PNG: the first sweep
  spends all 32 claims on sidecars and leaves the image behind. An extra
  sweep needs another journal read.

The baseline probe sees no post-claim journal read when the selected batch
contains no image candidates; its zero measurement is not a claim that the
old batch held no descriptors.

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/PastedImageLeaseTests \
  -only-testing:PiAppTests/PastedAttachmentTests
```

`r6-lease-fixed.log`: **21/21 passed** (13 lease, 8 attachment). The blocked
fixture collects its orphan in one sweep with **1** peak lease and **2**
journal reads, preserving every unknown file, directory, symlink and sidecar.
The empty-sidecar fixture collects its orphan plus 31 sidecars in one sweep,
then the last two sidecars without another journal read: **32** peak leases,
**2** reads total. Existing retained/garbage fixtures repeat **3 / 32** peak
leases and **2 / 6** reads.

### Mutation checks and adversarial self-review

Each mutation ran with `scripts/test-macos.sh -parallel-testing-enabled NO`
and the single `-only-testing:PiAppTests/PastedImageLeaseTests/<selector>`
below, then the source was restored.

| Mutation | Test selector | Runtime result |
| --- | --- | --- |
| Return all groups, omitting the occupied-prefix filter | `testNonRetirableSidecarsCannotStarveOrphanImages` | 1 test, 1 assertion failure; peak 32 instead of 1 |
| Sort only by generation name, omitting image priority | `testOrphanImagesTakePriorityOverRetirableSidecars` | 1 test, 4 assertion failures; orphan remains after first sweep |

Logs: `r6-mutation-{eligibility,priority}.log`. **2/2 mutations caught at
runtime, 0 unexpected errors.** Neither result relies on a build failure.

Adversarial review checked that occupation is recorded before file-type
filtering, so an unrecognized directory or symlink cannot be mistaken for an
empty group. A group containing both recognized PNGs and unknown names remains
eligible for image collection; its sidecar still survives the final directory
check. Wholly retained groups and busy/unverifiable leases continue to skip
without consuming capacity. The new ordering does not move inventory reads,
lease release or unlink operations. Existing tests still exercise a real child
holding a live lease, collection after SIGKILL, the producer commit/exit race,
claim-before-inventory, sidecar replacement, and 70-generation bounded cleanup.
No further issue was found in this change. The conservative text-first caption
choice and the separate helper finding already recorded above are unchanged.

### Final focused validation

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/PastedImageLeaseTests \
  -only-testing:PiAppTests/ClipboardImageTests \
  -only-testing:PiAppTests/ComposerAttachmentDestinationTests \
  -only-testing:PiAppTests/ComposerImportSubmissionTests \
  -only-testing:PiAppTests/ComposerSubmissionTests \
  -only-testing:PiAppTests/PastedAttachmentTests \
  -only-testing:PiAppTests/QueuedAttachmentLimitTests \
  -only-testing:PiAppTests/CatalogImageInputTests \
  -only-testing:PiAppTests/DraftSizeTests \
  -only-testing:PiAppTests/DraftMarkTests \
  -only-testing:PiAppTests/RecoveredDraftTests \
  -only-testing:PiAppTests/QueuedEditPresentationTests \
  -only-testing:PiAppTests/WorkspaceTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ClipboardHTMLPerformanceTests
```

`r6-regressions-final.log`: **110 executed, 109 passed, 1 existing skip,
0 failures**. Per-class passes: PastedImageLease **13**, ClipboardImage **19**,
ComposerAttachmentDestination **2**, ComposerImportSubmission **11**,
ComposerSubmission **6** (+ **1** existing missing-Conversation-menu skip),
PastedAttachment **8**, QueuedAttachmentLimit **2**, CatalogImageInput **2**,
DraftSize **2**, DraftMark **5**, RecoveredDraft **13**,
QueuedEditPresentation **9**, Workspace **17**. `r6-timing-final.log`:
**1/1 passed**; malformed HTML took **1.260 ms** text-first and **0.165 ms**
image-first.

The remaining classes each ran alone under the shared full-lane lock:

```sh
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/PendingChatProjectTests
scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ComposerPasteRoutingTests
TEST_RUNNER_PI_APP_PASTE_GALLERY="$PI_BUILD_ROOT/gallery-r6-paste" \
  scripts/test-macos.sh -parallel-testing-enabled NO \
  -only-testing:PiAppTests/ComposerPasteGalleryTests
```

| Final run | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Paste/attachment/lease/draft/workspace (`r6-regressions-final.log`) | 109 | 1 existing | 0 |
| HTML timing (`r6-timing-final.log`) | 1 | 0 | 0 |
| Pending-chat projects (`r6-pending-project-final.log`) | 24 | 0 | 0 |
| Real Edit-menu routing (`r6-menu-final.log`) | 6 | 0 | 0 |
| Refusal gallery (`r6-gallery-final.log`) | 1 | 0 | 0 |
| **Total** | **141** | **1** | **0** |

Regenerated and inspected `gallery-r6-paste/paste-refusal-{light,dark,narrow}.png`.
The full notice, Copy/Dismiss controls and draft remain visible in all three;
the narrow footer continues to truncate its duplicate notice while the full
top notice wraps. The runner released its own shared lock, and no clone folders
or workstream test lock remain. No helper or wire source changed, so those
suites were not rerun. No round-6 issue remains unresolved.
