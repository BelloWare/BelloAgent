#!/usr/bin/env python3
"""Apply the reviewed Pi 0.85.1 SSE fix; reject any unexpected upstream bytes."""
import hashlib
import json
from pathlib import Path
import sys

ORIGINAL = 'f748560c80fe91bb5736b62f6f34c5e2e2bfa224cd5eb959134ca903c226b604'
MARKER = '// Pi App patch: defer a trailing CR until LF or EOF is known.'

def patched(source):
    assert source.count('function consumeLine(text) {') == 1
    source = source.replace('function consumeLine(text) {', 'function consumeLine(text, final = false) {')
    old = '    let nextIndex = lineBreakIndex + 1;'
    assert source.count(old) == 1
    source = source.replace(old, f'    {MARKER}\n    if (!final && text[lineBreakIndex] === "\\r" && lineBreakIndex === text.length - 1) return null;\n' + old)
    before, after = source.split('        buffer += decoder.decode();', 1)
    assert after.count('consumeLine(buffer)') == 2
    return before + '        buffer += decoder.decode();' + after.replace('consumeLine(buffer)', 'consumeLine(buffer, true)')

def apply(root):
    paths = sorted(root.glob('**/@earendil-works/pi-ai/dist/api/anthropic-messages.js'))
    if not paths:
        raise SystemExit(f'Pi installation missing under {root}')
    records = []
    for path in paths:
        package = json.loads((path.parents[2] / 'package.json').read_text())
        assert package['version'] == '0.85.1', f'Unreviewed Pi version: {path}'
        source = path.read_text()
        if MARKER in source:
            original = source.replace('function consumeLine(text, final = false)', 'function consumeLine(text)')
            original = original.replace(f'    {MARKER}\n    if (!final && text[lineBreakIndex] === "\\r" && lineBreakIndex === text.length - 1) return null;\n', '')
            original = original.replace('consumeLine(buffer, true)', 'consumeLine(buffer)')
        else:
            original = source
        assert hashlib.sha256(original.encode()).hexdigest() == ORIGINAL, f'Pi source mismatch: {path}'
        result = patched(original)
        assert source in (original, result), f'Unexpected partial patch: {path}'
        if source != result:
            path.write_text(result)
        records.append({'path': str(path.relative_to(root)), 'upstreamSHA256': ORIGINAL, 'patchedSHA256': hashlib.sha256(result.encode()).hexdigest()})
    return records

if __name__ == '__main__':
    print(json.dumps(apply(Path(sys.argv[1] if len(sys.argv) > 1 else 'node_modules').resolve()), indent=2))
