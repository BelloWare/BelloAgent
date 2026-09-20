# Prompt for the next implementation agent

```text
Continue BelloWare/BelloAgent on main. Inspect the working tree and configured
upstream, preserving unrelated edits. Do not reset to the archived BelloWare/pi-app
repository or an earlier release.

Read docs/Implementation-Status.md first, then Features.md, Design.md,
docs/Swift-Feature-Parity.md, docs/Swift-Test-Handoff.md and
docs/Deep-Review-2026-09-19.md, docs/Performance-Review-2026-09-19.md and
docs/Concurrency-Review-2026-09-19.md and docs/TPS-Workers-Review-2026-09-19.md.
Read docs/Responsiveness-Review-2026-09-19.md.
Read docs/Session-Reference-Review-2026-09-19.md.
Read docs/Scrolling-Review-2026-09-19.md.
Read docs/Topics-Review-2026-09-19.md.
Read docs/Five-Session-Performance-Review-2026-09-19.md.
Read docs/Crash-Audit-Implementation-2026-09-20.md and
docs/validation/Bello-Agent-0.1.61-2026-09-20.md for the current crash-fix release
status. Do not use subagents unless explicitly requested in the current owner request.
Read the latest release record linked below. Current source and the latest
validation record take precedence over historical counts and chat claims.

Owner workflow change after 0.1.6: prioritize faster tests/releases. Do not run
fresh-install or Sparkle update/relaunch rehearsals (including the signed
owner/update rehearsal) unless the owner explicitly requests them again. Keep
signing, notarization and public feed/archive hash/signature checks. Select tests
for changed behavior; reuse passing checks for unchanged source/dependencies/
toolchain. Run independent suites in parallel, use stable incremental build
caches and isolated per-run fixtures, and avoid routine full-gallery/full-matrix
repeats. Follow the current test-selection policy in Swift-Test-Handoff.md.

Bello Agent 0.1.60/build 64 is publicly released at
[belloware.com](https://belloware.com/bello-agent.html), from source `ce252bcabe542efc58d87774f16bbe09b4a646d8`
and website `4ceb9e8773b605931d15eceaf04b0e4947f6f2c7`. The DMG measures **7,824,296 bytes (7.46 MiB)**,
SHA-256 `0cf92ca649e56a4293a404fa98a9d8fcbe547d2ee9a97222a04be124e1cc81c7`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-19 23:24:08 UTC**.
Read the [0.1.60 release record](validation/Bello-Agent-0.1.60-2026-09-19.md). Its
source and the subsequent performance work are already included on origin/main.

Bello Agent 0.1.59/build 63 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `f24e92d0649ceba066ad62e0a9ba439a0e07aacc`
and website `25f67c4a683c0927981df5940388b4f3f1759fa6`. The DMG measures **7,658,997 bytes (7.30 MiB)**,
SHA-256 `27f4680d1e1181880309f17250328f8b93c39cb6a7db09407e2fae9f01d668ab`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-19 09:00:47 UTC**.
Read the [0.1.59 release record](validation/Bello-Agent-0.1.59-2026-09-19.md).

Bello Agent 0.1.58/build 62 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `998411e757bddfe419d4afdd3e578f299689ad60`
and website `fa044232670ca60292baf2de3744526aed86f3ff`. The DMG measures **7,593,537 bytes (7.24 MiB)**,
SHA-256 `be36e9bbfe783c3463038fca6337ad19fc9808aa17334c28bd567fc7fafb979d`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-19 02:56:13 UTC**.
Read the [0.1.58 release record](validation/Bello-Agent-0.1.58-2026-09-19.md).

Bello Agent 0.1.57/build 61 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `dbbf3421a7143e606768659be8e688ba64d8ac59`
and website `eaaa9f647ff410dacc4126d3e370ea7249357264`. The DMG measures **7,538,829 bytes (7.19 MiB)**,
SHA-256 `f82811cec97b217385e2d58b9fb6a1ac62b3a6a8c8fa725e937a08afe00b5f3b`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-19 01:00:09 UTC**.
Cloudflare check **105810946636** succeeded.
Read the [0.1.57 release record](validation/Bello-Agent-0.1.57-2026-09-19.md) and
[five-session performance review](Five-Session-Performance-Review-2026-09-19.md). Source commits remain local;
the website publication commit was pushed. Installation/update rehearsals were
skipped under the standing owner policy.

Bello Agent 0.1.56/build 60 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `bb114ef07a69ef6e1cb33c60e733564e930a8a27`
and website `3fe37bb891f544f6ed464a1f82d9e60d4c7a1b08`. The DMG measures **7,478,445 bytes (7.13 MiB)**,
SHA-256 `e19097bbaaf6c2eaa3fcc69ba9db2d1427ffaf299f03761546266c2d57fd822b`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 23:34:17 UTC**.
Cloudflare check **105796177570** succeeded.
Read the [0.1.56 release record](validation/Bello-Agent-0.1.56-2026-09-19.md) and
[topics review](Topics-Review-2026-09-19.md). Source commits remain local;
the website publication commit was pushed. Installation/update rehearsals were
skipped under the standing owner policy.

Bello Agent 0.1.55/build 59 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `f42d237efe30c298523a47b62dd23c35fdda107e`
and website `5c1aec57e1c8e9a69ef44cbbd053715280db3e01`. The DMG measures **7,357,293 bytes (7.02 MiB)**,
SHA-256 `031ec071db485f796e9dc2e66c9b8b24f13da443778877db54a1f35d8f1955db`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 22:58:16 UTC**.
Cloudflare check **105788774388** succeeded.
Read the [0.1.55 release record](validation/Bello-Agent-0.1.55-2026-09-19.md) and
[scrolling review](Scrolling-Review-2026-09-19.md). Source commits remain local;
the website publication commit was pushed. Installation/update rehearsals were
skipped under the standing owner policy.

Bello Agent 0.1.54/build 58 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `49ed3c95e7fe53605bfb31b7ad8c0c8595ed0f4d`
and website `8170e23d0ef7b0f9284c37679aa4895108b679d0`. The DMG measures **7,335,665 bytes (7.00 MiB)**,
SHA-256 `f97d207d8f18ed7c0d2a12f7898d04b70463598c3067cce3590b2076e35b0a83`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 22:03:23 UTC**.
Cloudflare check **105776630049** succeeded.
Read the [0.1.54 release record](validation/Bello-Agent-0.1.54-2026-09-19.md) and
[session-reference review](Session-Reference-Review-2026-09-19.md). Source commits remain local;
the website publication commit was pushed. Installation/update rehearsals were
skipped under the standing owner policy.

Bello Agent 0.1.53/build 57 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `feb9df30c02c21e38ccb95d378ac619688062e49`
and website `5d43a239e2fdc8665e5782976ba8e3ec7c9cd352`. The DMG measures **7,329,401 bytes (6.99 MiB)**,
SHA-256 `6354391322a03c8bc408b8db57e2edddc0fa1eb15cdece0f68c29edd30ae9c24`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 21:30:15 UTC**.
Cloudflare check **105767983479** succeeded.
Read the [0.1.53 release record](validation/Bello-Agent-0.1.53-2026-09-19.md) and
[responsiveness review](Responsiveness-Review-2026-09-19.md). Source commits remain local;
the website publication commit was pushed. Installation/update rehearsals were
skipped under the standing owner policy.

Bello Agent 0.1.52/build 56 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `78e7b8f80a89e497978d915908f97b080a751512`
and website `f188c0db312da614df13b97a6f113b899b87932a`. The DMG measures **7,269,703 bytes (6.93 MiB)**,
SHA-256 `39037ef81f15ef1c3c28be59c1c142b258f5b967372df03ceec71cb534887c4a`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 20:13:40 UTC**.
Read the [0.1.52 release record](validation/Bello-Agent-0.1.52-2026-09-19.md)
and [throughput/worker review](TPS-Workers-Review-2026-09-19.md). Installation/update
rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.51/build 55 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `1eb8f9ea3b801aa50d380b5ae9627f337aa45189`
and website `fdcde0b40f8cc99d50bcc5ad2de74911912e33de`. The DMG measures **7,254,854 bytes (6.92 MiB)**,
SHA-256 `4674b23636b513802ebbca323bed9e02794f129936f2b851528fc95c30fa3e40`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 19:40:46 UTC**.
Read the [0.1.51 release record](validation/Bello-Agent-0.1.51-2026-09-19.md)
and [concurrency review](Concurrency-Review-2026-09-19.md). Installation/update
rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.50/build 54 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `0969ad030f769aadf1761d9e18869ca85130c031`
and website `178662a9abad8bd567553ed5f3dcf899d3f265b4`. The DMG measures **7,232,970 bytes (6.90 MiB)**,
SHA-256 `e3e5b43e042fa435a691819e6d30918c7915e7bd6298c3b5c8298f8c65e67e30`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 18:56:46 UTC**.
Read the [0.1.50 release record](validation/Bello-Agent-0.1.50-2026-09-19.md)
and [performance review](Performance-Review-2026-09-19.md). Installation/update
rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.49/build 53 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `b59a34a63bc4f174fddb2cd5c4ae5068ba6c834d`
and website `69520c61e62bc4e4b3152296ced8ebfbee6c72d8`. The DMG measures 7,222,143 bytes (6.89 MiB),
SHA-256 `e10cf9b7e2df730192801124b942e51138b92c269ebcb25e891c8d2628938aae`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-18 18:10:02 UTC.
Read the [0.1.49 release record](validation/Bello-Agent-0.1.49-2026-09-19.md)
and [deep review](Deep-Review-2026-09-19.md). Installation/update rehearsals
were skipped under the standing owner policy.

Bello Agent 0.1.48/build 52 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `c52a3d197553c32c7ef0e8dfa2230f16cff68066`
and website `67e1eb1414622f013abafc3e27f05462e9c64b93`. The DMG measures 7,203,566 bytes (6.87 MiB),
SHA-256 `5b74ee2fded4a7ca8305a157d85db95a979b842ee6ab66624d1f1b14af129bd4`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-18 17:12:05 UTC.
Read the [0.1.48 release record](validation/Bello-Agent-0.1.48-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.47/build 51 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `a093b4df18176df0df411d842475cbaff9efc43e`
and website `4580f6b23af1dafecd459cc47b96cfcbc1923781`. The DMG measures 7,186,673 bytes (6.85 MiB),
SHA-256 `8b718ddd7b93de0626328383f7344b1c078f1c81aebbae6980fe435219922f0f`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-18 16:14:07 UTC.
Read the [0.1.47 release record](validation/Bello-Agent-0.1.47-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.46/build 50 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `3fcb762c54d6dc8a4681b846a1b339d5d56ae6d8`
and website `def13c36778eefc98fb6d61ecd8959b71a3fb7b8`. The DMG measures 7,180,448 bytes (6.85 MiB),
SHA-256 `789fc8ab3a3b313b9d3e7c658e7e2f55394139cfd4c4559e73a0437347f0a259`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-18 15:20:46 UTC.
Read the [0.1.46 release record](validation/Bello-Agent-0.1.46-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.45/build 49 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `9af946daf435d696d0cab53ac402c21b70966912`
and website `d52e8ac9c8435cbac619812b54893764bdc12766`. The DMG measures 7,179,717 bytes (6.85 MiB),
SHA-256 `11d923809f4d6c4b7f524c280805372068b39ebe2f74e61d547db082f4082b0d`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-18 14:45:05 UTC.
Read the [0.1.45 release record](validation/Bello-Agent-0.1.45-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.44/build 48 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `a0cc15e3386cef9b6a044504191c72134a514f35`
and website `7199c735eb1ed977d187286b73b892f37dc538c4`. The DMG measures 7,160,116 bytes (6.83 MiB),
SHA-256 `4d890fc163a3df16e5e9aad37fc781bc969297f12e6a2ab105ecc547f3879337`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-18 13:25:46 UTC.
Read the [0.1.44 release record](validation/Bello-Agent-0.1.44-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.43/build 47 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `b3491f8c2fe62250896c918c9624d0f79a2991e3`
and website `8008e13ec2ce0bf447d1f4f80c58f12df760d7a4`. The DMG measures 7,161,822 bytes (6.83 MiB),
SHA-256 `f30b09b90f84f0ce25c72314352f74b4ad36f4f04ea5917656543e677f408ce1`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-18 13:13:16 UTC.
Read the [0.1.43 release record](validation/Bello-Agent-0.1.43-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.42/build 46 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `6b80619760c8328f9eb8a94e3f040cebfd82cc5c`
and website `1e57c83b90df30187a0e5d1943f29ee7225d425e`. The DMG measures 7,137,493 bytes (6.81 MiB),
SHA-256 `f3b8460af5c7ee378921ab8766fbf1cd8dade20921c995255c7b0b0874e0405c`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-18 11:35:50 UTC.
Read the [0.1.42 release record](validation/Bello-Agent-0.1.42-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.41/build 45 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `4bfa49e039c6206e12afbb4dac823af27620c9ef`
and website `a11fb2989b9839061d6bb24f82dbb8e80876b072`. The DMG measures 7,115,515 bytes (6.79 MiB),
SHA-256 `b9835306e36b9744258f1e50e41f5998c0438505d6676d6e01faea5c28bb58c4`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-18 10:33:48 UTC.
Read the [0.1.41 release record](validation/Bello-Agent-0.1.41-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.40/build 44 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `d2802278100ebaf6a414a0de139fc48a59cc7233`
and website `65730b4432a1d089df7804d9b92365a2ab638b60`. The DMG measures 7,113,393 bytes (6.78 MiB),
SHA-256 `b8e4036068f3e89eb7e462a7a44c4bb418e3c8f638e1b5d1204eb87833a03b4e`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-18 09:15:59 UTC.
Read the [0.1.40 release record](validation/Bello-Agent-0.1.40-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.39/build 43 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `a88bddbb4fbe0772bce8b182cf9116cda4309047`
and website `a7d2d22d809962d5f123d6c0b1cfbcb2a2bbf49b`. The DMG measures 7,149,724 bytes (6.82 MiB),
SHA-256 `1e93b8639cf4cd0ee12c20246f7ed331b929f1e925b62585ba2beab15de168f7`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-18 07:25:06 UTC.
Read the [0.1.39 release record](validation/Bello-Agent-0.1.39-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.38/build 42 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `bf04acfd3f41d2313d206052579091b94bf3966b`
and website `7538ca1ce73000bc1d11ec04989caa9625db2500`. The DMG measures 7,128,652 bytes (6.80 MiB),
SHA-256 `90ed4270a53955671d875cae58b946b27ac7f74b561525b6599298f79246150d`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-18 06:25:13 UTC.
Read the [0.1.38 release record](validation/Bello-Agent-0.1.38-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.37/build 41 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `f803d904f7c3963cc0fd170a652ba15d836ea319`
and website `4363262d41c79fb0fb2f2f6aa9162bfc4e0d18e1`. The DMG measures 7,336,336 bytes (7.00 MiB),
SHA-256 `19801f32ec462a9cba321629802db2ee4eecb2a07907377fbbe8ed3428577a06`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-18 01:57:55 UTC.
Read the [0.1.37 release record](validation/Bello-Agent-0.1.37-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.36/build 40 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `e1836b3bf5511a97e9cc9a6f9a7d48644106dfde`
and website `942d788b4591b182dd0638e182ed010aebac207c`. The DMG measures 7,328,637 bytes (6.99 MiB),
SHA-256 `d5ce235338331aa2f8fae3fc3ca8ae37bb14fe4bcc97862dbc86dbdcaee307fc`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-18 01:24:31 UTC.
Read the [0.1.36 release record](validation/Bello-Agent-0.1.36-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.35/build 39 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `2f1e33fa9b40f3100a1018d18054380c3723fb1d`
and website `c5ef318bc6e14f688627cb7002fab4b75617a514`. The DMG measures 7,283,236 bytes (6.95 MiB),
SHA-256 `b7d8d50d7196a36287a8642fd447411ded475c89e1415c0f8742565baf7974a4`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-17 17:16:54 UTC.
Read the [0.1.35 release record](validation/Bello-Agent-0.1.35-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.34/build 38 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `124b2f2fccb8d5648bbfeff7f49c5f94e62b9d12`
and website `1b8ef22a9a558aa37698c4dce74b7ac1d434f0d1`. The DMG measures 7,275,516 bytes (6.94 MiB),
SHA-256 `edd71cf3ede27bb773d68059542cd1bcc07fb8e6387d4053702dbd9edf3bce64`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-17 16:48:47 UTC.
Read the [0.1.34 release record](validation/Bello-Agent-0.1.34-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.33/build 37 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `e677cdd231584fcec89af3b15e3faa306b10fbee`
and website `f7d6e1a1dd828123d54f436709be201ea1dca78a`. The DMG measures 7,268,189 bytes (6.93 MiB),
SHA-256 `9348db4b6471c5ead40672783e5494a0c14e621e481041750d628f865bab4256`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-17 15:41:42 UTC.
Read the [0.1.33 release record](validation/Bello-Agent-0.1.33-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.32/build 36 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `094ea5c175e3f43c8e994aaf5e88121f1701683b`
and website `86ea696d6e7f5d57498943c34c7f7207e220d7dd`. The DMG measures 7,256,957 bytes (6.92 MiB),
SHA-256 `cdf95a723f37ede9d7f87d9993097d976f9b09cc422a92e251a4bbf122899c62`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-17 14:29:59 UTC.
Read the [0.1.32 release record](validation/Bello-Agent-0.1.32-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.31/build 35 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `3ba3c8a9cf99b14fe283efb23afd5789283cc466`
and website `fa1de3de210f6e0a1803015fe3875d8d61f00690`. The DMG measures 7,246,039 bytes (6.91 MiB),
SHA-256 `d4ed7f87eb93ef0703824e186f7771bcf566d6d8c84ccb1055d505ad4ce0b82f`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-17 13:26:47 UTC.
Read the [0.1.31 release record](validation/Bello-Agent-0.1.31-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.30/build 34 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `c9ef75aac5d5c3c69a83d81ddd55ba4c8e4fa47e`
and website `a7ad6b2b89db03461667f734fdb26aa909c88fac`. The DMG measures 7,238,488 bytes (6.90 MiB),
SHA-256 `426f8613ddb5d60bfeec0a5b90cd8df51af0b3c2bbbfbc90625b9ce80815b9f3`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-17 11:19:04 UTC.
Read the [0.1.30 release record](validation/Bello-Agent-0.1.30-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.29/build 33 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `40675e8b7952b146c816771011d2c3fc2e721bea`
and website `8cfe0b1e0174a73fee771e302d1fc90845d40a27`. The DMG measures 7,237,359 bytes (6.90 MiB),
SHA-256 `75712c3265011ef43d67c165dee308825ac7aa1c78ee9f01e9337bbcb12329ba`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-17 06:49:15 UTC.
Read the [0.1.29 release record](validation/Bello-Agent-0.1.29-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.28/build 32 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `5c8d5141d80a808d6048d29441e898c49b2acf62`
and website `1198f1e1a41469313b8aa119e4aaea9d02b31b9a`. The DMG measures 7,230,232 bytes (6.90 MiB),
SHA-256 `ad09c1c2097925556da05a7324eae9aed118f98caa0b9d51831af6bd9ec37e6f`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-17 06:06:02 UTC.
Read the [0.1.28 release record](validation/Bello-Agent-0.1.28-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.27/build 31 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `6e74ece51dae8780197b6430d2f8ce8963a02c63`
and website `1826ed0739decfd08a756602f26ea48b1c37618a`. The DMG measures 6,467,351 bytes (6.17 MiB),
SHA-256 `15122026b2dadfe0687dca482df9c40614dc79809a707aff169249f9254ee22c`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-17 05:13:27 UTC.
Read the [0.1.27 release record](validation/Bello-Agent-0.1.27-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.26/build 30 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `f9c4edb8a16302cb8c5cb8c094af620f65d1d00a`
and website `332fa57ab023d20897b7f9856e3502737a867fa0`. The DMG measures 6,324,764 bytes (6.03 MiB),
SHA-256 `6bfaa63c54d53a42640f50b371e1488899d2aa250f7717289154a5e6f91f58ac`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-17 04:37:08 UTC.
Read the [0.1.26 release record](validation/Bello-Agent-0.1.26-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.25/build 29 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `541b206b4c710fa081b77917569f40754effed95`
and website `74365cd67c84cb3c8b9ab86295c3a4fb4d37d4de`. The DMG measures 6,277,089 bytes (5.99 MiB),
SHA-256 `ace9b565cf8b2d3d3cf03d642eee3c9a63d5ebc95a8a445b0aca67fcc3d164a4`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-17 03:24:26 UTC.
Read the [0.1.25 release record](validation/Bello-Agent-0.1.25-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.24/build 28 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `f5cd242345d315dd9a3997ce721112a031b30f86`
and website `679e9d4244a8f275694009f3b224b85c0b88833f`. The DMG measures 6,275,896 bytes (5.99 MiB),
SHA-256 `52ef5685de99b400ed31e10d420ed43ea8655843388df1f89a2bb802a908919a`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-17 03:15:07 UTC.
Read the [0.1.24 release record](validation/Bello-Agent-0.1.24-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.23/build 27 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `9fe4cbc518bd1b3003aa11d0eb1e55d268d6fc95`
and website `9d3156f58a25b6f40ff90f7ff889bba9f50c4943`. The DMG measures 6,276,182 bytes (5.99 MiB),
SHA-256 `cd40536036a9b27a75624f4129ebf4df56790e87c02175951f3d9cc0d24e04a3`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-17 02:56:14 UTC.
Read the [0.1.23 release record](validation/Bello-Agent-0.1.23-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.22/build 26 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `6e3cc97c50a9257e957339092f3339c14f741fd7`
and website `e899b8af4e08b3970576651c0699f0af6beca3d3`. The DMG measures 6,261,291 bytes (5.97 MiB),
SHA-256 `0efd10e77d7eeb5514113c18e19994fecfc04bc7bc97376c5c7ba6381d2b0eb5`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-17 02:12:26 UTC.
Read the [0.1.22 release record](validation/Bello-Agent-0.1.22-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.21/build 25 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `6654428f9b4dfddaff2a470d9965d5be4e3d8877`
and website `7ac59ce6764510f0ef34cf095864f2e5616e9fd0`. The DMG measures 7,409,250 bytes (7.07 MiB),
SHA-256 `220b140c4b778963234ffe796684cbae08363807f4ea05effa5caa5cd7609e6d`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-17 01:41:55 UTC.
Read the [0.1.21 release record](validation/Bello-Agent-0.1.21-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.20/build 24 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `26579aa049f15c99c9968a135b97e070c14f920b`
and website `4b67a23de568a6b711c80b283dc8b3acde3c75eb`. The DMG measures 7,326,425 bytes (6.99 MiB),
SHA-256 `868034b838c18b2303e1e6ab88638039a1f87e175aab2f6ea262f61172bf878c`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: 2026-09-16 21:06:29 UTC.
Read the [0.1.20 release record](validation/Bello-Agent-0.1.20-2026-09-17.md).
Installation/update rehearsals were skipped under the standing owner policy.

Bello Agent 0.1.19/build 23 is a historical verified release at
[belloware.com](https://belloware.com/bello-agent.html), from source `9b94e4df711d66ed35b7168fbceca669009e368e`
and website `d37b88540c453ee808f930eb3bfe9525b8d01810`. The DMG measures 7,288,456 bytes (6.95 MiB),
SHA-256 `281e067d89759688af85390c0df5a37486b6a0620f76fe6ee6bb6e6e4bd3c0cf`. Signing/notarization, packaged-catalog/helper smoke,
public pages/icon, identical canonical/legacy feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: 2026-09-16 16:58:48 UTC.
Read the [0.1.19 release record](validation/Bello-Agent-0.1.19-2026-09-17.md).
Installation/update rehearsals were skipped by owner instruction.

Version 0.1.48 fixes the crash the owner reported in 0.1.47 and hardens
the app after it. The transcript page drove SwiftUI's scroll proxy from an
AppKit frame-change notification that fired while the hosting scroll view
was still mid-update, which trapped the app; every scroll the page lands is
now deferred to the next run-loop turn. Settings can be saved while a
connection's chats are working: the helper's new `session.configure` command
hands the saved profile and key to open sessions, a run that is going keeps
the settings it started with and switches when it ends, and an idle chat
takes them at once, so nothing is closed or blocked. Editing an earlier
message no longer re-anchors the page on every frame of the composer's
resize, and the slash-completion popup no longer forces a composer
re-render per keystroke. A code audit for the same classes of failure fixed
a host pipe deadlock (the stdout reader waited on the command queue while
a stdin write could block on a full pipe), a stale handshake watchdog that
could kill a later healthy host, a delayed terminal SIGKILL that could reach
a recycled pid, a `precondition` in the terminal, force unwraps on archive
rows that would trap on a damaged database, and AppKit calls made from
inside SwiftUI updates in the captured-JSON outline, the paged text view,
the page-visibility background and the session usage window.
See the [0.1.48 release record](validation/Bello-Agent-0.1.48-2026-09-18.md).

Version 0.1.47 changes three things the owner asked for. Retry request
now sends the chat's current model and reasoning effort: the app passes the
pills as they stand to `turn.retry`, and the helper builds the retried
request from them (cleared pills retry with the connection's defaults), so a
model switched after a failure is what retries. The output budget is
metadata only: it is never sent as `max_output_tokens` and never fails a
turn. A conversation request carries the model's catalog ceiling as its
output limit, clipped to the room the context estimate leaves in the window,
or no limit when the catalog gives none; the connection test, chat titles
and compaction summaries keep their own small caps. The budget only sizes
the reserve that decides when a chat compacts, and a request whose input
fits the window is always sent. The Usage menu's model distribution keeps
its layout with very long model ids: axis labels and the per-model rows are
cut in the middle, and the bars and figures keep their columns.
See the [0.1.47 release record](validation/Bello-Agent-0.1.47-2026-09-18.md).

Version 0.1.46 fixes the retry the owner found wrong: Retry request re-ran
the failed turn with the connection's default model and effort, because the
helper cleared the turn's submission (which carries the chat's model,
reasoning effort and budgets) when the run ended, and the retried run built
its request from the bare profile. The helper now keeps the failed or
stopped turn's submission and restores it for the retry, so the retried
request uses the same model, effort and budgets as the request that failed
and completes the same command receipt.
See the [0.1.46 release record](validation/Bello-Agent-0.1.46-2026-09-18.md).

Version 0.1.45 walks the first-run and everyday paths after the owner
asked for a smooth, self-explaining experience. Gateway failures are worded
for the reader by the helper: the provider's own detail first, then the
likely cause with what to check (the API key for 401/403, the base URL and
alias for 404, a rate limit for 429, the gateway for 5xx, the final URL for
redirects; an unknown host, an unreachable gateway, a timeout or an
untrusted certificate for transport failures), keeping the
"Provider returned HTTP N." prefix the retry policy and the connection test
read. Onboarding explains a disabled Continue (the URL, its scheme, the
key), greets a returning user whose connection is saved, and names the last
step "Start your first chat" once a project is ready. The welcome screen
offers New Chat once a project and a connection exist. The test request in
Settings, removing a project and typing a model alias for a chat are
confirmed or entered in place, in the sheet or popover already open, so no
flow runs a system alert from a sheet. Two run failures the owner met are
gone: a reply the model cuts at the output budget is a complete row with
`stopReason` "length" and a warning under it, the turn ends idle and queued
follow-ups go on (before, the run failed with "Response reached its output
limit"); and the helper's HTTP stream buffers without limit, so a consumer
busy journaling or notifying the app never loses a chunk to a fixed buffer
(before, a 128-part buffer cancelled the stream with "Consumer could not
keep up"), with `stream_backpressure` retried like a transport failure
should it ever occur. A run that failed or was stopped can be retried from
its failure row: "Retry request" sends the turn again from where it stopped
(helper command `turn.retry`), the partial reply stays but is not replayed,
and queued follow-ups go on after the turn.
See the [0.1.45 release record](validation/Bello-Agent-0.1.45-2026-09-18.md).

Version 0.1.44 removes the cap on live chats at the owner's request. The
project helper kept at most three chat runtimes loaded per project, unloaded
an idle one to make room and refused a fourth with "Three runtimes are active
or pinned by side chats; close or keep a side first" when every loaded chat
was busy or pinned by a side. `HostService.ensureCapacity` and its three
call sites (opening a chat, opening a side, forking a side) are gone: every
opened chat and side stays loaded for as long as the app holds it open, and
nothing is unloaded to make room. The app's handling of a `session.unloaded`
event stays for older helpers.
See the [0.1.44 release record](validation/Bello-Agent-0.1.44-2026-09-18.md).

Version 0.1.43 reworks the connection flow in Settings after the owner
found it off in every step. The sheet's state moved into
`ConnectionSettingsController`, so it could be driven by a test the way a
person drives it. A new connection lists models before it is saved: the API
key now sits right under the base URL, the included Bello catalog lists
without a key, and a gateway's own catalog lists with the key typed above
(or the saved one), relisting when the base URL or catalog URL changes and
saying why when it cannot list; before, the picker was disabled until the
connection was saved and its list ignored edited URLs. Each tab keeps its
own draft, so switching tabs no longer discards edits; a dot marks unsaved
edits, Save writes every edited tab (the current one last), and Discard
drops an unsaved one. Saves use the vault's current revision rather than
the sheet's snapshot and retry once after a conflict, so a write made
elsewhere while Settings was open no longer fails the save quietly; a save
that fails keeps its edits on their tab with the reason in red.
See the [0.1.43 release record](validation/Bello-Agent-0.1.43-2026-09-18.md).

Version 0.1.42 fixes the connection deletion the owner reported as
doing nothing. Editing a connection's API route saves a new connection and
keeps the old one for its chats, recording the new one as the old route's
model-catalog source (`catalogSources`); deleting either one then left a
link to a missing connection, the vault's validation refused the save, and
the reason appeared only in the sheet's small status line, so the three
tabs stayed. `deleteProfile` now drops every catalog link of the deleted
connection inside the same vault update, reads the vault back and treats a
connection still listed as an error, reloads once when the list on screen is
older than the vault, and logs each outcome to the system log (subsystem
`com.belloware.PiApp`, category `vault`); the Settings footer reports a
failed deletion in red and the window's banner repeats it. Saving a
connection whose route changed keeps Settings open and explains that a new
tab appeared and why the old one stays.
See the [0.1.42 release record](validation/Bello-Agent-0.1.42-2026-09-18.md).

Version 0.1.41 changes two things at the owner's request. Delete
Connection works from the Settings footer itself: the button asks in place
(no modal alert to miss), the question says what the deletion touches (the
key leaves the Keychain item, which chats keep their history and will need
another connection, how many runs will stop), and a run still going under
the connection is stopped and its helper session closed instead of the
deletion being refused; a vault revision conflict is retried once after a
reload, and the footer then says that the connection was deleted, or why it
was not. Motion, now that the whole app is native: one set of tokens
(`PiMotion`, honouring Reduce Motion through `piAnimation`) drives a
selection highlight that glides between sidebar rows, panes that cross over
when the chat changes, tab strips that slide their selected pill, sheet
badges that pop in, an empty chat's card that builds up line by line, title
suggestions that arrive one after another, tool rows whose glyph bounces
once as the call completes, footer figures that roll, unread dots that pop
and a terminal that springs open. Nothing animates while a reply streams.
See the [0.1.41 release record](validation/Bello-Agent-0.1.41-2026-09-18.md).

Version 0.1.40 changes four things at the owner's request. Opening a
saved chat shows the question that started its last turn: a page that
began inside a reply's rows (what a short chat with many tool calls looks
like through the sixty-row window) pulls earlier pages until the user
message leads, and an idle chat whose last turn is taller than the window
opens with that question at the top rather than at the bottom; a working
chat, a remembered reading position and sending all behave as before.
Connections can be deleted from Settings after a confirmation (their chats
keep their history and ask for another connection; a chat still working or
a side not yet kept refuses the deletion), and renaming one keeps its id,
key, chats and model cache, which the settings row now says. Chat titles are
read leniently, as models actually answer: the first usable line without
labels, bullets, numbering, quotes, emphasis or a trailing period; a failed
request says why in the chat's footer and the window's banner, and Generate
Title in the chat's menu asks again. Performance across the app: the terminal
takes program output about six times faster (printable runs print in one
pass over the row, character widths are cached, the history trims in
batches and the parser's hot state skips exclusivity checks), a streaming
reply parses only the part still changing (the text is cut where a delta
can no longer change how the parts parse and settled parts are remembered),
and every Markdown run is dressed once instead of three times.
See the [0.1.40 release record](validation/Bello-Agent-0.1.40-2026-09-18.md).

Version 0.1.39 changes six things at the owner's request. Text no longer
jumps while a reply streams: the page scrolls once per change, after the
AppKit document has taken SwiftUI's new height, and nothing animates during
a live turn; and every row is laid out exactly rather than lazily, so rows
in view (and their buttons) stay put while a reply streams below them. A reply reads in
the order things happened: what the model did comes first, under a small
header naming the work with the chevron that folds it (reasoning, one row
per tool call, the figures of each request), then the reply text, then the
turn line. A run that fails while its chat is not in front marks the chat
in the sidebar (a red dot when nothing new arrived) without bouncing the
Dock or counting in its badge; opening the chat clears the mark. Archived
chats are read-only until restored: sending, steering, editing, queue
resume and commands other than Stop are refused with a notice, the composer
gives way to a Restore footer, archiving a running chat stops it, and
archived chats never count in the Dock badge. Project chat lists fold back
with Show less. A chat's action menu can ask the mini model for a title
again, replacing an edited one, and a title request that fails says why in
the chat's footer.
See the [0.1.39 release record](validation/Bello-Agent-0.1.39-2026-09-18.md).

Version 0.1.38 makes the whole application native and leaves Sparkle as
its only third-party code. The conversation page is SwiftUI
(`apps/macos/PiApp/Transcript`): `TranscriptActivity` groups rows into
replies and turns and sums their usage, `TranscriptMarkdown` turns
Foundation's Markdown parse into blocks, `SyntaxHighlighter` colours code
with its own scanners, `TranscriptCopy` finds section and code copy targets
in the source, `TranscriptRows` draws the rows, and `TranscriptPage`
owns scrolling (the reader's own scrolls decide whether the page follows,
programmatic scrolls never do), anchors across chat switches and earlier
pages, fresh-row motion and read receipts. The WKWebView, React,
react-markdown, remark-gfm, highlight.js, esbuild, TypeScript, the old
TypeScript host and Node itself are gone from the build and the bundle.
The terminal panel is the app's own emulator (`apps/macos/PiApp/Terminal`):
a pty-owning process runner, an xterm-style VT parser over a cell grid with
scrollback, alternate screen, scroll regions, tab stops, DEC line drawing,
16/256/true colour, bracketed paste and the replies programs ask for, and a
CoreText view with keys, input methods, selection, copy, paste and wheel
scrollback; SwiftTerm and its swift-argument-parser dependency are gone.
Three behaviours changed at the owner's request: tool call rows and
per-request figures stay in view after a turn (the chevron folds them),
the working bar follows the session's run state rather than only a
streaming row, so it stays up from send to settle including between
requests, and any number of projects and chats can be active at once (the
concurrent-projects setting and its eviction are gone).
See the [0.1.38 release record](validation/Bello-Agent-0.1.38-2026-09-18.md).

Version 0.1.37 removes the system title bar from every window. A strip
of the app's own chrome (`PiWindowBar`) replaces it: it drags the window,
zooms on a double click, hides the system title while keeping `.titled` for
native key handling and the traffic lights, and leaves the leading room
those buttons need. The Session info window's header and the Settings
window use it; sheets have no title bar to replace and are untouched, and
the window title still names the window in the Window menu. The dashboard
reads more quietly: a tile carries a small tinted glyph instead of a filled
badge, its value is 20pt semibold, and its caption reserves two lines so a
row of tiles keeps one height; sheet headers use a soft tinted icon and a
17pt title. Session info opens larger so its Models table and request
charts are both in view.
See the [0.1.37 release record](validation/Bello-Agent-0.1.37-2026-09-18.md).

Version 0.1.36 splits usage per model wherever a scope can mix routes.
Session info shows one Models table in place of two distribution lists:
for each requested route and the model that served it, requests and cost
with their share of the session, tokens, the route's own duration-weighted
output rate and its nearest-rank first-token median, so a fast model and a
slow one never blend; the header tiles say "per model below" when a session
used more than one route. The usage report gains a By model view with the
same columns for the filtered window, share bars of that window, and an
Output tok/s tile beside Time to first token; clicking a route narrows the
report to its alias and model. The gallery now captures the Session info
window and the By model view.
See the [0.1.36 release record](validation/Bello-Agent-0.1.36-2026-09-18.md).

Version 0.1.35 is a visual and motion pass with no loss of detail. A user
message is a soft tint with no outline; a settled turn closes with a hairline
and one quiet line of figures instead of a filled band, and that line wraps
between its dots in a narrow side pane instead of clipping; the composer,
cards and the live bar sit on a hairline with a short, soft shadow; footer
metric icons are tertiary so the figures read first. Motion follows one
language defined as tokens (one ease for state changes, a longer ease-out
for arrivals; 140, 220 and 320 ms): every hover, fold, chevron and arrival
uses them, a settled turn warms its hairline for a moment rather than
flashing a fill, and Reduce Motion turns off every transition as well as
every animation. The turn line is flowing text with the chevron as the
toggle, so a narrow pane wraps between figures. The cursor follows intent:
a new chat, a selected chat, an opened side, a side closed back to its
parent and an edited message all focus the right composer; plain typing
after a click on the transcript or a sidebar row goes to the composer,
while text fields, the terminal and shortcuts are untouched, and Escape
leaves the chat filter for the composer. Narrow panes shorten instead of
clipping: composer pills fall back to icons before the send button would
be pushed off, the metrics footer drops rows it cannot fit, sidebar rows
drop token and recency figures, and the empty-chat buttons wrap.
See the [0.1.35 release record](validation/Bello-Agent-0.1.35-2026-09-18.md).

Version 0.1.34 makes the transcript's work lines outcome-aware: a file
counts once however many times it was read or edited, a directory listing is
not a file read, failed or skipped calls are reported as attempts rather than
as work done, and verbs follow the call's state (Editing, Edited, Failed
editing, Skipped editing). MCP calls name their action (listed servers,
loaded tool schemas, called a tool). Edit previews are labelled as the
requested change and marked not applied when the call failed or was skipped;
an overwrite shows its requested content plainly and only a confirmed new
file reads as added lines. The helper stamps every row with its turn id and
each reply with the measured duration of its model request, journaled with
the row; the transcript groups replies by that id, so a compaction, a retry
notice or a failure mid-run no longer splits a turn, a turn that began before
the loaded history says so, and model time is measured rather than inferred
from row gaps. The turn line counts files changed. An expanded work line
keeps a stable key while its reply streams in and stays open; the reply line
no longer repeats the live bar's spinner and current action; the model link
is the toggle's sibling rather than its child; reasoning inside an expanded
line starts folded and unfolds with the same motion; a live reply's line
eases in once it has work to report.
See the [0.1.34 release record](validation/Bello-Agent-0.1.34-2026-09-18.md).

Version 0.1.33 gives a settled one-reply turn a single line, labelled
Turn, carrying the reply's work, its duration, the model-versus-tool split,
the turn's usage and cost, and the model; multi-reply turns keep a line per
reply plus the turn line. The turn line's hover timestamp no longer wraps an
empty band under the text. Conversations pace by turn: more room before
each user message, less between a message and its reply. Code blocks name
their language beside the copy control on hover, user bubbles wrap at the
same readable width as reply prose, and the empty composer's placeholder
carries the keyboard hints and leaves as typing starts. Motion is brief:
new rows slide in, a finished turn glows for under a second, details unfold,
the live bar breathes and names when the turn started, copies confirm with a
pop, the terminal slides up and sidebar chats fade in and out, all off under
Reduce Motion. The sidebar loses its app name and icon (New Chat joins
the Projects row); the Bello mark sits on the empty-chat card and pulses
while a chat is being prepared.
See the [0.1.33 release record](validation/Bello-Agent-0.1.33-2026-09-17.md).

Version 0.1.32 removes the conversation header. While a turn runs a live
bar docks above the composer with a spinner, the elapsed time counting up,
the action under way, any retry in progress, the replies, tool calls, tokens
and cost so far, and Stop; it settles back into the flow as the turn line.
Changes, Session info and the chat's action menu live in the composer bar,
an empty chat shows a starter card (project folders, connection, model, tool
mode and quick actions), and side panes say in plain words what they share.
Sidebar rows show cost, one token figure with the split on hover, a recency
stamp, a spinner while running and their archive control only on hover. A
live reply lists its last three actions inline and shows the first sentence
of exposed reasoning; edit and write calls expand to real diffs; prose is
capped near 80 characters a line; user bubbles and settled turn lines show
their times on hover; the model sits on the reply line before the chevron.
Reports and Session info name coverage only where it is partial, and an
unreported final model is a quiet dash.
See the [0.1.32 release record](validation/Bello-Agent-0.1.32-2026-09-17.md).

Version 0.1.31 puts a reply's figures on its own line: what it did, how
long it took, its tokens, cost and model (a link to the request), with
reasoning, tool call rows and each request's full accounting folded behind
the chevron. The turn line, under the last reply of every turn including
single-reply turns, is a plain summary with nothing to expand: time, replies
and tool calls, model versus tool time, input tokens split into cached and
uncached, output tokens with the reasoning share, and cost, each with
coverage when not every request reported. Session info is one scrolling page:
first-token time and speed first, then requests, tokens and cost, the
per-request charts, a bar stacking cached input, uncached input and output,
the token and cache cards, and the cost and model distributions. Settings
shows every saved connection as a tab with the count beside them, and a new
connection opens in its own tab until it is saved.
See the [0.1.31 release record](validation/Bello-Agent-0.1.31-2026-09-17.md).

Version 0.1.30 makes the turn line the one place for a turn's figures:
its time, replies and tool calls, model-versus-tool split, summed tokens and
reported cost, with coverage shown when not every request reported. Clicking
the line lists each request's usage with its model and a Details action, so
replies no longer repeat their accounting under themselves, and the "Did"
label is gone from the reply's work line. A spinner turns while a reply is
being worked on, while a turn is live (it also counts up every second) and
while a failed request is being retried; the retry notice names the attempt.
See the [0.1.30 release record](validation/Bello-Agent-0.1.30-2026-09-17.md).

Version 0.1.29 moves errors into the conversation: a failed run appears
as a card where the conversation stopped, a refused send as a card under the
messages, and while the helper retries a transient failure a status line
says so. The helper now tries a model request up to three times before
reporting it: transport failures, HTTP 408/425/429/5xx and provider errors
describing overload, rate limits or temporary unavailability are retried
one and three seconds apart, a partial reply from the failed attempt is
dropped, request errors fail at once, and the report names the attempt
count. Conversations load earlier pages as the reader scrolls up, merging
live updates underneath; switching to an unloaded chat shows its newest page
rather than a page around an old reading position, and up to eight hidden
chats keep their pages. A new chat or an empty side is created only by its
first message; empty ones disappear when the user moves on and a rename or
archive writes the record first. The app has one window, so the menu bar item
and the Dock bring it forward instead of opening a duplicate; the sidebar
opens 300 points wide. Turn totals sit under every turn's last reply and
count up while the turn is live; a reply's own line only names its work.
See the [0.1.29 release record](validation/Bello-Agent-0.1.29-2026-09-17.md).

Version 0.1.28 lets the chats of one project run at the same time: the helper
no longer holds a workspace-wide lease for a whole run, so a message sent to a
second chat starts immediately while the first is still answering; only
editing tool calls (write, edit, bash, MCP invoke) take turns on the
workspace gate. The Changes sheet becomes an IntelliJ-style git tool: a
branch menu that switches or creates branches, fetch, pull (fast-forward) and
push with ahead/behind counters, stash and pop, per-file and per-section
checkboxes so Commit takes the checked files, Amend that prefills HEAD's
message, Discard with a confirmation, a unified or side-by-side diff, history
filtered by message, hash prefix or author across all branches with branch
and tag badges, and per-file diffs inside a commit. A terminal panel (⌃`)
opens under the chat with one login shell per project that survives hiding.
Opening a chat focuses the composer; double-clicking a chat opens a rename
sheet with mini-model title suggestions; every chat row has an archive button
that asks once inline; projects list five chats with a "Show more" row. The
Session usage window becomes Session info, with tiles for the latest and
median first-token time, latest and average output rate, and the session's
model and tool time with the last turn's split; and when a turn spans several
replies the transcript adds the whole turn's time, counts and model/tool
split under the last reply.
See the [0.1.28 release record](validation/Bello-Agent-0.1.28-2026-09-17.md).

