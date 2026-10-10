//! Code colouring for the transcript's fences, as Swift 0.1.122 colours them
//! (`SyntaxHighlighter.scan`): a small scanner per language family that finds
//! comments, strings, numbers, keywords and declared names. Anything it does
//! not recognise stays plain, and code beyond the size limit is not coloured.
//! The scanner reads Unicode scalars as Swift does; tokens are byte ranges.
//! An oracle built from the Swift source pins the result (`syntax_tests.rs`).
use std::ops::Range;
use unicode_properties::{GeneralCategory, GeneralCategoryGroup, UnicodeGeneralCategory};

/// The most code, in UTF-8 bytes, that is coloured.
pub const LIMIT: usize = 16_384;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Language {
    Swift,
    TypeScript,
    JavaScript,
    Python,
    Json,
    Bash,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TokenKind {
    Keyword,
    String,
    Number,
    Comment,
    /// The name a declaration keyword declares.
    Title,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Token {
    /// Bytes of the code.
    pub range: Range<usize>,
    pub kind: TokenKind,
}

/// The language for a fence label, honouring the short aliases people type.
pub fn language(name: &str) -> Option<Language> {
    match name.to_lowercase().as_str() {
        "ts" | "typescript" => Some(Language::TypeScript),
        "js" | "jsx" | "mjs" | "cjs" | "javascript" => Some(Language::JavaScript),
        "py" | "python" => Some(Language::Python),
        "sh" | "shell" | "zsh" | "bash" => Some(Language::Bash),
        "swift" => Some(Language::Swift),
        "json" => Some(Language::Json),
        _ => None,
    }
}

/// A fence's colours in the transcript: its first `LIMIT` bytes (cut back to
/// a character) are scanned and the rest stays plain, as Swift's
/// `MarkdownTextBuilder.highlighted` colours a fence.
pub fn fence_tokens(code: &str, label: &str) -> Vec<Token> {
    let Some(language) = language(label) else {
        return Vec::new();
    };
    let mut bound = code.len().min(LIMIT);
    while !code.is_char_boundary(bound) {
        bound -= 1;
    }
    scan(&code[..bound], language)
}

struct Grammar {
    line_comment: &'static [&'static str],
    block_comment: bool,
    quotes: &'static [char],
    triple_quotes: bool,
    keywords: &'static [&'static str],
    literals: &'static [&'static str],
    declarations: &'static [&'static str],
}

