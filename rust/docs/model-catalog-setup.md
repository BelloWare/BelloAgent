# Catalog-assisted Connections setup

## Source and boundary

Swift `ModelCatalog.swift`, `ModelCatalogEndpoint.swift`,
`ConnectionSettingsController.swift`, `ProfileSettings.swift` and
`ConfigurationVault.swift` remain the behavior specification. This Rust slice
covers Connections setup, saved identity/fork propagation and explicit later
chat sends. It does not add onboarding, model probes, per-chat model overrides,
mini models, catalog-source selector UI or live catalog-driven image capability.
The opt-in native connection-only host from `6eee1d0` is preserved. Catalog
intents remain strictly Fixture-mode-only; Native manual Connections and their
background vault/preflight/navigation work are unchanged. Catalog preparation
never runs on the foreground thread for Native mode. Production remote catalog
execution remains rejected, and default/native startup and tool gates are retained.

## Lists and transport

- Default: the six-row reviewed `catalogs/bello-agent.models.json` is embedded
  directly with `include_bytes!`, without a duplicate resource. Both Rust CI
  workflows include that path in their triggers. Loading it is local and keyless.
- Custom: the URL exclusively replaces the bundle. Unsupported URLs, parse or
  transport failures do not trigger a `/models` request or bundled fallback.
- Only explicit fixture authority can prepare remote requests, and only numeric
  loopback endpoints are permitted in this slice. Same scheme, host and effective
  port may resolve the fixed fake gateway key. External origins never decode that
  key. Provider custom headers are never copied to catalog requests.
- Fresh clients disable inherited proxies, redirects, cookies and shared
  credentials. GET includes Accept application/json and Cache-Control no-cache.
  Each read has an eight-second idle limit; the complete transfer has a
  120-second deadline. Declared and streamed bodies are capped at 2 MiB.
- Source identity, request generation, active form, opening/window binding and
  owner state fence completion. Close, Cancel, tab change, Reload and rebind
  cancel in-flight work. Source/key/revision changes clear old rows immediately.
  A stale task cannot clear or replace a newer request.
- Custom results are fresh for five minutes. Errors back off for 30 seconds;
  explicit Refresh bypasses either timer. Repeated opens share one request.
  Failed same-source refreshes keep previous results usable beside a fixed error.
  An inherited custom source uses the remote timer even when its own URL is blank.

Catalog URLs have redacted Debug output, and form/event Debug redacts all URL text.
Notices use fixed error descriptions and fixed source labels, without server
response bodies, raw network errors or query values. The source URL remains
explicitly editable in the form, consistent with Swift.

## Parser and retained metadata

The parser accepts a bare model array or an object with `models` and optional
version 1. It allows at most 2,048 entries with unique trimmed printable IDs of
at most 200 UTF-8 bytes. Names/descriptions retain at most 2 KiB on Unicode
boundaries. Explicit order is stable; unspecified order follows ordered rows.
Context/output aliases, supported bounds, strict booleans/numeric metadata,
absent versus empty reasoning, effort order and input filtering follow Swift.
Unknown metadata never becomes a runtime permission.

Choose changes only the retained form. Context applies only when supplied, the
model ceiling replaces its prior value, and the reply budget only decreases as
needed for that ceiling/context. Compatible effort survives; incompatible effort
returns to model default. A metadata-only choice is dirty even when all visible
text fields happen to remain unchanged. Manual alias edits cannot resurrect old
catalog metadata by typing the original alias again. Search is transient and
never makes an otherwise clean form dirty.

The vault recognizes only the additional `catalogUrl` metadata field. It keeps
unknown opaque fields and whole-envelope CAS behavior. Source links are bounded,
flat and reference existing saved Responses connections. Own URL edits detach
links; compatible model forks preserve source lineage; deletion clears related
links. None of these links chooses the request endpoint, key or saved chat route.

## Validation scope

Focused parser/transport, fake vault, cache/form, GPUI view and full
catalog-to-explicit-loopback-request regressions are included. They cover bundle
identity, type/boundary rejection, origin isolation, HTTP headers, limits,
cancellation/deadlines, metadata retention, budget/ceiling separation, list
search beyond 130 entries, failed refresh, stale tasks and route forks.

The reusable `rust/fixtures/catalog_workflow_gateway.py` serves only numeric
loopback and logs sanitized GET/POST facts. Run a second instance on another
port to exercise anonymous external-origin fetches. It never calls a provider.

Written tests and successful source formatting are not execution or GUI evidence.
Exact candidate execution, mutation controls, frozen-binary desktop results and
CI are recorded separately when performed. Linux fixture evidence does not
establish native macOS keyboard/IME/accessibility, signing, Keychain or production
startup acceptance.
