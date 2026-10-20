#!/usr/bin/env python3
"""Which lane each native test class runs in.

The native suite runs in two lanes (docs/Swift-Test-Handoff.md, "Test
lanes"): most classes in parallel clones of the test host, then the rest in
one host with the machine to itself. A class runs alone when its source does
any of the things below. Its source is its body, its extensions, the test
classes it inherits from, and the other declarations (helper types and
functions) in the files where those are written. Focus checks instead follow
the referenced declarations, including shared fixtures and nested source folders.

  focus     shows windows, changes/depends on app focus, or posts global input:
            one window server gives focus to one process at a time. Offscreen
            responders and direct local event delivery do not contend
  defaults  writes the standard user defaults, which every host shares
  pasteboard  uses the general or the drag pasteboard, which every host shares
  timing    asserts on elapsed time in this configuration: an elapsed-time
            expression inside an XCTAssert, or compared there through a local
            it was read into (`let elapsed = ...systemUptime - start`, then
            `XCTAssertLessThan(elapsed, 0.5)`), or a class that declares
            `SerialTestLane` (TestSeams.swift) for the timing assertions these
            patterns cannot see. A bound written `releaseBudget(...)` binds only
            in Release, and is the budget rule below
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
import textwrap
from typing import NamedTuple

ROOT = pathlib.Path(__file__).resolve().parent.parent
TESTS = ROOT / "apps/macos/PiAppTests"
TARGET = "PiAppTests"

PATTERNS = {
    "focus": re.compile(
        r"\b(?:NSApp|NSApplication\s*\.\s*shared)\s*\.\s*(?:activate|isActive|keyWindow|mainWindow|hide|unhide|deactivate|sendEvent|postEvent)\b"
        r"|\.\s*activate\s*\(\s*(?:ignoringOtherApps|options)\s*:"
        r"|\.\s*(?:makeKeyAndOrderFront|makeKey|makeMain|becomeKey|becomeMain|resignKey|resignMain|orderFrontRegardless"
        r"|orderFront\w*|isKeyWindow|isMainWindow|showWindow|runModal\w*)\b"
        r"|\b(?:CGWarpMouseCursorPosition|CGAssociateMouseAndMouseCursorPosition|CGEventPost|CGEventPostToPid)\s*\("
        r"|\.\s*(?:postToPid\s*\(|post\s*\(\s*(?:tap|toPid)\s*:)"
        r"|\bNSEvent\s*\.\s*mouseLocation\b"
        # App entry points that open/raise native windows through those APIs.
        r"|\bSessionInspectorWindows\b|\.\s*(?:openInspector|showMessageDetail|popOut|bringForward|bringMainWindowForward)\s*\("),
    "defaults": re.compile(r"UserDefaults\.standard|adjustStoredSidebarWidth"),
    "pasteboard": re.compile(r"NSPasteboard\.general|NSPasteboard\(name:\s*\.(?:drag|general)\)"),
}
BUDGET = re.compile(r"\breleaseBudget\(")
ELAPSED = re.compile(r"systemUptime|Date\(\)\.timeIntervalSince\(|timeIntervalSinceNow|DispatchTime\.now|CFAbsoluteTimeGetCurrent|ContinuousClock")
MARKER = "SerialTestLane"
MODIFIERS = r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:final|open|public|internal|private|fileprivate|nonisolated)\s+)*"
DECLARATION = re.compile(MODIFIERS + r"class\s+(\w+)\s*:\s*([^{]+)\{")
EXTENSION = re.compile(MODIFIERS + r"extension\s+(\w+)\b[^{]*\{")
HELPER = re.compile(MODIFIERS + r"(?:(?:static|class|mutating|override|convenience|required)\s+)*"
                    r"(class|struct|enum|actor|protocol|func|let|var|typealias)\s+(\w+)")
REFERENCE = re.compile(r"(?<![\w.])\b[A-Za-z_]\w*(?:\s*\??\.\s*[A-Za-z_]\w*)*")


class Sources(NamedTuple):
    local: str
    focus: str


def swift_code(text):
    """Mask comments/string contents, retaining code in Swift interpolations."""
    out = list(text)

    def blank(start, end):
        out[start:end] = ["\n" if char == "\n" else " " for char in text[start:end]]

    def scan(i, closing=None):
        while i < len(text):
            if closing and text[i] == closing:
                return i + 1
            if text.startswith("//", i):
                end = text.find("\n", i)
                end = len(text) if end < 0 else end
                blank(i, end); i = end
            elif text.startswith("/*", i):
                start, depth = i, 1
                i += 2
                while i < len(text) and depth:
                    if text.startswith("/*", i):
                        depth += 1; i += 2
                    elif text.startswith("*/", i):
                        depth -= 1; i += 2
                    else:
                        i += 1
                blank(start, i)
            elif text[i] in '"#' and (match := re.match(r'(#+)?("""|")', text[i:i + 32])):
                hashes, quote = match.group(1) or "", match.group(2)
                end, escape = quote + hashes, "\\" + hashes
                blank(i, i + len(match[0])); i += len(match[0])
                while i < len(text):
                    if text.startswith(end, i):
                        blank(i, i + len(end)); i += len(end)
                        break
                    if text.startswith(escape + "(", i):
                        blank(i, i + len(escape))
                        i = scan(i + len(escape) + 1, ")")
                    else:
                        stop = min(len(text), i + len(escape) + 1) if text.startswith(escape, i) else i + 1
                        blank(i, stop); i = stop
            elif text[i] == "(":
                i = scan(i + 1, ")")
            else:
                i += 1
        return i

    scan(0)
    return "".join(out)


