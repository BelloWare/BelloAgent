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

The classifier now checks file/type metadata and obtains encoded image bytes
before considering HTML. Image-first copies without rich text, explicit image
URLs, and absence of meaningful text decide without reading HTML. A missing
image flavor or unavailable image bytes never triggers an HTML read. Deferred
private pasteboard providers verify the request order and omitted reads.

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
All **6** new mutations were caught. No unresolved finding remains; ambiguous
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
