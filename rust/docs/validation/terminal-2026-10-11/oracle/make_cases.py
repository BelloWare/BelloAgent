#!/usr/bin/env python3
"""Writes the terminal emulator corpus: hand-made escape sequences for every
feature Swift 0.1.122's TerminalEmulator handles, plus output recorded from
real programs under script(1) (vim, less, ls -G, tput, zsh) at 40x10.
Usage: make_cases.py <recordings dir> <out cases.json>"""
import json, os, sys

rec, out = sys.argv[1], sys.argv[2]
E = "\x1b"
C = E + "["

def h(text):
    if isinstance(text, str):
        text = text.encode("utf-8")
    return text.hex()

cases = []
def case(name, *steps, columns=20, rows=6, scrollback=None, cell=None):
    c = {"name": name, "columns": columns, "rows": rows, "steps": []}
    if scrollback is not None:
        c["scrollback"] = scrollback
    if cell is not None:
        c["cellPixelSize"] = cell
    for step in steps:
        if isinstance(step, (str, bytes)):
            c["steps"].append({"hex": h(step)})
        else:
            c["steps"].append(step)
    cases.append(c)

def split(text):
    return {"hex": h(text), "split": True}

# Printing, wrapping, controls
case("plain", "hello\r\nworld")
case("wrap", "abcdefghijklmnopqrstuvwxyz0123")
case("wrap-at-edge-then-cr", "abcdefghijklmnopqrst\rX")
case("no-autowrap", C + "?7l" + "abcdefghijklmnopqrstuvwxyz" + C + "?7h" + "!")
case("backspace-tab", "a\tb\tc\x08\x08Z\r\n\tq" + C + "3g" + "\r\tW")
case("tab-stops-set-clear", "\r" + C + "3g" + C + "5G" + E + "H" + "\r\tX" + C + "0g\r\tY")
case("cht-cbt", "\r" + C + "2IA" + C + "Z" + "B" + C + "9ZC")
case("newline-mode", C + "20h" + "ab\ncd" + C + "20l" + "\nef")
case("linefeed-scroll", "\r\n".join(str(i) for i in range(12)))
case("scrollback-limit", "\r\n".join("line %d" % i for i in range(50)), scrollback=10)
case("bell", "a\x07b\x07")
case("vt-ff", "a\x0bb\x0cc")
# Cursor movement
case("cup", C + "3;5HX" + C + "HY" + C + "10;30HZ" + C + "2;2f" + "W")
case("cuu-cud-cuf-cub", C + "4;4H" + C + "2AU" + C + "3BD" + C + "5CR" + C + "20DL")
case("cnl-cpl-cha-vpa", C + "3;3H" + C + "EN" + C + "2FP" + C + "7GG" + C + "5dV" + C + "4`H" + C + "2aA" + C + "eE")
case("decsc-decrc", C + "2;3H" + C + "1m" + E + "7" + C + "5;5H" + C + "0mx" + E + "8y")
case("scosc-scorc", C + "2;3H" + C + "s" + C + "5;5Hx" + C + "uy")
case("dsr", C + "3;7H" + C + "6n" + C + "5n")
case("dsr-origin", C + "2;5r" + C + "?6h" + C + "2;3H" + C + "6n")
case("da", C + "c" + C + ">c" + C + "0c")
case("xtwinops", C + "14t" + C + "18t", cell=[7.418, 17.0])
case("xtwinops-fraction", C + "14t", cell=[7.5, 16.25], columns=21, rows=7)
case("decrqm", C + "?1$p" + C + "?2004h" + C + "?2004$p" + C + "?25$p" + C + "?2026$p" + C + "?9999$p" + C + "4$p" + C + "4h" + C + "4$p" + C + "20$p" + C + "7$p")
# Erase
case("ed-0", "aaaa\r\nbbbb\r\ncccc" + C + "2;2H" + C + "J")
case("ed-1", "aaaa\r\nbbbb\r\ncccc" + C + "2;2H" + C + "1J")
case("ed-2", "aaaa\r\nbbbb" + C + "2J" + "x")
case("ed-3", "\r\n".join(str(i) for i in range(10)) + C + "3J")
case("ed-private-3", "\r\n".join(str(i) for i in range(10)) + C + "?3J")
case("el", "abcdefgh" + C + "4G" + C + "K" + "\r\nabcdefgh" + C + "4G" + C + "1K" + "\r\nabcdefgh" + C + "4G" + C + "2K")
case("ech", "abcdefgh" + C + "3G" + C + "3X")
case("ech-bg", C + "44m" + "abcdefgh" + C + "3G" + C + "3X" + C + "0m")
case("erase-bg", C + "41m" + C + "2J" + C + "0m" + "x")
# Insert / delete
case("ich", "abcdef" + C + "3G" + C + "2@" + "XY")
case("dch", "abcdef" + C + "2G" + C + "2P")
case("il-dl", "1\r\n2\r\n3\r\n4\r\n5" + C + "2;1H" + C + "2L" + C + "5;1H" + C + "M")
case("insert-mode", "abcdef" + C + "3G" + C + "4h" + "XY" + C + "4l" + "Z")
case("su-sd", "1\r\n2\r\n3\r\n4\r\n5\r\n6" + C + "2S" + C + "T")
case("rep", "ab" + C + "5b" + C + "b")
# Scroll regions
case("decstbm", "1\r\n2\r\n3\r\n4\r\n5\r\n6" + C + "2;4r" + C + "4;1H" + "\nX\nY")
case("decstbm-ri", "1\r\n2\r\n3\r\n4\r\n5\r\n6" + C + "2;4r" + C + "2;1H" + E + "M" + E + "MZ")
case("decstbm-invalid", C + "4;2r" + C + "3;1H" + "x" + C + "5;5r" + "y")
case("origin-mode", C + "3;5r" + C + "?6h" + C + "1;1HA" + C + "10;1HB" + C + "?6l" + C + "1;1HC")
case("ind-nel-ri", "ab" + E + "D" + "c" + E + "E" + "d" + E + "M" + "e" + C + "H" + E + "M" + "top")
case("region-movement", C + "2;4r" + C + "3;1H" + C + "9A" + "u" + C + "9B" + "d" + C + "6;1H" + C + "9A" + "z")
case("decaln", C + "2;3r" + E + "#8" + C + "2;2HQ")
# SGR
case("sgr-basic", C + "1mB" + C + "2mD" + C + "22m" + C + "3mI" + C + "23m" + C + "4mU" + C + "24m" + C + "7mR" + C + "27m" + C + "8mH" + C + "28m" + C + "9mS" + C + "29m" + C + "5;6mx" + C + "21my" + C + "mz")
case("sgr-colours", C + "31ma" + C + "42mb" + C + "93mc" + C + "104md" + C + "39;49me" + C + "38;5;200mf" + C + "48;5;17mg" + C + "38;2;10;20;30mh" + C + "48;2;300;0;255mi")
case("sgr-colon", C + "38:5:123ma" + C + "38:2::1:2:3mb" + C + "48:2:4:5:6mc" + C + "4:0md" + C + "4:3me" + C + "58;5;9mf" + C + "38;5mg" + C + "38;2;1mh")
case("sgr-many", C + "1;3;4;7;9;31;42m" + "x" + C + "0;" + "1" * 20 + "m" + "y")
case("sgr-over-32", C + ";".join(["1"] * 40) + ";31m" + "x")
# Wide, combining, UTF-8
case("wide", "漢字abc")
case("wide-last-column", "abcdefghijklmnopqrs漢x")
case("wide-last-column-no-wrap", C + "?7l" + "abcdefghijklmnopqrs漢x")
case("wide-overwrite", "漢字" + C + "1G" + "a" + C + "4G" + "b")
case("wide-overwrite-run", "漢字漢" + C + "2G" + "xyz")
case("wide-insert-delete", "漢字ab" + C + "2G" + C + "@" + C + "1;4H" + C + "P")
case("wide-erase", "漢字ab" + C + "2G" + C + "K" + "\r\n漢字ab" + C + "3G" + C + "1X")
case("combining", "éạ̈ x" + C + "5G" + "́")
case("combining-at-wrap", "abcdefghijklmnopqrst́")
case("combining-on-wide", "漢́")
case("combining-limit", "a" + "́" * 40 + "b")
case("combining-start", "́x")
case("emoji", "😀 🖥 👍🏽 🇫🇷 ❤️ ☺ 1️⃣")
case("zwj", "👩‍💻x")
case("utf8-invalid", b"a\xffb\xc3(c\xe2\x82d\xf0\x9f\x98e\xc0\x80f\xed\xa0\x80g\x80h")
case("utf8-split", split("añ漢😀z"))
case("c1-as-utf8", "a\u0085b\u009bc")
case("dec-graphics", E + "(0" + "lqk\r\nx x\r\nmqj" + E + "(B" + "q")
case("dec-graphics-g1", E + ")0" + "a\x0eq\x0fq")
case("dec-graphics-rep", E + "(0q" + C + "3b" + E + "(B")
case("decsc-charset", E + "(0" + E + "7" + E + "(B" + "q" + E + "8" + "q")
# OSC / strings
case("osc-title", E + "]0;first\x07" + E + "]2;second" + E + "\\" + E + "]1;icon\x07")
case("osc-icon-first", E + "]1;icon\x07")
case("osc-unterminated", E + "]0;abc" + "\x18" + "x")
case("osc-esc-inside", E + "]2;a" + E + "b\x07y")
case("osc-dir", E + "]7;file://host/Users/me/My%20Dir/\x07" + E + "]7;notaurl\x07" + E + "]7;file:///tmp\x07")
case("osc-colours", E + "]10;?\x07" + E + "]11;?" + E + "\\" + E + "]10;rgb:0/0/0\x07")
case("osc-numeric-only", E + "]0\x07" + E + "]abc\x07" + "z")
case("dcs-apc", E + "Pq#0;2;0;0;0" + E + "\\" + "a" + E + "_hello\x07b" + E + "^pm" + E + "\\c" + E + "Xsos\x07d")
case("csi-ignore", C + "1;2:3$#m" + "a" + C + "?1;>2h" + "b" + C + "1\x80m" + "c")
case("csi-control-inside", C + "2\r" + "C" + "x")
case("csi-cancel", C + "12\x18" + "a" + C + "3\x1a" + "b" + C + "4" + E + "c")
case("esc-cancel", E + "\x18a" + E + E + "7" + "b" + E + " F" + "c" + E + "\x07d")
case("esc-intermediate-control", E + "(\x08" + "0q")
case("long-params", C + "99999999999999999999999A" + "x" + C + "0;0H" + "y")
case("cursor-style", C + "4 q" + C + "6 q" + C + "2 q" + C + "3 q" + C + "5 q" + C + "1 q")
case("cursor-visible", C + "?25l")
case("modes", C + "?1h" + E + "=" + C + "?1000h" + C + "?1006h" + C + "?1004h" + C + "?2004h" + C + "?1;1004l")
case("deckpnm", E + "=" + E + ">")
# Alternate screen
case("alt-1049", "main\r\nscreen" + C + "?1049h" + "alt text" + C + "?1049l" + "!")
case("alt-47", "main" + C + "?47h" + "alt" + C + "?47l" + "+")
case("alt-1047-1048", "ab" + C + "?1048h" + C + "?1047h" + C + "3;3Hz" + C + "?1047l" + C + "?1048l" + "c")
case("alt-no-scrollback", C + "?1049h" + "\r\n".join(str(i) for i in range(12)) + C + "?1049l")
case("alt-resize", "main" + C + "?1049h" + "alt", {"resize": [10, 4]}, C + "?1049l" + "x")
case("alt-twice", C + "?1049h" + "a" + C + "?1049h" + "b" + C + "?1049l" + C + "?1049l" + "c")
# Reset
case("ris", C + "1;31m" + C + "?25l" + C + "?1h" + "abc" + E + "c" + "x")
case("reset-step", "abc" + C + "4 q", {"reset": True}, "d")
# Resize
case("resize-shrink-rows", "\r\n".join(str(i) for i in range(6)), {"resize": [20, 3]})
case("resize-shrink-blank-below", "a\r\nb" + C + "1;1H", {"resize": [20, 3]})
case("resize-grow-rows", "\r\n".join(str(i) for i in range(10)), {"resize": [20, 9]})
case("resize-columns", "abcdefghijklmnop漢", {"resize": [10, 6]}, {"resize": [30, 6]})
case("resize-wide-cut", "abcd漢", {"resize": [5, 6]})
case("resize-tiny", "abc", {"resize": [1, 0]})
case("resize-same", "abc", {"resize": [20, 6]})
case("resize-saved-cursor", C + "6;20H" + E + "7", {"resize": [10, 3]}, E + "8" + "s")
case("resize-scrollback-round-trip", C + "41m" + "red" + C + "0m" + " 漢 x\r\n" + "\r\n".join(str(i) for i in range(8)), {"resize": [20, 2]}, {"resize": [20, 8]})
case("scrollback-styles", C + "1;32m" + "green bold" + C + "0m  tail" + C + "44m   " + C + "0m\r\n" + "é 🇫🇷 漢\r\n" + "\r\n" * 6)
# Dirty rows
case("dirty", {"clearDirty": True}, "a", {"dirty": True}, {"clearDirty": True}, C + "3;1Hb\r\nc", {"dirty": True}, {"clearDirty": True}, C + "2J", {"dirty": True}, {"clearDirty": True}, C + "2;4r" + C + "4;1H\n", {"dirty": True})
# A flood
case("flood", "".join("%05d " % i + ("x" * (i % 30)) + "\r\n" for i in range(400)), columns=40, rows=10, scrollback=100)

# Recorded from real programs at 40x10 (script(1); `^D\b\b` is script's own EOF echo).
for name in ["vim", "vimedit", "less", "ls", "tput", "zsh"]:
    path = os.path.join(rec, name + ".bin")
    data = open(path, "rb").read()
    case("recorded-" + name, data, columns=40, rows=10)
    case("recorded-" + name + "-split", {"hex": data.hex(), "split": True}, columns=40, rows=10)
vim = open(os.path.join(rec, "vimedit.bin"), "rb").read()
case("recorded-vimedit-open", vim[: vim.rfind(b"\x1b[?1049l")], columns=40, rows=10)
case("recorded-vim-resize", vim[: vim.rfind(b"\x1b[?1049l")], {"resize": [30, 7]}, vim[vim.rfind(b"\x1b[?1049l"):], columns=40, rows=10)

json.dump(cases, open(out, "w"), indent=1, ensure_ascii=True)
print(len(cases), "cases")
