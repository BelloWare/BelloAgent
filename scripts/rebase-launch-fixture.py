#!/usr/bin/env python3
"""Rebase a copied launch fixture onto its own folder (scripts/perf-launch.sh).

Its records and vault.json name journals and projects by absolute path, as
JSON that may escape "/" as "\\/", and the search index beside the database
keys each chat by its journal's path (a moved journal is read again in full).
Every occurrence of <origin>/ becomes <copy>/ in all three, and <copy>'s
fixture-root marker names <copy>.
usage: rebase-launch-fixture.py <desktop.sqlite> <vault.json> <origin> <copy>
"""
import os
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
index = os.path.join(os.path.dirname(database), "search-index.sqlite")
if os.path.exists(index):
    connection = sqlite3.connect(index)
    with connection:
        connection.execute("UPDATE chats SET path = ? || substr(path, ?) WHERE substr(path, 1, ?) = ?",
                           (copy + "/", len(origin) + 2, len(origin) + 1, origin + "/"))
    connection.close()
with open(vault, "rb") as handle:
    data = handle.read()
with open(vault, "wb") as handle:
    handle.write(rebase(data))
marker = os.path.join(copy, "fixture-root")
if os.path.exists(marker):
    with open(marker, "w") as handle:
        handle.write(os.path.abspath(copy))
