# Native read: source contract and validation boundaries

This checkpoint integrates the explicitly selected macOS `read` capability with
bounded text/image results, durable content, declared model input capability,
Responses projection and the existing transcript. Linux validates portable
contracts and retained-content replay; it does not offer a partial text-only
capability under the full `read` name. Actual native oracle/loopback execution
and exact published CI remain separate acceptance gates. Production desktop
tools and native authority remain disabled by default.

## Swift source contract

- `PiAgentCore/Tools.swift:248–275,318–359`: explicit read schema, required path,
  existing-path multi-root resolution, then bounded acquisition and cancellation.
  Image recognition/processing precedes UTF-8 and paging validation. Read failures
  must win over invalid offset/limit. Image reads ignore otherwise-invalid paging
  values after schema preparation/native key validation.
- `Support.swift:76–87`: nonblocking close-on-exec open, descriptor fstat regular
  file requirement, 16 MiB metadata bound and maximum+1 growth detection. Do not
  precheck path metadata and then open a potentially replaced FIFO blocking.
- `Tools.swift:21–67`, `TextPreviews.swift:14`: model lines split only at LF,
  retaining CR and trailing empty line; 1-based offset defaults 1/max 10,000,000;
  limit defaults 2,000/max 10,000; zero fails. 32,768 source-byte prefix decodes
  lossily and trims U+FFFD at both edges, including genuine replacement characters.
  Viewer stats count CRLF/CR/LF differently and are not model text line numbers.
- `PiImage.swift`: sniff only first 4,100 bytes, excludes JPEG-LS and detected APNG,
  validates BMP headers. Sniff is not successful decode. ImageIO upright first-frame
  dimensions account for EXIF 5–8. Supported PNG/GIF/WebP/JPEG under 2000×2000 and
  strict base64 length <4,718,592 remain byte-identical, including EXIF metadata.
  This fast path checks metadata, not full pixel decode; it cannot promise every
  corrupt/truncated stream is detected when ImageIO still reports dimensions.
  BMP converts to PNG. Resizing uses upright pixels, high-quality CoreGraphics,
  PNG then JPEG qualities 80,85,70,55,40, then dimensions×3/4 repeatedly to 1×1.
  Explicit conversion/resize omission text remains a non-error result with path
  stats. Conversion and coordinate-scaling hints are exact source strings.
- `ResponsesInput.swift:125–141`: without image input declaration, adjacent images
  collapse to `(tool image omitted: model does not support images)`; with it,
  function_call_output becomes input_text/input_image array with data URLs. Text-only
  output remains the existing string and empty output becomes `(no tool output)`.

## Integrated boundaries

1. New bounded file/text/sniff modules feed complete content blocks and resolved
   stats. Image processing uses same pinned Apple ImageIO/CoreGraphics families;
   no substitute Rust resampler is labeled identical to Apple's image pipeline.
2. Preserve content in an optional Arc<ToolContent> ResultRecord field with strict MIME,
   base64, content count/serialized byte validation, backward-compatible absent
   fields, and truthful text projection. Snapshot v4 is required for retained
   content; old v1–3 snapshots remain readable. Idle v2–3 reads remain
   byte-preserving; existing v1 migration, journal and interruption recovery still
   checkpoint as before. Legacy result serialization omits the absent field. Historical images never trigger file reads
   or reexecution. Persisted data is retained privately, not read by guessed paths.
3. Profile explicitly declares input capability; defaults remain text-only. Saved
   settings/profile model changes and Retry use the effective frozen configuration.
   Provider replay projects source-exact placeholders or image arrays. Context
   preview uses the bounded actual request projection; ordinary transcript Copy
   remains the original text and does not include image base64. Manual model-ID
   changes without catalog metadata fall back to text-only input capability.
4. Swift TranscriptMessage/TranscriptActivity/TranscriptCards show tool text,
   including the image note and `[image/png result, N bytes]`-style descriptors;
   they do not render tool-image thumbnails. Preserve that presentation, numbered read windows, truncation notes and resolved path
   and viewer-line stats. Durable/provider payload tests establish image delivery,
   not the visible note alone. Do not add new thumbnail behavior for parity.
5. Tests explicitly select read through trusted core or synthetic project
   constructors. No normal desktop composition opts into it. Production defaults
   remain unchanged; path roots are resolution context, not a sandbox.

## Resource/lifecycle requirements

