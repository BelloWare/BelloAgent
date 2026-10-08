# Per-file review ledger

## rust/crates/bello-agent-app/src/transcript_live_terminal_ui_tests.rs

Entire new file is support: main.rs positive cfg(test) owns transcript_view_tests, which owns live_terminal_ui through its new path/module declaration.

Before SHA-256: None

After SHA-256: 9e23463131e5f63e471bb586c48606bc60c91e842cf3faf7a994f46b95bc6932

Baseline classification: New whole test module owned by transcript_view_tests (main.rs:51-52 positive cfg(test)); child module declared at transcript_view_tests.rs:2501-2502.

Before counts: {"production": 0, "tests_and_test_support": 0, "benchmark_example": 0}

Before support ranges (inclusive physical line numbers): none

After counts: {"production": 0, "tests_and_test_support": 268, "benchmark_example": 0}

After support ranges (inclusive physical line numbers): 1–275

Delta: {"production": 0, "tests_and_test_support": 268, "benchmark_example": 0}

## rust/crates/bello-agent-app/src/transcript_tool_presentation.rs

All added fixture helpers and tests lie within the existing positive cfg(test) tests module. Production is unchanged.

Before SHA-256: 04b156e50d7fec468e3c36325b49a9dcd35f4d5d9841315288fbf3d19ac7812c

After SHA-256: d54b8b166a2d413b3bfff40b617e6c8d5834cc636838c069fb21ffd3f85df7f6

Baseline classification: rust/docs/validation/bash-workflow-2026-10-07/loc/loc-bash-workflow-2026-10-07-delta.json

Before counts: {"production": 343, "tests_and_test_support": 303, "benchmark_example": 0}

Before support ranges (inclusive physical line numbers): 358–663

After counts: {"production": 343, "tests_and_test_support": 486, "benchmark_example": 0}

After support ranges (inclusive physical line numbers): 358–850

Delta: {"production": 0, "tests_and_test_support": 183, "benchmark_example": 0}

## rust/crates/bello-agent-app/src/transcript_view_tests.rs

Entire source is support through main.rs positive cfg(test). New child-module declaration adds two nonblank support lines.

Before SHA-256: a5e80daf6349ce0150da6559883537d23c0231f1fc16fab256271b4c57246c21

After SHA-256: fa8dd2007b694412db42b8e4c0bca9f374b47a8bd3c9fce58172efdedfdd43ef

Baseline classification: rust/docs/validation/bash-workflow-2026-10-07/loc/loc-bash-workflow-2026-10-07-delta.json

Before counts: {"production": 0, "tests_and_test_support": 2427, "benchmark_example": 0}

Before support ranges (inclusive physical line numbers): 1–2499

After counts: {"production": 0, "tests_and_test_support": 2429, "benchmark_example": 0}

After support ranges (inclusive physical line numbers): 1–2502

Delta: {"production": 0, "tests_and_test_support": 2, "benchmark_example": 0}

## rust/crates/bello-agent-core/src/live_tool_runtime.rs

New bounded preview, admission and terminal-state implementation is production, including its comments and debug assertions. Existing three-line positive cfg(test) child-module declaration remains support and moves with the implementation.

Before SHA-256: c869782499452f080ad426741bb9ede02bd8285f3263c9752b8f1fc84852f76d

After SHA-256: a1b934d864f1b3d7ce5197816517f48f02695301e3cb287575119468699ac20d

Baseline classification: rust/docs/validation/bash-workflow-2026-10-07/loc/loc-bash-workflow-2026-10-07-delta.json

Before counts: {"production": 128, "tests_and_test_support": 3, "benchmark_example": 0}

Before support ranges (inclusive physical line numbers): 131–133

After counts: {"production": 198, "tests_and_test_support": 3, "benchmark_example": 0}

After support ranges (inclusive physical line numbers): 204–206

Delta: {"production": 70, "tests_and_test_support": 0, "benchmark_example": 0}

## rust/crates/bello-agent-core/src/live_tool_runtime_tests.rs

Entire source is support through the positive cfg(test) owner in live_tool_runtime.rs.

Before SHA-256: 70fb7b88b9fa6b4bc83d164e2a1e6b9cdf3acefe77a456891be26050e74ff9ba

After SHA-256: 5b6365690fdd0ec88d388c5a57af4197d13804f9dfa2b1f148e960aa1d57e9c2

Baseline classification: rust/docs/validation/bash-workflow-2026-10-07/loc/loc-bash-workflow-2026-10-07-delta.json

Before counts: {"production": 0, "tests_and_test_support": 125, "benchmark_example": 0}

Before support ranges (inclusive physical line numbers): 1–128

After counts: {"production": 0, "tests_and_test_support": 302, "benchmark_example": 0}

After support ranges (inclusive physical line numbers): 1–310

Delta: {"production": 0, "tests_and_test_support": 177, "benchmark_example": 0}

## rust/crates/bello-agent-core/src/mcp/concurrency_tests.rs

Entire existing source remains support through its test-only MCP module ownership; historical exact-blob classification inherited.

Before SHA-256: bb6012d2ee1285d54c23bf16f5a76ca17c89ca79ecc5983cb3cb203e92ea0e79

After SHA-256: 726f68c6243426b91a49dde19b470c26461ae062f84761e31d56c9f0658607e1

Baseline classification: rust/docs/validation/concurrent-tools-2026-10-08/loc-pre-lease.json

Before counts: {"production": 0, "tests_and_test_support": 811, "benchmark_example": 0}

Before support ranges (inclusive physical line numbers): 1–829

After counts: {"production": 0, "tests_and_test_support": 911, "benchmark_example": 0}

After support ranges (inclusive physical line numbers): 1–929

Delta: {"production": 0, "tests_and_test_support": 100, "benchmark_example": 0}

## rust/crates/bello-agent-core/src/tool_runtime.rs

Changed native/MCP dispatch and terminal result publication occur wholly in the production block. Existing test/synthetic-only support ranges are unchanged except for mapped line positions; comments in the changed dispatch block are production.

Before SHA-256: 8598673ab20398bf88d642e2f76bc2f5935f2f17e78c671cf56333eb0cc8e7f3

After SHA-256: 29167de0b529880d1f96a1b33de9ce603db85f4d99ba6b200bbf73d1d22c3a97

Baseline classification: rust/docs/validation/concurrent-tools-2026-10-08/loc-pre-lease.json

Before counts: {"production": 967, "tests_and_test_support": 634, "benchmark_example": 0}

Before support ranges (inclusive physical line numbers): 81–88, 141–153, 196–208, 603–623, 657–665, 677–680, 885–900, 902–911, 988–991, 1046–1082, 1131–1545, 1547–1557, 1559–1561, 1563–1634, 1636–1638, 1640–1642, 1644–1646

After counts: {"production": 969, "tests_and_test_support": 634, "benchmark_example": 0}

After support ranges (inclusive physical line numbers): 81–88, 141–153, 196–208, 605–625, 659–667, 679–682, 887–902, 904–913, 990–993, 1048–1084, 1133–1547, 1549–1559, 1561–1563, 1565–1636, 1638–1640, 1642–1644, 1646–1648

Delta: {"production": 2, "tests_and_test_support": 0, "benchmark_example": 0}

