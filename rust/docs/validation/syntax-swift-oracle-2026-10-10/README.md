# Code colouring: Swift oracle (2026-10-10)

The Rust transcript colours fenced code as Swift 0.1.122 does
(`bello_agent_core::syntax`, a port of `SyntaxHighlighter.scan`). Swift's own
scanner is the oracle: `swift-src/SyntaxHighlighter.swift` is the file at
`6319e368` unchanged, and `swift-src/main.swift` dumps its tokens for a corpus.

```sh
swiftc -O swift-src/SyntaxHighlighter.swift swift-src/main.swift -o syntax-oracle
python3 -I generate.py corpus.json        # 20 curated + 540 seeded generated cases
./syntax-oracle corpus.json swift-tokens.json
```

`generate.py` (seed 20261010) builds documents for all six grammars (Swift,
TypeScript, JavaScript, Python, JSON, bash) from the scanner's decision points:
line and block comment markers, `$#` in bash, single, triple and template
quotes, escapes, unterminated strings and comments, hex, fraction and exponent
forms, digits in other scripts (Arabic-Indic, superscripts), combining marks,
emoji, non-breaking spaces and declaration keywords split by whitespace.

The corpus and Swift's tokens (ranges over Unicode scalars, as Swift reports
them) are `crates/bello-agent-core/tests/data/syntax/`; the test
`syntax::tests::code_is_coloured_as_swift_colours_it` compares all 560 cases.
Result: 560 of 560 identical (1,873 tokens), first run.

Character classes follow Foundation: `CharacterSet.alphanumerics` is general
category L, M or N, `decimalDigits` is Nd (via `unicode-properties` 0.1.4,
already in the lock). Swift's `Character`/scalar indexing maps to Rust `char`s;
tokens are returned as byte ranges for drawing.

The transcript colours a fence's first 16,384 bytes (cut back to a whole
character) and leaves the rest plain, as `MarkdownTextBuilder.highlighted`
does; Swift resumes from checkpoints while a fence streams, which gives the
same tokens as a scan from the start, and Rust scans the visible fences again
per frame instead.