Encoded source <=16 MiB, processed base64 strict <4,718,592 per image, bounded
serialized durable result and per-session existing checkpoint bounds. A 32 MiB
per-batch retained-content budget charges serialized content/stats plus duplicated
visible-text bytes before a native worker returns. Reservations last through batch
settlement. Over-budget outputs become explicit Failed results with no image data;
earlier accepted results stay intact. Parsing/reservation occurs in the original
four-worker executor, avoiding a second queue of large returned Values. This is
not a total result-object or process-memory cap. Snapshot serialization stops
before exceeding 256 MiB, including its final newline, rather than allocating an
oversized JSON buffer first. The 16,777,216-pixel checked
budget precedes full decode (roughly 64 MiB RGBA8-equivalent, excluding opaque native
allocations and copies); source has no such pixel cap. This is a deliberate bounded difference,
not silently claimed source parity. Opaque ImageIO allocations are not measurable
whole-process memory limits. Workers retain ownership until native calls return;
cooperative cancellation checks occur before/after acquisition, decode, encode,
and each candidate. Stop/retire joins workers; cancellation never publishes a late
image as completed or releases a still-running worker's slot early.

## End-to-end acceptance required before completion

- Synthetic trusted project -> numeric loopback provider -> real read execution ->
  durable content/stat result -> continuation request -> close/reopen replay -> UI.
- Text: empty/trailing LF/CRLF/bare CR, Unicode prefix cuts and real U+FFFD edges,
  multiple roots, file errors versus invalid paging, exact caps and missing path.
- Images: synthetic PNG/JPEG/GIF/WebP/BMP, EXIF orientation, invalid recognized
  bytes, APNG/JPEG-LS rejection, oversize resize, encode ordering and hints. Compare
  macOS synthetic oracle against the original Swift, never real user images.
- Image-supported vs text-only model declaration, changed model configuration,
  valid legacy text-only journals, malformed/oversized content refusal, byte-exact
  durable replay after original file removal, and preview redaction/bounds.
- Cancellation queued/running and between processing stages; FIFO/device/growth
  refusal; revocation before admission; no historical reexecution; default
  constructors still omit tools. UI handles repeated navigation and reopen.
- Independent review, focused tests, aggregate lint/build and exact published CI.
  Native execution/GUI claims require their own actual evidence.

## Deliberate bounded differences

- The 32 MiB retained-content batch budget and 16 Mi-pixel predecode guard are
  stricter than Swift. The metadata-only
  under-limit fast path otherwise preserves source bytes, including animation.
- The existing GPUI file editor reveals the first retained viewer line rather
  than selecting the entire first–last range. The complete range remains stored.
- Expanded numbered read text stays in the existing bounded 150 px selectable
  scroller. The collapsed card preserves source head/tail line numbers and the
  separate truncation note. Raw Copy and provider content are not numbered.
- Model catalog input discovery and production trust/vault-to-tools composition
  remain outside this checkpoint. An arbitrary changed model name is never
  treated as proof that the new model accepts images.

## Evidence at implementation time

- Portable read file/paging/sniff/schema tests, durable v4 content/replay tests,
  declared-input/vault preservation tests and strict core Clippy pass locally.
- Source image adapter independently reviewed; isolated Apple-target test
  type-check and strict Clippy pass. The 27-case synthetic Swift image oracle,
  actual native read cancellation and trusted-project loopback/reopen fixtures
  are included for Apple CI, not described as executed on Linux.
- Focused GPUI read-card tests cover expansion, source text Copy, path/line reveal,
  new-content invalidation, reopen and stale navigation guards. Their final test
  counts and exact CI are recorded with the frozen checkpoint.
- No signing, Keychain, real credentials, external provider or user image was used.

## Local final validation — 2026-10-07

On the Linux development environment:

- `cargo test --locked --workspace --features synthetic-authority`: 851 passed,
  2 ignored (the manual benchmark and macOS-only end-to-end native read fixture).
  This includes 415 app tests, 329 core unit tests and 107 integration tests.
- `cargo clippy --locked --workspace --all-targets -- -D warnings`: passed.
- Synthetic-feature strict workspace Clippy and focused transcript checks passed.
- `cargo build --locked --workspace --features synthetic-authority`, `cargo fmt
  --all -- --check` and `git diff --check`: passed.
- Isolated actual tool-source Apple-target test type-check and strict Clippy passed.
  Whole-core Apple cross-check on Linux stops at ring's C compiler needing a Mac
  toolchain; this is not native linking/execution evidence.

Independent native-image and runtime/history/schema reviews completed. Review
found and corrected aggregate result retention, eager snapshot serialization,
missing image byte descriptors, and a premature-idle fixture race. The GPUI
cache-invalidation mutation failed at the expected assertion, then exact source
restoration and the final transcript suite passed. These tests do not establish
native macOS focus/IME/Accessibility or same-machine performance parity.

The macOS workflow now explicitly runs `read_native_workflow` using GPUI's fake
test platform. That fixture confirms synthetic project trust, makes a numeric
loopback request, executes real native read, retires/joins, deletes the original
file, reopens and replays durable results, then renders the numbered result.
Actual execution and the exact published commit's CI must still be checked.
