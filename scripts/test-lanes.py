#!/usr/bin/env python3
"""Which lane each native test class runs in.

The native suite runs in two lanes (docs/Swift-Test-Handoff.md, "Test
lanes"): most classes in parallel clones of the test host, then the rest in
one host with the machine to itself. A class runs alone when its source does
any of the things below. Its source is its body, its extensions, the test
classes it inherits from, and the other declarations (helper types and
functions) in the files where those are written.

  focus     activates the app, or reads activation or key-window state: one
            window server gives focus to one process at a time
  defaults  writes the standard user defaults, which every host shares
  pasteboard  uses the general or the drag pasteboard, which every host shares
  timing    asserts on elapsed time in this configuration: an elapsed-time
            expression inside an XCTAssert, or a class that declares
            `SerialTestLane` (TestSeams.swift) for the timing assertions this
            pattern cannot see
  budget    Release only: calls `releaseBudget`, whose budgets are infinite in
            Debug and only bind in a Release build

Everything else runs in the parallel lane. The parallel lane skips the serial
classes rather than naming its own, so a class this script cannot read still
runs.

usage:
  scripts/test-lanes.py serial   [--configuration Debug|Release]
      xcodebuild arguments for the serial lane, one per line
  scripts/test-lanes.py parallel [--configuration Debug|Release]
      xcodebuild arguments for the parallel lane, one per line
  scripts/test-lanes.py list     [--configuration Debug|Release]
      every test class, its lane and why
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TESTS = ROOT / "apps/macos/PiAppTests"
TARGET = "PiAppTests"

PATTERNS = {
    "focus": re.compile(r"NSApp\.activate|\.activate\(ignoringOtherApps|NSApp\.isActive|NSApplication\.shared\.isActive"
                        r"|\.isKeyWindow\b|NSApp\.keyWindow|NSApp\.mainWindow|orderFrontRegardless"),
    "defaults": re.compile(r"UserDefaults\.standard|adjustStoredSidebarWidth"),
    "pasteboard": re.compile(r"NSPasteboard\.general|NSPasteboard\(name:\s*\.(?:drag|general)\)"),
}
BUDGET = re.compile(r"\breleaseBudget\(")
ELAPSED = re.compile(r"systemUptime|Date\(\)\.timeIntervalSince\(|timeIntervalSinceNow|DispatchTime\.now|CFAbsoluteTimeGetCurrent|ContinuousClock")
MARKER = "SerialTestLane"
MODIFIERS = r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:final|open|public|internal|private|fileprivate|nonisolated)\s+)*"
DECLARATION = re.compile(MODIFIERS + r"class\s+(\w+)\s*:\s*([^{]+)\{")
EXTENSION = re.compile(MODIFIERS + r"extension\s+(\w+)\b[^{]*\{")


def blocks(text):
    """Top-level declarations and their text, up to the closing brace at the
    start of a line. Test sources indent their members, as Xcode does. Yields
    ("class", name, inherits, text), ("extension", name, [], text), and
    ("helper", None, [], text) for every other declaration."""
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line or line[0] in " \t}/" or line.startswith(("import ", "#")):
            i += 1
            continue
        end = i
        if line.count("{") > line.count("}"):
            end = i + 1
            while end < len(lines) and lines[end].rstrip() != "}":
                end += 1
        chunk = "\n".join(lines[i:end + 1])
        if (match := DECLARATION.match(line)):
            yield "class", match.group(1), [part.strip() for part in match.group(2).split(",")], chunk
        elif (match := EXTENSION.match(line)):
            yield "extension", match.group(1), [], chunk
        else:
            yield "helper", None, [], chunk
        i = end + 1


def asserts_elapsed_time(text):
    """An XCTAssert whose own arguments measure elapsed time."""
    for match in re.finditer(r"\bXCTAssert\w*\(", text):
        depth, j = 1, match.end()
        while j < len(text) and depth:
            depth += {"(": 1, ")": -1}.get(text[j], 0)
            j += 1
        if ELAPSED.search(text[match.end():j]):
            return True
    return False


def classes():
    declared, extended, files, helpers = {}, {}, {}, {}
    for path in sorted(TESTS.glob("*.swift")):
        for kind, name, inherits, text in blocks(path.read_text()):
            if kind == "class":
                declared[name] = (inherits, text)
                files.setdefault(name, set()).add(path.name)
            elif kind == "extension":
                extended.setdefault(name, []).append(text)
                files.setdefault(name, set()).add(path.name)
            else:
                helpers.setdefault(path.name, []).append(text)

    def is_test_case(name, seen=()):
        if name == "XCTestCase":
            return True
        if name not in declared or name in seen:
            return False
        return any(is_test_case(parent, seen + (name,)) for parent in declared[name][0])

    # A declared class that is not a test case is a helper of its file.
    for name, (inherits, text) in declared.items():
        if not is_test_case(name):
            for file in files.get(name, ()):
                helpers.setdefault(file, []).append(text)

    result = {}
    for name, (inherits, text) in declared.items():
        if not is_test_case(name):
            continue
        own = [text] + extended.get(name, [])
        if not any(re.search(r"\bfunc test\w*\s*\(", part) for part in own):
            continue
        source, lineage, parent = list(own), [name], inherits[0] if inherits else None
        while parent and parent in declared:
            source.append(declared[parent][1])
            source.extend(extended.get(parent, []))
            lineage.append(parent)
            parent = declared[parent][0][0] if declared[parent][0] else None
        for file in sorted(set().union(*(files.get(member, set()) for member in lineage))):
            source.extend(helpers.get(file, []))
        result[name] = (inherits, "\n".join(source))
    return result


def reasons(inherits, source, configuration):
    found = [name for name, pattern in PATTERNS.items() if pattern.search(source)]
    if MARKER in inherits or asserts_elapsed_time(source):
        found.append("timing")
    if configuration == "Release" and BUDGET.search(source):
        found.append("budget")
    return found


def main():
    parser = argparse.ArgumentParser(description="The native suite's two lanes.")
    parser.add_argument("command", choices=["serial", "parallel", "list"])
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    options = parser.parse_args()
    lanes = {name: reasons(inherits, source, options.configuration) for name, (inherits, source) in classes().items()}
    serial = sorted(name for name, found in lanes.items() if found)
    if not serial:
        sys.exit("test-lanes: no serial classes found; is the test folder where this script expects it?")
    if options.command == "serial":
        print("\n".join(f"-only-testing:{TARGET}/{name}" for name in serial))
    elif options.command == "parallel":
        print("\n".join(f"-skip-testing:{TARGET}/{name}" for name in serial))
    else:
        for name in sorted(lanes):
            found = lanes[name]
            print(f"{'serial  ' if found else 'parallel'} {name}{'  (' + ', '.join(found) + ')' if found else ''}")


if __name__ == "__main__":
    main()