fn grammar(language: Language) -> Grammar {
    match language {
        Language::Swift => Grammar {
            line_comment: &["//"],
            block_comment: true,
            quotes: &['"'],
            triple_quotes: false,
            keywords: &[
                "func",
                "let",
                "var",
                "if",
                "else",
                "guard",
                "return",
                "for",
                "in",
                "while",
                "repeat",
                "switch",
                "case",
                "default",
                "break",
                "continue",
                "struct",
                "class",
                "enum",
                "protocol",
                "extension",
                "import",
                "init",
                "deinit",
                "self",
                "Self",
                "super",
                "throw",
                "throws",
                "try",
                "catch",
                "async",
                "await",
                "actor",
                "static",
                "private",
                "public",
                "internal",
                "fileprivate",
                "open",
                "final",
                "override",
                "mutating",
                "inout",
                "where",
                "as",
                "is",
                "some",
                "any",
                "defer",
                "do",
                "typealias",
                "associatedtype",
                "subscript",
                "get",
                "set",
                "willSet",
                "didSet",
                "lazy",
                "weak",
                "unowned",
                "convenience",
                "required",
                "indirect",
                "rethrows",
                "fallthrough",
                "operator",
                "precedencegroup",
                "nonisolated",
                "isolated",
                "consuming",
                "borrowing",
            ],
            literals: &["true", "false", "nil"],
            declarations: &[
                "func",
                "class",
                "struct",
                "enum",
                "protocol",
                "extension",
                "actor",
                "typealias",
            ],
        },
        Language::TypeScript | Language::JavaScript => Grammar {
            line_comment: &["//"],
            block_comment: true,
            quotes: &['"', '\'', '`'],
            triple_quotes: false,
            keywords: &[
                "function",
                "const",
                "let",
                "var",
                "if",
                "else",
                "return",
                "for",
                "of",
                "in",
                "while",
                "do",
                "switch",
                "case",
                "default",
                "break",
                "continue",
                "class",
                "extends",
                "new",
                "this",
                "super",
                "import",
                "export",
                "from",
                "as",
                "throw",
                "try",
                "catch",
                "finally",
                "async",
                "await",
                "yield",
                "typeof",
                "instanceof",
                "void",
                "delete",
                "interface",
                "type",
                "enum",
                "implements",
                "public",
                "private",
                "protected",
                "readonly",
                "static",
                "declare",
                "namespace",
                "abstract",
                "keyof",
                "satisfies",
                "with",
            ],
            literals: &["true", "false", "null", "undefined", "NaN", "Infinity"],
            declarations: &[
                "function",
                "class",
                "interface",
                "type",
                "enum",
                "namespace",
            ],
        },
        Language::Python => Grammar {
            line_comment: &["#"],
            block_comment: false,
            quotes: &['"', '\''],
            triple_quotes: true,
            keywords: &[
                "def", "class", "if", "elif", "else", "return", "for", "in", "while", "break",
                "continue", "pass", "import", "from", "as", "with", "try", "except", "finally",
                "raise", "lambda", "yield", "async", "await", "global", "nonlocal", "del",
                "assert", "and", "or", "not", "is", "match", "case",
            ],
            literals: &["True", "False", "None"],
            declarations: &["def", "class"],
        },
        Language::Json => Grammar {
            line_comment: &[],
            block_comment: false,
            quotes: &['"'],
            triple_quotes: false,
            keywords: &[],
            literals: &["true", "false", "null"],
            declarations: &[],
        },
        Language::Bash => Grammar {
            line_comment: &["#"],
            block_comment: false,
            quotes: &['"', '\''],
            triple_quotes: false,
            keywords: &[
                "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until",
                "case", "esac", "function", "return", "local", "export", "set", "unset",
                "readonly", "declare", "shift", "exit", "source", "alias", "select",
            ],
            literals: &["true", "false"],
            declarations: &["function"],
        },
    }
}

/// Foundation's `CharacterSet.decimalDigits`: general category Nd.
fn decimal(scalar: char) -> bool {
    scalar.general_category() == GeneralCategory::DecimalNumber
}

/// Foundation's `CharacterSet.alphanumerics` (L*, M*, N*), `_` and `$`.
fn word(scalar: char) -> bool {
    scalar == '_'
        || scalar == '$'
        || matches!(
            scalar.general_category_group(),
            GeneralCategoryGroup::Letter
                | GeneralCategoryGroup::Mark
                | GeneralCategoryGroup::Number
        )
}

