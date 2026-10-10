#!/bin/sh
# exec the Rust Agent with the fake loopback key on stdin (same PID for measurement).
exec "$@" < /Users/admin/Library/Caches/BelloRustWork/claude-2026-10-10/fixtures/bench/fake-key.txt
