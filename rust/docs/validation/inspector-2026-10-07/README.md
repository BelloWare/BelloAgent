# Inspector: first executed GPUI and actual Linux interaction

Date: 2026-10-07 UTC. Source commit
`d2c85d4b9730fb8aa29a88922116af78de3d1a6b`, Git tree
`870053b9d0921c5ec5f2ecaf18009fe2d8d68995`. The local build used the identical
Git tree before publication; only commit metadata changed at publication.
The production debug binary's SHA256 was
`2380e290a554e67aea6f32f9afb07199ae7318b8b1c8f7b0492c2414f1e3d819`.

Exact-commit checks both passed:
- [Linux 37571661607](https://github.com/BelloWare/BelloAgent/actions/runs/37571661607)
- [macOS 37571661653](https://github.com/BelloWare/BelloAgent/actions/runs/37571661653)

Locally, Rust 1.99.0 ran all 13 focused Inspector tests (12 GPUI, one pure paging
property test), strict app all-target Clippy, formatting and the production build.
The GPUI tests ran again after the lint correction. An independent source review
checked the macro collision fix, equivalent key-handler conditional and unchanged
assertions. No tests were disabled and no recursion limit was increased.

## Actual desktop observations

The cloud Linux desktop ran the actual GPUI app with a process-isolated fixture
project, application data/configuration, numeric-loopback gateway and fake key.
Linux software Vulkan is not a macOS or hardware-performance comparison.

1. Typed the unsent draft `inspector draft cafe`. Clicking Context opened a
   separate Session Inspector with the matching JSON text and a 412-byte request.
   [Initial window](02-inspector-open.jpg).
2. Typing `x` into the JSON did not modify it.
3. Appended ` changed` in the owner composer while the Inspector stayed open.
   The Inspector preserved its original JSON and showed a captured-snapshot warning.
4. Clicking Prepare it again cleared that warning and produced the matching
   420-byte request. [Refreshed request](05-refreshed-request.jpg).
5. Copy request, returning to the composer and pasting showed the JSON without
   submitting it. Undo restored the changed draft. This checks usable clipboard
   behavior; the automated tests separately assert exact whole-body bytes.
6. Reopening Context reused the same owner's Inspector window. New Chat did not
   retarget the existing Inspector or change its original session/draft snapshot.
7. Closing the Inspector, selecting the original chat and reopening retained its
   draft and produced a new Inspector window with the correct original session.
8. The fixture gateway recorded zero POST requests throughout. The app log was
   empty and the windows closed normally. No provider or paid service was used.

## Limits

Native Unicode input injection/IME could not be exercised by this desktop input
interface; only ASCII typing and application-clipboard paste were available.
Automated marked-text, Unicode paging and Undo tests are not native IME proof.
The manual request fit one page; bounded multi-page behavior, stale callbacks,
shutdown and exact clipboard serialization remain automated evidence here.
No real credentials, Keychain, signing, macOS focus/accessibility, resource/tool
production enablement or complete Swift Inspector parity is established.
