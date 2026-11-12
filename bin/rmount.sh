#!/usr/bin/env bash
# rmount.sh - mount a remote directory over SSHFS, or unmount it again.
#
# Mount detection reads the kernel mount table (findmnt) instead of stat'ing
# the directory, so a stale mount left behind by a dead sshfs process
# ("Transport endpoint is not connected") is detected and cleaned up rather
# than being reported as a missing directory.
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

SSHFS_OPTS=(
    -o reconnect
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o follow_symlinks
    -o idmap=user
    -o cache=yes
    -o kernel_cache
    -o compression=yes
)

show_help() {
    cat <<HELPEOF
Usage:
  $SCRIPT_NAME <user@host> [<remote_dir>] <local_mount>
  $SCRIPT_NAME <user@host>:<remote_dir> <local_mount>
  $SCRIPT_NAME -u <local_mount>
  $SCRIPT_NAME -h | --help

Description:
  Mount a remote directory locally via SSHFS, or unmount an existing mount.
  If <remote_dir> is omitted, it defaults to the remote user's home directory.
  Stale mounts (sshfs process gone, "Transport endpoint is not connected")
  are lazily unmounted automatically before mounting or on -u.

Arguments:
  <user@host>     Remote SSH target (e.g., user@server.com or SSH config host)
  <remote_dir>    Optional path on remote host to mount (defaults to remote home)
  <local_mount>   Local directory to mount into

Options:
  -u, --unmount   Unmount the specified local mount point
  -h, --help      Display this help message and exit

Examples:
  # Mount remote home directory (defaults to remote \$HOME):
  $SCRIPT_NAME user@remote-box ~/mnt/remote

  # Mount specific remote directory:
  $SCRIPT_NAME user@remote-box /var/www ~/mnt/webserver
  $SCRIPT_NAME user@remote-box:/var/www ~/mnt/webserver

  # Unmount directory:
  $SCRIPT_NAME -u ~/mnt/remote
HELPEOF
}

# Prints an error plus the usage hint to stderr and exits with status 1.
usage_error() {
    echo "Error: $1" >&2
    echo "Run '$SCRIPT_NAME --help' for usage." >&2
    exit 1
}

# Returns success when `path` is listed in the kernel mount table. Unlike
# `mountpoint` or `[ -d ]`, this works on stale FUSE mounts that fail stat().
is_mounted() {
    local path="$1"

    if command -v findmnt >/dev/null 2>&1; then
        findmnt -rn -M "$path" >/dev/null 2>&1
        return
    fi

    mountpoint -q "$path" 2>/dev/null
}

# Returns success when `path` is mounted but can no longer be accessed.
is_stale_mount() {
    local path="$1"

    is_mounted "$path" || return 1
    ! stat -- "$path" >/dev/null 2>&1
}

# Runs the platform FUSE unmount for `path`. Pass "lazy" as the second
# argument to detach a stale or busy mount (fusermount -z / umount -l).
fuse_unmount() {
    local path="$1"
    local mode="${2:-}"
    local fuse_flags=(-u)
    local umount_flags=()

    if [[ "$mode" == "lazy" ]]; then
        fuse_flags=(-u -z)
        umount_flags=(-l)
    fi

    if command -v fusermount3 >/dev/null 2>&1; then
        fusermount3 "${fuse_flags[@]}" "$path"
    elif command -v fusermount >/dev/null 2>&1; then
        fusermount "${fuse_flags[@]}" "$path"
    else
        umount "${umount_flags[@]}" "$path"
    fi
}

# Lazily unmounts a stale mount at `path`; exits with guidance on failure.
cleanup_stale_mount() {
    local path="$1"
    local reason

    reason="$(stat -- "$path" 2>&1 >/dev/null | sed 's/.*: //' || true)"
    echo "Notice: '$path' is a stale mount (${reason:-not accessible}); lazy-unmounting."

    if ! fuse_unmount "$path" lazy; then
        echo "Error: Could not detach stale mount '$path'." >&2
        echo "Hint: try 'fusermount3 -uz $path' or 'sudo umount -l $path'." >&2
        exit 1
    fi
}