RECEIVER = r"[A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*"
WINDOW_SETTING = re.compile(
    r"(?P<brace>[{}])"
    rf"|(?P<setting>{RECEIVER})\s*\.\s*showsWindows\s*=\s*(?P<value>true|false)\b(?=[ \t]*(?:[;}}\n]|$))"
    rf"|(?P<assignment>{RECEIVER})\s*=(?!=)"
    rf"|(?P<popout>{RECEIVER})\s*\.\s*popOut\s*\("
    rf"|\breturn\s+(?P<returned>{RECEIVER})")


def offscreen_popouts(text, is_factory=lambda name: False):
    """Honor TabHost's existing opt-out only when a scoped assignment proves it.

    Unknown hosts stay serial. Conditional assignments do not escape their
    block as proof, and reassigning/re-enabling a host removes the exemption.
    """
    states, returns, masked = [{}], [], list(text)
    for match in WINDOW_SETTING.finditer(text):
        if match["brace"] == "{":
            states.append(dict(states[-1]))
        elif match["brace"] == "}":
            if len(states) > 1:
                child = states.pop()
                for key in states[-1].keys() & child.keys():
                    if states[-1][key] != child[key]:
                        states[-1][key] = None
        elif match["setting"]:
            states[-1][re.sub(r"\s+", "", match["setting"])] = match["value"] == "true"
        elif match["assignment"]:
            receiver = re.sub(r"\s+", "", match["assignment"])
            if receiver.endswith(".showsWindows"):
                states[-1][receiver.removesuffix(".showsWindows")] = None
            for key in list(states[-1]):
                if key == receiver or key.startswith(receiver + "."):
                    states[-1][key] = None
            call = re.match(rf"\s*(?:try[?!]?\s+)?({RECEIVER})\s*\(", text[match.end():])
            if call and is_factory(re.sub(r"\s+", "", call[1])):
                states[-1][receiver] = False
        elif match["popout"]:
            receiver = re.sub(r"\s+", "", match["popout"])
            if states[-1].get(receiver) is False:
                start = text.rfind("popOut", match.start(), match.end())
                masked[start:start + 6] = " " * 6
        elif match["returned"]:
            returns.append(states[-1].get(re.sub(r"\s+", "", match["returned"])) is False)
    return "".join(masked), bool(returns) and all(returns)


