# Secure Connections input: cloud Linux evidence

These are eight curated, unmodified CUA screenshots from the 2026-10-07 cloud
Linux interaction run. Their original bytes and hashes are in `report.json`.
The full local run retained 15 images; this directory omits redundant views.
All fields and requests used the fixed public fixture values, never real secrets.

- `06-both-secrets-masked.jpg`: API-key paste and typed header JSON are both masked.
- `02-copy-cut-sentinel.jpg`: Copy/Cut from the selected secure field leave both
  its masks and a prior ordinary clipboard sentinel unchanged.
- `03-mouse-selection.jpg` → `04-selected-delete.jpg`: pointer selection and deletion.
- `05-clear-no-undo.jpg`: Select All, Delete and Undo leave an empty replacement.
- `09-saved-reopen-blank.jpg`: saved replacements reopen blank.
- `14-stale-authority-refusal.jpg`: project-trust changes fence a stale save,
  retaining its masked draft and asking for explicit reload/review.
- `15-cleared-header-request.jpg`: two explicit local requests completed. The
  credential/header outcome is in `request-checks.jsonl`, containing booleans only.

The first request followed Cancel and a metadata-only save with blank replacement
fields: both saved fake key and custom header were preserved. The second followed
explicit reload and a masked `{}` header replacement: the key remained and the
custom header was absent. Settings save, trust and selection made no requests.

`source-manifest.json` identifies the exact 152-source/manifests binary build and
assets. The tested binary SHA-256 was
`0c1539f98bdd0692e71f9d69787d9e0604938bd9f55a9df94c96d23ac82079a6`.
A later Projects success-label correction is outside this binary; the secure
input source is unchanged. Final checkpoint CI is separate from this receipt.

For a repeatable local fixture, run
`python3 rust/fixtures/secure_connections_gateway.py --port 47861 --log /tmp/secure-requests.jsonl`,
then launch the nondefault synthetic-authority build with `--synthetic-connections`
and explicit disposable project/session paths. Use the visible Settings and
Projects controls. The fixture server binds numeric loopback, logs only request
check booleans, and makes no external calls. Its request-handling code is the one
used in this run, packaged with explicit port/log arguments.

See [the input contract](../../secure-connection-inputs.md) for source references,
limits and automated tests. Native macOS secure keyboard/IME/accessibility,
signing, Keychain and production-startup acceptance remain unopened.
