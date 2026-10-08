# Explicit native saved-connection host

Baseline: `2a788cdc226ae6f5d8142112921d04db523681bc`.
Implementation: `f155d7ec3632562db85e1711e21b9e2e06193470`.

The [host contract](../../native-authority-host.md) connects the existing native
storage adapter to Connections, Projects and saved provider chat. It requires
both the nondefault app feature and explicit launch flag. Ordinary startup keeps
native storage unavailable. The saved-chat factory preserves trust, catalog/chat
identity and revocation checks while exposing no builtin tools, MCP manager or
project instruction/skill resources.

New Chat and connection preflight use the background executor. Pending preflight
blocks submission without retiring the existing actor, and failed preflight
preserves its draft. Navigation and later connection selection supersede stale
New Chat completion. Native presentation cannot relax synthetic-storage rules.

## Local validation

Host: Apple Silicon, macOS 14.8 (23J21), Xcode 16.1 (16B40), macOS SDK 15.1,
Homebrew Rust/Cargo 1.91.1. Dependencies remain locked. CI uses its existing pinned
Rust 1.99.0. Builds use two jobs and the isolated Agent target directory.

Tests use generated temporary workspaces, fixed fake credentials, numeric
loopback servers, the native adapter's fake API and GPUI's test platform. They
do not read the real Keychain, check an actual signing identity, request platform
permissions, launch the GUI or call a paid provider.

| Check | Result |
| --- | --- |
| `cargo test --locked -p bello-agent-app` | 429 passed, 1 ignored |
| `cargo test --locked -p bello-agent-app --features native-authority` | 429 passed, 1 ignored |
| `cargo test --locked -p bello-agent-app --features native-authority,synthetic-authority` | 554 passed, 1 ignored |
| Final combined app rerun filtered to `native_mode` | 7 passed |
| `cargo test --locked -p bello-agent-core --lib --all-features` | 558 passed |
| `cargo build --locked -p bello-agent-app --features native-authority` | Compiled and linked |
| Native-feature executable `--help` and conflicting-mode checks | Passed |
| Workspace formatting, diff whitespace and workflow YAML parsing | Passed |

The two new fake-native core tests cover connection-only runtime construction,
ordinary-looking fake HTTPS credentials, trust and revocation, denied/corrupt/
uncertain storage, and absence of tool or resource admission. App tests exercise
the retained save form, failed saves, real loopback chat submission, startup and
New Chat reuse, preflight failure and overlapping navigation/connection actions.
The final filtered rerun follows the skill/MCP affordance adjustment.

The executable smoke checked the native-feature help text, then passed
`--native-authority --profile <absent-file> --credential-stdin` with stdin held
open. It exited with the authority-mode conflict before reading stdin or the
absent profile, and created no files in its isolated working directory. It did
not perform a valid native-authority launch.

The full core all-features run passed its 558 library tests and the earlier
integration suites, then stopped in the unchanged file-search integration. On
this host, `native_find_and_grep_match_the_current_swift_source_on_macos` disagrees
with the Swift source oracle for UTF-8 BOM decoding: Rust finds `bom:1: needle`,
while the Swift oracle returns no matching line. This is not a passing full core
integration gate. Rebuilding the core package from the unchanged baseline and
running that exact integration case reproduced the same mismatch. The baseline's
[Linux](https://github.com/BelloWare/BelloAgent/actions/runs/37719147602) and
[macOS](https://github.com/BelloWare/BelloAgent/actions/runs/37719147569) CI runs
passed; no oracle expectation was weakened for this host's result.

Strict local Clippy also encounters existing Rust 1.91 diagnostics in
`workspace.rs` (`nonminimal_bool`) and Objective-C macros in `native_menu.rs`
(`unexpected_cfgs`). CI keeps its existing strict warnings policy; no allowance
is added to the source or workflow for these local diagnostics. A diagnostic
Clippy run exempting only those two existing diagnostics passed.

An independent final source, documentation and workflow review found no blocking
issues. The CI additions test the native-only and combined feature configurations
and compile/link the native executable without selecting native authority.

## Remaining acceptance

This checkpoint does not establish signed-app vault access, no-prompt native
behavior, secure input/IME or VoiceOver acceptance, complete lifecycle parity,
production tools, provider model discovery, Swift import or release readiness.
Compilation and fake-storage tests do not substitute for those checks.
