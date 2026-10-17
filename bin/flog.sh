#!/usr/bin/env bash
# flog.sh - Launch flog.lua via LuaJIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v luajit >/dev/null 2>&1; then
    exec luajit "${SCRIPT_DIR}/flog.lua" "$@"
else
    echo "[ERROR] luajit is required to run flog.lua." >&2
    exit 1
fi