Version 0.1.27 adds a Changes sheet that runs the system git for a
project's folders: branch, upstream and ahead/behind, staged and unstaged
files with status badges, a rendered unified diff with hunk headers, old/new
line numbers and tinted rows, stage and unstage per file or all, a commit box,
and the commit history with each commit's message, files and diff. Reads never
touch the index; stage, unstage and commit are the only writes. It opens from
the project header, the conversation header and ⇧⌘G. Chat titles require a
mini model again: without a chosen or catalog mini model the app says so once
per connection and launch and the chat keeps its first-message title. Sidebar
cost and token totals load through one grouped archive query instead of one
query per chat.
See the [0.1.27 release record](validation/Bello-Agent-0.1.27-2026-09-17.md).

Version 0.1.26 makes pending follow-ups editable: they can be dragged to
reorder, rewritten in place, promoted to steering so they reach the current
run after its tool batch, or removed, with the helper validating and
persisting each change. A chat can have several side conversations; the pane
shows one at a time at exactly half the content width, opening another side
swaps the pane, and clicking a saved child chat in the sidebar shows it there.
The sidebar's width is dragged on its hairline and remembered. Chat titles are
generated again when no mini model is configured, using the chat's own model,
saved side chats get titles too, and a failed title task releases its claim so
the next message retries. The session usage window gains a Timing tab with
per-request charts for time to first token, output tokens per second, output
tokens and reported cost. The context ring waits 1.5 seconds after the last
keystroke before recounting a draft, and a reply that has not produced a
token yet shows three pulsing dots instead of a bare caret.
See the [0.1.26 release record](validation/Bello-Agent-0.1.26-2026-09-17.md).

