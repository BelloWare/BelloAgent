# Earlier b3 native focused checks

[migration-peer report6067713313](https://github.com/BelloWare/BelloAgent/issues/1#issuecomment-6067713313) records28 focused tests passed, zero failures/ignored, on exact
`b3acabc25817fbac97f54b73c88362fa584d40e3`, tree
`b88d8335683a7c116b1f9aac21f7fda7842c5f16`.

The attributed macOS14.8 /Xcode16.1 /Rust1.91.1 checks comprise three
workspace lease regressions,17 MCP concurrency tests, four native/Controller
concurrency tests and four native source-oracle tests. No retries or source
edits were reported; all2111 tracked paths/modes/blobs were reported unchanged.
The original commands, raw logs and hashes remain in the linked issue comment.

This is peer-reported native CLI/synthetic evidence for the earlier published
b3 source. It is not native execution of this new live-card candidate and is
not interactive GUI, Keychain, TCC/AX, signing, release or performance acceptance.
