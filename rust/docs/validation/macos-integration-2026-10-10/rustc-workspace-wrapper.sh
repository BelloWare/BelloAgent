#!/bin/sh
# Separate this worktree's workspace artifact names inside the shared target.
# Cargo includes RUSTC_WORKSPACE_WRAPPER's path in the workspace artifact hash.
# Pass the compiler and every argument through without changing compilation.
exec "$@"