Version 0.1.25 refreshes custom model catalogs lazily every five minutes
instead of every hour, so a changed catalog reaches the model picker sooner.
Loading stays lazy and per connection, a failed fetch still backs off for
thirty seconds, and explicit Refresh still reloads immediately.
See the [0.1.25 release record](validation/Bello-Agent-0.1.25-2026-09-17.md).

Version 0.1.24 moves each reply's work line to its bottom. Every assistant
reply ends with how long it took, what it did and the model-versus-tool
split, and expanding that line shows the reasoning and tool calls that
produced the reply; a turn no longer shares one toggle at its top, so a long
reply is read first and its work is at hand where reading ends. Work a turn
ended on without prose forms a trailing line of its own. The Dock badge
counts chats with unread replies, one per chat, matching the sidebar dot.
Accounting lines show only what the gateway reported: an unreported model,
usage or cost is left out, and a message with nothing reported has no line.
See the [0.1.24 release record](validation/Bello-Agent-0.1.24-2026-09-17.md).

Version 0.1.23 lets a chat move between saved LiteLLM connections. Bello
Agent already stored several connections (endpoint, key, headers, model
catalog) and bound each chat to one at creation; the composer now shows a
connection pill beside the model and effort pills once more than one
Responses connection is saved. Switching is refused while the chat is working
and for imported history, connection tests, background tasks and side
conversations; otherwise it closes the open helper session, rebinds the chat,
keeps a model override only when the new connection's catalog lists it,
re-derives limits and effort, and the next turn reopens on the new endpoint
and key with the portable history replayed there. The switch is not
remembered as a model choice for new chats, but the switched chat's
connection becomes the next-chat default while it is selected. Sidebar rows
name each chat's connection when several are saved.
See the [0.1.23 release record](validation/Bello-Agent-0.1.23-2026-09-17.md).

