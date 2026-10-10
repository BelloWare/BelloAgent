# Fixed-seed random Markdown documents mixing every construct the transcript reads.
import json, random, sys
rng = random.Random(20261010)
words = ["parser", "module", "tree", "offset", "日本語", "é", "token", "block", "value", "caller", "Søren", "x_y", "a*b", "1.5", "(paren)", "end."]
def word(): return rng.choice(words)
def inline(depth=0):
    parts = []
    for _ in range(rng.randint(1, 7)):
        k = rng.randint(0, 14)
        w = " ".join(word() for _ in range(rng.randint(1, 3)))
        if depth < 2 and k == 0: parts.append(f"*{inline(depth+1)}*")
        elif depth < 2 and k == 1: parts.append(f"**{inline(depth+1)}**")
        elif k == 2: parts.append(f"`{w}`")
        elif k == 3: parts.append(f"[{w}](https://example.com/{rng.randint(1,99)})")
        elif k == 4: parts.append(f"[{w}](/rel/{rng.randint(1,9)})")
        elif k == 5: parts.append(f"https://bare{rng.randint(1,9)}.example.com/p" + rng.choice(["", ".", ")", ","]))
        elif k == 6: parts.append(f"~~{w}~~")
        elif k == 7: parts.append(f"<b>{w}</b>")
        elif k == 8: parts.append("  \n" + w)
        elif k == 9: parts.append("\n" + w)
        elif k == 10: parts.append(f"![{w}](https://img.example/{rng.randint(1,9)}.png)")
        elif k == 11: parts.append("&amp;")
        else: parts.append(w)
    return " ".join(parts)
def block(depth=0):
    k = rng.randint(0, 9)
    if k == 0: return "#" * rng.randint(1, 6) + " " + inline()
    if k == 1:
        lang = rng.choice(["", "swift", "rust", " Python ", "js extra"])
        return f"```{lang}\n" + "\n".join(f"let v{i} = {i}" for i in range(rng.randint(0, 4))) + "\n```"
    if k == 2 and depth < 2:
        marker = rng.choice(["-", "*", "1.", "3."])
        items = []
        for i in range(rng.randint(1, 4)):
            m = marker if not marker[0].isdigit() else f"{int(marker[:-1]) + i}."
            item = f"{m} {inline()}"
            if rng.random() < 0.3: item += "\n\n   " + inline()
            if rng.random() < 0.25: item += "\n" + "\n".join("   " + line for line in block(depth + 1).split("\n"))
            items.append(item)
        return ("\n\n" if rng.random() < 0.3 else "\n").join(items)
    if k == 3 and depth < 2: return "\n".join("> " + line for line in block(depth + 1).split("\n"))
    if k == 4:
        cols = rng.randint(1, 3)
        align = rng.choice(["---", ":--", ":-:", "--:"])
        return "| " + " | ".join(word() for _ in range(cols)) + " |\n|" + "|".join(align for _ in range(cols)) + "|\n" + "\n".join("| " + " | ".join(inline() .replace("|", "/").replace("\n", " ") for _ in range(cols)) + " |" for _ in range(rng.randint(1, 3)))
    if k == 5: return "---"
    if k == 6: return "<div>" + word() + "</div>"
    return inline()
docs = ["\n\n".join(block() for _ in range(rng.randint(1, 5))) for _ in range(int(sys.argv[1]))]
json.dump(docs, sys.stdout, ensure_ascii=False)