/// Tokens over the whole of `code`, in order and non-overlapping; none for
/// code over `LIMIT` bytes.
pub fn scan(code: &str, language: Language) -> Vec<Token> {
    if code.len() > LIMIT {
        return Vec::new();
    }
    let grammar = grammar(language);
    let scalars: Vec<(usize, char)> = code.char_indices().collect();
    let count = scalars.len();
    let at = |index: usize| scalars[index].1;
    let byte = |index: usize| scalars.get(index).map_or(code.len(), |&(byte, _)| byte);
    let starts_with = |prefix: &str, position: usize| {
        prefix
            .chars()
            .enumerate()
            .all(|(offset, scalar)| position + offset < count && at(position + offset) == scalar)
    };
    let mut tokens = Vec::new();
    let mut emit = |start: usize, end: usize, kind: TokenKind| {
        tokens.push(Token {
            range: byte(start)..byte(end),
            kind,
        });
    };
    let mut index = 0;
    let mut previous_word = "";
    while index < count {
        let scalar = at(index);
        // Comments to the end of the line; in bash `$#` is a parameter.
        if let Some(marker) = grammar
            .line_comment
            .iter()
            .find(|marker| starts_with(marker, index))
            && !(*marker == "#" && language == Language::Bash && index > 0 && at(index - 1) == '$')
        {
            let mut end = index;
            while end < count && at(end) != '\n' {
                end += 1;
            }
            emit(index, end, TokenKind::Comment);
            index = end;
            previous_word = "";
            continue;
        }
        if grammar.block_comment && starts_with("/*", index) {
            let mut end = index + 2;
            while end < count && !starts_with("*/", end) {
                end += 1;
            }
            end = count.min(end + if end < count { 2 } else { 0 });
            emit(index, end, TokenKind::Comment);
            index = end;
            previous_word = "";
            continue;
        }
        // Strings, with backslash escapes; Python's triple quotes span lines.
        if grammar.quotes.contains(&scalar) {
            let triple = grammar.triple_quotes
                && index + 2 < count
                && at(index + 1) == scalar
                && at(index + 2) == scalar;
            let mut end = index + if triple { 3 } else { 1 };
            while end < count {
                if at(end) == '\\' {
                    end += 2;
                    continue;
                }
                if triple {
                    if end + 2 < count
                        && at(end) == scalar
                        && at(end + 1) == scalar
                        && at(end + 2) == scalar
                    {
                        end += 3;
                        break;
                    }
                } else if at(end) == scalar {
                    end += 1;
                    break;
                } else if at(end) == '\n' && scalar != '`' {
                    break;
                }
                end += 1;
            }
            end = end.min(count);
            emit(index, end, TokenKind::String);
            index = end;
            previous_word = "";
            continue;
        }
        // Numbers: decimal, fractional, exponent and hex; not the middle of a word.
        if decimal(scalar) && (index == 0 || !word(at(index - 1))) {
            let digits = |scalar: char| scalar.is_ascii_digit() || scalar == '_';
            let mut end = index + 1;
            if scalar == '0' && end < count && matches!(at(end), 'x' | 'X') {
                end += 1;
                while end < count && (at(end).is_ascii_hexdigit() || at(end) == '_') {
                    end += 1;
                }
            } else {
                while end < count && digits(at(end)) {
                    end += 1;
                }
                if end + 1 < count && at(end) == '.' && decimal(at(end + 1)) {
                    end += 1;
                    while end < count && digits(at(end)) {
                        end += 1;
                    }
                }
                if end < count && matches!(at(end), 'e' | 'E') {
                    let mut probe = end + 1;
                    if probe < count && matches!(at(probe), '+' | '-') {
                        probe += 1;
                    }
                    if probe < count && decimal(at(probe)) {
                        end = probe;
                        while end < count && decimal(at(end)) {
                            end += 1;
                        }
                    }
                }
            }
            emit(index, end, TokenKind::Number);
            index = end;
            previous_word = "";
            continue;
        }
        // Words: keywords, literals and the name declared right after a
        // declaration keyword.
        if word(scalar) && !decimal(scalar) {
            let mut end = index + 1;
            while end < count && word(at(end)) {
                end += 1;
            }
            let value = &code[byte(index)..byte(end)];
            if grammar.keywords.contains(&value) || grammar.literals.contains(&value) {
                emit(index, end, TokenKind::Keyword);
            } else if grammar.declarations.contains(&previous_word) {
                emit(index, end, TokenKind::Title);
            }
            previous_word = value;
            index = end;
            continue;
        }
        if !scalar.is_whitespace() {
            previous_word = "";
        }
        index += 1;
    }
    tokens
}

#[cfg(test)]
#[path = "syntax_tests.rs"]
mod tests;
