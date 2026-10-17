#!/usr/bin/env bash
# frg.sh - Launch frg.lua via LuaJIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v luajit >/dev/null 2>&1; then
    exec luajit "${SCRIPT_DIR}/frg.lua" "$@"
else
    echo "[ERROR] luajit is required to run frg.lua." >&2
    exit 1
fi