def focus_sources(paths):
    """Follow actual named declarations, not every helper sharing their file.

    A constructed fixture is inspected as a whole type. A qualified static
    member (e.g. ConversationPaneTests.workbench) includes only that member,
    so data builders do not import unrelated window fixtures or test methods.
    """
    nodes, names, containers, parents, members, kinds = [], {}, set(), {}, {}, {}

    def add(text, file, scope="", inherited_private=False):
        for kind, name, inherits, chunk in blocks(text):
            extension = EXTENSION.match(chunk)
            declaration = HELPER.match(chunk)
            if not declaration and not extension:
                continue
            member = extension[1] if extension else declaration[2]
            qualified = scope + "." + member if scope else member
            private = inherited_private or bool(re.search(r"\b(?:private|fileprivate)\b", chunk.split("{", 1)[0]))
            index = len(nodes)
            nodes.append((qualified, file, chunk, scope, private))
            names.setdefault(qualified, []).append(index)
            members.setdefault(scope, []).append(index)
            kinds[index] = "extension" if extension else declaration[1]
            if kind == "class":
                parents.setdefault(qualified, set()).update(inherits)
            if not extension:
                containers.add(qualified)
            if extension or declaration[1] in ("class", "struct", "enum", "actor", "protocol"):
                if "{" in chunk:
                    body = textwrap.dedent(chunk[chunk.index("{") + 1:chunk.rfind("}")]).strip()
                    add(body, file, qualified, private)

    for path in paths:
        add(swift_code(path.read_text()), str(path))

    def accessible(key, file, seen=()):
        if key in seen:
            return []
        if key in containers:
            return [index for index in names.get(key, ()) if not nodes[index][4] or nodes[index][1] == file]
        # A qualified fixture member can be inherited from a test-free base.
        # Resolve it before falling back to the derived class as a whole.
        parts = key.split(".")
        for size in range(len(parts) - 1, 0, -1):
            for parent in sorted(parents.get(".".join(parts[:size]), ())):
                if found := accessible(".".join([parent] + parts[size:]), file, seen + (key,)):
                    return found
        return []

    def resolve(index, parts, local=()):
        qualified, file, _, scope, _ = nodes[index]
        if parts[0] in ("self", "Self") and len(parts) > 1:
            parts = parts[1:]
        # An extension builder can be called without spelling XCTestCase.
        scopes = [qualified, scope]
        while scopes[-1] and "." in scopes[-1]:
            scopes.append(scopes[-1].rsplit(".", 1)[0])
        for prefix in scopes:
            scopes.extend(parent for parent in sorted(parents.get(prefix, ())) if parent not in scopes and parent != "XCTestCase")
        scopes += ["XCTestCase", ""]
        candidates = [prefix for prefix in scopes if prefix] if parts[0] in local else scopes
        for prefix in candidates:
            for size in range(len(parts), 0, -1):
                key = ".".join(([prefix] if prefix else []) + parts[:size])
                if resolved := accessible(key, file):
                    return resolved
        return []

    def references(index):
        text = nodes[index][2]
        found = set()
        local = set(re.findall(r"\b(?:let|var|func)\s+(\w+)", text))
        for match in REFERENCE.finditer(text):
            parts = re.split(r"\s*\??\.\s*", match[0])
            # A local receiver's members are reached through its fixture type,
            # never through an unrelated global with the same variable name.
            found.update(resolve(index, parts, local))
        return found

    edges = {index: references(index) for index in range(len(nodes))}
    factories = {index for index, node in enumerate(nodes)
                 if re.search(r"\bfunc\b[^{}]*->\s*TabHost\s*\{", node[2].split("{", 1)[0] + "{")
                 and offscreen_popouts(node[2])[1]}

    def is_factory(index, name):
        resolved = resolve(index, name.split("."))
        return bool(resolved) and all(target in factories for target in resolved)

    texts = [offscreen_popouts(node[2], lambda name, i=index: is_factory(i, name))[0] if "popOut" in node[2] else node[2]
             for index, node in enumerate(nodes)]

    def collect(lineage):
        # An unused base-class window builder does not open a window. Start
        # with runnable methods, lifecycle hooks and stored fixture properties.
        pending = [index for name in lineage for index in members.get(name, ())
                   if kinds[index] in ("let", "var")
                   or (kinds[index] == "func" and re.match(r"(?:test\w*|setUp\w*|tearDown\w*)$", nodes[index][0].rsplit(".", 1)[-1]))]
        visited = set()
        while pending:
            index = pending.pop()
            if index in visited:
                continue
            visited.add(index)
            pending.extend(edges[index] - visited)
        return "\n".join(texts[index] for index in sorted(visited))

    return collect


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


