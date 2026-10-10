"""Corpus for the syntax highlighter oracle: curated cases per language and
seeded random documents built from the scanner's decision points."""
import json, random, sys

curated = [
    ("typescript", "const x = \"<img src=x onerror=alert(1)>\"; // note\nconst earth = '🌍'; /* block */ function greet() { return 1.5e3; }"),
    ("python", "def greet(name):\n    return '''multi\nline'''  # trailing"),
    ("bash", "echo $# and \"quoted # not\" # comment"),
    ("json", "{\"a\": true, \"b\": 0x1F, \"c\": null}"),
    ("swift", "func charge(_ order: Order) async throws -> Receipt { for attempt in 1...3 { } }"),
    ("swift", "let a = 1 // c"),
    ("swift", "    let value0 = compute(39900, 0) // step 0 of the pass\n    let value1 = compute(39900, 1) // step 1 of the pass"),
    ("swift", "/* nested /* not */ counted */ struct Foo {}\nclass\nBar {}\nenum E: Int { case a = 0x1F }"),
    ("swift", "let s = \"\"\"\nmulti \"quoted\"\n\"\"\"\nlet n = 1_000.5e-3"),
    ("javascript", "const t = `template ${x}\nspans`; let r = /re/g; x = 0X_ff + 1.e5 + 2.5E+ + .5"),
    ("typescript", "interface Shape { kind: 'circle' }\ntype Alias = Shape;\nnamespace NS {}\nenum Color { Red }"),
    ("python", "x = \"unterminated\ny = 'ok' # comment\nclass  Spaced : pass\nprint(f\"{x}\")\n\"\"\"open triple"),
    ("bash", "#!/bin/zsh\nfunction deploy() { local x=$1; echo \"$#\" '$#'; }\nfor f in *; do echo $f; done"),
    ("json", "[1, -2.5e10, \"\\\"esc\\\"\", false, {\"k\": [null]}]"),
    ("swift", "let café = naïve + x²; let ٣ = ١٢٣ + ۴; let é = 1"),
    ("typescript", "const a = \"unterminated string\nconst b = 'next'\n/* unterminated comment"),
    ("python", "'''\n'''x'''\n'' '\\'' \"\\\\\""),
    ("swift", "func\tname() {}\nfunc /* c */ other() {}\nfunc\n\nspaced() {}"),
    ("bash", "x=$((1+2)) # sum\necho \"a\\\"b\" 'c\\'d' # after"),
    ("javascript", "x = a$b + _c1 + 1a + a1 + 0x + 0xg + 1e + 1e+ + 1.x"),
]

fragments = {
    "common": [" ", "  ", "\n", "\t", "(", ")", "{", "}", ";", ",", ".", ":", "=", "+", "-", "*", "/", "\\", "_", "$",
               "0", "7", "42", "0x1F", "0X", "1.5", "1.", ".5", "1e3", "2E-4", "3e+", "1_000", "١٢", "²", "é", "é",
               "日本", "🌍", "a", "Z", "name", "value1", "x_y", "$x", "__init__", " ", " "],
    "swift": ["func", "let", "var", "class", "struct", "enum", "protocol", "extension", "actor", "typealias", "true", "nil",
              "self", "Self", "\"", "\"\"\"", "//", "/*", "*/", "#if", "'"],
    "typescript": ["function", "const", "class", "interface", "type", "enum", "namespace", "undefined", "NaN", "this",
                   "\"", "'", "`", "//", "/*", "*/", "${", "satisfies"],
    "javascript": ["function", "const", "let", "class", "null", "Infinity", "yield", "\"", "'", "`", "//", "/*", "*/"],
    "python": ["def", "class", "lambda", "True", "None", "and", "\"", "'", "\"\"\"", "'''", "#", "f\"", "elif"],
    "json": ["true", "false", "null", "\"", "\":", "[", "]"],
    "bash": ["function", "if", "then", "fi", "local", "echo", "\"", "'", "#", "$#", "${", "$(", "esac"],
}

rng = random.Random(20261010)
cases = [{"language": language, "code": code} for language, code in curated]
for language in ["swift", "typescript", "javascript", "python", "json", "bash"]:
    pool = fragments["common"] + fragments[language] * 3
    for _ in range(90):
        length = rng.randint(1, 60)
        cases.append({"language": language, "code": "".join(rng.choice(pool) for _ in range(length))})
json.dump(cases, open(sys.argv[1], "w"), ensure_ascii=False, indent=0)
print(len(cases), "cases")
