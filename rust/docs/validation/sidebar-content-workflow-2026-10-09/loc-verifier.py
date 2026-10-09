#!/usr/bin/env python3
"""Exact nonblank Rust LOC delta on the immutable loaded-search baseline.

Comments count. Positive cfg(test) spans and test-owned files are support.
No native, performance or feature-completion claim follows from this accounting.
"""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

BASE = '92fca5871240788f9da9c109fe451c76fb128480'
LEDGER = 'rust/docs/validation/loc-unloaded-observation-2026-10-09-delta.json'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def positive_support_gate(condition):
    """True only if the gate cannot compile with both test/synthetic disabled.

    Other atoms are conservatively unknown. This excludes negative synthetic
    gates and native any(test, target_os=...) arms from support ownership.
    """
    def possible(expression):
        expression = expression.strip()
        if expression in {'test', 'feature="synthetic-authority"'}:
            return {False}
        match = re.fullmatch(r'(all|any|not)\((.*)\)', expression, re.S)
        if not match:
            return {False, True}
        name, arguments = match.groups()
        parts, start, depth, quoted, escaped = [], 0, 0, False, False
        for index, character in enumerate(arguments):
            if quoted:
                if escaped: escaped = False
                elif character == "\\": escaped = True
                elif character == '"': quoted = False
                continue
            if character == '"': quoted = True
            elif character == '(': depth += 1
            elif character == ')': depth -= 1
            elif character == ',' and depth == 0:
                parts.append(arguments[start:index]); start = index + 1
        if arguments[start:].strip(): parts.append(arguments[start:])
        values = [possible(part) for part in parts]
        if name == 'not':
            if len(values) != 1: raise ValueError('Invalid cfg not')
            return {not value for value in values[0]}
        result = {name == 'all'}
        for choices in values:
            result = {(left and right) if name == 'all' else (left or right)
                      for left in result for right in choices}
        return result
    compact = re.sub(r'\s+', '', condition)
    assert compact.startswith('#[cfg(') and compact.endswith(')]')
    return True not in possible(compact[6:-2])


def cfg_test_ranges(text):
    """Reviewed changed files use only ordinary cfg(test) items/statements.

    Lexically mask comments/strings, preserving offsets and newlines. Mark each
    complete test item/statement from its positive cfg attribute. Whole test
    modules at EOF are included; preceding production comments stay production.
    This is intentionally a reviewed-slice counter, not a general Rust parser.
    """
    masked = re.sub(r'//[^\n]*|"(?:\\.|[^"\\])*"', lambda m: ''.join('\n' if c == '\n' else ' ' for c in m[0]), text)
    ranges = []
    for match in re.finditer(r'#\[cfg\((.*?)\)\]', masked, re.S):
        # Gate text is read from the original source: strings were masked above.
        condition = text[match.start():match.end()]
        if not positive_support_gate(condition):
            continue
        start = match.start()
        rest = masked[match.end():]
        # cfg attributes may guard struct fields or field initializers. A
        # field ends at its top-level comma, not at the next method body.
        field = re.match(r'\s*(?:pub(?:\([^)]*\))?\s+)?[A-Za-z_]\w*\s*:(?!:)', rest)
        arm = re.match(r'\s*[^\n;{}]*=>', rest)
        if field or arm:
            depth = {'(': 0, '[': 0, '<': 0, '{': 0}
            pairs = {')': '(', ']': '[', '>': '<', '}': '{'}
            end = match.end()
            braced_arm = bool(arm and re.match(r'\s*{', rest[arm.end():]))
            for character in rest:
                if character == ',' and not any(depth.values()):
                    end += 1
                    break
                if character in depth:
                    depth[character] += 1
                elif character in pairs and depth[pairs[character]]:
                    depth[pairs[character]] -= 1
                end += 1
                if braced_arm and character == '}' and not any(depth.values()):
                    break
            else:
                raise ValueError('Unterminated cfg field: ' + rest[:100])
            ranges.append((text.count('\n', 0, start) + 1, text.count('\n', 0, max(start, end - 1)) + 1))
            continue
        first = re.search(r'[;{]', rest)
        if first is None:
            raise ValueError('Unterminated cfg(test) item')
        position = match.end() + first.start()
        if masked[position] == ';':
            end = position + 1
        else:
            depth = 1
            end = position + 1
            while depth:
                if end >= len(masked):
                    raise ValueError('Unbalanced cfg(test) item')
                depth += (masked[end] == '{') - (masked[end] == '}')
                end += 1
            # For closure statements/macros, include same-line trailing ); or ;.
            line_end = masked.find('\n', end)
            if line_end == -1:
                line_end = len(masked)
            if not masked[end:line_end].strip(' );\t'):
                end = line_end
        ranges.append((text.count('\n', 0, start) + 1, text.count('\n', 0, max(start, end - 1)) + 1))
    return ranges


