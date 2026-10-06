# Native Find contract

Find extends the opt-in core tool runtime on macOS. It is not enabled by the
app, project trust editing, or the existing `TrustedReadOnlyTools::new`
constructor. The existing constructor still selects only ls; callers must
explicitly use `new_with_capabilities` after satisfying the host's trust and
read-only-mode contract. Workspace roots resolve paths and are not a sandbox.
Production project authority remains unavailable pending its separate native
identity and storage work.

## Platform boundary

The macOS adapter uses Foundation URLs and directory enumeration, matching
`packages/swift-host/Sources/PiAgentCore/Tools.swift` and `Support.swift`.
A portable recursive directory walk is not substituted for Foundation's native
pre-cap enumeration order, mount behavior, cached resource properties, or
stop-on-error behavior. Linux continues to offer ls only. Requesting Find on an
unsupported platform fails during construction, before a provider can see it.
The shared engine is exercised on Linux through private synthetic scanners.

The adapter keeps Objective-C objects inside a blocking job and autorelease pool.
Only owned Rust values leave that scope. Dependencies reuse the already locked
objc2, objc2-foundation, block2 and unicode-segmentation versions; the three native
packages are target-gated. Existing worker admission and cancellation/join rules
remain in effect.

## Source behavior

The schema requires pattern and permits optional path and limit. Preparation
preserves the original call and applies the existing source coercion rules;
unknown fields and missing required fields fail before worker dispatch. Inside
the worker, path resolution precedes pattern and limit validation, followed by
root existence and enumeration. The default limit is 100, maximum 2000. Native
validation permits zero even though the schema minimum is one.

Find scans directory descendants, including directories, hidden entries,
packages, special files, large files and binary files. It does not read their
contents. Entries named .git, node_modules or .build and symbolic links are
excluded with their descendants. A selected non-directory root is a singleton
and does not receive those descendant exclusions. Foundation enumeration errors
stop the scan using the source error-handler policy.

The 20,000-candidate cap is applied in native enumeration order before sorting
or matching. Reaching the cap marks the scan limited, without looking ahead.
Candidates are sorted by normalized full paths while retaining original spelling.
Relative-path slicing follows the source's grapheme count/dropFirst expression,
including its root-slash edge behavior. Darwin fnmatch is called with flags zero
against the relative path or basename. Embedded NUL follows the source C-string
termination behavior; malformed patterns follow the platform's fnmatch result.

Limit checks follow candidate evaluation. Consequently limit zero still evaluates
one available candidate and can return one match. Output is joined with newlines
and bounded to 32,768 UTF-8 bytes using the source replacement-character trimming.
The exact source footer is preserved, including its grep wording and claim about
large/binary files, despite Find itself not filtering them. No stats field is
invented.

## Validation boundary

Focused fixtures cover the pure scan/match/format engine, required-field
preparation, immutable raw calls, default capabilities and unsupported-platform
admission. A macOS integration fixture compares results against a small Swift
oracle assembled from the checked-in source; a loopback provider fixture covers
explicit mixed ls/find calls, durable result continuation and reopening without
reexecution. Native tests require the macOS CI runner and Swift compiler.

A successful cross-target binding check proves the Objective-C API calls type
check; it does not prove runtime enumeration or Swift Unicode parity. Real
macOS oracle and runtime test results must be recorded before native parity is
claimed. Mount creation, user-home discovery, actual project tools, credentials,
Keychain access, GUI tool enablement and provider spending are outside these
fixtures.