Version 0.1.22 ships stripped binaries and folds exposed reasoning with the
tool calls. The release script now strips the app and helper executables
before signing, so the signature and notarization cover the stripped files,
and keeps both dSYMs in the release directory for crash symbolication; the
symbol table had been more than half of the app binary. The stripped app
binary measures 6,144,448 bytes (down from 14,216,720) and the helper 1,297,008 bytes (down from 1,908,368). Dead-code stripping and
optimisation settings are unchanged. In the transcript, a turn's header now
reads "Reasoned", "Read 1 file" or "Reasoned, read 1 file", and exposed
reasoning stays folded behind it with the tool calls until the user expands
it; a reply with no prose folds away entirely while the turn is collapsed.
See the [0.1.22 release record](validation/Bello-Agent-0.1.22-2026-09-17.md).

Version 0.1.21 folds tool calls behind each turn's header by default; the
header names the work and, while live, the current action, expanding lists the
calls, and only clicking a call shows its request and response. The status bar
panel is one page: a "Now" list of running, waiting and unread chats that open
on click, period tabs, token and cost tiles, a chart switching between
requests, reported cost and historical output tok/s per time slice, and a model
distribution bar chart; the Activity tab and its live output-rate estimate are
removed. The colour scheme is flat: no gradients or corner wash, solid
brand-orange fills for primary controls and badges, and a darker accent for
text that reads at 4.5:1 on cream. A reply becomes unread, on the Dock badge and
the sidebar dot, only after the run has finished and reported back. Archiving a
chat keeps the sidebar on active chats and moves on to the nearest active chat.
While a run is in progress the context ring holds its last settled count
instead of flickering through pending and per-request estimates.
See the [0.1.21 release record](validation/Bello-Agent-0.1.21-2026-09-17.md).

