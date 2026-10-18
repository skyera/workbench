#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec luajit "$SCRIPT_DIR/fputty.lua" "$@"
