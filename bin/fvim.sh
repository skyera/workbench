#!/usr/bin/env bash
# fvim.sh - Backward-compatibility wrapper for fe.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/fe.sh" "$@"