Version 0.1.20 adopts the Codex-style activity presentation for tool calls
and simplifies the sidebar and project flow. The transcript groups each user
message with its reply as a turn whose header reports how long it worked and
how that time split between the model and tools; consecutive tool calls fold
into one collapsed activity line that expands to verb-and-object rows with
status, duration, line counts and a command/output card, and tool-result rows
fold into their call. The helper stamps message clocks, tool durations and file
edit line counts and persists the model/tool split with the session. Sidebar
chats mark unread replies with a dot instead of a count and list cost with
input, cached-input and output tokens. Projects open and are created without a
trust confirmation; the Trusted badge and "Editing tools · Trusted project"
notice are removed while read-only and tool-less notices remain. The footer
shows the session's model-versus-tool time with the last turn in its details.
See the [0.1.20 release record](validation/Bello-Agent-0.1.20-2026-09-17.md).

Version 0.1.19 completes a deeper review of Claude's recent changes and the
Settings-to-existing-chat catalog flow. It fixes clock-correction write loss,
quit and side recovery failures, non-atomic handoffs, false transcript paint/read
acknowledgements, command replay after ledger eviction and duplicated queued
messages after a partial journal commit. Response capture masks known credential
echoes across streaming boundaries and labels that transformation. Archive
maintenance avoids repeated whole-store sweeps; partial cache observations keep
paired sample coverage. Existing catalog lineage and explicit repair remain.
Unavailable live-export bodies cannot be misrepresented as empty captured files.
See the [review and remaining limits](Deep-Review-2026-09-17.md).

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

