# Picker-selected image attachments

This bounded vertical follows `Attachments.swift`, `PiQuestion.swift`,
`ComposerInput.swift`, `WorkspaceRun.swift`, `QueuePanel.swift`,
`SessionQueue.swift`, `Tools.swift:loadImages`, `PiImage.swift` and
`ResponsesInput.swift:userContent` from the checked-in Swift source.
It does not implement clipboard/TIFF paste, promised drag data, skill selection,
model catalog discovery or full model-capability Settings.

## Metadata and native processing

The photo control uses the supported system multi-file chooser. PNG, JPEG, GIF
and WebP contents are identified by signatures, not filenames. GPUI 0.2.2 does
not expose content-type filters or an owning-window sheet through this chooser;
a native filtered macOS sheet remains a separately accepted parity item.

Selected records contain a UUID, canonical symlink-resolved path, SHA-256,
source byte count and MIME. A nonempty regular file is bounded to 8 MiB;
submissions are bounded to four files and 16 MiB total. Nonblocking CLOEXEC opens,
descriptor regular-file checks, 64 KiB read/hash chunks, maximum-plus-one growth
checks and size/modification/inode checks prevent special-file hangs and reject
selection races. The inode check is an additional defensive check. Selection
retains Swift's loose GIF8 prefix; delivery accepts only GIF87a/GIF89a. The full
read tool's broader sniffing rules are deliberately not reused.

The native adapter reuses the existing source-backed ImageIO/CoreGraphics
processor, including upright EXIF geometry, strict base64 length below 4,718,592,
2000-pixel axes, PNG then JPEG quality order 80/85/70/55/40, and quarter-step
shrinking. The existing 16,777,216-pixel predecode guard remains a documented
stricter Rust bound; it is not a whole-process memory guarantee. Native work is
cooperatively cancellable, with late results discarded after its physical worker
returns. No portable decoder is substituted on Linux.

## Acceptance, delivery and recovery

Acceptance reads and normalizes all selected images on the bounded shared file
executor before the session transaction. An omission rejects acceptance and keeps
input recoverable. Prepared acceptance bytes are discarded. Queued metadata is
read, hashed, signature-checked and normalized again before actual delivery.
Following Swift, a later decoder omission is delivered as its explicit omission
text; changed/missing/signature-mismatched source files instead pause and retain
the pending submission without a provider request.

Preparation never holds the session actor. Exact submitted metadata, text,
identity, model/effort, configuration Arc, admission generation, Stop epoch,
retirement, hold and pending selection are rechecked before commit. Saved
connection/project confirmation is repeated after preparation. Appended unrelated
input does not invalidate the captured candidate. Prepared content is bound to
the complete Submission and cannot be consumed by a different turn. Older
text-only delivery entry points refuse unprepared image submissions.

User-row bytes and dequeue/activation share one durable checkpoint. Before-rename
failures leave memory and pending input unchanged; after-rename uncertainty fences
further writes until authoritative recovery. Retry and reopened history replay
retained bytes, never the original paths. Steering preparation failures still
commit completed tool outcomes, retain the steering item and pause. MCP tickets
are settled only after a positively confirmed committed tool-result boundary,
including a committed paused boundary; uncertain commits do not settle them.

The physical image closure owns its lifetime lease. Stop cancels waiting or live
work; retirement and shutdown wait for actual closure completion before releasing
writer ownership, even when its awaiting caller was dropped. This does not claim
that an ImageIO call can be forcibly interrupted.

## Storage, display and capability

Snapshot version 7 adds metadata on pending/active/retry submissions and an
optional Arc-backed UserContent on the delivered user row. UserContent retains
metadata separately from ordered content blocks. Catalog version 8 adds metadata
to drafts and submission receipts. Empty fields are omitted and legacy catalogs
and snapshots remain readable without an opening rewrite. Wrong-version or
malformed retained content is rejected without rewriting the source bytes.

Fresh selection and acceptance keep the four-file limit. A rejected Send can
restore four captured records ahead of four newer picks, so an eight-record draft
may be retained for recovery. It cannot be submitted until reduced. Recovery
uses exact-record deduplication; matching only a path/hash could discard a distinct
selection. Queued edits keep their own original images and edit text only; any
new picker result joins the parked ordinary draft. Image-only queued rewrites can
be saved empty. Uncertain submissions remain in a reviewable receipt rather than
being automatically duplicated into a sendable draft. Acceptance recovery queries
a certain live actor and compares ID, text and complete attachment metadata;
a conflicting same-ID payload is not reported as absence.

