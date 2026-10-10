use super::{LIMIT, Language, TokenKind, fence_tokens, language, scan};
use serde_json::Value;

/// `SyntaxHighlighter.scan` from Swift 0.1.122 (6319e368) on curated and
/// seeded generated code. Harness: rust/docs/validation/syntax-swift-oracle-2026-10-10.
const CORPUS: &str = include_str!("../tests/data/syntax/corpus.json");
const SWIFT_TOKENS: &str = include_str!("../tests/data/syntax/swift-tokens.json");

fn kind_name(kind: TokenKind) -> &'static str {
    match kind {
        TokenKind::Keyword => "keyword",
        TokenKind::String => "string",
        TokenKind::Number => "number",
        TokenKind::Comment => "comment",
        TokenKind::Title => "title",
    }
}

/// Tokens as Swift reports them: ranges over Unicode scalars.
fn scalar_tokens(code: &str, language: Language) -> Vec<(usize, usize, &'static str)> {
    let scalar = |byte: usize| code[..byte].chars().count();
    scan(code, language)
        .into_iter()
        .map(|token| {
            (
                scalar(token.range.start),
                scalar(token.range.end),
                kind_name(token.kind),
            )
        })
        .collect()
}

#[test]
fn code_is_coloured_as_swift_colours_it() {
    let corpus: Vec<Value> = serde_json::from_str(CORPUS).unwrap();
    let expected: Vec<Vec<(usize, usize, String)>> = serde_json::from_str(SWIFT_TOKENS).unwrap();
    assert_eq!(corpus.len(), expected.len());
    let mut different = Vec::new();
    for (index, (case, expected)) in corpus.iter().zip(&expected).enumerate() {
        let code = case["code"].as_str().unwrap();
        let language = language(case["language"].as_str().unwrap()).unwrap();
        let actual = scalar_tokens(code, language);
        let same = actual.len() == expected.len()
            && actual
                .iter()
                .zip(expected)
                .all(|(a, e)| a.0 == e.0 && a.1 == e.1 && a.2 == e.2);
        if !same {
            different.push(format!(
                "case {index} {language:?} {code:?}\n  swift: {expected:?}\n  rust:  {actual:?}"
            ));
        }
    }
    assert!(
        different.is_empty(),
        "{} of {} cases differ from Swift:\n{}",
        different.len(),
        corpus.len(),
        different.join("\n")
    );
}

fn words(code: &str, language: Language, kind: TokenKind) -> Vec<&str> {
    scan(code, language)
        .into_iter()
        .filter(|token| token.kind == kind)
        .map(|token| &code[token.range])
        .collect()
}

fn kinds(code: &str, language: Language) -> Vec<TokenKind> {
    scan(code, language)
        .into_iter()
        .map(|token| token.kind)
        .collect()
}

/// Swift's `testHighlighterFindsCommentsStringsNumbersKeywordsAndNames`.
#[test]
fn comments_strings_numbers_keywords_and_names_are_found() {
    let ts = "const x = \"<img src=x onerror=alert(1)>\"; // note\nconst earth = '🌍'; /* block */ function greet() { return 1.5e3; }";
    let typescript = Language::TypeScript;
    assert_eq!(
        words(ts, typescript, TokenKind::Keyword),
        ["const", "const", "function", "return"]
    );
    assert_eq!(
        words(ts, typescript, TokenKind::String),
        ["\"<img src=x onerror=alert(1)>\"", "'🌍'"],
        "markup inside a string is string, and the emoji survives"
    );
    assert_eq!(
        words(ts, typescript, TokenKind::Comment),
        ["// note", "/* block */"]
    );
    assert_eq!(words(ts, typescript, TokenKind::Title), ["greet"]);
    assert_eq!(words(ts, typescript, TokenKind::Number), ["1.5e3"]);
    use TokenKind::*;
    assert_eq!(
        kinds(
            "def greet(name):\n    return '''multi\nline'''  # trailing",
            Language::Python
        ),
        [Keyword, Title, Keyword, String, Comment]
    );
    assert_eq!(
        kinds("echo $# and \"quoted # not\" # comment", Language::Bash),
        [String, Comment],
        "a dollar-hash is a parameter, not a comment"
    );
    assert_eq!(
        kinds("{\"a\": true, \"b\": 0x1F, \"c\": null}", Language::Json),
        [String, Keyword, String, Number, String, Keyword]
    );
    assert_eq!(
        words(
            "func charge(_ order: Order) async throws -> Receipt { for attempt in 1...3 { } }",
            Language::Swift,
            Title
        )
        .len(),
        1
    );
    assert_eq!(language("unknown"), None);
    assert_eq!(language("ts"), Some(Language::TypeScript));
    assert_eq!(language("SH"), Some(Language::Bash));
    assert!(scan(&"x".repeat(LIMIT + 1), Language::TypeScript).is_empty());
    assert_eq!(
        kinds("let a = 1 // c", Language::Swift),
        [Keyword, Number, Comment]
    );
}

/// A fence is coloured up to the limit, cut back to a whole character, and
/// plain after it; an unknown language is plain.
#[test]
fn a_long_fence_is_coloured_to_the_limit_only() {
    let head = "let a = 1\n";
    let code = format!(
        "{head}{}é // past the limit",
        "x".repeat(LIMIT - head.len() - 1)
    );
    let tokens = fence_tokens(&code, "swift");
    assert_eq!(
        tokens.iter().map(|token| token.kind).collect::<Vec<_>>(),
        [TokenKind::Keyword, TokenKind::Number]
    );
    assert!(tokens.iter().all(|token| token.range.end < LIMIT));
    assert!(fence_tokens("let a = 1", "text").is_empty());
    assert!(fence_tokens("let a = 1", "").is_empty());
}
