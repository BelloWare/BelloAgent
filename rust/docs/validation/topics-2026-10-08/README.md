# Topics validation — 2026-10-08

The 21-path source patch was developed on `a73f56acdf5847e7a9e34c1cb2aceeb051df0db3`
and integrated with every postimage verified on `ea2e2ed970cacd13d90e40eed5d1aaa3a565bd1a`
(tree `4f6ced57637b3979ad4c5ff5dbc0e14025144930`). The latter baseline contains the
separate test-only actor-publication observation repair. No topic source was
changed while final gates ran.

## Passed

- Focused catalog: 11 passed; focused GPUI workflow: 14 passed.
- Clean integrated core default: 442 unit + 127 integration tests passed.
- Clean integrated core all features: 621 unit + 127 integration tests passed.
  Two child-process test invocations also appear in the raw output; these are not
  additional independent tests in the reported unit total.
- Clean integrated App all features: 612 passed, 0 failed, 3 ignored.
- Strict default and all-feature core/App all-target Clippy; workspace formatting.
- Package cleaning explicitly verified that no old Agent executables remained.

The three ignored App tests are the manual synthetic CPU benchmark and native
macOS editing/read workflows requiring Foundation/ImageIO. No ignored Topics test.

The new GPUI tests dispatch actual fake-platform mouse/keyboard events, including
create/move and modal dismissal; they also cover IME marked text, held Enter,
Tab/Shift-Tab, stale panel/rebind/delete/membership callbacks, title filtering,
archive/pin behavior, catalog uncertainty, and closing/reopening a sheet during
physical persistence. A configured numeric-loopback listener receives zero
requests during create/move/rename/delete; no session file is created. Core tests
preserve an existing journal byte-for-byte and exercise atomic failure boundaries.

These results do not establish actual interactive GUI or native macOS/TCC/AX/
Keychain/signing/performance acceptance. Any later actual desktop replay must have
its own original screenshots and exact binary/source identity.

## Reproduce

See `run-final.sh` for exact commands. Its paths identify the isolated cloud
workspace used for this record; replace paths with your checkout and output
directory. Use the repository's pinned toolchain and documented GPUI prerequisites.
The source manifest lists SHA-256 postimages. Read the enclosing publication's
exact remote commit/CI separately; local success is not a CI result.

## Initial failures and ordinary binary

Initial compile attempts are preserved under `initial-failures/`: inherited GPUI
`test` macro recursion, a temporary debug-selector lifetime, and missing explicit
test trait imports. Initial strict Clippy found identity-map/auto-deref and cloned
slice-reference style warnings. These were corrected without suppressions; final
clean gates above passed afterward. They are build/test-support correction history,
not a claimed application regression RED/GREEN demonstration.

The ordinary debug application was also built with the existing
`synthetic-authority` feature. `sealed-build.json` records its SHA-256 and the same
source manifest, reverified after final gates/build. The binary is retained locally
for separately coordinated cloud desktop replay and is not uploaded in this record.
No trust catalog, keychain, signing identity or production authority was seeded.
