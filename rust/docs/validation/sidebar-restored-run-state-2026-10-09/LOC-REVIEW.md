# Sidebar/FIFO per-file range review

Ranges are inclusive physical lines; counts include nonblank comments.

## rust/crates/bello-agent-app/src/main.rs

Classification source: classification-evidence/rust/docs/validation/conversation-content-2026-10-09/loc-audit.json

Before SHA-256: e46f4eaf4488e731a518627d80d1aebacc89a85d8c58ca08d1a83496b06b14cd

Before counts: {"production": 3554, "tests_and_test_support": 111, "benchmark_example": 0}

Before production ranges: 1–1, 4–25, 28–51, 55–56, 59–170, 173–189, 192–232, 242–398, 401–443, 446–3435, 3438–3443, 3450–3460, 3478–3485, 3490–3494, 3498–3506, 3537–3570, 3582–3589, 3594–3629, 3636–3667, 3670–3672

Before support ranges: 2–3, 26–27, 52–54, 57–58, 171–172, 190–191, 233–241, 399–400, 444–445, 3436–3437, 3444–3449, 3461–3477, 3486–3489, 3495–3497, 3507–3536, 3571–3581, 3590–3593, 3630–3635, 3668–3669

After SHA-256: 4ddfec61ab59204d4a0031eee8da3fd18b8f8a0beec54ec0258c8061c4eb2661

After counts: {"production": 3548, "tests_and_test_support": 111, "benchmark_example": 0}

After production ranges: 1–1, 4–25, 28–52, 56–57, 60–172, 175–191, 194–234, 244–400, 403–446, 449–3429, 3432–3437, 3444–3454, 3472–3479, 3484–3488, 3492–3500, 3531–3564, 3576–3583, 3588–3623, 3630–3661, 3664–3666

After support ranges: 2–3, 26–27, 53–55, 58–59, 173–174, 192–193, 235–243, 401–402, 447–448, 3430–3431, 3438–3443, 3455–3471, 3480–3483, 3489–3491, 3501–3530, 3565–3575, 3584–3587, 3624–3629, 3662–3663

Delta: {"production": -6, "tests_and_test_support": 0, "benchmark_example": 0}

## rust/crates/bello-agent-app/src/sidebar_run_state.rs

Classification source: New source individually reviewed; exact positive cfg(test) range or test-only module ownership.

Before SHA-256: None

Before counts: {"production": 0, "tests_and_test_support": 0, "benchmark_example": 0}

Before production ranges: none

Before support ranges: none

After SHA-256: 31487f24603546ec99cce65c7c55c3e004259984a1cfee8de09305294db70dd6

After counts: {"production": 278, "tests_and_test_support": 3, "benchmark_example": 0}

After production ranges: 1–287

After support ranges: 288–290

Delta: {"production": 278, "tests_and_test_support": 3, "benchmark_example": 0}

## rust/crates/bello-agent-app/src/sidebar_run_state_tests.rs

Classification source: New source individually reviewed; exact positive cfg(test) range or test-only module ownership.

Before SHA-256: None

Before counts: {"production": 0, "tests_and_test_support": 0, "benchmark_example": 0}

Before production ranges: none

Before support ranges: none

After SHA-256: f4ed6611c60ea0f023128713b689592528237e65183db639919e906b6a6c60aa

After counts: {"production": 0, "tests_and_test_support": 473, "benchmark_example": 0}

After production ranges: none

After support ranges: 1–487

Delta: {"production": 0, "tests_and_test_support": 473, "benchmark_example": 0}

## rust/crates/bello-agent-core/src/session.rs

Classification source: classification-evidence/rust/docs/validation/context-recovery-2026-10-08/loc-audit.json

Before SHA-256: 38a20b3a21dfa9a7f13ca4951e24ece49c0d7f3d75524d8053375c7ed0e31edd

Before counts: {"production": 1611, "tests_and_test_support": 1531, "benchmark_example": 0}

Before production ranges: 1–898, 908–1076, 1079–1095, 1098–1301, 1304–1470, 1477–1554, 1559–1559, 1566–1661, 1665–1665, 3075–3075, 3167–3167, 3171–3171, 3175–3175

Before support ranges: 899–907, 1077–1078, 1096–1097, 1302–1303, 1471–1476, 1555–1558, 1560–1565, 1662–1664, 1666–3074, 3076–3166, 3168–3170, 3172–3174, 3176–3178

After SHA-256: 32a952b14c378eb24f698f1e9771bb4597485af777ff469b0744f9002d94e52e

After counts: {"production": 1621, "tests_and_test_support": 1531, "benchmark_example": 0}

After production ranges: 1–898, 908–1087, 1090–1106, 1109–1312, 1315–1481, 1488–1565, 1570–1570, 1577–1672, 1676–1676, 3086–3086, 3178–3178, 3182–3182, 3186–3186

After support ranges: 899–907, 1088–1089, 1107–1108, 1313–1314, 1482–1487, 1566–1569, 1571–1576, 1673–1675, 1677–3085, 3087–3177, 3179–3181, 3183–3185, 3187–3189

Delta: {"production": 10, "tests_and_test_support": 0, "benchmark_example": 0}

## rust/crates/bello-agent-core/src/stream_journal.rs

Classification source: Direct baseline source review: trailing positive cfg(test) module; prior platform-only Unix synchronization remains production.

Before SHA-256: e2abe2339f573ec690158927630df28f9af19c8c0a994c465817777109120ed1

Before counts: {"production": 172, "tests_and_test_support": 52, "benchmark_example": 0}

Before production ranges: 1–174

Before support ranges: 175–226

After SHA-256: 7af23416aa06f908dbac61ec16f922f0aa47c8f3f46675f3b86a4c8b6862e5f6

After counts: {"production": 180, "tests_and_test_support": 55, "benchmark_example": 0}

After production ranges: 1–183, 236–236

After support ranges: 184–235, 237–239

Delta: {"production": 8, "tests_and_test_support": 3, "benchmark_example": 0}

## rust/crates/bello-agent-core/src/stream_journal_inspection_tests.rs

Classification source: New source individually reviewed; exact positive cfg(test) range or test-only module ownership.

Before SHA-256: None

Before counts: {"production": 0, "tests_and_test_support": 0, "benchmark_example": 0}

Before production ranges: none

Before support ranges: none

After SHA-256: 6916d96328afa9894943e7ef1ec59df479a18785a7898f3c47668c9d8608944f

After counts: {"production": 0, "tests_and_test_support": 118, "benchmark_example": 0}

After production ranges: none

After support ranges: 1–123

Delta: {"production": 0, "tests_and_test_support": 118, "benchmark_example": 0}

