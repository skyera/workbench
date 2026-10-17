#!/usr/bin/env bash
# fe.sh - Launch fe.lua via LuaJIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v luajit >/dev/null 2>&1; then
    exec luajit "${SCRIPT_DIR}/fe.lua" "$@"
else
    echo "[ERROR] luajit is required to run fe.lua." >&2
    exit 1
fi
