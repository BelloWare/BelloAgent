# Explicit native saved-connection host

This checkpoint connects the existing separate Rust macOS vault adapter to the
Connections and Projects UI and saved provider-chat runtime. The source contracts
remain `ConfigurationVault.swift`, `KeychainVaultStorage.swift`,
`ConnectionSettingsController.swift`, `WorkspaceConfiguration.swift`,
`WorkspaceConnectionSwitch.swift` and `WorkspaceChatLifecycle.swift`.

## Selecting the host

Build with the nondefault app feature:

```sh
cargo build --locked -p bello-agent-app --features native-authority
```

The resulting application selects native authority only with the explicit
`--native-authority` launch argument. The approved signed identity and separate
vault namespace are specified in [the storage contract](native-authority-contract.md)
and [packaging templates](../packaging/macos/README.md). Building does not sign,
install, launch or register the application. An unsigned development executable
cannot use the vault and has no credential fallback.

The flag requires macOS and the build feature. Mixing it with synthetic flags,
legacy `--profile`, `--credential-stdin` or attachment fixtures is rejected before
profile/fixture reads, stdin consumption or authority access. The feature alone,
including an all-features build, never selects native storage. Ordinary startup
and `ProjectAuthority::new()`/`Default` keep their existing unavailable behavior.

## Connections, trust and provider chat

Native mode uses the same retained forms, per-tab save order and whole-envelope
compare-and-swap operations as the fixture workflow. New endpoint and model
fields start empty. Masked replacement fields retain the existing blank-keeps-
saved behavior. Save, Reload, trust confirmation and connection selection send
no model request. Storage labels distinguish native Keychain and the in-memory
fixture; mode presentation never changes the backend's validation provenance.
Synthetic storage continues to reject ordinary keys and non-loopback endpoints.

Since 2026-10-10 native saved chats use the same tool-capable
`SavedRuntimeFactory` composition as the fake-vault fixture: in a trusted
project the chat's mode offers Swift's read-only tools (read, ls, find, grep)
or its editing tools (those plus write, edit and bash), the project's MCP
manager, and its instructions and skills, with the factory's existing trust,
identity, connection and revocation checks before every request and tool
batch. Tools see the reader's own HOME, and PATH, LANG and TMPDIR from the
process with Swift's defaults, as Swift's `toolEnvironment` does (the fixture
keeps HOME in the project folder). `SavedRuntimeFactory::connection_only`
remains available but no launch uses it. Swift chats import from the command
line (`--import-swift`); there is no migration of the vault or credentials.

Native startup presents an unconfigured placeholder while the existing background
loader restores the selected saved chat. New Chat and connection preflight use
the existing background executor as well. New Chat completion checks its project,
window, navigation generation, connection choice and pending switches. Connection
preflight completion checks its operation token, chat record and controller
identity before it can change the UI or retire the previous actor.
Preflight blocks app submission actions but leaves the prior actor alive; failure
preserves that chat and its draft. Successful switching keeps the established
retire/join, durable binding, reopen and final confirmation ordering. Later
navigation or connection selection supersedes an earlier New Chat result.

## Validation boundary

Core tests use the native adapter's fake API and isolated temporary lock files to
exercise ordinary-looking fake HTTPS credentials, trust/identity confirmation,
revocation, denied/corrupt/uncertain storage and absence of tools/MCP/resources.
App tests inject Native presentation with the existing synthetic storage. They
exercise the actual coordinator and runtime using fixed fake keys and numeric
loopback traffic; native presentation cannot relax those fixture restrictions.
No test reads the real Keychain, validates an actual signing identity or uses a
real provider credential. GPUI uses its test platform.

CI retains default and synthetic configurations and adds native-only and combined
native/synthetic app suites. The Apple job compiles/links the native feature;
the Linux job checks that unsupported-platform/default startup remains closed.
Local results are recorded in the
[validation record](validation/native-authority-host-2026-10-08/README.md).
Published CI must be checked for the exact pushed revision, rather than inferred
from compilation or an earlier revision's passing run.

A locally signed app's vault access without prompts was accepted on
2026-10-10 (`validation/native-signed-acceptance-2026-10-10`). Secure native
input/IME, VoiceOver, full lifecycle, model catalog discovery, other Settings
sections and macOS acceptance of tools in the signed app remain separate
acceptance work. This checkpoint is
not a release or native end-to-end credential certification.
