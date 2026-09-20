# Implementation status and remaining work

Updated 2026-09-20. Repository `BelloWare/BelloAgent`, branch **main**. The original
`BelloWare/pi-app` implementation continued from `da6028153bea8d0b94a4b9a5bbae11158a64030d`
before the repository migration; do not reset the current repository to that archived history.

**Current owner workflow, after 0.1.6:** shorten release cycles with focused
tests, reuse passing evidence for unchanged code, run independent checks in
parallel and retain incremental build caches. Skip fresh-install and actual
Sparkle update/relaunch rehearsals, including the signed owner/update rehearsal,
unless explicitly requested again. Signing, notarization and public artifact
verification remain. See the [test selection policy](Swift-Test-Handoff.md#current-test-selection-policy).
The successful installation checks recorded below are historical evidence.

**Bello Agent 0.1.64/build 68 is the release candidate** implementing single-task
compaction, bounded chunk/merge summaries, scoped history recall, durable v2
checkpoints and one explicit context-rejection recovery. The 4,096 summary cap
is removed; reasoning effort stays unchanged and the summary instruction follows
its source. Read the [implementation and CP01–CP33 dispositions](Compaction-Implementation-2026-09-20.md)
and [0.1.64 validation](validation/Bello-Agent-0.1.64-2026-09-20.md).

**Bello Agent 0.1.63/build 67 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `b0ae02f51525f517929d4feb53deb5cf3bb9e3fc`
and website `2980441eeb55161c6e17d01c1d4f524d87e3e3d3`. The DMG measures **8,115,649 bytes (7.74 MiB)**,
SHA-256 `591a351f9a50f0deb34df45287336dddf654e146155336da0ae450daf5e8677d`. App/DMG signing and notarization,
packaged helper smoke, public product link, identical canonical/legacy feeds and
downloaded archive SHA-256/Ed25519 verification pass. Public verification:
**2026-09-20 08:14:46 UTC**. Cloudflare check **106047299701** succeeded.

This release implements Return/follow-up versus Command-Return/steering, logical
tool-call summaries, request-scoped context observations, stable streaming
Markdown, Copy Turn Info and persistent drag-and-drop session ordering. The
broader gateway check also found and fixed stalled HTTP MCP consumption.
Validation: 228 helper tests, 26 executable gateway tests, 176 optimized native
tests, 26 final focused actor-checked Debug tests and the every-prefix performance
comparison passed. See the
[implementation record](Chat-Behavior-Implementation-2026-09-20.md) and
[0.1.63 acceptance record](validation/Bello-Agent-0.1.63-2026-09-20.md).
Large cold-content layout costs remain documented. No subagents or installation/
update rehearsals were used.

**Bello Agent 0.1.62/build 66 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `2ec983143943e68230b4fbe383702a8015422b8b`
and website `3cb8726f66608b5cf4acbd5d12fbbcc99b24c745`. The DMG measures **8,030,328 bytes (7.66 MiB)**,
SHA-256 `896e7b488c70617aaa60aca496f68fae13a64f112ee5ee5ccf07c20000b93f76`. App/DMG signing and notarization, packaged helper/catalog smoke,
public product link, identical canonical/legacy feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: **2026-09-20 06:53:32 UTC**.
Cloudflare check **106037307690** succeeded. Read the
[release validation](validation/Bello-Agent-0.1.62-2026-09-20.md) and
[PF01–PF09 dispositions](Performance-Review-0.1.62-2026-09-20.md).
The release improves capture, report paging, context checks, tables and native
view retention; rich-row and giant-answer cold-layout limits remain explicit.
No subagents or installation/update rehearsals were used for this task.

**Performance follow-up included in 0.1.61, 2026-09-20:** display-linked disclosure motion
survives streaming updates; resize completion reconciles unseen history in bounded
idle work; both panes share input/visibility-aware preparation; large code fences
use a persistent native text leaf; asynchronous image paste keeps its originating
session. New measurements and regressions cover rich streaming, five sessions,
and 20 concurrent gateway sessions with two histories, capture, an inspector, IME
and resize. Rich-row, cold scrolling and large-table stalls remain; see the
[review implementation record](Performance-Review-Implementation-2026-09-20.md).
The initial performance-only request was committed and pushed without a release.
The subsequent crash-audit request authorizes **0.1.61/build 65**. Read the
[crash audit implementation](Crash-Audit-Implementation-2026-09-20.md) and
[release validation](validation/Bello-Agent-0.1.61-2026-09-20.md). Do not spawn
subagents unless explicitly requested by the owner in the current request.

**Bello Agent 0.1.61/build 65 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `62de9de0ed29be3a2be030b3b458b4e1cb8d996c`
and website `f2b89f07be5850426c0350ec3712f0951fd98e44`. The DMG measures **8,103,822 bytes (7.73 MiB)**,
SHA-256 `4d289ecdde0f518b5f361d4aae0d90505f2c1fc692d7bd89e0961a681387ab81`. Signing, notarization, packaged helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-20 05:01:56 UTC**.
Read the [0.1.61 release record](validation/Bello-Agent-0.1.61-2026-09-20.md)
and [crash audit implementation](Crash-Audit-Implementation-2026-09-20.md).
Installation and actual update rehearsals remain skipped under the owner's policy.

**Bello Agent 0.1.60/build 64 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `ce252bcabe542efc58d87774f16bbe09b4a646d8`
and website `4ceb9e8773b605931d15eceaf04b0e4947f6f2c7`. The DMG measures **7,824,296 bytes (7.46 MiB)**,
SHA-256 `0cf92ca649e56a4293a404fa98a9d8fcbe547d2ee9a97222a04be124e1cc81c7`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-19 23:24:08 UTC**.
Read the [0.1.60 release record](validation/Bello-Agent-0.1.60-2026-09-19.md). Its source
is included in the performance review's starting commit, already on `origin/main`.

**Bello Agent 0.1.59/build 63 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `f24e92d0649ceba066ad62e0a9ba439a0e07aacc`
and website `25f67c4a683c0927981df5940388b4f3f1759fa6`. The DMG measures **7,658,997 bytes (7.30 MiB)**,
SHA-256 `27f4680d1e1181880309f17250328f8b93c39cb6a7db09407e2fae9f01d668ab`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-19 09:00:47 UTC**.
Read the [0.1.59 release record](validation/Bello-Agent-0.1.59-2026-09-19.md).

**Bello Agent 0.1.58/build 62 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `998411e757bddfe419d4afdd3e578f299689ad60`
and website `fa044232670ca60292baf2de3744526aed86f3ff`. The DMG measures **7,593,537 bytes (7.24 MiB)**,
SHA-256 `be36e9bbfe783c3463038fca6337ad19fc9808aa17334c28bd567fc7fafb979d`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-19 02:56:13 UTC**.
Read the [0.1.58 release record](validation/Bello-Agent-0.1.58-2026-09-19.md).

**Bello Agent 0.1.57/build 61 is a historical verified release** at
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

**Bello Agent 0.1.56/build 60 is a historical verified release** at
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

**Bello Agent 0.1.55/build 59 is a historical verified release** at
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

**Bello Agent 0.1.54/build 58 is a historical verified release** at
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

**Bello Agent 0.1.53/build 57 is a historical verified release** at
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

**Bello Agent 0.1.52/build 56 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `78e7b8f80a89e497978d915908f97b080a751512`
and website `f188c0db312da614df13b97a6f113b899b87932a`. The DMG measures **7,269,703 bytes (6.93 MiB)**,
SHA-256 `39037ef81f15ef1c3c28be59c1c142b258f5b967372df03ceec71cb534887c4a`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 20:13:40 UTC**.
Read the [0.1.52 release record](validation/Bello-Agent-0.1.52-2026-09-19.md)
and [throughput/worker review](TPS-Workers-Review-2026-09-19.md). Installation/update
rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.51/build 55 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `1eb8f9ea3b801aa50d380b5ae9627f337aa45189`
and website `fdcde0b40f8cc99d50bcc5ad2de74911912e33de`. The DMG measures **7,254,854 bytes (6.92 MiB)**,
SHA-256 `4674b23636b513802ebbca323bed9e02794f129936f2b851528fc95c30fa3e40`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 19:40:46 UTC**.
Read the [0.1.51 release record](validation/Bello-Agent-0.1.51-2026-09-19.md)
and [concurrency review](Concurrency-Review-2026-09-19.md). Installation/update
rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.50/build 54 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `0969ad030f769aadf1761d9e18869ca85130c031`
and website `178662a9abad8bd567553ed5f3dcf899d3f265b4`. The DMG measures **7,232,970 bytes (6.90 MiB)**,
SHA-256 `e3e5b43e042fa435a691819e6d30918c7915e7bd6298c3b5c8298f8c65e67e30`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 18:56:46 UTC**.
Read the [0.1.50 release record](validation/Bello-Agent-0.1.50-2026-09-19.md)
and [performance review](Performance-Review-2026-09-19.md). Installation/update
rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.49/build 53 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `b59a34a63bc4f174fddb2cd5c4ae5068ba6c834d`
and website `69520c61e62bc4e4b3152296ced8ebfbee6c72d8`. The DMG measures **7,222,143 bytes (6.89 MiB)**,
SHA-256 `e10cf9b7e2df730192801124b942e51138b92c269ebcb25e891c8d2628938aae`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 18:10:02 UTC**.
Read the [0.1.49 release record](validation/Bello-Agent-0.1.49-2026-09-19.md)
and [deep review](Deep-Review-2026-09-19.md). Installation/update rehearsals
were skipped under the standing owner policy.

**Bello Agent 0.1.48/build 52 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `c52a3d197553c32c7ef0e8dfa2230f16cff68066`
and website `67e1eb1414622f013abafc3e27f05462e9c64b93`. The DMG measures **7,203,566 bytes (6.87 MiB)**,
SHA-256 `5b74ee2fded4a7ca8305a157d85db95a979b842ee6ab66624d1f1b14af129bd4`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 17:12:05 UTC**.
Read the [0.1.48 release record](validation/Bello-Agent-0.1.48-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.47/build 51 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `a093b4df18176df0df411d842475cbaff9efc43e`
and website `4580f6b23af1dafecd459cc47b96cfcbc1923781`. The DMG measures **7,186,673 bytes (6.85 MiB)**,
SHA-256 `8b718ddd7b93de0626328383f7344b1c078f1c81aebbae6980fe435219922f0f`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 16:14:07 UTC**.
Read the [0.1.47 release record](validation/Bello-Agent-0.1.47-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.46/build 50 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `3fcb762c54d6dc8a4681b846a1b339d5d56ae6d8`
and website `def13c36778eefc98fb6d61ecd8959b71a3fb7b8`. The DMG measures **7,180,448 bytes (6.85 MiB)**,
SHA-256 `789fc8ab3a3b313b9d3e7c658e7e2f55394139cfd4c4559e73a0437347f0a259`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 15:20:46 UTC**.
Read the [0.1.46 release record](validation/Bello-Agent-0.1.46-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.45/build 49 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `9af946daf435d696d0cab53ac402c21b70966912`
and website `d52e8ac9c8435cbac619812b54893764bdc12766`. The DMG measures **7,179,717 bytes (6.85 MiB)**,
SHA-256 `11d923809f4d6c4b7f524c280805372068b39ebe2f74e61d547db082f4082b0d`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 14:45:05 UTC**.
Read the [0.1.45 release record](validation/Bello-Agent-0.1.45-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.44/build 48 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `a0cc15e3386cef9b6a044504191c72134a514f35`
and website `7199c735eb1ed977d187286b73b892f37dc538c4`. The DMG measures **7,160,116 bytes (6.83 MiB)**,
SHA-256 `4d890fc163a3df16e5e9aad37fc781bc969297f12e6a2ab105ecc547f3879337`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 13:25:46 UTC**.
Read the [0.1.44 release record](validation/Bello-Agent-0.1.44-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.43/build 47 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `b3491f8c2fe62250896c918c9624d0f79a2991e3`
and website `8008e13ec2ce0bf447d1f4f80c58f12df760d7a4`. The DMG measures **7,161,822 bytes (6.83 MiB)**,
SHA-256 `f30b09b90f84f0ce25c72314352f74b4ad36f4f04ea5917656543e677f408ce1`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 13:13:16 UTC**.
Read the [0.1.43 release record](validation/Bello-Agent-0.1.43-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.42/build 46 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `6b80619760c8328f9eb8a94e3f040cebfd82cc5c`
and website `1e57c83b90df30187a0e5d1943f29ee7225d425e`. The DMG measures **7,137,493 bytes (6.81 MiB)**,
SHA-256 `f3b8460af5c7ee378921ab8766fbf1cd8dade20921c995255c7b0b0874e0405c`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 11:35:50 UTC**.
Read the [0.1.42 release record](validation/Bello-Agent-0.1.42-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.41/build 45 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `4bfa49e039c6206e12afbb4dac823af27620c9ef`
and website `a11fb2989b9839061d6bb24f82dbb8e80876b072`. The DMG measures **7,115,515 bytes (6.79 MiB)**,
SHA-256 `b9835306e36b9744258f1e50e41f5998c0438505d6676d6e01faea5c28bb58c4`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 10:33:48 UTC**.
Read the [0.1.41 release record](validation/Bello-Agent-0.1.41-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.40/build 44 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `d2802278100ebaf6a414a0de139fc48a59cc7233`
and website `65730b4432a1d089df7804d9b92365a2ab638b60`. The DMG measures **7,113,393 bytes (6.78 MiB)**,
SHA-256 `b8e4036068f3e89eb7e462a7a44c4bb418e3c8f638e1b5d1204eb87833a03b4e`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 09:15:59 UTC**.
Read the [0.1.40 release record](validation/Bello-Agent-0.1.40-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.39/build 43 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `a88bddbb4fbe0772bce8b182cf9116cda4309047`
and website `a7d2d22d809962d5f123d6c0b1cfbcb2a2bbf49b`. The DMG measures **7,149,724 bytes (6.82 MiB)**,
SHA-256 `1e93b8639cf4cd0ee12c20246f7ed331b929f1e925b62585ba2beab15de168f7`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 07:25:06 UTC**.
Read the [0.1.39 release record](validation/Bello-Agent-0.1.39-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.38/build 42 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `bf04acfd3f41d2313d206052579091b94bf3966b`
and website `7538ca1ce73000bc1d11ec04989caa9625db2500`. The DMG measures **7,128,652 bytes (6.80 MiB)**,
SHA-256 `90ed4270a53955671d875cae58b946b27ac7f74b561525b6599298f79246150d`. Signing/notarization, packaged-catalog/helper smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-18 06:25:13 UTC**.
Read the [0.1.38 release record](validation/Bello-Agent-0.1.38-2026-09-18.md).
Installation/update rehearsals were skipped under the standing owner policy.

**Bello Agent 0.1.37/build 41 is a historical verified release** at
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

**Bello Agent 0.1.18/build 22 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `29e2da5569165df79572218b490b3b63f8685bc9`
and website `69c6862688c6baf6d33220593f5f59246a7554e1`. The DMG measures **7,230,028 bytes (6.90 MiB)**,
SHA-256 `cd8374400c12f508fa8b0f1b653a90c5660dc4756a147306203609f3cb728629`. Signing/notarization, packaged-catalog/helper smoke,
public pages/icon, identical canonical/legacy feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: **2026-09-16 15:46:54 UTC**.
Read the [0.1.18 release record](validation/Bello-Agent-0.1.18-2026-09-16.md).
Installation/update rehearsals were skipped by owner instruction.

**Bello Agent 0.1.17/build 21 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `bbe02ecce0da172bbbcdf8304a663ff29d033269`
and website `2cb0c457f52b522ef13c1e21c291fe7e151bfb69`. The DMG measures **7,215,669 bytes (6.88 MiB)**,
SHA-256 `63cbbf327f44fd5e8fbdedab420e96ff32d17591c56a094d045e1c6c775248d1`. Signing/notarization, packaged-catalog/helper smoke,
public pages/icon, identical canonical/legacy feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: **2026-09-16 15:31:21 UTC**.
Read the [0.1.17 release record](validation/Bello-Agent-0.1.17-2026-09-16.md).
Installation/update rehearsals were skipped by owner instruction.

**Bello Agent 0.1.16/build 20 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `f680fc8cc4ac77a7efdd007cc319ced2bedf319f`
and website `d501b2a2f5f7c3100a53a0805b6295f311a0f1fc`. The DMG measures **7,167,470 bytes (6.84 MiB)**,
SHA-256 `33335dc999e633db7e395ae688daddb0044dfea53c143052a8d46bbf0bba4cbb`. Signing/notarization, packaged-catalog/helper smoke,
public pages/icon, identical canonical/legacy feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: **2026-09-16 14:59:06 UTC**.
Read the [0.1.16 release record](validation/Bello-Agent-0.1.16-2026-09-16.md).
Installation/update rehearsals were skipped by owner instruction.

**Bello Agent 0.1.15/build 19 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `65061de7440755b7f328fb4706d45e2ec5c5fc91`
and website `dd6f206fa24c2210f3f0d380c6e8d4f73ec04bce`. The DMG measures **7,137,895 bytes (6.81 MiB)**,
SHA-256 `cbe8d87022dd1455ea241fdd6b4b5b59b59b72c865d9c4f00c597ffd2768ef0f`. Signing/notarization, packaged-catalog/helper smoke,
public pages/icon, identical canonical/legacy feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: **2026-09-16 14:27:04 UTC**.
Read the [0.1.15 release record](validation/Bello-Agent-0.1.15-2026-09-16.md).
Installation/update rehearsals were skipped by owner instruction.

**Bello Agent 0.1.14/build 18 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `2542f31b3992fa1011008c0f317917eb2fcea105`
and website `d4ba4e3411d17a6bc0d1f8a11cb04bcd43a85781`. The DMG measures **7,135,182 bytes (6.80 MiB)**,
SHA-256 `d7d6a198f26f87a7d044b206ab38009843c1d40b4cb70290142e42f708b380a2`. Signing/notarization, packaged-catalog/helper smoke,
public pages/icon, identical canonical/legacy feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: **2026-09-16 14:00:20 UTC**.
Read the [0.1.14 release record](validation/Bello-Agent-0.1.14-2026-09-16.md).
Installation/update rehearsals were skipped by owner instruction.

**Bello Agent 0.1.13/build 17 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `a06287bcf21873a0757dfdeb3e55b5aa9a366b1f`
and website `cd28c3c4c630da9eec014acf5db8bb1dd1ffea17`. The DMG measures **7,118,570 bytes (6.79 MiB)**,
SHA-256 `4906755a2befbb89ff58cc85b032ac66517f33ff7d1faf6e3d1db015ec114228`. Signing/notarization, packaged-catalog/helper smoke,
public pages/icon, identical canonical/legacy feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: **2026-09-16 12:57:46 UTC**.
Read the [0.1.13 release record](validation/Bello-Agent-0.1.13-2026-09-16.md).
Installation/update rehearsals were skipped by owner instruction.

**Bello Agent 0.1.12/build 16 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `5bf9a8240df955725e05bfdcbc4b355a5d267cbf`
and website `9154d3fa8c81520025737ac44baab0a5b021b01e`. The DMG measures **6,989,644 bytes (6.67 MiB)**,
SHA-256 `16e7798b04abbe7ce73647844bf9a2b3a8bb4f042b0af792680920d87903748c`. Signing/notarization, packaged-catalog/helper smoke,
public pages/icon, identical canonical/legacy feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: **2026-09-16 11:52:59 UTC**.
Read the [0.1.12 release record](validation/Bello-Agent-0.1.12-2026-09-16.md).
Installation/update rehearsals were skipped by owner instruction.

**Bello Agent 0.1.11/build 15 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `bca8f816a9fe5959ad1d2a08e6ed077495c8ff2e`
and website `0264f7a5b331d2655bd6bde478178fe1ab145a17`. The DMG measures **6,937,176 bytes (6.62 MiB)**,
SHA-256 `e1058f581bb1ac809fd217ffbe64c3a888c601ef5a0e0739470d84adce907e4b`. App/DMG signing and notarization, packaged-catalog/helper smoke,
public pages/icon, identical canonical/legacy feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: **2026-09-16 10:44:00 UTC**.
Read the [0.1.11 release record](validation/Bello-Agent-0.1.11-2026-09-16.md).
Installation/update and signed owner/update rehearsals were skipped by owner instruction.

**Bello Agent 0.1.10/build 14 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `d1908dc978e6652f62eb04d2aec1dc6858d4dca2`
and website `b93433bb28172179ce9e7d3b1c52295ba3029b94`. The DMG measures **6,901,746 bytes (6.58 MiB)**,
SHA-256 `92ca6ffb4d09e84a6f78f8ec592bd0d21e27504b1f15af522e1a0af015b9fa49`. App/DMG signing and notarization, packaged-catalog/helper
smoke checks, public pages/icon, identical canonical/legacy feeds and downloaded
archive SHA-256/Ed25519 verification pass. Public verification: **2026-09-16 10:03:51 UTC**.
Read the [0.1.10 release record](validation/Bello-Agent-0.1.10-2026-09-16.md).
Installation/update and signed owner/update rehearsals were skipped by owner instruction.

**Bello Agent 0.1.9/build 13 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `e3940fe61ff03af2a58b083d632a56b3f1b5329c`
and website `856b71140ccbc20adfc1074e8275b1190d32c9e2`. The DMG measures **6,902,731 bytes (6.58 MiB)**,
SHA-256 `bf115a54a31210cf683949433eb0f8450e56637bc1354fba7925a91d56869bbc`. App/DMG signing and notarization, local smoke checks,
public pages/icon, identical canonical/legacy update feeds and downloaded archive
SHA-256/Ed25519 verification pass. Public verification: **2026-09-16 08:17:28 UTC**.
Read the [0.1.9 release record](validation/Bello-Agent-0.1.9-2026-09-16.md).
No installation/update or signed owner/update rehearsal was run.

**Bello Agent 0.1.8/build 12 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `3880709162722ba5d7e4bd3d1715aa396f2bef85`
and website `956a86317892a47b5ced402eb8a30aad5e086552`. The DMG measures **6,691,444 bytes (6.38 MiB)**,
SHA-256 `dca53c6d618c6bb56e8d499d1e8c748327182d617792129fe46b031f991c070b`. App/DMG
signing and notarization, local smoke checks, public pages/icon, identical update feeds
and downloaded archive SHA-256/Ed25519 verification pass.
Read the [0.1.8 release record](validation/Bello-Agent-0.1.8-2026-09-16.md).
Installation/update and signed
owner/update rehearsals were skipped by owner instruction.

**Bello Agent 0.1.7/build 11 is a historical verified release** at [belloware.com](https://belloware.com/bello-agent.html).
Source `bd6a5559fa5d52a647f997d9084cf9fbd7001c18` and website
`90ffc8fd821aa17789c85f2cf49cdf50d06518b3` are pushed. The installer measures
**6,688,314 bytes (6.38 MiB)**, SHA-256
`00e284caa89b62eec2d1e6246f029e0ceeef20dc1982610bc918f8151e0a3c96`.
App/DMG signing/notarization, local smoke checks and public page/icon/feed/archive
verification pass. Canonical and legacy feeds are byte-identical; the downloaded
archive matches its SHA-256 and Ed25519 signature.
Read the [0.1.7 release record](validation/Bello-Agent-0.1.7-2026-09-16.md).
No installation or update rehearsal was run, following the current owner policy.

**Bello Agent 0.1.6/build 10 is a historical verified release**, from source
`30fc4b4` and website `d92957c`. Its signed/notarized 6,656,677-byte installer,
public pages/feeds/archive and actual 0.1.5→0.1.6 Sparkle update passed. All 75
installed files/links matched, history/drafts remained, and Keychain revision 0
was unchanged. See its [historical record](validation/Bello-Agent-0.1.6-2026-09-16.md).

**Bello Agent 0.1.5/build 9 is a historical verified release** at
[belloware.com](https://belloware.com/bello-agent.html), from source `3460390`
and website `51d81cf`. The **5.04 MiB** signed/notarized installer, public page
and both update feeds are verified. An actual 0.1.4→0.1.5 Sparkle update
installed/relaunched with all 75 files/links matching, historical chats intact
and unchanged Keychain access. Read the
[0.1.5 release record](validation/Bello-Agent-0.1.5-2026-09-16.md).

**Bello Agent 0.1.4/build 8 is a historical verified baseline**, released at
[belloware.com](https://belloware.com/bello-agent.html), from source `16b5152`.
The **4.81 MiB** signed/notarized installer, public page and both update feeds
are verified. An actual 0.1.3→0.1.4 Sparkle update installed/relaunched with all
75 files/links matching, historical chats intact and unchanged Keychain access.
Read the [0.1.4 release record](validation/Bello-Agent-0.1.4-2026-09-16.md).
The [0.1.3 evidence](validation/Bello-Agent-0.1.3-2026-09-16.md) is historical.

## Current implementation

Version 0.1.60 is the pass the owner asked for after 0.1.59: performance,
a smooth experience, an intuitive UI and good code, each driven by an agent
that measured before and after in a Release build and kept its measurement as
a test.

Streaming. A streamed token cost the helper a quadratic preview rebuild
(74 µs per token on a 4,000-token reply, now 0.6 µs), put the whole 250 KB
display page on the wire (now the changed rows and the appended text, about
3 KB), and made the app decode, re-encode and re-decode that page three times
per token; the app now applies row updates to the page it holds, reusing
untouched rows by identity, so a token reaches the transcript in 0.7 ms
instead of 4.9 and the first token of a reply lands inside one frame. The
footer's figures travel only when the app will show them, the journal is
flushed once per settled run instead of once per record, and the helper's
event ring no longer shifts 4,096 entries per event. A 0.1.59 helper and a
0.1.60 app still understand each other: the row-update form is opt-in and
any out-of-step read is a whole page.

UI and UX. A review of every screen, in both appearances and at narrow and
wide sizes, is in `docs/UX-Review-2026-09-19-0.1.60.md`. From it: run states
are words a reader knows ("Paused", "Waiting to send · 1", never the wire
word); a marked sidebar row is outlined rather than wearing the open chat's
highlight; the composer keeps the model's name and drops the effort label
first when the pane narrows; the sidebar's rate abbreviates ("Latest 123k
tok/s") instead of being cut mid-number; the footer's notice can say its
whole sentence; Settings no longer shouts its destructive action; fetch,
pull and push are named, and a disabled Commit says what is missing; skill
policies, request attempts and offsets read as words; the report's headline
cost is a readable figure with the exact one in the caption; tab labels
never wrap inside their pill; and the terminal's surface reads as a terminal
in both appearances.

The app shell. Every sidebar group and row observed the whole workspace
model, so one unread dot or one click rebuilt every visible row's press
surface, context menu and drag overlay: the rows and headers now compare the
values they draw, a selection change rebuilds two rows of the fifteen on
screen and a streamed delta rebuilds none, and the same change over 540 chats
costs 6 ms instead of 14. The composer's text view captured its coordinator
strongly, so every chat the reader had opened stayed in memory with its whole
transcript until quit (50 of 50 pages alive after visiting 50 chats; now the
model's own eight). At launch the sidebar painted every chat under a
"Retained chats" placeholder until the Keychain answered; the vault and the
chat list load together, the rest of configuration finishes after the first
paint, and the first sidebar row paints at about 110 ms with 400 chats.
Opening a chat made three database round-trips before its history read;
they are one, and the composer takes focus before the transcript finishes
loading. Polls that ran for views nobody could see (the inspector over a
minimised window, Session info while occluded) stop, and identical snapshots
are no longer republished at 1 Hz. The status panel counts on change rather
than once a second; draft writes and accounting rows clean up after
themselves; Settings builds only the groups that fit; asking whether a
draft is a command no longer copies the draft; and the bundled catalog is
read off the main actor.

The transcript. Opening a 300-row chat laid every row out before the reader
saw a word: 3.8 s frozen, 7,658 views attached. The document now measures
the rows the reader can see (plus what the anchor will show), estimates the
rest from their typography for the scroll bar, keeps estimated rows out of
the view tree, and measures the remainder in idle slices that never move the
row being read: first paint in about 180 ms with five rows mounted and 139
views, and a return to a chat already read measures nothing (300 heights
come from the shared cache). A row was measured twice per delta; once now.
Folding a long turn kept re-measuring its sixty tool rows; the measured
height lives on the row container, keyed as strictly as the geometry cache,
so a fold is a frame change. Scrolling a 2,000-row page stays inside a
120 Hz frame on all but two of 11,908 wheel steps. Visiting fifty long chats
does not grow the process. A row builds its SwiftUI tree when the reader
reaches it and gives it back when they are pages away, and the conversation
pane is kept across chats instead of thrown away on every sidebar click:
returning to a 300-row chat takes about 90 ms and switching to one not yet
read about 160 ms, with ten trees built instead of 300. A turn's tool calls
draw through a viewport-culled native surface (a closed card is one line
high whatever it says, checked, never trusted), so folding a 60-tool turn
costs 2 ms and unfolding 8. Page Up and Down, Home and End page the
conversation from the composer, and the reading position no longer slides
when the conversation leaves the titlebar's inset.

Smoothness. The three draggable boundaries (sidebar edge, terminal top,
the chat/side split) had no visible affordance and the split could not be
dragged at all; each now carries a grip that strengthens under the pointer,
and the split remembers its fraction. Every pointer-only action has a
keyboard path: sidebar width, Archive, Pin, Move to Topic and Mark as Read
on the focused chat, and folding the turn the reader is on. The error strip
took its room from the conversation's column instead of floating over the
sidebar and the first lines, in both appearances at full strength, with
Dismiss reading as a control. A chat switch arrives settled in one drawn
frame; the reading position holds through the composer growing, the
follow-up panel, the strip, the terminal, the side pane and window and
sidebar resizes; a wheel move holds through streamed deltas; hover answers
from the pointer's own frame with no workspace publication; Reduce Motion
goes through one decision for every animated surface. Closing the request
inspector aborted the app (a state write from inside SwiftUI's teardown) and
does not now. The composer bar laid out nine candidate forms on every pass
(three pill forms inside three run-control forms); it measures its labels
once and builds the one form that fits (3.1 ms to 0.12 ms a pass, an oracle
of 2,725 cases against the trial layouts agreeing to within two points).
Across the shell, a project or topic unfolds its rows out from under its
header, "Show more" rows arrive with them, a chat moving up on activity
slides past its neighbours, the marked-rows strip pushes the list, the
follow-up panel and the terminal slide up and down, the error strip comes
down over the column, and the composer's pills cross-fade between forms,
each under 2 ms a frame, each holding the reader's line; a cross-fade of a
chat switch was built, measured at a second of extra latency, and left out.

Code quality, behaviour-preserving. In the helper, the 1,311-line session
file is thirteen extension files named for what they hold (journal,
persistence, branching, queue, run loop, streaming, tools, display,
compaction, context, reads, test seams); `Support.swift` is six files; every
force unwrap, `try!` and crash on a path a request can reach now reports an
error with a message instead; every `@unchecked Sendable` carries the
invariant that makes it safe and every `Task {}` says who owns it; the test
seams are grouped and documented; dead state and two unreachable branches
are gone; a queued-message test that failed on every Release run was a race
in the test and is deterministic.

Motion. The owner asked for transitions that feel as good as the app is
fast: "it's fast, but it doesn't feel right." The 0.1.59 rule against
animating a row's height came from SwiftUI re-measuring the tree every
frame; the rule now is that motion is driven by the document from geometry
measured once. A fold or unfold measures its target exactly, rewinds to the
old geometry and eases the changed row's height over 220 ms while every row
below shifts by the same amount, the document's height and scroll bar
follow each tick, the folding list slides out under its clip and fades on
its native layer, the chevron turns on the same curve, a second click
carries on from where the motion is, streaming lands after it, and Reduce
Motion snaps as before: 0.11 ms of document work per tick over 300 rows,
rows contiguous at every sampled point. A tool card, exposed reasoning and
the compaction summary move on the same curve, with the region the two
states do not share masked and faded on the row's layer; the live turn bar
slides up into its slot when a run starts and down when it settles, the
slot itself changing the conversation's height exactly once. A row is sized
once per measurement instead of twice, and a side pane opening measures the
rows the reader can see (12 ms over 120 rows, from 450) and lets the rest
stand until the slices reach them. The kept pane retained the chat the
reader left; rebinding now releases everything the previous chat owned,
and visiting fifty chats keeps exactly the eight pages the model caches.

Code quality in the app. Nine files over 800 lines (the workspace view and
model, the Git panel, the terminal emulator, the design system, the report
page and three test files) are forty-two files named for what they hold,
moved verbatim and verified statement by statement; three sheet-question
mechanisms are one (`PiQuestion`), two text-measurement caches are one
(`PiTextWidth`), the environment reader, the release-budget seam and the
scratch-root helper live in one `TestSeams.swift`; dead code, dead branches
(the two on a `keepError` the helper never sends) and every force unwrap on
a reachable path are gone; every unchecked `Sendable` names its invariant;
and the rendered UI before and after differs by less than the gallery's own
run-to-run noise.
See the [0.1.60 release record](validation/Bello-Agent-0.1.60-2026-09-19.md).

Version 0.1.59 fixes the two things the owner reported after 0.1.58.

Folding and unfolding a turn's work went wrong on long turns: a click on a
turn with dozens of tool calls was slow, rows painted over their neighbours
while the height caught up, and a fold sometimes did not take. The open or
closed state of a turn's work, a tool card, exposed reasoning or a compaction
note was SwiftUI view state inside a row, so the AppKit document that owns row
heights learned about a click only when the hosting view happened to
invalidate its intrinsic size, one or two run-loop turns later; in between the
row kept its old frame and its content drew outside it. The state was keyed by
a block's latest row id, which changes as a turn grows, so a fold could reopen
on the next delta, and a 220 ms height animation kept the whole tree
re-measuring for its duration. Now that state lives with the conversation
(`TranscriptDisclosure`), keyed by the turn's stable key, each row reads its
own slice as a plain value and compares it like content, and a click records
the change, rebuilds that one row, drops its measurements and lays the whole
document out in the same pass; rows clip to their frames; the shared geometry
cache is keyed by the disclosure value so a height measured open is never
reused closed; the fold does not animate; and a folded turn keeps its list in
the tree at zero height and clipped instead of tearing sixty rows down and
building them again on the next click.

Dragging a chat in the sidebar never started: SwiftUI's `.onDrag` sat on a
row inside a `Button`, which claims the press on macOS, so nothing followed
the pointer. Each draggable row now carries a transparent AppKit surface that
takes only a plain left press, begins a real dragging session past four
points with a "N chats" image, and hands any other press (Control-click, the
row's own archive and side-chevron buttons, hover, scrolling) straight back to
the row; a press that ends without travelling is the click the row always
handled. Drop zones are the whole project and topic groups, not their header
strips. The first audit pass then found that the surface's tracking loop
could park the main thread for the rest of the session if a press never got
its release (window closed under it, a sheet taking the event stream); the
loop now polls and gives up when the button is no longer down, the row has
left its window, or a minute of silence passes.

The owner then asked for the bugs nobody had found. Six agents drove the real
views in real windows, area by area, and fixed what they confirmed; every
fix keeps its reproduction as a test.

Helper. A reply with many parallel tool calls produced a display snapshot
nine times over the helper's frame limit, and the helper exited mid-turn;
streamed tool cards are now projected in arrival order, capped at 32, with
constant memory beyond the cap. Every edit over about 4 KB showed raw JSON
instead of "Requested edit" because the arguments document was cut at a byte
offset; long string values are now cut individually with an explicit marker,
every card's input parses, `inputTruncated`/`inputBytes` say when it is
partial, and `session.tool.input` returns the full document (64 KiB for
edit-style tools) on demand. Editing a queued message longer than 1 KB saved
back its 1 KB preview; `queue.read` returns the whole text. Live tool cards
retired in lexicographic order (a running card could be dropped while a
finished one stayed) and had no memory bound; they now retire oldest-first
within 1 MiB.

Core. Every chat lookup was a scan of the whole list, called several times
per sidebar row per redraw, so the sidebar was O(chats²): 22.8 ms per redraw
over 400 chats, now 2.1 ms through an id index. The app's own idle stop of a
project helper made the next message fail with "Project host is stopping";
connect now waits for the previous helper to exit and starts a fresh one.
Quitting with text in a never-sent chat threw the text away for good. One
unreadable chat record disabled every topic move and topic deletion in every
project. Closing the last window or quitting during a run ran a blocking
modal alert inside AppKit's own decision (both new tests hang against the old
code); both now ask in a sheet. Capture was priced against the size of the
whole archive on every request (a full retention sweep per finished request,
a sum of every chunk per published chunk); the request inspector threw away
"Older Attempts" one second later; a local migration failure disabled
Settings permanently. The second pass fixed journal paging that decoded the
record once per 16 KiB page, id-less imported records that could never be
opened, a topic drop that decoded every chat in the database, SQLite opened
synchronously on the main actor during the first body, storage errors that
said "could not be saved" for read failures and "damaged" for a merely long
conversation, a stalled Keychain call that disabled credentials for the
session, an N+1 attempt listing polled at 1 Hz, a retention sweep that
committed once per row, a captured body decoded inside a view body on every
render, a connection switch that dropped the chat's model whenever the target
catalog had not been listed yet, a Settings sheet that stayed live during a
save, silent failed saves, a conflict retry that reverted another writer's
preferences, and a catalog fetch whose 8 s budget counted the whole transfer.

Sidebar. A Shift range under an active filter marked, and archived, chats the
filter had hidden. Folding a chat's side chats was forgotten whenever the
group was rebuilt, as was "Show 10 more"; both now live in the model and
travel in the existing project-sidebar record, so they survive a relaunch.
One unread dot or one selection cost three frames of main-thread work over
540 chats (44 and 41 ms); a sidebar index answers every group's lookup once
per change and the same events now cost 12 and 15 ms. The marked-rows bar
broke "Archive" across three lines at the sidebar's minimum width; project
names truncated in the middle ("be…ent") and the header kept three buttons
below 240 pt; Escape could not leave the rename sheet, or nine other sheets,
which `PiSheet` now handles for all of them; a chat deleted while a bulk
action ran was reported as a failure. The cursor pushed by a hovered row was
stranded app-wide when the window closed under it. The metrics line under a
chat laid out four candidate forms per row on every pass to find the one
that fits; it now measures its figures once and builds only the form that
fits (a 600-case oracle against the old view agrees everywhere), which took
3.9 ms off a frame on a workspace where every chat has run.

Git and terminal. "Stage all", "Discard All" and Commit on a repository with
thousands of changed files crashed the app: one argv held every path and
Foundation raised past 4,096 arguments; paths now go in batches and a commit
uses a pathspec file. A handful of git reads stalled every other task in the
app for seconds because the waits ran on Swift's cooperative pool; they run
on their own queue, at most eight processes at a time. A 20,000-line patch
took 23 s to open unified and three and a half minutes side by side (every
row built eagerly, every line walked, the split rows re-paired per redraw);
it opens in 85 ms and 143 ms. A commit touching 3,000 files froze the panel
for fifty seconds (one chip per file in a non-lazy layout); files list 200 at
a time. CRLF files showed their whole diff as one row (Swift reads "
" as
one Character); a renamed file showed as entirely added; clicking down the
file list left one `git diff` process per file; unticking every file was
undone by the next refresh; "Show the whole diff" followed the reader to the
next file. The panel now notices the working tree changing through FSEvents
(a saved file appears in about 300 ms, a burst of writes costs one refresh,
git's own writes cause none) and an automatic refresh never moves the reader.
In the terminal, scrolling back lost the reader's place as output arrived;
one streaming command cost 22,000 hops to the main thread (now 222); `cat`
on a binary file rang the system alert thousands of times; switching
projects stacked terminals in the panel and left the keyboard nowhere; a
shell per project lived for the app's whole life; the scrollback had no
memory ceiling (a 2,000-column window could hold 610 MB) and is now text and
style runs: four terminals of 10,000 dense lines cost the process 236 MB
before and 11 MB after.

Composer and run lifecycle. Typing into a long draft cost about 11 ms per
keystroke (the coordinator compared the whole document against the editor's
string on every edit, the footer re-rendered on every keystroke through an
observer it never read, `canSend` copied the draft to trim it); a keystroke
in a 200 KB draft is now 3 ms, most of it TextKit's own insert. The composer
bar stacked "Steer run" one letter per line in a 460-point pane. After the
helper died mid-turn the live bar and its Stop button stayed up for ever and
Stop did nothing; interrupted rows are now settled, the bar leaves, and the
next send starts a fresh helper. Stray typing walked the whole window's view
tree per keystroke to find the composer. Rewriting a queued follow-up clipped
the panel; editing a queued message over 1 KB saved its 1 KB preview back
(`queue.read` now supplies the whole text and the field waits for it);
pasting a 4000×3000 screenshot froze the window for 115 ms (PNG bytes now go
through untouched, other formats convert off the main thread); a long
gateway error was cut off with no way to read it (the strip opens, scrolls
and copies). "Previous command outcome is uncertain", "Delete this chat?",
the skill-arguments prompt, the image chooser, the connection test, keeping
a side and enabling editing all ran an application-modal loop that froze
every other chat's stream; each is now a sheet on the window showing that
chat, one at a time, with the work continuing in the completion.

Transcript. A turn folded while it ran sprang open when its reply settled
(blocks were keyed by the reply's provisional stream id, so the settled row
was a different row). A settled turn kept its "just arrived" accent for ever.
Every row was laid out natively three times per reflow, and every row built
three hover-only action pills and a copy control that only a pointer can
reveal: opening a 300-row chat to exact geometry took 2.3 s, now 1.2 s;
folding a 60-tool turn 30 ms, now 14. Dragging a pane's edge over a long
chat cost 729 ms a frame: resolving the reading anchor walked the whole page
for every row's frame (O(rows²)), and every row was re-measured on every
frame of the drag. The anchor is resolved once, and during a live resize the
document measures only from the top of the page to the bottom of the
viewport the reader will see, leaving the rows below standing at their old
height and out of the view tree, then measures everything when the drag
ends: 9 ms a frame over 500 rows, with a full read of the document after
the drag proving every row exact. The edit diff ran its O(n²) algorithm
inside a SwiftUI body on every redraw of an open card; it runs once per call
and refuses past 4,000 lines. The reasoning and compaction disclosures were
stock `DisclosureGroup`s and are now the transcript's own header. A run that
started as the pane opened never showed its live bar (the task wrote the
state captured when the view was built). A card whose arguments were cut
showed the raw fragment; it shows what arrived, fetches the whole document
through `session.tool.input` when opened, and a chat read from disk builds
the same card as a live one.
See the [0.1.59 release record](validation/Bello-Agent-0.1.59-2026-09-19.md).

Version 0.1.58 answers two owner requests. The sidebar now selects several
chats at once: Shift-click extends a range in the order the list shows,
Command-click adds or removes one row, and an ordinary click drops the marks
and opens the chat. A bar above the list says how many are marked and archives
or restores them in one press; a right-click on a marked row archives,
restores, pins, unpins, moves to a topic or marks read for the whole set, each
through the same durable per-chat path as its single-chat menu item. Dragging a
marked row carries every marked chat of that project in one bounded payload,
previewed as "N chats", and drops into a topic or a project root exactly as one
chat already did. Chats are still deleted one at a time.

Git history browsing was rebuilt around what a click actually needs. Choosing a
commit ran three git processes in a row, the last one producing the whole patch,
and the app then parsed that patch on the main thread inside a view body, so it
was re-parsed on every redraw and nothing appeared until all of it finished. Now
two cheap reads return the message, the changed paths and their line counts
without any patch text, so the file list and a "12 files · +340 −58" summary
appear first; the patch is read and parsed in one background task and never
crosses the main thread as text. Each commit's metadata, patch and per-file
patches are kept for the last 24 commits, so returning to one starts no process
at all, and choosing another commit terminates the reads of the one before it.
A commit of more than 30 files or 3,000 changed lines keeps its patch behind
"Show the whole diff" and opens one file at a time. Any file has its own
history through "Show History of This File", which follows renames, with a chip
naming the filtered path until it is cleared.
See the [0.1.58 release record](validation/Bello-Agent-0.1.58-2026-09-19.md).

<!-- release-summary:0.1.57 -->
Version 0.1.57 isolates per-chat usage notifications, skips hidden helper transcript
projection, rejects stale refresh replies and reuses verified immutable native row
geometry. In the five-session fixture, background content/billing work fell from
12.51 ms to 7.24 ms mean, with zero whole-workspace notifications. A return to the
initially mounted chat took 629.11 ms to readiness plus 68.76 ms deferred settlement;
the original readiness-only baseline was 1,421.23 ms. Repeated helper status reads
fell 98.0%. Acceptance covers 118 distinct native passes, 41 helper passes and three
request-aware concurrent gateway scenarios (162 distinct passes), with two native
interactive checks skipped. The final shipping-source selection passed 23/23;
unchanged checks reuse the earlier successful selections, excluding four discarded
experimental tests. Twenty simultaneous requests completed tools and exact capture.
A shared Markdown-block cache was rejected after it slowed long-answer scrolling.
Rich foreground layout still has spikes (54.46 ms mean, 124.57 ms maximum), and cold
large-history loading remains expensive. Physical trackpad/VoiceOver smoothness is
unverified on this inactive desktop. Installation and actual update rehearsals stay
skipped under the owner’s policy.
<!-- /release-summary:0.1.57 -->

<!-- release-summary:0.1.56 -->
Version 0.1.56 adds project topics: collapsible, named groups for related
sessions, with New Chat, rename, removal that keeps chats, and drag-and-drop
between topics or back to the project header. Move to Topic is also available
in session menus. New chats inherit the focused topic, sides/forks inherit
the source group, and moving a parent includes its saved side descendants.
Atomic metadata updates preserve active work, drafts, history and session IDs;
regressions cover side publication, late writes and concurrent deletion.
Topics and their disclosure state persist across restart.

The native Release selection passed 90 tests with no failures or skips; a
final seven-test subset also passed after checking the packaged drag-type
declaration. Unchanged helper/gateway/scrolling evidence was reused. Physical
pointer drag/drop, context-menu interaction and VoiceOver remain unverified
on the inactive remote desktop; real item-provider dispatch and hosted native
sidebar layout passed. Installation/update rehearsals remain skipped.
<!-- /release-summary:0.1.56 -->

<!-- release-summary:0.1.55 -->
Version 0.1.55 keeps only nearby native transcript rows and Markdown blocks
attached while retaining complete content, exact geometry and selected text.
The 300-message fixture drops from 85.7 to 9.6 ms per native scroll step on
average; the 88 KiB answer drops from 44.6 to 13.0 ms. These are comparable
layout/display stress measurements, not physical display FPS. Initial loading
of every retained row still requires an up-front geometry pass.
The affected Release XCTest run executed 78 cases: 76 passed and two interactive
pointer checks were explicitly skipped on the inactive remote desktop. A final
four-case Markdown/scroll rerun passed after fixing Copy/Copied layout feedback.
Unchanged provider/helper/gateway/worker and website-staging acceptance is
reused; physical trackpad and VoiceOver checks are not claimed. Single enormous
Markdown blocks and selection at the streaming renderer threshold remain
qualified in the scrolling review. Installation/update rehearsals are skipped
under the owner’s standing instruction.
<!-- /release-summary:0.1.55 -->

<!-- release-summary:0.1.54 -->
Version 0.1.54 adds Copy Session ID and Copy Session Reference to session right-click and conversation “…” menus. References include the authoritative local JSONL path and a shell-quoted read command, without switching chats, loading history or starting helpers. Empty chats and imported identities are explicit. All 27 focused native tests and 12 site-staging tests pass, including executable Bash quoting and complete retained-history reads. The release-page template now preserves native-transcript and reported-throughput wording. Existing helper, gateway, concurrency and rendering evidence is reused. Physical menu/VoiceOver and install/update rehearsals were not repeated.
<!-- /release-summary:0.1.54 -->

<!-- release-summary:0.1.53 -->
Version 0.1.53 uses Bello-styled selection panels and disables the system window tab strip. Exact row-layout caches isolate retained transcript text from streaming updates; ownership-scoped accounting avoids repeated history reads. Comparable native rendering fixtures open about 37% faster and reduce per-update layout/display work by 85.4% (61 rows) and 91.7% (300 rows); these are stress measurements, not a 60 fps guarantee. Final focused evidence contains 191 distinct native passes and four explicit interactive-desktop skips. The native/helper/gateway fixture completed 20 concurrent sessions and tool round trips with 80 exact retained bodies. Unchanged helper/provider/worker evidence is reused from 0.1.52. Pointer/popover and VoiceOver behavior are not claimed as verified on this remote desktop. Installation/update rehearsals remain skipped under the standing owner policy.
<!-- /release-summary:0.1.53 -->

Version 0.1.49 reviews Claude's completed 0.1.48 work and fixes confirmed
queue, crash-recovery, transcript, inspector, transport and storage defects.
It also coordinates context previews and connection removal across suspended
operations, preserving drafts and readable context snapshots. All 498 native
cases completed: 491 passed and 7 opt-in cases skipped. The helper's 170 tests,
52 Python checks and 24 local gateway checks passed. See the
[deep review](Deep-Review-2026-09-19.md) and
[0.1.49 acceptance record](validation/Bello-Agent-0.1.49-2026-09-19.md).

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

Version 0.1.16 keeps tool calls and results collapsed until their disclosure
is opened, including running tools; manual expansion survives streaming updates.
Chat timing shows the latest completed request's TPS and the weighted session
average together, including narrow layouts, with history and coverage on hover.
Failed responses show Error with a visible, retained, credential-sanitized message;
paused/cancelled work stays distinct and pending messages never retry implicitly.
Stop now sits in the chat input for main and side conversations. Background title
jobs, which have no input, keep Stop in their lower task footer.

Version 0.1.15 fixes New Project losing its primary folder immediately after
selection. The form now reads live draft state and publishes the primary/extra
folder change atomically. Changing the primary preserves unrelated extra
folders; an outgoing cancelled pane cannot reopen its draft. Additional projects
can be created after onboarding without replacing the first project.

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

Version 0.1.13 fixes chat catalog Refresh by reloading the saved connection
before fetching, using the same path as Settings. Chat TTFT and TPS show the
same latest completed request and retain it while a new request runs. Hover
shows native history charts; clicking keeps them open. Charts cover up to 128
recent completed requests in that session/project, with gaps for missing
measurements. Usage-window/menu-bar historical averages remain independent.

Version 0.1.12 adds Combined JSON for Responses streams, retaining the terminal
response object or an explicitly partial reconstruction. Events, UTF-8/hex,
original-byte exports and capture-state labels remain. Session usage opens in
reusable resizable native windows with tokens, response/prompt caching, reported
and reasoning cost, historical TPS and model/cost distributions. Windows retain
their session scope across chat changes and stop reads when closed.

Version 0.1.11 simplifies reply footers to one response-body model, with
header/body evidence on click. Captured SSE responses now open as expandable
JSON event trees with original framing and bytes preserved. Calculated context
previews update the footer, with stale-input/activity/reopen guards; unloaded
context offers “Inspect context” without an automatic model request.

Version 0.1.9 honored a model catalog only when a custom URL was saved; the
repository's catalog file was not packaged in the app. Version 0.1.10 fixes that
missed default path: nil, empty and whitespace catalog settings now load the
bundled six-model Bello catalog without requesting gateway models or reading an
API key. Existing selected aliases, reasoning efforts and per-connection defaults
are preserved. Explicit custom catalogs remain authoritative, with no fallback
to either the bundle or gateway after a custom-source failure.

The prior 0.1.9 release added session model/cost breakdowns and put historical output TPS
and requested/resolved model distribution first in the status panel. Activity
lists running work only; sidebar unread behavior is preserved. Historical TPS
uses reported output divided by summed dispatch-to-completion time, with
coverage; it is separate from the live exposed-byte estimate.

Captured bodies load all retained bytes without manual pagination. Valid JSON
defaults to an expandable native tree; raw text/hex and original-byte export
remain. Partial/expired/omitted states stay explicit. Assistant status lines
show one response-body model; clicking opens the separate reported names and
identity diagnostics without an inline model-conflict warning.

Composer model selection uses a searchable native popover backed by the bundled
Bello catalog or the saved connection's explicit custom catalog. Source changes,
remote refresh-on-open and same-source last-good-list errors remain. A separate configured or catalog-recommended mini model
can generate a title in a retained, tools-disabled background session. Those
sessions have fixed titles and separate capture/cost scope, stay hidden until
revealed, preserve manual titles, and never retry uncertain work after restart.
Without a mini choice, the local text title remains.

The empty strip above chat/report titles is removed. Native traffic lights keep
their reserved sidebar area while detail headers begin at the window top;
dragging, double-click zoom/restore and retained composer/transcript state remain.

F01–F21 have native implementations with the acceptance scope below. The selected
architecture is SwiftUI/AppKit native composers, a native SwiftUI transcript
(since 0.1.38; a React page in WKWebView before) and a self-contained Swift
helper. Node is gone; the retired Pi v0.85.1 host remains a behavior reference
and is not bundled.
Claude's latest dashboard changes in `0b3c255` were reviewed after its terminal
turn ended at 2026-09-16T06:23:50.945Z with no remaining child work. The review
found no blockers; gateway model conflicts retain all reported names and expose
them in request details. Historical 0.1.7 source `bd6a555` includes picker loading,
remembered choices and the version update. Earlier review and UI evidence
remains in the historical release records.

| Area | Current behavior |
| --- | --- |
| Responses-only connections | New requests require Responses. Historical Messages profiles, credentials, journals and captures remain readable; explicit conversion creates a separate connection. No silent endpoint/API replacement. |
| Transcript and accounting | Visible speaker-name labels are removed. Each attempt appears once inline, moving from user input to its assistant response; user Details retains linked requests. The status line shows one response-body model; clicking reveals header/body reports and identity diagnostics. Tool rows do not repeat accounting, and compaction keeps its own attribution. |
| LiteLLM usage and cost | Requested aliases and resolved models remain distinct. Cached input, cache-write, output and reasoning tokens are retained with coverage. Reasoning tokens/cost are subsets of output; reported totals are never inflated. Final JSON headers can provide cost when body cost is null; preliminary streaming headers are not final billing. Unknown/invalid/conflicting values stay explicit; every conflicting reported model name is retained and expandable in request details. |
| Report page | Native in-window report with collapsed filters/details, active chips, session groups, linked-message navigation and scrollable compact tables. Every request lists the requested model and the final model the gateway reported, marking routed and unreported identities. Drafts, focus, undo, selection, scroll and WKWebView identity survive navigation; hidden sends and stale query/navigation results are guarded. |
| Onboarding gateway check | Test & Start sends one short request with the selected model through the packaged helper and scoped vault/capture path. No tools, history, skills or workspace instructions; output is capped, cancellation/timeout are bounded and changed configuration is rejected. A failed test does not create a chat; a successful probe creates no probe journal. |
| Status bar Activity | The persistent status item opens on either mouse button and survives closing the main window. Activity lists running model/tool/compaction work and combined fresh live output estimates; unread/waiting/paused sessions are omitted from this panel. Sidebar unread behavior remains. |
| Status bar Usage | Usage is the default tab. All-project 24-hour, seven-day and retained scopes show tokens, reported cost/cache coverage, historical output TPS and requested/resolved model groups. Completed requests with valid output and dispatch-to-completion timing contribute to weighted historical rates; coverage stays visible. Live rates remain separate and hidden-panel polling cancels. |
| Durable unread replies | Existing history is baselined; new durable assistant output is reconciled from offline journals and survives restart. Only the latest completed reply visibly painted in a foreground chat, or explicit Mark as Read, clears unread state. Report/background/scrollback and stale receipts cannot clear newer output. Quit/install persistence is bounded. |
| Capture defaults, privacy and compatibility | Capture request/response bodies and headers by default, retaining plaintext bodies for 30 days subject to quota. Inspectors show retained bodies directly: valid JSON defaults to expandable formatting and both entry points load all retained bytes without manual pagination. Raw text/hex, exact exports and partial/expired labels remain. Longer request authentication tokens retain only a masked final-four-character suffix; short tokens, cookies, response authentication and credential echoes are fully masked. Known credential literals in request bodies remain labeled SHA-256 transformations, without altering wire bytes. Ordinary headers remain readable; legacy encrypted history retains its key. Metadata survives body expiry. |
| Projects and session organization | All projects appear in persistent expandable sidebar groups. Rename, pin, archive and restore preserve history and work; organization revisions prevent stale unrelated saves from reverting changes. Idle archived chats can be explicitly deleted after closing any open parent/child side pane. Sidebar cost updates without focusing the session, including unloaded sessions, and running chats show fresh estimated output speed. Conversation titles omit gateway/API/model-ID/editing badges. |
| Native sessions, durable sides and forks | `/side` plus Enter opens an empty read-only child without a request. Its complete-boundary context, subsequent history and draft are saved immediately; closing the pane preserves running work and the child relationship across restart. `/fork` creates an independent journal with the same complete context, tool/reasoning/provider state and no inherited pending commands. Trusted multiple roots, queues, steering, paused recovery, atomic edit/branch persistence and selected model/effort/capacity limits remain. |
| Automatic context | Safe idle focused chats calculate on selection, sharing the footer/inspector estimate with cache, cancellation and stale-input guards. Native active-context tool-pair checks prevent automatic recovery or repair; imported/untrusted/interrupted/active sessions are skipped. No LLM request or tool execution. |
| Context inspection and transcript copy | The context ring opens a bounded provider-built preview, distinct from captured wire bodies. Code and Markdown-section copy preserve original source. Chat/report headers start at the window top beside reserved sidebar window controls, without a full-width empty strip. Native dragging and available-screen double-click zoom/restore remain. |
| Session timing | Chat TTFT/TPS use the same latest completed retained request; hover opens native per-request charts and click keeps them open. Up to 128 recent completed requests are scoped to the current session/project. Missing measurements stay gaps, observed zeroes stay zero, and historical usage rates remain separate. |
| Catalogs, skills and MCP | The composer, Settings and onboarding use the bundled six-model Bello catalog when no custom URL is saved, without gateway discovery or a credential read. Catalog sources are stored independently from request routes; known same-authority forks retain linkage and legacy chats can choose a saved source explicitly. Refresh reloads saved bindings, revalidates HTTP and shows update time; active pickers observe saved metadata without changing the chat selection. An explicit custom catalog replaces it; one-hour remote caching, same-source last-good-list errors, same-origin credentials and anonymous external catalogs remain. Bello-only skill toggles preserve source policies. Explicit-only skills, one MCP meta-tool, serial invocation and human-only unknown-outcome acknowledgement remain. |
| Session distributions and title jobs | Header/cost controls open reusable native session-usage windows with tokens/cache/cost/TPS, whole-scope model/cost shares and unknown-report coverage. A separate selected/catalog-recommended mini model can generate an automatic title in one retained tools-disabled background session; its fixed title, own capture/cost scope, hidden/reveal state, manual-title protection and durable no-retry claim survive restart. |
| Remembered model choices | The last deliberate model/effort choice and catalog limits are saved per connection for new chats across projects/restarts. Chat and defaults commit atomically; New Chat waits for pending picker saves. Explicit profile/model defaults remain distinct. Existing chats and connection defaults stay unchanged; sides/forks inherit their parent. |
| Gateway fallbacks | Every request sends `disable_fallbacks: true` unless the connection enables Allow fallback models, so a failing route surfaces its error instead of a silently substituted model. |
| Settings and connection tests | Settings has one Save action and closes only on success. Preferences-only saves preserve untouched connections, including active and retained Messages profiles; invalid edited fields remain available for correction. Test Connection saves first and targets its own persisted, tools-disabled chat under No project. It needs no project, keeps its native composer and cannot send into a different chat after selection changes or promote tools through sides/editing. |
| Compaction | The composer strip shows progress and the latest successful summary from authoritative active context. Fast/background completion and historical baselines are handled independently of transcript scrollback; failed/cancelled attempts cannot display an older success as their result. |
| Identity and signing continuity | The exact selected `bello-agent-flat-01-soft.png` is the committed icon master, with its opaque exterior margin preserved and native sizes resampled deterministically. Bundle ID `com.belloware.PiApp`, Keychain item, history paths and Sparkle signing key remain unchanged. Use Clipboard's profile-free Developer ID flow; [icon provenance](../assets/branding/icon-0.1.6-prompt.md) records the selection. |

The owner's second accounting sample is covered directly: **38 input + 302
output = 340 total tokens**, with **253 reasoning tokens** inside output;
**$0.0013875 total cost**, with **$0.0011385 reasoning cost** inside output cost.
No local pricing estimate or extra reasoning/classifier charge is manufactured.
Session/sidebar consumption is distinct from the composer's context estimate.
See [accounting](LiteLLM-Accounting-Contract.md),
[routing/replay](LiteLLM-Routing-Contract.md) and [model catalogs](Model-Catalog.md).

Capture-policy migration is versioned. The exact old off/unaccepted/7-day/default
quota tuple adopts default persistence; explicit session overrides and
distinguishable custom/off settings remain. Every legacy seven-day retention
value becomes 30 days because the old format cannot distinguish its default from
an explicitly chosen seven days. Other custom retention values remain unchanged,
and settings saved under the new policy retain deliberate off/seven-day choices.
No capture-enable consent or body-reveal gate is added to these owner-authorized
defaults. Export and destructive purge actions remain deliberate.

## Verification of 0.1.49

Version 0.1.49 reviews Claude's completed 0.1.48 work and fixes confirmed
queue, crash-recovery, transcript, inspector, transport and storage defects.
It also coordinates context previews and connection removal across suspended
operations, preserving drafts and readable context snapshots. All 498 native
cases completed: 491 passed and 7 opt-in cases skipped. The helper's 170 tests,
52 Python checks and 24 local gateway checks passed. See the
[deep review](Deep-Review-2026-09-19.md) and
[0.1.49 acceptance record](validation/Bello-Agent-0.1.49-2026-09-19.md).

## Verification of 0.1.48

**458 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures**; the
changed helper package passes its 161 cases, the Python fixtures (52),
unchanged since 0.1.47, pass again, and the performance baseline ran again
in a Release build. The optional acceptance class and installation/update
rehearsals were not run. Details are in the
[0.1.48 release record](validation/Bello-Agent-0.1.48-2026-09-18.md).

## Verification of 0.1.47

**457 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures**; the
changed helper package passes its 159 cases, the Python fixtures (52),
whose contract changed in this version, pass, and the performance baseline ran again
in a Release build. The optional acceptance class and installation/update
rehearsals were not run. Details are in the
[0.1.47 release record](validation/Bello-Agent-0.1.47-2026-09-18.md).

## Verification of 0.1.46

**457 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures**; the
changed helper package passes its 154 cases, the Python scripts (52),
unchanged since 0.1.38, pass again, and the performance baseline ran again
in a Release build. The optional acceptance class and installation/update
rehearsals were not run. Details are in the
[0.1.46 release record](validation/Bello-Agent-0.1.46-2026-09-18.md).

## Verification of 0.1.45

**457 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures**; the
changed helper package passes its 154 cases, the Python scripts (52),
unchanged since 0.1.38, pass again, and the performance baseline ran again
in a Release build. The optional acceptance class and installation/update
rehearsals were not run. Details are in the
[0.1.45 release record](validation/Bello-Agent-0.1.45-2026-09-18.md).

## Verification of 0.1.44

**455 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures**; the
changed helper package passes its 151 cases, the Python scripts (52),
unchanged since 0.1.38, pass again, and the performance baseline ran again
in a Release build. The optional acceptance class and installation/update
rehearsals were not run. Details are in the
[0.1.44 release record](validation/Bello-Agent-0.1.44-2026-09-18.md).

## Verification of 0.1.43

**455 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures**; the
helper package (150) and the Python scripts (52), unchanged since
0.1.38, were run again and pass, and the performance baseline ran again in
a Release build. The optional acceptance class and installation/update
rehearsals were not run. Details are in the
[0.1.43 release record](validation/Bello-Agent-0.1.43-2026-09-18.md).

## Verification of 0.1.42

**453 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures**; the
helper package (150) and the Python scripts (52), unchanged since
0.1.38, were run again and pass, and the performance baseline ran again in
a Release build. The optional acceptance class and installation/update
rehearsals were not run. Details are in the
[0.1.42 release record](validation/Bello-Agent-0.1.42-2026-09-18.md).

## Verification of 0.1.41

**452 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures**; the
helper package (150) and the Python scripts (52), unchanged since
0.1.38, were run again and pass, and the performance baseline ran again in
a Release build. The optional acceptance class and installation/update
rehearsals were not run. Details are in the
[0.1.41 release record](validation/Bello-Agent-0.1.41-2026-09-18.md).

## Verification of 0.1.40

**452 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures**; the
helper package (150) and the Python scripts (52), unchanged since
0.1.38, were run again and pass, and the performance baseline ran in a
Release build. The optional acceptance class and installation/update
rehearsals were not run. Details are in the
[0.1.40 release record](validation/Bello-Agent-0.1.40-2026-09-18.md).

## Verification of 0.1.39

**446 native unit cases pass with 4 skipped, and the screenshot gallery
and terminal capture cases pass with 42 light/dark captures**; the
helper package (150) and the Python scripts (52) are unchanged since
0.1.38 and reuse that evidence. The optional acceptance class, the Release
performance matrix and installation/update rehearsals were not run. Details
are in the [0.1.39 release record](validation/Bello-Agent-0.1.39-2026-09-18.md).

## Verification of 0.1.38

**443 native unit cases pass with 4 skipped, the screenshot gallery and
terminal capture cases pass with 42 light/dark captures, and 150
helper cases pass**; the Python suite passes with 52 cases (the 10
dependency-cache cases left with npm), and the former 149 transcript/host
JavaScript cases are now native tests. The optional acceptance class, the
Release performance matrix and installation/update rehearsals were not run.
Details are in the [0.1.38 release record](validation/Bello-Agent-0.1.38-2026-09-18.md).

## Verification of 0.1.37

**423 native unit cases pass with 4 skipped, the screenshot gallery case
passes with 38 light/dark captures, and 150 helper and 149
transcript/host cases pass**; the Python suite (62) is unchanged since 0.1.36.
A new regression covers the window chrome. The optional acceptance class, the Release performance
matrix and installation/update rehearsals were not run. Details are in the
[0.1.37 release record](validation/Bello-Agent-0.1.37-2026-09-18.md).

## Verification of 0.1.36

**422 native unit cases pass with 4 skipped, the screenshot gallery case
passes with 38 light/dark captures, and 150 helper and 149
transcript/host cases pass**; the Python suite (62) is unchanged since 0.1.35.
New regressions cover per-route rates and medians in both query paths.
The optional acceptance class, the Release performance
matrix and installation/update rehearsals were not run. Details are in the
[0.1.36 release record](validation/Bello-Agent-0.1.36-2026-09-18.md).

## Verification of 0.1.35

**420 native unit cases pass with 4 skipped, the screenshot gallery case
passes with 34 light/dark captures, and 150 helper and 149
transcript/host cases pass**; the Python suite (62) is unchanged since 0.1.34.
New regressions cover typing redirection, side-close focus and edit focus.
The optional acceptance class, the Release performance
matrix and installation/update rehearsals were not run. Details are in the
[0.1.35 release record](validation/Bello-Agent-0.1.35-2026-09-18.md).

## Verification of 0.1.34

**418 native unit cases pass with 4 skipped, the screenshot gallery case
passes with 34 light/dark captures, and 150 helper and 149
transcript/host cases pass**; the Python suite (62) is unchanged since 0.1.33.
New regressions cover outcome-aware summaries, requested-change labels, stable
block keys, turn grouping by host turn id, measured model time and the
journaled turn fields. The optional acceptance class, the Release performance
matrix and installation/update rehearsals were not run. Details are in the
[0.1.34 release record](validation/Bello-Agent-0.1.34-2026-09-18.md).

## Verification of 0.1.33

**417 native unit cases pass with 4 skipped, the screenshot gallery case
passes with 34 light/dark captures, and 149 helper and 148
transcript/host cases pass**; the Python suite (62) is unchanged since 0.1.32.
New regressions cover the merged turn line, the stamp fix and code language labels. The optional acceptance
class, the Release performance matrix and installation/update rehearsals were
not run. Details are in the
[0.1.33 release record](validation/Bello-Agent-0.1.33-2026-09-17.md).

## Verification of 0.1.32

**417 native unit cases pass with 4 skipped, the screenshot gallery case
passes with 34 light/dark captures, and 149 helper and 146
transcript/host cases pass**; the Python suite (62) is unchanged since 0.1.31.
New regressions cover the live turn bar, action trails, diffs, teasers, stamps and quiet coverage. The optional acceptance
class, the Release performance matrix and installation/update rehearsals were
not run. Details are in the
[0.1.32 release record](validation/Bello-Agent-0.1.32-2026-09-17.md).

## Verification of 0.1.31

**417 native unit cases pass with 4 skipped, the screenshot gallery case
passes with 34 light/dark captures, and 149 helper and 145
transcript/host cases pass**; the Python suite (62) is unchanged since 0.1.30.
New regressions cover reply-line figures, turn summaries and the stacked token bar. The optional acceptance
class, the Release performance matrix and installation/update rehearsals were
not run. Details are in the
[0.1.31 release record](validation/Bello-Agent-0.1.31-2026-09-17.md).

## Verification of 0.1.30

**416 native unit cases pass with 4 skipped, the screenshot gallery case
passes with 34 light/dark captures, and 149 helper and 145
transcript/host cases pass**; the Python suite (62) is unchanged since 0.1.29.
New regressions cover turn usage sums, folded per-request rows and spinners. The optional acceptance
class, the Release performance matrix and installation/update rehearsals were
not run. Details are in the
[0.1.30 release record](validation/Bello-Agent-0.1.30-2026-09-17.md).

## Verification of 0.1.29

**416 native unit cases pass with 4 skipped, the screenshot gallery case
passes with 34 light/dark captures, and 149 helper and 144
transcript/host cases pass**; the Python suite (62) is unchanged since 0.1.28.
New regressions cover model-request retries, transcript paging, pending chats and sides,
and failure rows in the conversation. The optional acceptance
class, the Release performance matrix and installation/update rehearsals were
not run. Details are in the
[0.1.29 release record](validation/Bello-Agent-0.1.29-2026-09-17.md).

## Verification of 0.1.28

**411 native unit cases pass with 4 skipped, the screenshot gallery case
passes with 34 light/dark captures, and 144 helper and 143
transcript/host cases pass**; the Python suite (62) is unchanged since 0.1.27.
New regressions cover concurrent sessions sharing an editing gate, the
enriched git service, the side-by-side diff rows, turn totals and the Session
info timing figures. The optional acceptance
class, the Release performance matrix and installation/update rehearsals were
not run. Details are in the
[0.1.28 release record](validation/Bello-Agent-0.1.28-2026-09-17.md).

## Verification of 0.1.27

**408 native unit cases pass with 4 skipped and the screenshot gallery case
passes with 34 light/dark captures**; the transcript/host (143), helper
(142) and Python (62) suites are unchanged since 0.1.26. New regressions
cover the git service and diff parser and the explicit mini-model rule. The optional acceptance
class, the Release performance matrix and installation/update rehearsals were
not run. Details are in the
[0.1.27 release record](validation/Bello-Agent-0.1.27-2026-09-17.md).

## Verification of 0.1.26

**406 native unit cases pass with 4 skipped, the screenshot gallery case
passes with 32 light/dark captures, 143 transcript/host cases pass and
the helper suite passes with its new queue-editing case**; the Python suite is
unchanged since 0.1.22. New regressions cover queue editing, the title-model
fallback and claim release. The optional acceptance
class, the Release performance matrix and installation/update rehearsals were
not run. Details are in the
[0.1.26 release record](validation/Bello-Agent-0.1.26-2026-09-17.md).

## Verification of 0.1.25

**405 native unit cases pass with 4 skipped and the screenshot gallery case
passes with 32 light/dark captures**; the transcript/host, helper and
Python suites are unchanged since 0.1.24. The catalog refresh regression now
encodes the five-minute window. The optional acceptance
class, the Release performance matrix and installation/update rehearsals were
not run. Details are in the
[0.1.25 release record](validation/Bello-Agent-0.1.25-2026-09-17.md).

## Verification of 0.1.24

**405 native unit cases pass with 4 skipped, the screenshot gallery case
passes with 32 light/dark captures, and 143 transcript/host cases pass**;
the helper and Python suites are unchanged since 0.1.22. New regressions cover
per-reply blocks and their folded work line, accounting lines without
unreported figures, and the per-chat Dock badge. The optional acceptance
class, the Release performance matrix and installation/update rehearsals were
not run. Details are in the
[0.1.24 release record](validation/Bello-Agent-0.1.24-2026-09-17.md).

## Verification of 0.1.23

**405 native unit cases pass with 4 skipped and the screenshot gallery case
passes with 32 light/dark captures**; the transcript/host, helper and
Python suites are unchanged since 0.1.22. A new regression covers the
connection switch: rebinding, override reconciliation, next-chat default and
every refusal. The optional acceptance class, the Release performance matrix
and installation/update rehearsals were not run. Details are in the
[0.1.23 release record](validation/Bello-Agent-0.1.23-2026-09-17.md).

## Verification of 0.1.22

**404 native unit cases pass with 4 skipped, the screenshot gallery case passes
with 32 light/dark captures, and 143 transcript/host and 62 Python cases
pass**; the helper suite is unchanged since 0.1.20. New transcript regressions
cover the "Reasoned" header and folded reasoning. The stripped bundle passed the
release script's Gatekeeper, notarization and packaged-helper smoke checks. The
optional acceptance class, the Release performance matrix and
installation/update rehearsals were not run. Details are in the
[0.1.22 release record](validation/Bello-Agent-0.1.22-2026-09-17.md).

## Verification of 0.1.21

**404 native unit cases pass with 4 skipped, the screenshot gallery case passes
with 32 light/dark captures, the opt-in status-bar capture passes, and 143
transcript/host cases pass**; the helper (141) and Python (62) suites are
unchanged since 0.1.20 and reuse that evidence. New regressions cover unread
timing, archive navigation, status-bar buckets and activity grouping, accent
contrast on every surface, and the folded transcript header. The optional
acceptance class, the Release performance matrix and installation/update
rehearsals were not run. Details are in the
[0.1.21 release record](validation/Bello-Agent-0.1.21-2026-09-17.md).

## Verification of 0.1.20

**400 native unit cases pass with 4 skipped, the screenshot gallery case passes
with 32 light/dark captures, and 141 helper, 143 transcript/host and 62 Python
cases pass**, all from a clean worktree at the release source. New regressions
cover turn grouping and action descriptions in the transcript, helper message
clocks, tool durations and file diff statistics, the persisted model/tool time
split, the sidebar usage breakdown and the footer time split. The optional
acceptance class, the Release performance matrix and installation/update
rehearsals were not run. Another session's uncommitted accent contrast work in
the main checkout is excluded from this release. Details are in the
[0.1.20 release record](validation/Bello-Agent-0.1.20-2026-09-17.md).

## Verification of 0.1.19

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

## Historical verification of 0.1.18

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

## Historical verification of 0.1.17

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

## Historical verification of 0.1.16

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

## Historical verification of 0.1.15

**27 focused native tests passed with zero failures in 0.714 seconds**:
Workspace 17, ProjectSidebar 6 and ReleaseConfiguration 4. Three new regressions
cover live folder-selection state, cancellation/reopening and second-project
persistence with a fresh vault readback. These are state/integration checks;
physical NSOpenPanel interaction was not exercised. Unchanged context/catalog,
provider/transcript/capture evidence is reused from 0.1.14 and earlier records.
Installation/update rehearsals were skipped by owner instruction.

## Historical verification of 0.1.14

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

## Historical verification of 0.1.13

**108 focused native tests passed with zero failures in 13.773 seconds**:
GatewayAccounting 19, LiveAccounting 5, MenuBarMetrics 21, ModelCatalogEndpoint
19, ModelSwitch 15, ReleaseConfiguration 4, SessionTiming 9, SessionUsage 10,
SettingsSave 6.
Synthetic native fixtures cover picker rendering and timing charts. The release
record preserves the corrected Swift test-helper isolation error and explains
why an inactive-window mouse harness does not establish a physical click or
end-to-end hover test. Unchanged helper/provider, transcript and capture evidence
is reused from 0.1.12. No installation/update rehearsal was run.

## Historical verification of 0.1.12

**89 focused native tests passed with zero failures in 4.716 seconds**:
CapturedBody 14, CombinedResponse 21, MenuBarMetrics 21, MessageDetail 9,
SessionUsage 10 and Workspace 14. Five synthetic own-window views were inspected.
Helper/provider, transcript, catalog and storage evidence is reused from 0.1.11
and earlier records because those sources are unchanged. No deployed gateway,
full gallery, installation/update or signed owner/update rehearsal was run.

## Historical verification of 0.1.11

**103 unique focused native cases pass** after correcting two optional
screenshot readiness checks. The final 21-case viewer/context rerun passed in
1.248 seconds; helper ContextPreview 4 passed in 0.085 seconds, transcript 25
passed and TypeScript passed. Two synthetic own-window JPEGs were inspected.
The 100k-attempt Debug accounting fixture preserved attribution and coverage
(101-message page 605.350 ms; session-only 68.847 ms; one message 65.396 ms).
See the release record for individual suites and the original failures.
Unchanged catalog/onboarding/title and broader evidence is reused from 0.1.10
and earlier records; it was not rerun. No full gallery, deployed LiteLLM,
install/update/relaunch or signed owner/update rehearsal was performed.

## Historical verification of 0.1.10

**60 focused native tests passed, zero failures, in 6.899 seconds.**

| Native suite | Passed | Seconds |
| --- | ---: | ---: |
| ModelCatalogEndpoint | 18 | 5.365 |
| ModelSwitch | 11 | 0.243 |
| Onboarding | 18 | 0.684 |
| SettingsSave | 6 | 0.169 |
| TitleGeneration | 7 | 0.439 |

Checks read the actual application-bundle catalog and assert all six aliases,
context/output limits and reasoning choices. Legacy/blank defaults require no
gateway traffic or credential lookup; explicit catalogs retain source isolation,
credential-origin checks, caching and cancellation guards. Remembered choices,
Settings saves, onboarding probes and title-session isolation remain covered.

Three synthetic own-window picker JPEGs were visually inspected, with OCR
assertions for the default, custom-catalog and error views. No unrelated
application content is captured.
The unchanged helper, transcript, capture/accounting, chrome, broader native and
Keychain evidence is reused explicitly from the [0.1.9 record](validation/Bello-Agent-0.1.9-2026-09-16.md)
and its linked historical records. Those are not additional tests run for 0.1.10.
No full gallery, deployed LiteLLM, fresh-install, Sparkle update/relaunch or signed
owner/update rehearsal was run. Log: `catalog-default-fix/native.log` in session scratch.

## Historical verification of 0.1.9

**155 unique focused native tests pass after corrections and focused reruns.**
The first broad selected run executed 155 tests in 19.717 seconds with four
failed assertions across two cases: catalog-render inspection and a 28-point
native safe-area inset. The layout fix applies top safe-area handling to the
split child; the final WindowPresentation/ReportNavigation rerun passes.
The eight WindowPresentation/ReportNavigation cases pass in native-ui-rerun.log. That 22-case run also included the catalog check, which was corrected and passed in its separate final 14-case rerun; repeated cases are not added to the unique total.
ModelCatalogEndpoint's 14 cases pass in 4.124 seconds in native-picker-final.log. The fixture's inaccessible test-process accessibility tree was replaced with local Vision OCR over actual rendered window pixels, checking catalog names/aliases, wrong-source exclusion, source-change errors and removal of stale choices. Both picker JPEGs were inspected.

Helper title/session/context checks: **17 passed in 0.494 seconds**. Transcript:
**24 passed in 0.811 seconds**; TypeScript passes. Capture coverage includes
CapturedBody 9, MessageDetail 7 and PayloadArchive 13. TitleGeneration 7 includes
an actual packaged-helper loopback request checking the chosen mini model,
512-token output cap, disabled tools, isolated instructions, one dispatch,
durable title session and separate capture/cost accounting.

The 100,000-attempt/300,100-link Debug fixture preserves attribution and
coverage: a 101-message page took **555.924 ms**, session-only **56.682 ms**, and
a single-message query **59.201 ms**. These are local database timings, not
input-to-paint measurements or the full Release performance budget.

Eleven synthetic JPEGs were inspected: five session/menu usage views, three window-chrome views, expandable JSON, and two model-picker views. They show only isolated fixture windows, not unrelated applications.
Unchanged broader provider/wire/process, Python, native/gallery and ordinary
Keychain evidence is reused from versioned records. No full gallery, deployed
LiteLLM test, production gateway credentials, install/update or signed owner/update
rehearsal was used.

| Focused native suite | Final passing cases |
| --- | --- |
| AccountingScale | 1 |
| CapturedBody / MessageDetail / PayloadArchive | 9 / 7 / 13 |
| GatewayAccounting / LiveAccounting | 16 / 5 |
| MenuBarMetrics / MenuBarPresentation / SessionUsage | 21 / 3 / 6 |
| ModelCatalogEndpoint / ModelSwitch | 14 / 11 |
| ProjectSidebar / SessionOrganization | 6 / 8 |
| SettingsSave / TitleGeneration | 6 / 7 |
| WindowPresentation / ReportNavigation | 5 / 3 |
| Workspace | 14 |

## Historical verification of 0.1.8

**Eight unique focused native tests pass**: WindowPresentation 5 and
ReportNavigation 3 (5.409 seconds combined). The five window tests passed again
(2.756 seconds) after optional capture-readiness changes. Three synthetic JPEGs
were inspected: light chat, compact dark chat and light report. Checks cover the
real SwiftUI WindowGroup after layout/resize, native-control exclusions,
zoom/restore, focus/drafts and retained report/chat surfaces. A test-only SDK
compile issue was corrected; no test assertion failed. See the
[0.1.8 record](validation/Bello-Agent-0.1.8-2026-09-16.md) for scope and logs.

Unchanged 0.1.7 (81 tests) and broader 0.1.6 evidence is reused. No full native
suite/gallery, provider/performance acceptance, install/update or signed
owner/update rehearsal was run.

App/DMG signing and notarization, local smoke checks, public pages/icon, identical
update feeds and downloaded archive SHA-256/Ed25519 verification pass.

## Historical verification of 0.1.7

All **81 unique affected native tests pass**: GatewayModelDiscovery 9,
ModelCatalogEndpoint 12, ProjectSidebar 6, Workspace 14, ModelSwitch 11,
Dashboard 14 and MenuBarMetrics 15. They cover non-hover catalog loading,
saved-profile changes, remembered choices across restart/projects, pending-save
ordering, atomic rollback and model-conflict reporting. The restart fixture
initially retained the previous instance's archive lock; closing that archive
fixed the fixture, with all original assertions retained. Exact timings and
logs are in the [0.1.7 record](validation/Bello-Agent-0.1.7-2026-09-16.md).

Unchanged helper, wire, process, transcript and broader native/gallery results
below are reused, not rerun. No new full suite, gallery, full interactive gateway,
signed owner/update, install or Sparkle update rehearsal is claimed. Code signing,
app/DMG notarization, local feed/archive/smoke checks and public artifact
verification pass. Existing UI/performance and deployed-gateway
limits remain unchanged.

## Historical verification of 0.1.6

That release's source acceptance covers the reviewed Settings, scratch connection-test,
catalog, fallback, compaction, report/sidebar and selected-icon changes.
Signing/notarization, public verification and the actual update are complete;
exact distribution evidence is in the linked 0.1.6 release record.

| Check | Result |
| --- | --- |
| Swift helper full suite | 105 passed, 5.179 seconds |
| Optimized helper wire | 24 passed, 5.339 seconds |
| Process/MCP recovery | 2 passed, 2.599 seconds |
| Python release/gateway suite | 52 passed, 17.046 seconds |
| Transcript | 21 passed, 0.933 seconds; TypeScript passed |
| Full native app suite, gallery enabled | 247 executed: 246 passed, one interactive opt-in skip, zero failures; 91.525 seconds |
| Included screenshot gallery/onboarding boundary | One passed, 75.464 seconds; 30 light/dark images |
| Isolated signed Keychain owner/update acceptance | 51 checks/observations passed |

The gallery is included in the native total. The four Settings regressions and
five native follow-up tests cover preserved connections, invalid edits, the
scratch composer and empty tool preview, selection-independent test submission,
side restrictions, child deletion and authoritative compaction notices. Helper
regressions cover successful, failed, cancelled and abandoned-branch summaries.
The scratch composer test sends no HTTP request. The gallery exercises the
packaged onboarding helper/scoped vault before chat creation.

The eight-request/sixteen-body CUA run below belongs to 0.1.5 and was not repeated
for 0.1.6. Current fixtures use synthetic vaults and loopback gateways, without
production credentials or a deployed LiteLLM service. Initial fixture failures,
corrections and original logs are recorded in the 0.1.6 release record.

## Historical verification of 0.1.5

The final native/gallery run includes updater edit-draft preservation and
composer update-loop corrections. Distribution evidence is recorded separately
in the linked release record.

| Check | Result |
| --- | --- |
| Swift helper full suite | 101 passed, 4.905 seconds |
| Optimized helper wire | 24 passed, 5.160 seconds |
| Process/MCP recovery | 2 passed, 2.576 seconds |
| Python release/gateway suite | 52 passed, 16.967 seconds |
| Transcript | 21 passed; TypeScript passed |
| Full native app suite, gallery enabled | 236 executed: 235 passed, one opt-in skip, zero failures; 91.136 seconds |
| Included screenshot gallery/onboarding boundary | One passed, 75.587 seconds; 30 light/dark images |
| Separate CUA fixture | One passed, 670.249 seconds; eight requests, 16 independently matched exact bodies, 1,290 tokens, $0.0101375 |

The gallery is included in the full native total, not an additional test. The
separate CUA run opens the menu twice, checks day/retained usage scopes, Report,
main-window close/recovery, background cost and unread updates, session
rename/pin/archive/restore, exact code/Markdown-section copying, context preview,
captured requests and directly displayed headers, a Bello-only skill toggle,
empty `/side` creation and draft close/reopen, and `/fork`. It also performs an
actual title-bar double-click zoom and restore. All gateway traffic is synthetic
loopback traffic; no production credentials or deployed LiteLLM were used.
Physical status-item clicks, successful foreground unread clearing, real-language
IME and the full Release performance budget are not claimed by this run.

## Historical verification of 0.1.4

Environment: macOS 14.8 arm64, Xcode 16.1 / Swift 6.0.2, XcodeGen 2.44.1.
The [0.1.4 record](validation/Bello-Agent-0.1.4-2026-09-16.md) contains commands,
logs and the exact source scope; earlier counts are historical.

| Check | Result |
| --- | --- |
| Swift helper full suite | 92 passed, 4.862 seconds |
| Final focused activity suite | 3 passed, 0.091 seconds, including the additional silent-tool notification regression |
| Optimized helper wire | 23 passed, 3.110 seconds |
| Process/MCP recovery | 2 passed, 2.586 seconds |
| Python release/gateway suite | 52 passed, 17.159 seconds |
| Native app suite | 195 executed: 193 passed, two opt-in skips, zero failures; 12.980 seconds |
| Transcript | 13 passed; TypeScript passed |
| Final report-page regression | 15 passed, 1.330 seconds; compact grouping/pagination controls corrected |
| Native screenshot gallery/onboarding boundary | One passed, 76.585 seconds; 30 light/dark images |
| Final fresh-state CUA fixture | One passed, 284.612 seconds; four requests, eight independently matched bodies, 677 tokens, $0.0051375 |

The gallery calls `verifyOnboardingConnection` through the packaged helper and
scoped test vault before any chat exists, verifies cleanup and renders the app.
The final CUA run covers the owner's billing sample, a tool round trip, a slow
reply, details, report/message navigation, usage scopes and menu recovery after
closing the main window. It shows 13.5 estimated output tokens/second during
streaming. The earlier seven-request CUA run additionally showed running and
pending work together; its separate scope remains in the validation record.

Unread correctly remained while Report was visible. During the final attempt to
verify foreground clearing, macOS SecurityAgent owned focus and CUA refused
access to it. **Successful foreground clearing is not claimed from that CUA
run.** Native tests cover painted-frame ordering, visibility, stale receipts,
restart and explicit marking. The fixture invokes the real status-button action;
physical left/right menu-bar clicks are separately outside CUA coverage, although
both event masks have native tests.

## Distribution and remaining limits

- **0.1.48 distribution is complete.** Source `c52a3d1`, website `67e1eb1`;
  **7,203,566 bytes (6.87 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.47 distribution is complete.** Source `a093b4d`, website `4580f6b`;
  **7,186,673 bytes (6.85 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.46 distribution is complete.** Source `3fcb762`, website `def13c3`;
  **7,180,448 bytes (6.85 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.45 distribution is complete.** Source `9af946d`, website `d52e8ac`;
  **7,179,717 bytes (6.85 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.44 distribution is complete.** Source `a0cc15e`, website `7199c73`;
  **7,160,116 bytes (6.83 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.43 distribution is complete.** Source `b3491f8`, website `8008e13`;
  **7,161,822 bytes (6.83 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.42 distribution is complete.** Source `6b80619`, website `1e57c83`;
  **7,137,493 bytes (6.81 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.41 distribution is complete.** Source `4bfa49e`, website `a11fb29`;
  **7,115,515 bytes (6.79 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.40 distribution is complete.** Source `d280227`, website `65730b4`;
  **7,113,393 bytes (6.78 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.39 distribution is complete.** Source `a88bddb`, website `a7d2d22`;
  **7,149,724 bytes (6.82 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.38 distribution is complete.** Source `bf04acf`, website `7538ca1`;
  **7,128,652 bytes (6.80 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.37 distribution is complete.** Source `f803d90`, website `4363262`;
  **7,336,336 bytes (7.00 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.36 distribution is complete.** Source `e1836b3`, website `942d788`;
  **7,328,637 bytes (6.99 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.35 distribution is complete.** Source `2f1e33f`, website `c5ef318`;
  **7,283,236 bytes (6.95 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.34 distribution is complete.** Source `124b2f2`, website `1b8ef22`;
  **7,275,516 bytes (6.94 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.33 distribution is complete.** Source `e677cdd`, website `f7d6e1a`;
  **7,268,189 bytes (6.93 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.32 distribution is complete.** Source `094ea5c`, website `86ea696`;
  **7,256,957 bytes (6.92 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.31 distribution is complete.** Source `3ba3c8a`, website `fa1de3d`;
  **7,246,039 bytes (6.91 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.30 distribution is complete.** Source `c9ef75a`, website `a7ad6b2`;
  **7,238,488 bytes (6.90 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.29 distribution is complete.** Source `40675e8`, website `8cfe0b1`;
  **7,237,359 bytes (6.90 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.28 distribution is complete.** Source `5c8d514`, website `1198f1e`;
  **7,230,232 bytes (6.90 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.27 distribution is complete.** Source `6e74ece`, website `1826ed0`;
  **6,467,351 bytes (6.17 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.26 distribution is complete.** Source `f9c4edb`, website `332fa57`;
  **6,324,764 bytes (6.03 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.25 distribution is complete.** Source `541b206`, website `74365cd`;
  **6,277,089 bytes (5.99 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.24 distribution is complete.** Source `f5cd242`, website `679e9d4`;
  **6,275,896 bytes (5.99 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.23 distribution is complete.** Source `9fe4cbc`, website `9d3156f`;
  **6,276,182 bytes (5.99 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.22 distribution is complete.** Source `6e3cc97`, website `e899b8a`;
  **6,261,291 bytes (5.97 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.21 distribution is complete.** Source `6654428`, website `7ac59ce`;
  **7,409,250 bytes (7.07 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.20 distribution is complete.** Source `26579aa`, website `4b67a23`;
  **7,326,425 bytes (6.99 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.19 distribution is complete.** Source `9b94e4d`, website `d37b885`;
  **7,288,456 bytes (6.95 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.18 distribution is complete.** Source `29e2da5`, website `69c6862`;
  **7,230,028 bytes (6.90 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.17 distribution is complete.** Source `bbe02ec`, website `2cb0c45`;
  **7,215,669 bytes (6.88 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.16 distribution is complete.** Source `f680fc8`, website `d501b2a`;
  **7,167,470 bytes (6.84 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.15 distribution is complete.** Source `65061de`, website `dd6f206`;
  **7,137,895 bytes (6.81 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.14 distribution is complete.** Source `2542f31`, website `d4ba4e3`;
  **7,135,182 bytes (6.80 MiB)**. Signing/notarization and public artifact checks pass.
  No installation/update rehearsal.
- **Historical 0.1.13 distribution is complete.** Source `a06287b`, website `cd28c3c`;
  **7,118,570 bytes (6.79 MiB)**. Signing/notarization, packaged smoke, public pages/icon
  and feed/archive hash/signature checks pass. No installation/update rehearsal.
- **Historical 0.1.12 distribution is complete.** Source `5bf9a82`, website `9154d3f`;
  **6,989,644 bytes (6.67 MiB)**. Signing/notarization, packaged smoke, public pages/icon
  and feed/archive hash/signature checks pass. No installation/update rehearsal.
- **Historical 0.1.11 distribution is complete.** Source `bca8f81`, website `0264f7a`;
  **6,937,176 bytes (6.62 MiB)**. Signing/notarization, packaged smoke, public pages/icon
  and feed/archive hash/signature checks pass. No installation/update rehearsal.
- **Historical 0.1.10 distribution is complete.** App/DMG signing and notarization,
  packaged-catalog/helper smoke, public pages/icon, identical update feeds and
  downloaded archive SHA-256/Ed25519 verification pass. Source `d1908dc`, website
  `b93433b`; 6,901,746-byte installer. No installation/update rehearsal was run.
- **Historical 0.1.9 distribution is complete.** App/DMG signing and notarization, local
  smoke checks, public pages/icon, identical update feeds and downloaded archive
  SHA-256/Ed25519 verification pass. Source `e3940fe`, website `856b711`;
  6,902,731-byte installer. No installation/update rehearsal was run.
- **Historical 0.1.8 distribution is complete.** App/DMG signing and notarization, local smoke
  checks, public pages/icon, identical update feeds and downloaded archive
  SHA-256/Ed25519 verification pass. Source `3880709`, website `956a863`; 6,691,444-byte
  archive. No install/update rehearsal was run.
- **Historical 0.1.7 distribution is complete.** App/DMG signing/notarization, local smoke
  checks, public product/home/legacy pages, exact icon bytes, identical update
  feeds and downloaded archive SHA-256/Ed25519 verification pass. Website
  `90ffc8f` serves the 6,688,314-byte archive. No install/update or signed
  owner/update rehearsal was run, following owner instruction.
- **Historical 0.1.6 distribution is complete.** App and DMG notarization, public pages/icon,
  identical canonical/legacy feeds and the downloaded archive's SHA-256/Ed25519
  signature pass; website commit `d92957c`. The actual 0.1.5→0.1.6 Sparkle update
  installed/relaunched at the existing app path with all 75 files/links matching
  the signed release; deep strict codesign, stapler and Gatekeeper pass. Five
  chats, five drafts and five journals remain. All journal bytes and ten of
  eleven chat/draft/workspace records are byte-identical; one empty draft was
  re-encoded with JSON key order only, and its original hash was reproduced
  from the unchanged values. Settings Reload Vault succeeds at unchanged
  revision 0, then is canceled without saving or a gateway request. The new icon
  is visible after launch. The isolated signed synthetic Keychain suite passed
  all 51 checks/observations for this release.
- **Historical 0.1.5 distribution is complete.** App and DMG notarization, public bytes/
  signature, product page and actual 0.1.4→0.1.5 installation pass; website commit
  `51d81cf`. All 75 installed files/links match. The existing empty vault reloads
  at revision 0 without settings writes, a real gateway request or signing-key
  policy changes. The unchanged ordinary-Keychain policy retains the prior
  isolated 51-check evidence; that full suite was not repeated for this release.
- **Historical 0.1.4 distribution is complete.** App and DMG notarization, public bytes/
  signature and actual 0.1.3→0.1.4 installation pass; website commit `75c4090`.
  The isolated signed Keychain suite also passed all 51 checks/observations.
- **0.1.3 is the historical distribution baseline.** Its 4,787,386-byte DMG,
  notarization, public hash/signature and actual update passed. Website commit
  `61456d6` supplied byte-identical canonical/legacy feeds. Exact hashes and the
  75-file/symlink installed-app comparison remain in the 0.1.3 record.
- **Ordinary Keychain remains selected.** One versioned item, scoped helper IPC,
  no plaintext/per-profile fallback. The Data Protection/access-group requirement
  and interim `~/.bello-agent` settings proposal were superseded. Historical
  0.1.6 signed owner/update acceptance completed 51
  checks/observations without failures or production-vault access. No signing-key ACL or persistent policy
  changed. Standard Keychain does not guarantee raw same-user write/delete isolation.
- **Real deployment remains unverified.** Local request-aware gateways validate
  requests before choosing responses, including malformed-request rejection and
  exact byte comparisons. They are not an installed/deployed LiteLLM service.
  No real gateway or production credentials were used.
- **UI/performance limits remain explicit.** Physical status-item clicks, chart
  dragging, real-language IME and the full Release performance budget remain
  unverified. Historical Debug burst-input and helper-to-paint targets were not
  met; the 0.1.3 record preserves those measurements without discarded samples.
- **HTTP-body full-text search stays deferred.** Chat search and request metadata
  filters remain. The exact selected flat icon is now the release asset; the
  discarded transparency derivative was not used. Its source/provenance remains
  committed alongside the master artwork.

## Continuation

Read this file, `Features.md`, `Design.md`, the
[parity document](Swift-Feature-Parity.md) and [test handoff](Swift-Test-Handoff.md).
Preserve passing source and user history, fix actual failures with focused
regressions, and use small reviewable commits on `master` with normal pushes.
Preserve current 0.1.48 acceptance and the completed 0.1.47/0.1.46/0.1.45/0.1.44/0.1.43/0.1.42/0.1.41/0.1.40/0.1.39/0.1.38/0.1.37/0.1.36/0.1.35/0.1.34/0.1.33/0.1.32/0.1.31/0.1.30/0.1.29/0.1.28/0.1.27/0.1.26/0.1.25/0.1.24/0.1.23/0.1.22/0.1.21/0.1.20/0.1.19/0.1.12/0.1.11/0.1.10/0.1.9/0.1.8/0.1.7/0.1.6/0.1.5/0.1.4 historical
source/distribution records. Repeat validation when changed source or a concrete
concern warrants it; install/update rehearsals still require a new explicit
owner request. The [continuation prompt](Continue-Implementation-Prompt.md) carries the
current constraints; raw HTTP bodies are never replaced by normalized events.
