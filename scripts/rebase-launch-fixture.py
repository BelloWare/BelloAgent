#!/usr/bin/env python3
"""Rebase a copied launch fixture onto its own folder (scripts/perf-launch.sh).

Its records and vault.json name journals and projects by absolute path, as
JSON that may escape "/" as "\\/". Every occurrence of <origin>/ becomes
<copy>/ in desktop.sqlite's records and in vault.json.
usage: rebase-launch-fixture.py <desktop.sqlite> <vault.json> <origin> <copy>
"""
import sqlite3
import sys

database, vault, origin, copy = sys.argv[1:5]
pairs = [((origin + "/").encode(), (copy + "/").encode())]
pairs.append((pairs[0][0].replace(b"/", b"\\/"), pairs[0][1].replace(b"/", b"\\/")))


def rebase(value: bytes) -> bytes:
    for old, new in pairs:
        value = value.replace(old, new)
    return value


connection = sqlite3.connect(database)
with connection:
    for kind, key, value in connection.execute("SELECT kind, id, value FROM records").fetchall():
        moved = rebase(bytes(value))
        if moved != bytes(value):
            connection.execute("UPDATE records SET value=? WHERE kind=? AND id=?", (moved, kind, key))
connection.close()
with open(vault, "rb") as handle:
    data = handle.read()
with open(vault, "wb") as handle:
    handle.write(rebase(data))