def count(path, data):
    text = data.decode()
    support_file = ('/tests/' in path or path.endswith(('_tests.rs', '/tests.rs')) or path in {
        'rust/crates/bello-agent-core/src/sidebar_search/cache/observer.rs',
        'rust/crates/bello-agent-app/src/synthetic_sidebar_fixture.rs',
    })
    spans = [] if support_file else cfg_test_ranges(text)
    counts = {'production': 0, 'support': 0, 'benchmark': 0}
    for number, line in enumerate(text.splitlines(), 1):
        if line.strip():
            support = support_file or any(start <= number <= end for start, end in spans)
            counts['support' if support else 'production'] += 1
    return counts, spans


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, default=Path('.'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    repo = args.repo.resolve()

    def git(*parts):
        return subprocess.check_output(['git', '-C', str(repo), *parts])

    baseline_bytes = git('show', f'{BASE}:{LEDGER}')
    baseline = json.loads(baseline_bytes)
    inventory = {row['path']: row for row in baseline['inventory']}
    for path, row in inventory.items():
        data = git('show', f'{BASE}:{path}')
        assert sha(data) == row['sha256'], path
        assert sum(bool(line.strip()) for line in data.decode().splitlines()) == row['nonblank'], path
    actual_base = set(git('ls-tree', '-r', '--name-only', BASE, 'rust').decode().splitlines())
    assert {p for p in actual_base if p.endswith('.rs')} == set(inventory)
    paths = set(git('ls-files', '--cached', '--others', '--exclude-standard', 'rust').decode().splitlines())
    paths = {p for p in paths if p.endswith('.rs')}
    delta = dict.fromkeys(['production', 'support', 'benchmark'], 0)
    files = []
    live_inventory = []
    for path in sorted(paths | set(inventory)):
        old = git('show', f'{BASE}:{path}') if path in inventory else b''
        new = (repo / path).read_bytes() if (repo / path).exists() else b''
        if old != new:
            before, before_ranges = count(path, old)
            after, after_ranges = count(path, new)
            change = {key: after[key] - before[key] for key in delta}
            for key in delta:
                delta[key] += change[key]
            files.append({'path': path, 'before_sha256': sha(old) if old else None,
                          'after_sha256': sha(new) if new else None, 'before_counts': before,
                          'after_counts': after, 'delta': change,
                          'before_cfg_test_ranges': before_ranges, 'after_cfg_test_ranges': after_ranges,
                          'fully_test_owned': ('/tests/' in path or path.endswith(('_tests.rs', '/tests.rs')) or path.endswith(('/cache/observer.rs', '/synthetic_sidebar_fixture.rs')))})
        if new:
            live_inventory.append({'path': path, 'sha256': sha(new),
                                   'nonblank': sum(bool(line.strip()) for line in new.decode().splitlines()),
                                   'classification': inventory.get(path, {}).get('classification', 'product')})
    cumulative = {key: baseline['cumulative_counts'][key] + delta[key] for key in delta}
    result = {'baseline_commit': BASE, 'baseline_tree': git('rev-parse', f'{BASE}^{{tree}}').decode().strip(),
              'baseline_ledger_sha256': sha(baseline_bytes), 'baseline_counts': baseline['cumulative_counts'],
              'baseline_inventory_verified': True, 'delta': delta, 'cumulative_counts': cumulative,
              'changed_rust_files': len(files), 'files': files, 'inventory': live_inventory,
              'excluded_evidence_nonblank': baseline['excluded_evidence_nonblank'], 'shared_box_excluded': True,
              'method': 'Nonblank physical Rust including comments. Immutable92fca inventory and prior60690/82902/1192 totals verified byte-for-byte. Positive-only test/synthetic-authority gates (never negative gates or native any(test,platform)) count as support, as do test-owned files, cache observer and synthetic launcher. Classification is applied symmetrically before/after for changed files; unchanged lines are not reclassified. Core cache and gated product App pipeline count as production without a readiness claim. Shared Box, Python/Swift/YAML/docs and existing documentation evidence excluded.'}
    product_total = sum(row['nonblank'] for row in live_inventory if row['classification'] == 'product')
    assert product_total == sum(cumulative.values()), (product_total, cumulative)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in ['delta', 'cumulative_counts', 'changed_rust_files']}))


if __name__ == '__main__':
    main()
