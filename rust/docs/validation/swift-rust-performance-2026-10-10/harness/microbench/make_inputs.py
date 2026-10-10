#!/usr/bin/env python3
"""Regenerate the fixed-seed microbenchmark inputs: make_inputs.py OUTDIR"""
import json, os, random, sys
out = sys.argv[1]; os.makedirs(out, exist_ok=True)
random.seed(20261010)
names = ["Ada", "Lin", "Zoë", "José", "Søren", "李雷", "Ünal", "Café", "éclair", "Ωmega"]
items = []; i = 0
while True:
    i += 1
    items.append({"id": i, "uuid": f"{random.getrandbits(128):032x}", "name": random.choice(names) + f" {i}",
                  "active": random.random() < 0.5, "score": round(random.uniform(-1000, 1000), 6),
                  "big": str(random.getrandbits(80)), "ratio": 1e-7 * i, "tags": [random.choice(names) for _ in range(3)],
                  "meta": {"zeta": None, "alpha": {"n": i % 7, "path": f"/a/b/{i}", "quote": "say \"hi\"\n"}}})
    text = json.dumps(items, ensure_ascii=False, separators=(",", ":"))
    if len(text.encode()) > 490_000:
        items.pop(); text = json.dumps(items, ensure_ascii=False, separators=(",", ":")); break
text = text.replace('"big":"', '"big":').replace('","ratio"', ',"ratio"')
open(os.path.join(out, "json-490k.json"), "w", encoding="utf-8").write(text)
words = ["alpha", "Beta", "gamma", "Delta", "café", "café", "naïve", "ZEBRA", "zebra", "日本語", "emoji 😀", "  padded  "]
lines = []
while sum(len(l.encode()) + 1 for l in lines) < 490_000:
    lines.append(" ".join(random.choice(words) for _ in range(random.randint(1, 6))) + (" #%d" % random.randint(0, 3000)))
text2 = "\n".join(lines)
while len(text2.encode()) > 490_000: lines.pop(); text2 = "\n".join(lines)
open(os.path.join(out, "lines-490k.txt"), "w", encoding="utf-8").write(text2)
# First 1,100 top-level elements, sliced from the raw text to keep exact number lexemes.
depth, start, elems, in_str, esc = 0, None, [], False, False
for k, ch in enumerate(text):
    if in_str:
        if esc: esc = False
        elif ch == "\\": esc = True
        elif ch == '"': in_str = False
        continue
    if ch == '"': in_str = True
    elif ch in "[{":
        depth += 1
        if depth == 2: start = k
    elif ch in "]}":
        if depth == 2: elems.append(text[start:k + 1])
        depth -= 1
open(os.path.join(out, "json-300k.json"), "w", encoding="utf-8").write("[" + ",".join(elems[:1100]) + "]")
