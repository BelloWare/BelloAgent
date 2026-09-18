# Direct distribution

**Owner workflow change, 2026-09-16, after 0.1.6:** prioritize short release
cycles. Do not run fresh-install or Sparkle update/relaunch rehearsals unless
the owner explicitly requests them again. They are no longer release gates.
Keep code signing, notarization, artifact/feed validation and public download
hash/signature verification. The successful older rehearsals below are historical.

Use the affected checks in [Swift-Test-Handoff.md](Swift-Test-Handoff.md), reuse
passing results for unchanged code, and run independent checks in parallel.
Reuse a stable `PI_BUILD_ROOT` outside the repository so Swift, Xcode, downloaded
runtime and package caches survive subsequent runs; keep per-run logs/fixtures
in separate subdirectories. Do not run concurrent writers against the same
build or dependency directory. Versioned release directories stay immutable.

App staging reuses npm dependencies when package/lock files, the pinned runtime,
install configuration and installed package metadata still match. Missing or
stale dependencies rerun `npm ci`; failed installs leave no reusable success
stamp. Transcript assets still rebuild, and Swift builds remain incremental.

The sibling BelloClipboardManager, BelloTracker and BelloBox scripts were inspected
before implementing this flow. They use Developer ID team `43TXHV3TM3`, notarization,
the existing Sparkle Ed25519 signing key in the login Keychain, and assets
committed/pushed to the sibling `belloware.com` repository (Cloudflare hosting).
The canonical Bello Agent feed is `https://belloware.com/assets/bello_agent.appcast.xml`.
The legacy `pi_app.appcast.xml` feed remains byte-identical so existing Pi App
installations receive the same update.
**Bello Agent 0.1.37/build 41 is publicly released** at
[belloware.com](https://belloware.com/bello-agent.html), from source `f803d904f7c3963cc0fd170a652ba15d836ea319`
and website `4363262d41c79fb0fb2f2f6aa9162bfc4e0d18e1`. The DMG measures **7,336,336 bytes (7.00 MiB)**,
SHA-256 `19801f32ec462a9cba321629802db2ee4eecb2a07907377fbbe8ed3428577a06`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 01:57:55 UTC**.
Read the [0.1.37 release record](validation/Bello-Agent-0.1.37-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.36/build 40 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `e1836b3bf5511a97e9cc9a6f9a7d48644106dfde`
and website `942d788b4591b182dd0638e182ed010aebac207c`. The DMG measures **7,328,637 bytes (6.99 MiB)**,
SHA-256 `d5ce235338331aa2f8fae3fc3ca8ae37bb14fe4bcc97862dbc86dbdcaee307fc`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 01:24:31 UTC**.
Read the [0.1.36 release record](validation/Bello-Agent-0.1.36-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.35/build 39 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `2f1e33fa9b40f3100a1018d18054380c3723fb1d`
and website `c5ef318bc6e14f688627cb7002fab4b75617a514`. The DMG measures **7,283,236 bytes (6.95 MiB)**,
SHA-256 `b7d8d50d7196a36287a8642fd447411ded475c89e1415c0f8742565baf7974a4`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-17 17:16:54 UTC**.
Read the [0.1.35 release record](validation/Bello-Agent-0.1.35-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.34/build 38 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `124b2f2fccb8d5648bbfeff7f49c5f94e62b9d12`
and website `1b8ef22a9a558aa37698c4dce74b7ac1d434f0d1`. The DMG measures **7,275,516 bytes (6.94 MiB)**,
SHA-256 `edd71cf3ede27bb773d68059542cd1bcc07fb8e6387d4053702dbd9edf3bce64`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-17 16:48:47 UTC**.
Read the [0.1.34 release record](validation/Bello-Agent-0.1.34-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.33/build 37 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `e677cdd231584fcec89af3b15e3faa306b10fbee`
and website `f7d6e1a1dd828123d54f436709be201ea1dca78a`. The DMG measures **7,268,189 bytes (6.93 MiB)**,
SHA-256 `9348db4b6471c5ead40672783e5494a0c14e621e481041750d628f865bab4256`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-17 15:41:42 UTC**.
Read the [0.1.33 release record](validation/Bello-Agent-0.1.33-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.32/build 36 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `094ea5c175e3f43c8e994aaf5e88121f1701683b`
and website `86ea696d6e7f5d57498943c34c7f7207e220d7dd`. The DMG measures **7,256,957 bytes (6.92 MiB)**,
SHA-256 `cdf95a723f37ede9d7f87d9993097d976f9b09cc422a92e251a4bbf122899c62`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-17 14:29:59 UTC**.
Read the [0.1.32 release record](validation/Bello-Agent-0.1.32-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.31/build 35 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `3ba3c8a9cf99b14fe283efb23afd5789283cc466`
and website `fa1de3de210f6e0a1803015fe3875d8d61f00690`. The DMG measures **7,246,039 bytes (6.91 MiB)**,
SHA-256 `d4ed7f87eb93ef0703824e186f7771bcf566d6d8c84ccb1055d505ad4ce0b82f`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-17 13:26:47 UTC**.
Read the [0.1.31 release record](validation/Bello-Agent-0.1.31-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.30/build 34 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `c9ef75aac5d5c3c69a83d81ddd55ba4c8e4fa47e`
and website `a7ad6b2b89db03461667f734fdb26aa909c88fac`. The DMG measures **7,238,488 bytes (6.90 MiB)**,
SHA-256 `426f8613ddb5d60bfeec0a5b90cd8df51af0b3c2bbbfbc90625b9ce80815b9f3`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-17 11:19:04 UTC**.
Read the [0.1.30 release record](validation/Bello-Agent-0.1.30-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.29/build 33 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `40675e8b7952b146c816771011d2c3fc2e721bea`
and website `8cfe0b1e0174a73fee771e302d1fc90845d40a27`. The DMG measures **7,237,359 bytes (6.90 MiB)**,
SHA-256 `75712c3265011ef43d67c165dee308825ac7aa1c78ee9f01e9337bbcb12329ba`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-17 06:49:15 UTC**.
Read the [0.1.29 release record](validation/Bello-Agent-0.1.29-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.28/build 32 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `5c8d5141d80a808d6048d29441e898c49b2acf62`
and website `1198f1e1a41469313b8aa119e4aaea9d02b31b9a`. The DMG measures **7,230,232 bytes (6.90 MiB)**,
SHA-256 `ad09c1c2097925556da05a7324eae9aed118f98caa0b9d51831af6bd9ec37e6f`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-17 06:06:02 UTC**.
Read the [0.1.28 release record](validation/Bello-Agent-0.1.28-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.27/build 31 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `6e74ece51dae8780197b6430d2f8ce8963a02c63`
and website `1826ed0739decfd08a756602f26ea48b1c37618a`. The DMG measures **6,467,351 bytes (6.17 MiB)**,
SHA-256 `15122026b2dadfe0687dca482df9c40614dc79809a707aff169249f9254ee22c`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-17 05:13:27 UTC**.
Read the [0.1.27 release record](validation/Bello-Agent-0.1.27-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.26/build 30 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `f9c4edb8a16302cb8c5cb8c094af620f65d1d00a`
and website `332fa57ab023d20897b7f9856e3502737a867fa0`. The DMG measures **6,324,764 bytes (6.03 MiB)**,
SHA-256 `6bfaa63c54d53a42640f50b371e1488899d2aa250f7717289154a5e6f91f58ac`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-17 04:37:08 UTC**.
Read the [0.1.26 release record](validation/Bello-Agent-0.1.26-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.25/build 29 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `541b206b4c710fa081b77917569f40754effed95`
and website `74365cd67c84cb3c8b9ab86295c3a4fb4d37d4de`. The DMG measures **6,277,089 bytes (5.99 MiB)**,
SHA-256 `ace9b565cf8b2d3d3cf03d642eee3c9a63d5ebc95a8a445b0aca67fcc3d164a4`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-17 03:24:26 UTC**.
Read the [0.1.25 release record](validation/Bello-Agent-0.1.25-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.24/build 28 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `f5cd242345d315dd9a3997ce721112a031b30f86`
and website `679e9d4244a8f275694009f3b224b85c0b88833f`. The DMG measures **6,275,896 bytes (5.99 MiB)**,
SHA-256 `52ef5685de99b400ed31e10d420ed43ea8655843388df1f89a2bb802a908919a`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-17 03:15:07 UTC**.
Read the [0.1.24 release record](validation/Bello-Agent-0.1.24-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.23/build 27 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `9fe4cbc518bd1b3003aa11d0eb1e55d268d6fc95`
and website `9d3156f58a25b6f40ff90f7ff889bba9f50c4943`. The DMG measures **6,276,182 bytes (5.99 MiB)**,
SHA-256 `cd40536036a9b27a75624f4129ebf4df56790e87c02175951f3d9cc0d24e04a3`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-17 02:56:14 UTC**.
Read the [0.1.23 release record](validation/Bello-Agent-0.1.23-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.22/build 26 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `6e3cc97c50a9257e957339092f3339c14f741fd7`
and website `e899b8af4e08b3970576651c0699f0af6beca3d3`. The DMG measures **6,261,291 bytes (5.97 MiB)**,
SHA-256 `0efd10e77d7eeb5514113c18e19994fecfc04bc7bc97376c5c7ba6381d2b0eb5`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-17 02:12:26 UTC**.
Read the [0.1.22 release record](validation/Bello-Agent-0.1.22-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.21/build 25 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `6654428f9b4dfddaff2a470d9965d5be4e3d8877`
and website `7ac59ce6764510f0ef34cf095864f2e5616e9fd0`. The DMG measures **7,409,250 bytes (7.07 MiB)**,
SHA-256 `220b140c4b778963234ffe796684cbae08363807f4ea05effa5caa5cd7609e6d`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-17 01:41:55 UTC**.
Read the [0.1.21 release record](validation/Bello-Agent-0.1.21-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.20/build 24 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `26579aa049f15c99c9968a135b97e070c14f920b`
and website `4b67a23de568a6b711c80b283dc8b3acde3c75eb`. The DMG measures **7,326,425 bytes (6.99 MiB)**,
SHA-256 `868034b838c18b2303e1e6ab88638039a1f87e175aab2f6ea262f61172bf878c`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-16 21:06:29 UTC**.
Read the [0.1.20 release record](validation/Bello-Agent-0.1.20-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.19/build 23 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `9b94e4df711d66ed35b7168fbceca669009e368e`
and website `d37b88540c453ee808f930eb3bfe9525b8d01810`. The DMG measures **7,288,456 bytes (6.95 MiB)**,
SHA-256 `281e067d89759688af85390c0df5a37486b6a0620f76fe6ee6bb6e6e4bd3c0cf`. Signing/notarization, packaged-catalog/helper smoke,
public pages/icon, identical canonical/legacy feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: **2026-09-16 16:58:48 UTC**.
Read the [0.1.19 release record](validation/Bello-Agent-0.1.19-2026-09-17.md).
Installation/update rehearsals were skipped by owner instruction.

**394 unique native cases and 140 unique helper cases have a final
pass; 6 optional visual/interactive native captures were skipped.** The broad
native run had one failing case (two assertions); its corrected expectation and
affected behavior passed the 54-case focused rerun; the final nine-case export
and release-configuration check passed. The helper's full 138-case
suite passed, followed by 12 focused queue/recovery cases, including two new
regressions reproduced before the fix. Repeated cases are counted once.
**29 transcript tests, TypeScript checking and 10 dependency-cache tests pass.**
Four native tests exercise the packaged React page in WKWebView, including
render rejection and recovery. Local HTTP/SSE fixtures validate requests, tools,
cancellation, compaction and capture; no deployed LiteLLM was used. No full
screenshot gallery or Release performance matrix was run. Installation/update
rehearsals were skipped by owner instruction.

The [0.1.18 record](validation/Bello-Agent-0.1.18-2026-09-16.md) preserves
the preceding catalog release and its verified artifact evidence.

The [0.1.6 record](validation/Bello-Agent-0.1.6-2026-09-16.md) retains its verified
public artifacts and actual 0.1.5→0.1.6 Sparkle update, including the 75-file
installed-app comparison, history/draft retention and unchanged Keychain revision
0. Earlier [0.1.5](validation/Bello-Agent-0.1.5-2026-09-16.md) and
[0.1.4](validation/Bello-Agent-0.1.4-2026-09-16.md) evidence also remains historical.

New downloads contain `Bello Agent.app`. Bundle ID `com.belloware.PiApp`, Keychain
service/account, stored history paths and the Sparkle signing key are unchanged.
Sparkle 2.8.1 finds the renamed app by bundle ID and normally installs to the
existing host path. An older installation may therefore keep the filesystem
name `PiApp.app` after its first update, while its displayed product name and
contents are Bello Agent. Do not move or overwrite a user's installed app just
to change that filename; verify its actual bundle version and signature.

The native app ships the Swift helper, not the former approximately 184 MiB
Node/Pi distribution. Since 0.1.28 the app links SwiftTerm 1.19.0 (MIT) for
the terminal panel; its licence ships as `ThirdPartyNotices.txt` in the
bundle's Resources, next to Sparkle's own framework licence. Since 0.1.22 the release script strips the app and helper
binaries before signing (the symbol table was more than half of the app binary)
and keeps their dSYMs in the release directory for crash symbolication; nothing
else about the bundle changes, and dead-code stripping remains off. The 0.1.37 DMG measures **7,336,336 bytes (7.00 MiB)**, SHA-256
`19801f32ec462a9cba321629802db2ee4eecb2a07907377fbbe8ed3428577a06`.
The selected flat icon and its deterministic native resamples are included;
[provenance](../assets/branding/icon-0.1.6-prompt.md) preserves the exact master
and its opaque exterior margin. The earlier 2.94 MiB unsigned engineering image
is historical.
Publication enforces
the native **below 20 MiB** target and the existing static-host limit before any
website mutation. No external binary host is needed if this gate passes.

The owner selected Clipboard's ordinary macOS Keychain approach. Bello Agent does
not use restricted Data Protection/access-group entitlements and requires no
provisioning profile or Apple Developer browser sign-in for this flow. App
configuration and credentials stay in one Keychain item, with no plaintext
fallback. The earlier profile requirement was introduced by Pi App's stricter
access-group design; it was not required by the working sibling release process.
Standard Keychain policy does not promise same-user raw write/delete isolation.
The historical 0.1.6 isolated signed owner/update suite passed all 51 checks and
observations with synthetic items, without changing production vault data,
signing-key ACLs or persistent signing policy.

1. Set the next marketing/build version in `project.yml`, add release notes
   under `releases/`, and regenerate with XcodeGen 2.44.1.
2. Run checks affected by the changes using `docs/Swift-Test-Handoff.md`.
   Do not rerun the full matrix, screenshot gallery or signed synthetic
   owner/update rehearsal for every release. Reuse passing results when their
   source, dependencies and toolchain are unchanged. Keep fixtures separate
   from release assets and record which checks ran versus were reused.
3. Commit and push Bello Agent's intended source changes to its configured upstream.
4. The default download prefix is `https://belloware.com/assets/`. Run
   `PI_BUILD_ROOT=/scratch/path scripts/release.sh`.
   It signs nested Sparkle
   components, signs/notarizes/staples the app, creates/signs/notarizes/staples a
   DMG, generates the appcast, and verifies the signature with the public key.
   Missing notarization or signature failures stop the release; no unsigned
   or untimestamped fallback is publishable. Stale embedded profiles and restricted
   entitlements are rejected before signing/publication. Secrets are never command
   arguments or log output.
5. Validate against the previously published build with
   `scripts/validate-release.py FEED DMG APP --previous-build BUILD
   --download-url-prefix "${PI_DOWNLOAD_URL_PREFIX:-https://belloware.com/assets/}"`.
6. Run `PI_BUILD_ROOT=/scratch/path scripts/publish-release.sh VERSION`. It validates
   the signed app, feed and installer and preflights the website before writing.
   It stages `bello-agent.html`, the homepage product card, sitemap entry and the
   checked-in Bello Agent icon, with a compatibility redirect at `pi-app.html`.
   It publishes `BelloAgent-VERSION.dmg` and identical canonical/legacy feeds. For an explicitly selected external host it downloads
   and verifies the external binary against the local SHA-256 and Ed25519
   signature **before** committing the appcast. For the default static host,
   only validated native DMGs below 20 MiB are copied into `../belloware.com/assets/`. The feed
   always remains on belloware.com. Retain older DMGs as rollback installers.
   Stage only these release paths, commit, then push that repo's configured
   upstream. Stop if upstream/authentication is unavailable.
7. Run `scripts/verify-published.py /scratch/path/releases/VERSION /scratch/downloads
   --download-url-prefix "${PI_DOWNLOAD_URL_PREFIX:-https://belloware.com/assets/}"`.
   It downloads both public feeds and requires byte equality, then downloads the
   archive, compares SHA-256, and verifies
   Ed25519 against the application's public key. Git push success alone is
   not deployment verification; run again after deployment if the feed is stale.
8. Record the source/site commits and performed checks, including that install
   and update rehearsals were skipped by owner instruction. Finish once the
   published artifacts are verified; do not install the DMG or launch Sparkle
   to perform an update. Existing updater functionality remains enabled.

If the installer was already signed before its download host was known, set
`PI_DOWNLOAD_URL_PREFIX` and run
`PI_BUILD_ROOT=/scratch/path scripts/restage-appcast.sh VERSION`. This regenerates
and validates only the staged appcast against the unchanged notarized DMG. Upload
that DMG, then use the normal publication/verification steps above.

Set `NOTARY_KEY_PATH` to an existing approved App Store Connect API key file if
the sibling project's default location is unavailable. `SIGN_IDENTITY`,
`NOTARY_KEY_ID`, and `NOTARY_ISSUER_ID` can select another authorized account.
The Sparkle tool reads its signing key directly from Keychain (account
`ed25519`, service `https://sparkle-project.org`). Do not export it into source,
logs, or build artifacts.

Sparkle 2.8.1 uses archive Ed25519 signatures and HTTPS; later Sparkle features
such as signed-feed enforcement are not claimed. Protocol failures and host
work must not trigger an unattended app replacement. Automatic checking is
enabled, automatic installation is disabled, and relaunch is guarded by host
activity. Manual rollback requires quitting all hosts and installing an older
notarized DMG; future session schema migrations must define rollback support.

References: [Sparkle installation](https://sparkle-project.org/documentation/),
[publishing updates](https://sparkle-project.org/documentation/publishing/),
[Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
