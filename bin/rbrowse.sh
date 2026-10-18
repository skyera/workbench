#!/bin/sh
# rbrowse.sh - Backward-compatible shim for rfe.lua
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec luajit "$SCRIPT_DIR/rfe.lua" "$@"