The existing explicit Insert in draft recovery remains available when the loader
has only a retired, unconfigured, never-materialized placeholder and its expected
checkpoint is missing. It may extract even a CheckpointRequired receipt into a
local draft after exact saved-receipt/chat/source-draft checks. This is unverified
local extraction, not evidence that the earlier request was never executed. No
runtime is created, configured or materialized; CheckpointRequired/load_failed
remain, Send stays blocked, and the warning says it may already have executed.
Same-chat durable data can follow a window-only rebind without focus; changed
project/controller/load identity or newer draft cannot be overwritten. Existing
files, symlinks, directories, FIFOs and non-NotFound errors block this exception.

Composer chips contain filenames, explicit open-original actions, remove actions and
path help. Local file URLs are safely encoded and bound to the captured
chat/workspace/window/controller and full record. Removal cannot bubble into
opening. Fresh picker launch is disabled throughout held/resolving queue edits;
a chooser already started before the edit can still finish into the parked draft.
Image-only transcript/queue labels use Image/N images. No thumbnails are invented. Raw Copy
remains the user's Message.text, never encoded media or a synthetic image label.
Large payloads never enter draft/catalog text, transcript text or ordinary Copy.
UserContent and ContextPreview Debug output contain bounded metadata/lengths,
not image data, paths or captions.

UserContent has its own 20 MiB serialized envelope. Four individually legal inline
images can exceed ToolContent's 16 MiB limit. User projection preserves exact
block order and image-adjacent hints; unsupported historical images use only the
source user placeholder, collapsed only when adjacent. Aggregate actual image
bytes and final serialization retain the existing 32 MiB request bound. The
256 MiB snapshot safety bound and recovery reserve are unchanged.

Images require explicit effective model input capability. Names never imply
support. Current full catalog/input controls remain absent; CLI declarations and
retained saved profile capabilities are used. Changing a saved model continues
to clear inherited image capability under the existing conservative Rust rule.

## Context and compaction

Idle Context explicitly prepares selected draft images using the same provider
projection without sending or checkpointing. Active Context defers draft text
and image metadata and does not open their files. The app binds captured text,
metadata and revision to the originating chat/window/controller. An image-only
preview omits an empty text block to describe actual Rust dispatch. This is an
intentional difference from Swift SessionContext, which currently includes an
empty preview text block although Swift delivery itself omits it. As in the source,
a preview may show a decoder omission that Send subsequently refuses during its
stricter acceptance check; preview preparation is not proof of admission.

Compaction refuses to turn retained user images into placeholders when the
selected model lacks image input, as for tool images. Conservative token estimates
count an image allowance rather than base64 characters. Request and snapshot
limits still apply to compacted active context.

## Explicit synthetic cloud fixture

Debug builds with synthetic-authority recognize:

    --synthetic-connections --synthetic-attachment-fixture PROFILE

The fixture profile must be a bounded regular JSON file, have a valid UUID ID,
explicit text/image input, numeric loopback endpoint and no custom headers. The
fixed synthetic key is used; an optional stdin value must match it exactly. This
cannot be combined with the legacy --profile option. It saves a connection only
through normal ProjectAuthority.save_connection. Connections selection, project
trust, saved-chat composition and admission still use the normal paths; startup
never selects, trusts or sends automatically. Native release builds do not expose
this option.

Only the exact generated one-pixel GIF used by the fixture is normalized on Linux.
Other selected valid formats produce the honest native-unavailable fixture error.
This is test support, not a production capability or ImageIO-equivalence claim.
On macOS, even synthetic saved connections use the real native processor.
The generated GIF base64 is
R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==.

## Validation boundary

Focused portable tests cover signature/count/file/total bounds, canonical paths,
FIFO acquisition, mutation/deletion, file-less replay, image-only projection,
legacy/schema rejection, exact receipt identity, draft recovery, rename/capacity
faults, candidate/config/Stop/hold/removal/retirement races, dropped awaiters and
committed-versus-uncertain tool boundaries. The native selection/loadImages oracle
extracts the actual checked-in Swift code; the existing native PiImage oracle
continues to test generated EXIF/resizing/format cases. Native oracle execution
requires Apple CI. Actual picker/focus/IME/accessibility/sheet ownership requires
separate native Mac acceptance. No owner images, credentials, signing, native
vault, paid model calls or real Mac access is used by these fixtures.

The [dated acceptance report](validation/picker-images-2026-10-07.md) identifies
the immutable candidates, exact executed cloud GUI cases and remaining native
gates. Compilation and headless event tests alone do not constitute actual
picker acceptance or native macOS parity.