Historical Bello Agent 0.1.18/build 22 is publicly released at
[belloware.com](https://belloware.com/bello-agent.html), from source `29e2da5569165df79572218b490b3b63f8685bc9`
and website `69c6862688c6baf6d33220593f5f59246a7554e1`. The DMG measures 7,230,028 bytes (6.90 MiB),
SHA-256 `cd8374400c12f508fa8b0f1b653a90c5660dc4756a147306203609f3cb728629`. Signing/notarization, packaged-catalog/helper smoke,
public pages/icon, identical canonical/legacy feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: 2026-09-16 15:46:54 UTC.
Read the [0.1.18 release record](validation/Bello-Agent-0.1.18-2026-09-16.md).
Installation/update rehearsals were skipped by owner instruction.

Version 0.1.18 makes stale catalog sources visible in older unbound chats.
The model picker offers a direct Use this catalog action for one later saved
custom list on the same gateway, or a chooser for multiple alternatives. The
selected source loads immediately and persists across restart. Repair preserves
the request connection, credentials, selected model, reasoning effort, output
budget and history. Explicit source bindings remain authoritative.

The originally reported fresh-save alias/catalog flow was already handled
by inheritCatalog and covered by an integration test. The remaining gap was
older records without catalog lineage: Refresh correctly reloaded their old
source but gave no prominent repair path. Suggestions now use later saved
same-base/API records with a different custom URL, independently of profileChoice.
No independent connections are silently merged. See the
[issue resolution](Issue-Stale-Chat-Model-Catalog.md).

**67 focused native tests passed**, with 0 skips and
zero unresolved failures. Counts come from the actual test log, with repeated
cases counted once. Coverage includes the original save/inherit flow, legacy
repair and restart, distinct/multiple sources, explicit-binding preservation,
refresh source routing and the mounted picker's visible banner/replacement rows.
The mounted-view check invokes the action shared by the button; it does not
claim a physical mouse click. Unchanged helper/context/capture and transcript/
TypeScript evidence is reused from 0.1.17 and its referenced earlier records.
No live deployed gateway or full screenshot gallery was run. Installation/update
rehearsals were skipped by owner instruction.

Historical Bello Agent 0.1.17/build 21 is publicly released at
[belloware.com](https://belloware.com/bello-agent.html), from source `bbe02ecce0da172bbbcdf8304a663ff29d033269`
and website `2cb0c457f52b522ef13c1e21c291fe7e151bfb69`. The DMG measures 7,215,669 bytes (6.88 MiB),
SHA-256 `63cbbf327f44fd5e8fbdedab420e96ff32d17591c56a094d045e1c6c775248d1`. Signing/notarization, packaged-catalog/helper smoke,
public pages/icon, identical canonical/legacy feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: 2026-09-16 15:31:21 UTC.
Read the [0.1.17 release record](validation/Bello-Agent-0.1.17-2026-09-16.md).
Installation/update rehearsals were skipped by owner instruction.

Version 0.1.17 uses one request-aware context count for the ring, inspector,
preflight and compaction. It counts the actual provider-built instructions,
tools and replayed input. Gateway-reported input is reused only for a matching
prefix and an explicitly pinned, reported model; previous output is not added
wholesale. Counts carry method, request fingerprint, model and uncertainty.
Safe idle tabs and draft edits refresh through a shared debounce/cache; pending
counts do not display stale conversation totals. Output budgets are separate
from catalog model ceilings, with a distinct safety margin. Reported usage,
request context and estimated live output activity remain separate measurements.

These remain estimates, not exact tokenizer results or independently
verified billing usage. No remote counting endpoint is enabled: the reviewed
LiteLLM interfaces do not establish complete Responses request compatibility
and a route-bound counted model. Automatic routing and opaque/image costs retain
explicit uncertainty. See [Context-Accounting.md](Context-Accounting.md).

**129 unique native tests and 132 unique helper tests have a final
observed pass.** Initial broad runs did not pass: one native case and three
helper cases failed. The corrected focused reruns passed (36 native, seven
capacity and 11 request-context cases), followed by 21 passing final helper
context/gateway/capacity cases. Every initial failing case has a later pass;
repeated executions are counted once. Coverage includes debounced/stale context,
output-budget migration, replay/baseline invalidation, image uncertainty and a
request-validating loopback gateway with exact request/response capture.
The unchanged transcript/WebKit/TypeScript evidence is reused from 0.1.16.
No live deployed gateway, remote token counter, screenshot gallery or physical
UI interaction is claimed. Installation/update rehearsals were skipped by owner
instruction.

Historical Bello Agent 0.1.16/build 20 is publicly released at
[belloware.com](https://belloware.com/bello-agent.html), from source `f680fc8cc4ac77a7efdd007cc319ced2bedf319f`
and website `d501b2a2f5f7c3100a53a0805b6295f311a0f1fc`. The DMG measures 7,167,470 bytes (6.84 MiB),
SHA-256 `33335dc999e633db7e395ae688daddb0044dfea53c143052a8d46bbf0bba4cbb`. Signing/notarization, packaged-catalog/helper smoke,
public pages/icon, identical canonical/legacy feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: 2026-09-16 14:59:06 UTC.
Read the [0.1.16 release record](validation/Bello-Agent-0.1.16-2026-09-16.md).
Installation/update rehearsals were skipped by owner instruction.

Version 0.1.16 keeps tool calls and results collapsed until their disclosure
is opened, including running tools; manual expansion survives streaming updates.
Chat timing shows the latest completed request's TPS and the weighted session
average together, including narrow layouts, with history and coverage on hover.
Failed responses show Error with a visible, retained, credential-sanitized message;
paused/cancelled work stays distinct and pending messages never retry implicitly.
Stop now sits in the chat input for main and side conversations. Background title
jobs, which have no input, keep Stop in their lower task footer.

**74 unique focused native tests passed**, with
1 optional capture skip and zero failures. The initial native run executed
75 cases (74 passed, one skipped); the final Stop run rebuilt the app and repeated
five follow-up cases. Repeated cases are counted once. **115 unique helper tests,
27 transcript tests and 9 WebKit disclosure checks passed**; TypeScript passed.
Loopback HTTP 429/SSE failure fixtures verify useful errors, credential masking,
no automatic retry and exact captured bytes. Native coverage includes retained
errors, weighted timing and actual wide/narrow footer rendering with OCR.
No manual Stop click, screenshot gallery or full interactive gateway run is claimed.
Installation/update rehearsals were skipped by owner instruction.

Historical Bello Agent 0.1.15/build 19 is publicly released at
[belloware.com](https://belloware.com/bello-agent.html), from source `65061de7440755b7f328fb4706d45e2ec5c5fc91`
and website `dd6f206fa24c2210f3f0d380c6e8d4f73ec04bce`. The DMG measures 7,137,895 bytes (6.81 MiB),
SHA-256 `cbe8d87022dd1455ea241fdd6b4b5b59b59b72c865d9c4f00c597ffd2768ef0f`. Signing/notarization, packaged-catalog/helper smoke,
public pages/icon, identical canonical/legacy feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: 2026-09-16 14:27:04 UTC.
Read the [0.1.15 release record](validation/Bello-Agent-0.1.15-2026-09-16.md).
Installation/update rehearsals were skipped by owner instruction.

Version 0.1.15 fixes New Project losing its primary folder immediately after
selection. The form now reads live draft state and publishes the primary/extra
folder change atomically. Changing the primary preserves unrelated extra
folders; an outgoing cancelled pane cannot reopen its draft. Additional projects
can be created after onboarding without replacing the first project.

**27 focused native tests passed with zero failures in 0.714 seconds**:
Workspace 17, ProjectSidebar 6 and ReleaseConfiguration 4. Three new regressions
cover live folder-selection state, cancellation/reopening and second-project
persistence with a fresh vault readback. These are state/integration checks;
physical NSOpenPanel interaction was not exercised. Unchanged context/catalog,
provider/transcript/capture evidence is reused from 0.1.14 and earlier records.
Installation/update rehearsals were skipped by owner instruction.

Historical Bello Agent 0.1.14/build 18 is publicly released at
[belloware.com](https://belloware.com/bello-agent.html), from source `2542f31b3992fa1011008c0f317917eb2fcea105`
and website `d4ba4e3411d17a6bc0d1f8a11cb04bcd43a85781`. The DMG measures 7,135,182 bytes (6.80 MiB),
SHA-256 `d7d6a198f26f87a7d044b206ab38009843c1d40b4cb70290142e42f708b380a2`. Signing/notarization, packaged-catalog/helper smoke,
public pages/icon, identical canonical/legacy feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: 2026-09-16 14:00:20 UTC.
Read the [0.1.14 release record](validation/Bello-Agent-0.1.14-2026-09-16.md).
Installation/update rehearsals were skipped by owner instruction.

Version 0.1.14 calculates prepared context automatically when a safe idle
chat opens, using the local helper without sending a model request or executing
tools. Matching estimates are reused; cancelled or changed inputs cannot publish
stale results. Unsent chats retain their allocated journal across helper eviction.

Catalog lists now resolve independently of preserved request connections.
New same-authority default-model forks keep catalog linkage; older chats can
choose a saved custom catalog through **Catalog source…** in the model picker.
Refresh reloads saved bindings, requests HTTP revalidation and displays its
successful update time. Changing the list preserves the chat's request route,
credentials, selected model and effort. Legacy lookalike connections are not
automatically merged because their records contain no reliable lineage.

**98 unique focused native tests passed with zero failures.** The catalog/
configuration run passed 71 cases in 9.523 seconds; the final context/workspace
run passed 34 cases in 2.144 seconds, including seven repeated catalog-source
cases with strengthened credential assertions. Counts are not added twice.
The packaged-helper fixture verifies automatic calculation, no model request,
no message/queue changes, durable unsent journal paths and unchanged bytes after
helper reopening. Local catalogs verify refresh, metadata and credential scope.
Unchanged provider/transcript/capture evidence is reused from 0.1.13 and earlier
records. Installation/update rehearsals were skipped; the owner will test on
their own MacBook.

Historical Bello Agent 0.1.13/build 17 is publicly released from source a06287bcf21873a0757dfdeb3e55b5aa9a366b1f
and website cd28c3c4c630da9eec014acf5db8bb1dd1ffea17. Installer: 7,118,570 bytes (6.79 MiB),
SHA-256 4906755a2befbb89ff58cc85b032ac66517f33ff7d1faf6e3d1db015ec114228. Signing/notarization, packaged smoke and public
pages/icon/feed/archive verification pass at 2026-09-16 12:57:46 UTC.
Read the 0.1.13 record. Installation/update rehearsals were skipped.

Version 0.1.13 fixes chat catalog Refresh by reloading the saved connection
before fetching, using the same path as Settings. Chat TTFT and TPS show the
same latest completed request and retain it while a new request runs. Hover
shows native history charts; clicking keeps them open. Charts cover up to 128
recent completed requests in that session/project, with gaps for missing
measurements. Usage-window/menu-bar historical averages remain independent.
0.1.14 supersedes the original same-profile-only catalog lookup: keep request
routes unchanged while resolving the separately saved catalogSources binding.
Only explicit source selection or a known same-authority default-model fork
establishes linkage; never guess lineage from similar old profiles. Do not
modify the chat's selected model/effort when its catalog changes.
Keep credential-origin rules and custom-source failure isolation. Chat footer
timings use the latest completed retained request, both values from one record;
no older non-missing rate replaces a missing value. Hover charts use bounded
typed metrics, not HTTP bodies or inherited parent/fork requests. Historical
weighted rates in usage windows and the menu bar retain their separate meaning.

Historical Bello Agent 0.1.12/build 16 is publicly released from source 5bf9a8240df955725e05bfdcbc4b355a5d267cbf
and website 9154d3fa8c81520025737ac44baab0a5b021b01e. Installer: 6,989,644 bytes (6.67 MiB),
SHA-256 16e7798b04abbe7ce73647844bf9a2b3a8bb4f042b0af792680920d87903748c. Signing/notarization, packaged smoke and public
pages/icon/feed/archive verification pass at 2026-09-16 11:52:59 UTC.
Read the 0.1.12 record. Installation/update rehearsals were skipped.

Version 0.1.12 adds Combined JSON for Responses streams, retaining the terminal
response object or an explicitly partial reconstruction. Events, UTF-8/hex,
original-byte exports and capture-state labels remain. Session usage opens in
reusable resizable native windows with tokens, response/prompt caching, reported
and reasoning cost, historical TPS and model/cost distributions. Windows retain
their session scope across chat changes and stop reads when closed.
Treat Combined JSON as a derived view. Never replace retained stream bytes or
hashes with reconstructed JSON. Preserve canonical terminal objects, partial
notices and explicit raw-copy labels. Usage windows are scoped per owner/project/
session, reuse header/footer actions, and cancel polls/subscriptions on close or
owner shutdown. Response-cache rate excludes unreported/conflicting observations;
prompt-cache tokens alone never imply a response-cache hit.

Historical Bello Agent 0.1.11/build 15 is publicly released from source bca8f816a9fe5959ad1d2a08e6ed077495c8ff2e
and website 0264f7a5b331d2655bd6bde478178fe1ab145a17. The installer measures 6,937,176 bytes (6.62 MiB),
SHA-256 e1058f581bb1ac809fd217ffbe64c3a888c601ef5a0e0739470d84adce907e4b. Signing/notarization, packaged smoke,
public pages/icon and feed/archive hash/signature verification pass at 2026-09-16 10:44:00 UTC.
Read the 0.1.11 record. No install/update or signed owner/update rehearsal was run.

Version 0.1.11 simplifies reply footers to one response-body model, with
header/body evidence on click. Captured SSE responses now open as expandable
JSON event trees with original framing and bytes preserved. Calculated context
previews update the footer, with stale-input/activity/reopen guards; unloaded
context offers “Inspect context” without an automatic model request.
Keep one response-body model inline (router_model_name before model), with
header reports and strict identity/replay diagnostics in click-through details.
Do not turn an alias echo into verified upstream identity or restore an inline
model-conflict badge. Model projection version 6 backfills sourced metadata in
bounded batches and expires it with metrics. Keep SSE frame order, raw bytes,
non-JSON/unfinished data and exact export; the outline is a derived view only.
Prepared context estimates are input/configuration/sequence-bound and discarded
on helper reopening. Preserve the shared footer/inspector counts. The 0.1.14 automatic preview on safe idle tab selection supersedes the older inspector-only loading policy.

Historical Bello Agent 0.1.10/build 14 is publicly released from source d1908dc978e6652f62eb04d2aec1dc6858d4dca2
and website b93433bb28172179ce9e7d3b1c52295ba3029b94. The installer measures 6,901,746 bytes (6.58 MiB),
SHA-256 92ca6ffb4d09e84a6f78f8ec592bd0d21e27504b1f15af522e1a0af015b9fa49. Signing/notarization, packaged catalog/helper smoke,
public pages/icon, identical feeds and downloaded archive SHA-256/Ed25519 checks
pass. Public verification: 2026-09-16 10:03:51 UTC. Read the 0.1.10 record.

The 0.1.9 catalog fix missed the default path: it only used a catalog when a URL
was saved, and did not package catalogs/bello-agent.models.json. 0.1.10 includes
that file and uses its six rich entries for nil/blank catalog settings, including
existing profiles. Do not reinstate implicit /v1/models discovery or read a key
to list bundled models. Custom catalogs replace the bundle and remain the sole
source even on failure. Keep aliases/efforts/defaults already selected by users.
The bundled catalog has no mini:true recommendation; explicit mini selection is
independent and must not auto-enable title calls merely because the app upgraded.

Historical Bello Agent 0.1.9/build 13 is publicly released from source e3940fe61ff03af2a58b083d632a56b3f1b5329c
and website 856b71140ccbc20adfc1074e8275b1190d32c9e2. The installer measures 6,902,731 bytes (6.58 MiB),
SHA-256 bf115a54a31210cf683949433eb0f8450e56637bc1354fba7925a91d56869bbc. Signing/notarization, local smoke checks, public pages/icon,
identical feeds and downloaded archive SHA-256/Ed25519 verification pass.
Public verification: 2026-09-16 08:17:28 UTC. Read the 0.1.9 record for
focused test scope, corrected failures and remaining limits. No install/update
or signed owner/update rehearsal was run.

Keep the current session model/cost breakdown, historical TPS and Usage-first
status panel. Activity lists running work; sidebar unread state remains.
Captured JSON is expandable by default and complete retained responses load
without manual body pagination. Assistant status uses actual gateway model
reports, preferring a body name inline and keeping others on click. The composer uses a searchable live catalog popover. Mini-model title
jobs remain fixed-title retained background sessions with separate accounting,
manual-title protection, durable claim/no automatic retry and explicit reveal.
Chat/report headers begin at the window top beside the native window controls;
do not restore a blank full-width title row or the detail child's safe-area gap.

Historical Bello Agent 0.1.8/build 12 is publicly released from source
3880709162722ba5d7e4bd3d1715aa396f2bef85 and website 956a86317892a47b5ced402eb8a30aad5e086552. The installer measures
6,691,444 bytes (6.38 MiB), SHA-256 dca53c6d618c6bb56e8d499d1e8c748327182d617792129fe46b031f991c070b.
App/DMG signing and notarization, local smoke checks, public pages/icon, identical
update feeds and downloaded archive SHA-256/Ed25519 verification pass.
Public verification UTC: 2026-09-16 07:09:31 UTC. No install/update or signed owner/update
rehearsal was run. Read the 0.1.8 record for exact scope and evidence.
Implementation 50818b3 replaces the covering native title strip with a custom
36-point content row. The 0.1.9 layout supersedes its full-width row: keep WindowGroup.hiddenTitleBar,
full-size content and detail-child top safe-area handling consistent. Native
traffic lights, header dragging and available-screen double-click zoom remain.

Historical Bello Agent 0.1.7/build 11 is publicly released with signed/notarized app and DMG.
Source bd6a5559fa5d52a647f997d9084cf9fbd7001c18 and website
90ffc8fd821aa17789c85f2cf49cdf50d06518b3 are pushed. The installer measures
6,688,314 bytes (6.38 MiB), SHA-256
00e284caa89b62eec2d1e6246f029e0ceeef20dc1982610bc918f8151e0a3c96.
Local smoke checks, public product/home/legacy pages, exact icon bytes and
identical canonical/legacy feeds pass. The downloaded archive matches its
SHA-256 and Ed25519 signature. Public verification completed at 06:36:37 UTC.
No install/update or signed owner/update rehearsal was performed.
Read the 0.1.7 record for exact scope and evidence. Claude's final turn ended
at 2026-09-16T06:23:50.945Z with no child work; its 0b3c255 dashboard changes
were reviewed and preserved, retaining all conflicting gateway model names.

Historical Bello Agent 0.1.6/build 10 was publicly released from source 30fc4b4
and website d92957c. Its notarization, public artifacts and actual 0.1.5→0.1.6
Sparkle update passed, with all 75 installed files/links matching. History,
drafts and unchanged Keychain revision 0 remained. One empty draft changed JSON
key order only; all journal bytes and other retained state were unchanged.
This installation evidence is historical and does not establish an installation
rehearsal for 0.1.7 or 0.1.8. Do not repeat it without a new explicit owner request.

Historical Bello Agent 0.1.5/build 9 was publicly released from source 3460390 and website
51d81cf. App/DMG notarization, public page/feed/archive verification and an actual
0.1.4→0.1.5 Sparkle update pass. The 5,283,041-byte (5.04 MiB) installer and all
75 installed files/links match; five historical chats and Keychain revision 0
remain intact. Its source/native acceptance included the final updater
edit-draft and composer update-loop regressions. Read the 0.1.5 record for exact
hashes, commands and scope; do not repeat completed release work without new
source changes or a concrete concern.

Historical Bello Agent 0.1.4/build 8 was publicly released from source 16b5152 and website
75c4090. Signing/notarization, public page/feed/archive verification and an actual
0.1.3→0.1.4 Sparkle update pass. The 5,044,519-byte (4.81 MiB) installer and all 75
installed files/symlinks match; historical chats and Keychain access remain intact.
Read the 0.1.4 validation record for exact hashes, checks and limits. The 0.1.3
record is historical. Do not repeat completed release work without a new change
or concrete concern.

Keep SwiftUI/AppKit composers, the native SwiftUI transcript selected in 0.1.38,
and the self-contained Swift helper. React, WKWebView and Node are no longer in
the build; the retired Pi v0.85.1 host is an explicit behavioral reference. Preserve bundle ID com.belloware.PiApp,
Keychain service/account, stored history and existing Sparkle signing key.
The exact selected bello-agent-flat-01-soft.png is now the icon master at
assets/branding/bello-agent-icon.png, SHA-256
7d0dfb6361abd2da309b414cbbeddc6b5e39a336aa89f80bf11561f655a6779e.
Keep its RGB artwork and pale opaque exterior margin. Native sizes are
deterministic resamples; the discarded checkerboard transparency derivative was
not used. Preserve assets/branding/icon-0.1.6-prompt.md as source provenance.

Preserve the current owner requirements:
- Active requests use Responses only. Historical Messages profiles, credentials,
  journals and captures remain readable. Conversion creates a new Responses
  connection explicitly; never rewrite an endpoint or silently substitute APIs.
- Transcript rows omit visible speaker names. Each attempt has one inline
  accounting owner, moving from user input to its assistant response. User
  Details retains linked requests; tool rows do not duplicate accounting.
- Preserve requested aliases and resolved models, cache-write tokens, reasoning
  tokens and reported reasoning cost. Reasoning is a subset of output. Final
  JSON headers can supply cost when body usage.cost is null; preliminary SSE
  headers are not final billing. Never invent prices, treat unknown as zero or
  add reasoning/classifier components to the reported total.
- Test & Start sends one small selected-model request using scoped vault
  credentials and the normal helper/capture path. It has no tools, history,
  skills or workspace instructions, a bounded output budget, timeout and cancel.
  Empty/error/stale/cancelled results cannot complete setup or create a probe chat.
- The persistent native status item opens on either mouse button. Usage is
  first, with historical output TPS and requested/resolved model distribution.
  Activity shows running work, without a byte-derived output estimate;
  omit unread/waiting/paused sessions from this panel. Keep sidebar unread.
  Historical TPS divides reported output by summed dispatch-to-completion
  timing for valid completed samples, even without visible text; show coverage.
  Keep the actual latest completed rate stable during a new run; a newer completed
  request without usage shows unavailable instead of reusing an older sample.
  Session header/cost controls open scoped model/cost shares with truthful nulls.
- Durable unread state baselines old history and reconciles offline journals.
  Clear only when the latest completed reply is actually visible in a foreground
  chat, or by explicit Mark as Read. Report/background/scrollback cannot clear
  it; stale receipts cannot clear newer output. Preserve bounded quit/install flush.
- Capture request/response bodies and headers by default, retaining plaintext
  bodies for 30 days subject to quota; show retained bodies directly without a
  reveal step. Default valid JSON to an expandable native tree and load complete
  retained responses without manual body pagination. Preserve original-byte
  export, raw text/hex and partial/expired/omitted labels. Preserve ordinary headers. Longer request authentication tokens
  retain only a masked final-four-character suffix; short tokens, cookies,
  response authentication and credential echoes are fully masked. Configured
  custom credential headers must not leak full values. Known credential literals
  in request bodies remain labeled SHA-256 transformations; wire bytes are
  unchanged. Preserve legacy encrypted reads and their existing key. Raw HTTP
  capture is never replaced with normalized events. Full-text body search stays
  deferred.
- Capture-policy migration preserves explicit session overrides and
  distinguishable custom/off choices. The old off/unaccepted/7-day/default-quota
  tuple adopts persistence. Every legacy seven-day value becomes 30 days because
  the old format cannot distinguish default from explicit seven-day retention;
  other custom retention is preserved. New-policy deliberate choices stay intact.
  Owner-authorized defaults require no enable/reveal confirmation. Keep explicit
  export and destructive purge actions.
- Credentials/configuration remain in ONE ordinary macOS Keychain item following
  Clipboard, with scoped private helper IPC and no plaintext/per-profile fallback.
  The Data Protection/access-group and ~/.bello-agent proposals were superseded.
  Standard Keychain does not guarantee raw same-user write/delete isolation.
- Preserve native report navigation, drafts/focus/undo/WKWebView identity,
  compact layouts, collapsed filters, session grouping, linked-message actions,
  stale-query guards and Reduce Motion. Show all projects in persistent expandable
  groups while preserving internal workspace IDs, paths and host ownership.
  Rename/pin/archive/restore cannot discard work/history; stale unrelated saves
  cannot revert organization. Cost updates without focus changes, including
  unloaded sessions, and running rows keep the latest completed reported output speed stable. Omit
  gateway/API/model-ID/editing title badges.
- `/side` with Enter opens an empty durable child immediately, without sending.
  Closing its pane preserves context, history, draft, running work and the child
  relationship across restart. `/fork` makes an independent journal with the
  same complete active context and provider/tool/reasoning state, without queued
  work or an automatic request. Preserve selected model/effort/capacity settings,
  read-only side tools, explicit bring-back and complete-boundary behavior.
- The context ring opens a bounded read-only provider-built request preview,
  never a reconstruction claimed as past wire capture. Skill toggles live only
  in Bello Agent configuration and do not change Codex/shared files or bypass
  original skill policies. Copy code blocks and Markdown sections as original
  source. Reserve native traffic lights only above the sidebar; chat/report
  headers begin beside them at the top, with no blank full-width strip. Preserve
  dragging and double-click available-screen zoom/restore. Test the actual SwiftUI WindowGroup,
  not only a manually constructed NSWindow.
- Composer, Settings and onboarding default to the bundled Bello catalog when
  catalogUrl is nil/blank. Package the exact reviewed catalog resource and verify
  it in the built app. No gateway discovery or credential lookup for this path.
  A saved custom URL replaces the bundle; cache remote lists for one hour and
  refresh lazily on picker access. Retain only that source's last list plus error
  on failure; never fall back to the bundle or gateway. Keep credentials on the
  gateway's same origin; external catalogs remain anonymous.
- Requests disable LiteLLM fallbacks by default. Only the connection's explicit
  Allow fallback models setting permits them. Keep requested and final models
  together in Usage Report, with unreported identity explicit.
- Settings has one Save action and closes only on success. Compare editable
  form values against the loaded baseline so preferences-only saves preserve
  untouched active and legacy Messages connections. Invalid edited fields,
  including cleared URLs, remain available for correction without partial saves.
- Settings Test Connection saves first and sends to its own persisted,
  tools-disabled No project chat. It requires no project, retains the native
  composer and cannot send into another chat after selection changes. Scratch
  sessions cannot enable editing tools or open sides. The onboarding probe
  remains a separate bounded path that creates no chat or probe journal.
- Compaction progress stays above the composer. Show successful summaries from
  authoritative active context, including fast/background completion; failed or
  cancelled compaction cannot reuse an earlier success. Archived chats may be
  explicitly deleted only while idle and after closing open parent/child sides.
- A separate selected/catalog-recommended mini model can generate an automatic
  title. Keep one atomically claimed, tools-disabled, resource-isolated retained
  task session per source, with a fixed title and independent capture/cost.
  Hide these sessions by default and allow explicit reveal. Preserve manual
  renames, the 80-character title bound and persistent failure notices. No
  implicit main-model fallback or automatic retry after restart.
- Keep trusted roots, atomic edit recovery, explicit skills, queued/steered
  turns and human-only MCP unknown-outcome acknowledgement. No automatic retry
  of model or tool work.

Current 0.1.13 acceptance:
**108 focused native tests passed with zero failures in 13.773 seconds**:
GatewayAccounting 19, LiveAccounting 5, MenuBarMetrics 21, ModelCatalogEndpoint
19, ModelSwitch 15, ReleaseConfiguration 4, SessionTiming 9, SessionUsage 10,
SettingsSave 6.
Synthetic native fixtures cover picker rendering and timing charts. The release
record preserves the corrected Swift test-helper isolation error and explains
why an inactive-window mouse harness does not establish a physical click or
end-to-end hover test. Unchanged helper/provider, transcript and capture evidence
is reused from 0.1.12. No installation/update rehearsal was run.

Historical 0.1.12 acceptance:
**89 focused native tests passed with zero failures in 4.716 seconds**:
CapturedBody 14, CombinedResponse 21, MenuBarMetrics 21, MessageDetail 9,
SessionUsage 10 and Workspace 14. Five synthetic own-window views were inspected.
Helper/provider, transcript, catalog and storage evidence is reused from 0.1.11
and earlier records because those sources are unchanged. No deployed gateway,
full gallery, installation/update or signed owner/update rehearsal was run.

Historical 0.1.11 acceptance: 103 unique native cases pass after the focused
viewer readiness correction. CapturedBody 13/1.012s and ContextAndSkillPolicy
8/0.236s passed in the final 21-case rerun. Other suites and the two original
fixture failures remain in the release record. Helper ContextPreview 4/0.085s,
transcript 25 and TypeScript pass. Two native viewer JPEGs were inspected.
Unchanged 0.1.10 evidence is reused; install/update rehearsals remain skipped.

Historical 0.1.10 acceptance: 60 native cases passed, zero failures, in 6.899s:
ModelCatalogEndpoint 18/5.365s, ModelSwitch 11/0.243s, Onboarding 18/0.684s,
SettingsSave 6/0.169s, TitleGeneration 7/0.439s. Three own-window picker JPEGs
were visually inspected and OCR-checked. Actual
bundle metadata, legacy/blank defaults with no network/credential read, custom
source/credential/cancellation behavior and remembered choices are covered.
The unchanged helper/transcript/broader evidence below is reused, not rerun.
No install/update or signed owner/update rehearsal was performed.

Historical 0.1.9 focused acceptance: 155 unique native tests pass after focused
corrections/reruns; helper 17 pass/0.494s, transcript 24 pass/0.811s and TypeScript.
ModelCatalogEndpoint's 14 cases pass in 4.124 seconds in native-picker-final.log. The fixture's inaccessible test-process accessibility tree was replaced with local Vision OCR over actual rendered window pixels, checking catalog names/aliases, wrong-source exclusion, source-change errors and removal of stale choices. Both picker JPEGs were inspected.
The eight WindowPresentation/ReportNavigation cases pass in native-ui-rerun.log. That 22-case run also included the catalog check, which was corrected and passed in its separate final 14-case rerun; repeated cases are not added to the unique total.
TitleGeneration 7 includes the actual packaged helper and a validating loopback
gateway. CapturedBody 9, MessageDetail 7 and PayloadArchive 13 pass. The 100k-attempt
Debug accounting fixture measured page 555.924ms, session 56.682ms and single
message 59.201ms. Preserve the initial assertion/compile failures in the 0.1.9
record; no full gallery, deployed gateway or install/update rehearsal is claimed.

Historical 0.1.8 focused acceptance: eight unique tests pass, WindowPresentation 5
and ReportNavigation 3 (5.409s). The five window tests passed again (2.756s)
after optional capture-only readiness changes. Light chat, compact dark chat
and light report JPEGs were inspected; header geometry and content are clear.
Initial test-only Reduce Motion injection failed compilation and was removed;
no test assertions failed. No new full gallery/provider/performance acceptance
or install/update rehearsal was run. Keep reused results explicitly historical.

Historical 0.1.7 focused native acceptance: 81 unique tests pass. The first group
passed GatewayModelDiscovery 9/1.051s, ModelCatalogEndpoint 12/1.112s,
ProjectSidebar 6/0.179s and Workspace 14/0.341s. The final group passed
ModelSwitch 11/0.468s, Dashboard 14/1.088s and MenuBarMetrics 15/0.524s.
An initial restart fixture held the prior instance's archive lock; closing it
retained all original assertions and made them pass. Reuse unchanged helper,
wire, process, transcript and broader native/gallery evidence below. No new
full/gallery/interactive/install/update rehearsal is claimed; preserve limits.

Historical 0.1.6 source acceptance: helper 105 passed/5.179s; optimized wire
24 passed/5.339s; process/MCP two passed/2.599s; Python 52 passed/17.046s;
transcript 21 passed/0.933s plus TypeScript; full native 247 executed = 246 passed
+ one interactive opt-in skip, zero failures/91.525s. That total includes the
gallery: one passed/75.464s and 30 light/dark images, including the packaged
onboarding probe. The isolated signed synthetic Keychain owner/update suite
passed all 51 checks/observations. Native regressions cover Settings saves,
scratch composer/tools and selection-safe tests, side restrictions, child
archive deletion and compaction notices. Helper tests cover successful, failed,
cancelled and abandoned-branch compaction summaries. Initial fixture failures
and their corrections remain documented; the final suites pass.

Historical 0.1.5 source acceptance: helper 101/4.905s; optimized wire 24/5.160s;
process/MCP 2/2.576s; Python 52/16.967s; transcript 21 plus TypeScript; native 236
executed = 235 passed + one opt-in skip, zero failures/91.136s, including its
75.587s/30-image gallery. The separate 0.1.5 CUA run was not repeated for 0.1.6:
one passed in 670.249s, eight requests/16 exact bodies, 1,290 tokens and $0.0101375. It covers
two menu opens, day/retained usage scopes, Report/main-window close/recovery,
background cost and unread, title/pin/archive/restore, exact code/Markdown copy,
context preview and captured-request/direct-header views, a Bello-only skill
toggle, empty `/side` plus draft close/reopen, `/fork`, and actual title-bar
double-click zoom/restore. Preserve 0.1.4 source/distribution evidence as historical.

Keep limitations explicit: request-aware local fixtures are not a deployed
LiteLLM service and use no production credentials. Successful foreground unread
clearing is covered by native tests, not claimed by the historical CUA runs. The
historical 0.1.4 CUA run could not complete that interaction while SecurityAgent
owned focus; preserve that limit. The fixture invokes the actual status-button
action; physical left/right status clicks, chart dragging, real-language IME and
the full Release performance budget remain unverified. Historical Debug targets
were missed. Actual title-bar double-click zoom/restore was CUA-verified in 0.1.5.

Use small reviewable local commits on main. Push source only when the owner
asks, following the current squash policy; releasing pushes the website commit. Reuse passing checks
unless source changes or a concrete concern warrant rerunning them. Release
through the sibling apps' profile-free Developer ID/hardened-runtime/timestamp/
notarization/Sparkle flow; do not change signing-key ACLs or request an Apple
browser sign-in. Publish /bello-agent.html, the signed DMG and identical canonical
bello_agent.appcast.xml/legacy pi_app.appcast.xml; verify public bytes/signatures.
Skip install/update rehearsals under the owner instruction above. Record the
source/site commits, actual versus reused/skipped checks and limits before
updating the status docs. Never force-push, discard user
history or place secrets/unsigned fake installers in the outbox.
```
