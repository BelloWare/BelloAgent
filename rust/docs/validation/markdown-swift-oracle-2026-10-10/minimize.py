# Delta-debug a Markdown source to the smallest input on which the Swift oracle
# and the Rust reading (flattened spans) still disagree.
import json, subprocess, sys, tempfile, os
D = os.path.dirname(os.path.abspath(__file__))
SWIFT = os.path.join(D, 'swift-markdown-oracle')
RUST = '/Users/admin/Library/Caches/BelloRustWork/claude-2026-10-10/target/release/markdown-dump'
def flat_swift(blocks):
    out = []
    def spans(ss): return [[s['text'], ''.join(c for k, c in (('bold','b'),('italic','i'),('strike','s'),('code','c')) if s.get(k)) + ('l' if 'link' in s else '')] for s in ss]
    def walk(bs):
        for b in bs:
            if 'paragraph' in b: out.append(spans(b['paragraph']))
            elif 'heading' in b: out.append(spans(b['spans']))
            elif 'list' in b:
                for item in b['list']: walk(item)
            elif 'quote' in b: walk(b['quote'])
            elif 'table' in b:
                for cell in b['header']: out.append(spans(cell))
                for row in b['table']:
                    for cell in row: out.append(spans(cell))
            elif 'code' in b: out.append([[b['code'], 'code']])
    walk(blocks)
    return out
def both(sources):
    with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
        json.dump(sources, f, ensure_ascii=False); path = f.name
    s = json.loads(subprocess.run([SWIFT, path, 'prose'], capture_output=True, check=True).stdout)
    r = json.loads(subprocess.run([RUST, path], capture_output=True, check=True).stdout)
    os.unlink(path)
    return [flat_swift(x) for x in s], r
def differs(src): s, r = both([src]); return s[0] != r[0]
def minimize(src):
    tokens = src.split(' ')
    n = 2
    while len(tokens) >= 2:
        chunk = max(1, len(tokens) // n); reduced = False
        for i in range(0, len(tokens), chunk):
            candidate = tokens[:i] + tokens[i + chunk:]
            if candidate and differs(' '.join(candidate)):
                tokens = candidate; n = max(n - 1, 2); reduced = True; break
        if not reduced:
            if chunk == 1: break
            n = min(len(tokens), n * 2)
    return ' '.join(tokens)
corpus = json.load(open(os.environ.get('CORPUS', os.path.join(D, 'generated.json'))))
for i in map(int, sys.argv[1:]):
    m = minimize(corpus[i])
    s, r = both([m])
    print(f'case {i}: {m!r}\n  swift {json.dumps(s[0], ensure_ascii=False)}\n  rust  {json.dumps(r[0], ensure_ascii=False)}')
