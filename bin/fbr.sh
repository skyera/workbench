#!/usr/bin/env bash
# fbr.sh - Launch fbr.lua via LuaJIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v luajit >/dev/null 2>&1; then
    exec luajit "${SCRIPT_DIR}/fbr.lua" "$@"
else
    echo "[ERROR] luajit is required to run fbr.lua." >&2
    exit 1
fi
