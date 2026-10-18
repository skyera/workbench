#!/usr/bin/env bash
# fkill.sh - Launch fkill.lua via LuaJIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v luajit >/dev/null 2>&1; then
    exec luajit "${SCRIPT_DIR}/fkill.lua" "$@"
else
    echo "[ERROR] luajit is required to run fkill.lua." >&2
    exit 1
fi
