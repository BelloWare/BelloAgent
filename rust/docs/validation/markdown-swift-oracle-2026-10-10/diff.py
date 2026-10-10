# First differing node per document between the Swift oracle and Rust, grouped by kind.
import json, sys, collections
d = sys.argv[1]; name = sys.argv[2]
corpus = json.load(open(f'{d}/generated.json'))
swift = json.load(open(f'{d}/{name}')); rust = json.load(open(f'{d}/rust-{name}'))
def norm(v):
    if isinstance(v, float): return round(v, 3)
    if isinstance(v, list): return [norm(x) for x in v]
    if isinstance(v, dict): return {k: norm(x) for k, x in v.items()}
    return v
def first(a, b, path=''):
    if type(a) != type(b): return path, a, b
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b: return path + '/' + k, a.get(k), b.get(k)
            r = first(a[k], b[k], path + '/' + k)
            if r: return r
        return None
    if isinstance(a, list):
        for i, (x, y) in enumerate(zip(a, b)):
            r = first(x, y, f'{path}[{i}]')
            if r: return r
        if len(a) != len(b): return path + '.len', len(a), len(b)
        return None
    return None if a == b else (path, a, b)
kinds = collections.Counter(); examples = {}
for i, (s, r) in enumerate(zip(swift, rust)):
    r1 = first(norm(s), norm(r))
    if r1:
        path, a, b = r1
        key = path.split('/')[-1].split('[')[0] + ':' + (type(a).__name__)
        kinds[key] += 1
        examples.setdefault(key, []).append((i, path, a, b))
for k, n in kinds.most_common():
    print(n, k)
    for i, path, a, b in examples[k][:2]:
        print('   case', i, path, '\n      swift:', json.dumps(a, ensure_ascii=False)[:260], '\n      rust: ', json.dumps(b, ensure_ascii=False)[:260])