unmount_dir() {
    local target="$1"

    if is_stale_mount "$target"; then
        cleanup_stale_mount "$target"
        echo "Successfully unmounted $target."
        return
    fi

    if ! is_mounted "$target"; then
        if [ ! -d "$target" ]; then
            echo "Error: Directory '$target' does not exist." >&2
            exit 1
        fi
        echo "Notice: '$target' is not currently a mountpoint."
        return
    fi

    echo "Unmounting $target..."
    if ! fuse_unmount "$target"; then
        echo "Error: Could not unmount '$target' (see message above)." >&2
        echo "Hint: if it is busy, close programs using it (check: fuser -vm $target)" >&2
        echo "      or detach it lazily with 'fusermount3 -uz $target'." >&2
        exit 1
    fi
    echo "Successfully unmounted $target."
}

# Mounts REMOTE_SPEC onto LOCAL_MOUNT, cleaning up a stale mount first.
mount_dir() {
    if ! command -v sshfs >/dev/null 2>&1; then
        echo "Error: 'sshfs' is not installed or not in PATH." >&2
        echo "Hint: install it with your package manager (e.g. sudo apt install sshfs)." >&2
        exit 1
    fi

    if is_stale_mount "$LOCAL_MOUNT"; then
        cleanup_stale_mount "$LOCAL_MOUNT"
    elif is_mounted "$LOCAL_MOUNT"; then
        echo "Notice: '$LOCAL_MOUNT' is already mounted."
        return
    fi

    if ! mkdir -p -- "$LOCAL_MOUNT"; then
        echo "Error: Could not create mount directory '$LOCAL_MOUNT'." >&2
        exit 1
    fi

    echo "Mounting $REMOTE_HOST ($DISPLAY_DIR) to $LOCAL_MOUNT..."
    local sshfs_status=0
    sshfs "$REMOTE_SPEC" "$LOCAL_MOUNT" "${SSHFS_OPTS[@]}" || sshfs_status=$?

    if [[ $sshfs_status -ne 0 ]]; then
        echo "Error: sshfs could not mount $REMOTE_SPEC (exit $sshfs_status)." >&2
        echo "Hint: run 'ssh $REMOTE_HOST true' to see the underlying SSH error," >&2
        echo "      and check that the remote directory exists." >&2
        exit "$sshfs_status"
    fi

    if ! is_mounted "$LOCAL_MOUNT"; then
        echo "Error: sshfs exited successfully but '$LOCAL_MOUNT' is not mounted." >&2
        exit 1
    fi
    echo "Successfully mounted to $LOCAL_MOUNT"
}

# Sets REMOTE_HOST, REMOTE_SPEC, DISPLAY_DIR and LOCAL_MOUNT from the
# positional mount arguments, rejecting malformed input before touching disk.
parse_mount_args() {
    local arg
    for arg in "$@"; do
        if [[ "$arg" == -* ]]; then
            usage_error "Unknown option '$arg'."
        fi
    done

    if [[ $# -lt 2 ]]; then
        usage_error "Missing required arguments."
    fi
    if [[ $# -gt 3 ]]; then
        usage_error "Too many arguments ($#); expected at most 3."
    fi

    REMOTE_HOST="$1"
    local remote_dir=""
    LOCAL_MOUNT="${!#}"

    # Accept sshfs-style "host:dir" in the two-argument form. Bracketed IPv6
    # literals ("[::1]") are left alone.
    if [[ "$REMOTE_HOST" == *:* && "$REMOTE_HOST" != \[* ]]; then
        if [[ $# -eq 3 ]]; then
            usage_error "Remote directory given twice ('$1' and '$2')."
        fi
        remote_dir="${REMOTE_HOST#*:}"
        REMOTE_HOST="${REMOTE_HOST%%:*}"
    elif [[ $# -eq 3 ]]; then
        remote_dir="$2"
    fi

    if [[ -z "$REMOTE_HOST" ]]; then
        usage_error "Remote host is empty."
    fi
    if [[ -z "$LOCAL_MOUNT" ]]; then
        usage_error "Local mount directory is empty."
    fi

    REMOTE_SPEC="${REMOTE_HOST}:${remote_dir}"
    DISPLAY_DIR="${remote_dir:-remote \$HOME}"
}

main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 1
    fi

    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -u|--unmount)
            if [[ $# -lt 2 ]]; then
                usage_error "Missing local mount directory to unmount."
            fi
            if [[ $# -gt 2 ]]; then
                usage_error "Too many arguments for $1; expected one mount directory."
            fi
            unmount_dir "$2"
            exit 0
            ;;
    esac

    parse_mount_args "$@"
    mount_dir
}

main "$@"