TIMED_LOCAL = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::[^=\n]*)?=([^\n]*)")


def compared_values(arguments):
    """The two values an XCTAssertLess/Greater call compares: its first two
    top-level arguments, never the message after them."""
    parts, depth, start, quoted = [], 0, 0, False
    for index, character in enumerate(arguments):
        if character == '"' and arguments[index - 1:index] != "\\":
            quoted = not quoted
        elif not quoted:
            if character in "([{":
                depth += 1
            elif character in ")]}":
                depth -= 1
            elif character == "," and depth == 0:
                parts.append(arguments[start:index])
                start = index + 1
    parts.append(arguments[start:])
    return parts[:2]


def asserts_elapsed_time(text):
    """An XCTAssert whose own arguments measure elapsed time, or an ordering
    assertion that compares a local whose nearest assignment before it read a
    clock. The nearest one, because tests reuse names: one test's `started`
    is a byte count, another's the time a step began."""
    assignments = [(match.start(), match.group(1), bool(ELAPSED.search(match.group(2)))) for match in TIMED_LOCAL.finditer(text)]
    for match in re.finditer(r"\bXCTAssert\w*\(", text):
        depth, j = 1, match.end()
        while j < len(text) and depth:
            depth += {"(": 1, ")": -1}.get(text[j], 0)
            j += 1
        arguments = text[match.end():j - 1]
        if ELAPSED.search(arguments):
            return True
        if not re.match(r"XCTAssert(?:Less|Greater)", match.group(0)):
            continue
        values = compared_values(arguments)
        if any("releaseBudget" in value for value in values):
            continue
        latest = {}
        for position, name, timed in assignments:
            if position < match.start():
                latest[name] = timed
        if any(timed and re.search(r"\b%s\b" % re.escape(name), value) for name, timed in latest.items() for value in values):
            return True
    return False


def classes():
    declared, extended, files, helpers = {}, {}, {}, {}
    paths = sorted(TESTS.rglob("*.swift"))
    collect_focus = focus_sources(paths)
    for path in paths:
        file = str(path.relative_to(TESTS))
        for kind, name, inherits, text in blocks(path.read_text()):
            if kind == "class":
                declared[name] = (inherits, text)
                files.setdefault(name, set()).add(file)
            elif kind == "extension":
                extended.setdefault(name, []).append(text)
                files.setdefault(name, set()).add(file)
            else:
                helpers.setdefault(file, []).append(text)

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
                helpers[file].extend(extended.get(name, []))

    result = {}
    for name, (inherits, text) in declared.items():
        if not is_test_case(name):
            continue
        own = [text] + extended.get(name, [])
        source, lineage, parent = list(own), [name], inherits[0] if inherits else None
        while parent and parent in declared:
            source.append(declared[parent][1])
            source.extend(extended.get(parent, []))
            lineage.append(parent)
            parent = declared[parent][0][0] if declared[parent][0] else None
        has_tests = any(re.search(r"\bfunc test\w*\s*\(", part) for part in source)
        for file in sorted(set().union(*(files.get(member, set()) for member in lineage))):
            source.extend(helpers.get(file, []))
        if has_tests:
            result[name] = (inherits, Sources("\n".join(source), collect_focus(lineage)))
    return result


def reasons(inherits, source, configuration):
    local, focus = source if isinstance(source, Sources) else (source, swift_code(source))
    found = [name for name, pattern in PATTERNS.items() if pattern.search(focus if name == "focus" else local)]
    if MARKER in inherits or asserts_elapsed_time(local):
        found.append("timing")
    if configuration == "Release" and BUDGET.search(local):
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
