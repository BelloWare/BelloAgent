#!/usr/bin/env bash
# Runs a test command; if it fails, repeats its failing tests and panic
# messages as workflow error annotations, which the public check-runs API
# shows without log access. The command's own output and status are kept.
set -uo pipefail
log=$(mktemp)
"$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if [ "$status" -ne 0 ]; then
  grep -E -A1 '^test .* \.\.\. FAILED$|panicked at ' "$log" | grep -v '^--$' | head -20 |
    sed 's/%/%25/g' | while IFS= read -r line; do printf '::error::%s\n' "$line"; done
fi
rm -f "$log"
exit "$status"
