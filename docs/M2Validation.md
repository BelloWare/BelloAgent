# M2 — Profiles, metrics, native inspector

Validated on the same macOS 14.8 / Apple Silicon VM and pinned Node 24.21.0 /
Pi 0.85.1 baseline as M0. No production provider key or paid model call was used.

- 79 host tests pass, including the dual-API error, retry, tool, cancellation,
  usage and compaction matrix carried from M0, plus full-profile wire fidelity,
  endpoint normalization, read-only credential discovery, command resolver
  responsiveness, image inputs, portable handoff, scoped body paging and Off
  before the first Messages request. TypeScript strict checking passes.
- The full 14-case native suite passes. The subsequently added capture-preference
  restart test passes with the four-case retention subset (15 distinct native
  cases validated). Native code builds with Swift 6 complete concurrency checking.
- Actual native UI walkthrough: created an API-key fixture profile in Keychain;
  selected Responses independently from its model label; configured thinking and
  image support; ran the disclosed, tool-free Test Connection action. The native
  request viewer showed the final serialized `max_output_tokens:4096`, high
  reasoning effort and empty tool availability. The response's raw SSE byte
  ranges and host timestamps were visible independently of Pi event previews.
- An image selected with NSOpenPanel became a native draft chip, reached Pi,
  and appeared as an attachment marker in the web transcript. Both real Pi API
  adapters also pass exact synthetic image-body tests.
- The footer showed Pi's estimated context, separate draft estimate, thinking-first
  TTFT versus first text, and provider-reported request-average output rate.
  Missing values remained unavailable; streaming context was labeled stale.
- Sensitive-body reveal required native confirmation. Capture controls exposed
  Off, Session memory, and Persist locally. A later synthetic attempt was retained
  after explicit consent; the earlier attempt was not retroactively persisted.
  The native retained-artifact list showed the manifest and original byte files.
  Request: 7,988 bytes; response: 22,410 bytes. Both on-disk SHA-256 values matched
  the in-memory capture hashes. Directory mode 0700; body files mode 0600.
- Native quota/disk-failure tests verify no incomplete artifact is published;
  body transfer is 32 KiB at a time, with hashes and state checked again before
  atomic publication. One native actor enforces seven days / 1 GiB across hosts.
  Preferences can be set before host startup and are applied before a model call.
- The walkthrough exposed macOS smart-quote substitution in the advanced JSON
  field. It now uses a native literal editor with substitutions disabled.

Inspector exports default to metadata. Full retained-byte exports require a
native confirmation and destination; retained artifacts can also be exported.
A redacted export previews a user-specified literal transformation and includes
an explicit derived-view manifest. It does not claim automatic secret detection.
Text/hex views are paged; pretty JSON is available for a complete JSON body that
fits one 32 KiB page. Larger bodies remain readable as original paged bytes.

Imported profiles keep read-only model/auth/settings references, hashes,
configured limits, thinking defaults/maps, model inputs, sampling and supported
compatibility options. Unsupported fields/APIs are surfaced. Executable credential
references require profile-specific trust and resolve outside the host event loop.
New secrets and custom-header values use Keychain. Public metadata header
allowlisting cannot reveal auth/cookie/token/secret/key/credential/proxy headers.

Portable handoff deliberately creates an editable text-only new-chat draft;
it never calls a model or silently resumes incompatible opaque state. Source
history and an exact original snapshot are preserved. Applied handoff provenance
is retained separately and recorded in the managed Pi session on explicit Send.

M3 applied AGENTS/skill provenance, M4 side lifetime/promotion, and M5 complete
accessibility, search/copy, stress benchmarks and final release remain required.
