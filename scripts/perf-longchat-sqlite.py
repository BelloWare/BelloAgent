#!/usr/bin/env python3
"""Probe the system SQLite used by the app, using disposable generated data.

This is a cache-write microbenchmark, not an application speedup measurement.
Run through perf-longchat-run.py so it follows the same quiet-window rules.
"""
import argparse
import ctypes
import json
import os
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rows", type=int, default=10000)
    args = parser.parse_args()
    root = Path(os.environ["PI_BUILD_ROOT"]).resolve()
    lib = ctypes.CDLL("/usr/lib/libsqlite3.dylib")
    # Apple arm64 puts variadic arguments on the stack; declare the fixed
    # arguments before querying this variadic API with ctypes.
    lib.sqlite3_db_config.argtypes = [ctypes.c_void_p, ctypes.c_int]
    callback_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_int,
                                    ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_char_p))
    for batch in [1, 64, 5000]:
        path = root / "scratch" / f"perf-sqlite-{os.getpid()}-{batch}.sqlite"
        db = ctypes.c_void_p()
        assert lib.sqlite3_open(str(path).encode(), ctypes.byref(db)) == 0
        facts = {}
        defensive = ctypes.c_int()
        # -1 reads the connection setting without changing it (sqlite3.h).
        assert lib.sqlite3_db_config(db, 1010, -1, ctypes.byref(defensive)) == 0
        facts["defensive"] = defensive.value
        @callback_type
        def row(_, count, values, names):
            facts.update({names[i].decode(): values[i].decode() if values[i] else None for i in range(count)})
            return 0
        def execute(sql):
            status = lib.sqlite3_exec(db, sql.encode(), row, None, None)
            assert status == 0, (status, sql)
        try:
            execute("SELECT sqlite_version(); PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA cache_size=-512; "
                    "PRAGMA journal_mode; PRAGMA synchronous; CREATE TABLE matches(offset INTEGER PRIMARY KEY, count INTEGER, preview TEXT);")
            started = time.perf_counter()
            for index in range(args.rows):
                if batch > 1 and index % batch == 0:
                    execute("BEGIN")
                execute(f"INSERT OR REPLACE INTO matches VALUES({index},-1,'generated negative match')")
                if batch > 1 and (index % batch == batch - 1 or index == args.rows - 1):
                    execute("COMMIT")
            elapsed = (time.perf_counter() - started) * 1000
            print("PERF136_SQLITE " + json.dumps(dict(rows=args.rows, batch=batch, ms=elapsed,
                                                       facts=facts, bytes=path.stat().st_size)), flush=True)
        finally:
            lib.sqlite3_close(db)
            path.unlink(missing_ok=True)
            Path(str(path) + "-journal").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
