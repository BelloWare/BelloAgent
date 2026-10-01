#!/usr/bin/env python3
"""Compares two folders of PNG window captures, file by file.

Usage: scripts/compare-captures.py <folder A> <folder B>

For each PNG in A it prints how many pixels differ from the one of the same
name in B, and the largest difference of a channel; the exit status is 1 if
any file differs or is missing. Uses macOS's sips to read the images as raw
RGBA (no third-party modules)."""
import os, subprocess, sys, tempfile

def rgba(path):
    """Width, height, bytes per pixel and the rows of pixels, padding left out."""
    with tempfile.TemporaryDirectory() as folder:
        out = os.path.join(folder, "image.bmp")
        subprocess.run(["sips", "-s", "format", "bmp", path, "--out", out], capture_output=True, check=True)
        data = open(out, "rb").read()
    offset = int.from_bytes(data[10:14], "little")
    width = int.from_bytes(data[18:22], "little", signed=True)
    height = abs(int.from_bytes(data[22:26], "little", signed=True))
    step = int.from_bytes(data[28:30], "little") // 8
    stride = (width * step + 3) // 4 * 4
    rows = [data[offset + y * stride: offset + y * stride + width * step] for y in range(height)]
    return width, height, step, rows

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    first, second = sys.argv[1:]
    names = {folder: sorted(n for n in os.listdir(folder) if n.endswith(".png")) for folder in (first, second)}
    if not names[first]:
        sys.exit(f"No captures in {first}")
    failed = False
    for name in sorted(set(names[second]) - set(names[first])):
        print(f"{name}: missing in {first}"); failed = True
    for name in names[first]:
        other = os.path.join(second, name)
        if not os.path.exists(other):
            print(f"{name}: missing in {second}"); failed = True; continue
        a, b = rgba(os.path.join(first, name)), rgba(other)
        if a[:3] != b[:3]:
            print(f"{name}: size differs {a[:2]} vs {b[:2]}"); failed = True; continue
        step = a[2]
        pixels = differing = largest = 0
        for row_a, row_b in zip(a[3], b[3]):
            pixels += len(row_a) // step
            if row_a == row_b:
                continue
            for i in range(0, len(row_a), step):
                if row_a[i:i + step] != row_b[i:i + step]:
                    differing += 1
                    largest = max(largest, max(abs(x - y) for x, y in zip(row_a[i:i + step], row_b[i:i + step])))
        failed |= differing > 0
        print(f"{name}: {differing} of {pixels} pixels differ" + (f", largest channel difference {largest}" if differing else ""))
    sys.exit(1 if failed else 0)

if __name__ == "__main__":
    main()
