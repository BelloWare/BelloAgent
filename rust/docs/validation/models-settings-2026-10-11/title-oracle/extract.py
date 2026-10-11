#!/usr/bin/env python3
"""Copies the unchanged Swift declarations the title oracle needs, by name,
from a Swift 0.1.122 checkout (argv[1]) into swift-src/extracted.swift."""
import sys, pathlib
root = pathlib.Path(sys.argv[1]) / "apps/macos/PiApp"
wanted = [
    ("Host/WireValue.swift", "indirect enum WireValue"),
    ("Workspaces/ModelCatalog.swift", "enum ThinkingLevel"),
    ("Workspaces/ModelCatalog.swift", "enum TurnOverrides"),
    ("Workspaces/ModelCatalogEndpoint.swift", "struct ModelDescriptor"),
    ("Workspaces/WorkspaceTitleGeneration.swift", "struct TitleGenerationPlan"),
]
out = ["import Foundation\n"]
for path, head in wanted:
    text = (root / path).read_text()
    start = text.index(head)
    # Keep the doc comment block directly above it out; take the declaration.
    depth, i, opened = 0, start, False
    while True:
        c = text[i]
        if c == "{": depth += 1; opened = True
        elif c == "}":
            depth -= 1
            if opened and depth == 0: break
        i += 1
    out.append(f"// {path}: {head}\n" + text[start:i + 1] + "\n")
pathlib.Path("swift-src").mkdir(exist_ok=True)
pathlib.Path("swift-src/extracted.swift").write_text("\n".join(out))
