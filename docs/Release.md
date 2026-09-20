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

App staging builds only the Swift helper: there is no package manager step,
no downloaded runtime and no transcript asset build since 0.1.38. Swift builds
remain incremental.

The sibling BelloClipboardManager, BelloTracker and BelloBox scripts were inspected
before implementing this flow. They use Developer ID team `43TXHV3TM3`, notarization,
the existing Sparkle Ed25519 signing key in the login Keychain, and assets
committed/pushed to the sibling `belloware.com` repository (Cloudflare hosting).
The canonical Bello Agent feed is `https://belloware.com/assets/bello_agent.appcast.xml`.
The legacy `pi_app.appcast.xml` feed remains byte-identical so existing Pi App
installations receive the same update.
**Bello Agent 0.1.60/build 64 is publicly released** at
[belloware.com](https://belloware.com/bello-agent.html), from source `ce252bcabe542efc58d87774f16bbe09b4a646d8`
and website `4ceb9e8773b605931d15eceaf04b0e4947f6f2c7`. The DMG measures **7,824,296 bytes (7.46 MiB)**,
SHA-256 `0cf92ca649e56a4293a404fa98a9d8fcbe547d2ee9a97222a04be124e1cc81c7`. Signing, notarization, packaged helper/catalog smoke,
identical canonical/legacy feeds and downloaded archive SHA-256/Ed25519
verification pass. Public verification: **2026-09-19 23:24:08 UTC**.
Read the [0.1.60 release record](validation/Bello-Agent-0.1.60-2026-09-19.md). Source commits remain local;
the website publication commit was pushed.

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

**394 unique native cases and 140 unique helper cases have a final
pass; 6 optional visual/interactive native captures were skipped.** The broad
native run had one failing case (two assertions); its corrected expectation and
affected behavior passed the 54-case focused rerun; the final nine-case export
and release-configuration check passed. The helper's full 138-case
suite passed, followed by 12 focused queue/recovery cases, including two new
regressions reproduced before the fix. Repeated cases are counted once.
Since 0.1.38 the transcript is native Swift and its tests run inside the native
suite. Local HTTP/SSE fixtures validate requests, tools,
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
Node/Pi distribution. Since 0.1.38 the terminal panel is the app's own
emulator (`apps/macos/PiApp/Terminal`): SwiftTerm, linked from 0.1.28 to 0.1.37,
is gone, and Sparkle is the only third-party code in the bundle;
`ThirdPartyNotices.txt` in the bundle's Resources says so, next to Sparkle's own
framework licence. Since 0.1.22 the release script strips the app and helper
binaries before signing (the symbol table was more than half of the app binary)
and keeps their dSYMs in the release directory for crash symbolication; nothing
else about the bundle changes, and dead-code stripping remains off. The 0.1.48 DMG measures **7,203,566 bytes (6.87 MiB)**, SHA-256
`5b74ee2fded4a7ca8305a157d85db95a979b842ee6ab66624d1f1b14af129bd4`.
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
3. Commit Bello Agent's intended source changes. **Owner policy, 2026-09-18:
   a release does not push the source repository.** `publish-release.sh`
   therefore requires only a clean worktree and a committed `HEAD`, not that the
   commit reached the remote. The repository is pushed when the owner asks for
   it, as one squashed commit, so a validation record's source SHA names a local
   commit until that push happens. The website repository is still pushed by
   step 6, because pushing it is how the site deploys.
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
