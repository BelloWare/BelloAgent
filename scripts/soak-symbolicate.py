#!/usr/bin/env python3
"""Finishes the stacks in a SoakTests report with atos.

Usage: scripts/soak-symbolicate.py <report> [--dsym-root DIR]

The report lists each stall's frames as "[0xADDRESS] image +0xOFFSET symbol"
(the symbol only where dladdr found an exported one), and ends with a
"## frames" section of "path|0xLOAD|0xADDRESS" lines. This asks atos for
every address, image by image, and prints the report again with each
frame named: the app's own frames, its tests' and its frameworks'. A
system library keeps the name dladdr gave it. --dsym-root
points atos at the build's dSYMs, for the app's frames in a Release build.
"""
import re, subprocess, sys, collections, glob, os

def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    report = args[0]
    dsym_root = args[args.index("--dsym-root") + 1] if "--dsym-root" in args else None
    text = open(report, encoding="utf-8").read()
    head, _, frames = text.partition("## frames")
    images = collections.defaultdict(set)
    for line in frames.splitlines():
        parts = line.strip().split("|")
        if len(parts) == 3 and parts[0] != "?":
            images[(parts[0], parts[1])].add(parts[2])
    names = {}
    for (path, load), addresses in images.items():
        target = path
        # A system library runs from the shared cache, whatever is on disk
        # at its path: atos names its addresses wrongly, and dladdr has
        # named its exported symbols in the report already.
        if path.startswith(("/usr/lib/", "/System/")):
            continue
        if dsym_root:
            found = glob.glob(os.path.join(dsym_root, "**", os.path.basename(path) + ".app.dSYM"), recursive=True) + \
                    glob.glob(os.path.join(dsym_root, "**", os.path.basename(path) + ".dSYM"), recursive=True)
            if found:
                target = found[0]
        addresses = sorted(addresses)
        out = subprocess.run(["atos", "-o", target, "-l", load] + addresses, capture_output=True, text=True).stdout.splitlines()
        for address, name in zip(addresses, out):
            if name and not name.startswith("0x"):
                names[int(address, 16)] = name.strip()
    def name(match):
        address = int(match.group(1), 16)
        return match.group(0) + ("  — " + names[address] if address in names else "")
    print(re.sub(r"\[(0x[0-9a-f]+)\][^\n]*", name, head))

if __name__ == "__main__":
    main()
