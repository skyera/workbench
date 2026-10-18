#!/usr/bin/env bash
# fssh.sh - Shell wrapper for fssh (Git Bash / WSL / Linux / macOS)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v luajit >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/fssh.lua" ]; then
    exec luajit "$SCRIPT_DIR/fssh.lua" "$@"
else
    echo "[ERROR] 'luajit' is required to run fssh.lua." >&2
    exit 1
fi
