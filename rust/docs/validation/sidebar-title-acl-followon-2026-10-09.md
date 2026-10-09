# Sidebar startup title and admission diagnostics — 2026-10-09

## Integration baseline

This follow-on targets [`rust` at 8ceb2fd](https://github.com/BelloWare/BelloAgent/commit/8ceb2fd45125f20266fbad6e6816acdc5dc069be), tree `d52b948041d22fc89be63d4f629fd8e3bd40f4f2`. Its executable source equals [the b6e0 checkpoint](https://github.com/BelloWare/BelloAgent/commit/b6e0e31d50fc99d949740b24a35311baadd15324); the two intervening commits changed only root `duration.md` and `duration-data.json`. Their latest bytes are preserved.

The independent 16:00:14 UTC baseline check still found [`main` at 6319e368](https://github.com/BelloWare/BelloAgent/commit/6319e368c6ddb7c3ef18605e78f23b1a5b69e63a), tree `43ed6d8843a09b58fe00d436dd0e0c1a56c76972`. This work belongs on `rust`; it does not merge, rewrite or otherwise change `main`.

## Supported Linux startup correction

The synthetic fixture previously set its warning title in an extra synchronous window update after `open_window` returned. An isolated ten-run matrix reproduced black initial captures with that call, including when cache installation was omitted. No-op window updates and cache-only install/notify updates painted. Moving the same title into the existing root builder painted, while returning the same diagnostic binary to the original title ordering reproduced black again.

The final correction supplies the initial title to `WorkspaceLifetime`, sets it in root construction before the first draw, and retains it for detach/reopen. Ordinary launch keeps `Bello Agent`. Synthetic launch keeps the full `Bello Agent — SYNTHETIC SIDEBAR VALIDATION — NO PROVIDER` warning. Cache installation, ownership checks and production privacy gates are unchanged. No timer, diagnostic mode, forced resize/redraw or backend patch remains.

GPUI maps its platform window before root construction, so this is not a proven pre-map ordering defect. The lower-level X11 event/presentation mechanism remains unresolved. The supported finding is the specific extra post-open title setter as the triggering operation in this cloud Linux fixture.

The title-only constituent passed 826 synthetic and 653 default App tests (3 and 1 ignored), strict all-target App Clippy in both configurations, formatting and builds. Its two new TestPlatform regressions check actual stored titles, retained root/controller/composer identity, draft and Undo across reuse/reopen. Fresh synthetic, same-root/runtime restart and ordinary first scoped captures painted without input, expose or resize recovery. Loaded/unopened content reveal and retained tool-output reveal worked; ordinary content search remained privacy-gated. These were Linux observations, not native macOS acceptance or presentation-latency measurements.

## Unproven CI admission diagnosis

The b6e0 Linux failure reported only that a synthetic fixture ACL could not be excluded. Its syscall result, errno and descriptor role were absent. An ancestor ACL and interruption are hypotheses, not established causes. The macOS Core failure cause was not available when this follow-on was prepared. No successful local test is claimed to repair either remote failure.

The synthetic-only ACL diagnostic now reports descriptor role, attribute, result, errno and attempts. Only a negative ENODATA or ENOTSUP result admits, as before. Nonnegative results (including zero), missing/unexpected errno and repeated interruption fail closed. EINTR alone retries the same descriptor for at most three total probes. No ACL, ownership, mode or symlink requirement is relaxed and no production gate is enabled. The independent constituent passed all 13 fixture tests and strict all-target synthetic App Clippy; two new injected-probe tests cover absence, real ACL, unknown failures, exhausted interruption and interruption followed by a real ACL.

## Native failure observability

The existing pure Core command and step order remain intact. Its combined stdout/stderr is copied through `tee` with `pipefail`, preserving failure. Always-run steps retain only a bounded text tail: up to 2 MiB plus a short byte-count/SHA-256/truncation header, with one-day artifact retention. Missing logs produce an explicit not-reached notice. No screenshot, executable, source bundle, credential or user-data artifact is added. Public-repository guard and non-cancelling concurrency policy are unchanged.

Local workflow probes cover missing, empty, short and oversized logs and an original exit-7 command with both output streams. The artifact upload itself has not been executed locally. A new exact-commit CI run must establish the actual remote result; the diagnostic is not a green-build workaround.

See [the sidebar workflow contract](../sidebar-content-workflow.md) and [private cache boundary](../sidebar-private-cache.md). Combined-source tests and strict checks are a publication gate; original failure evidence and constituent validation must remain distinguishable.
