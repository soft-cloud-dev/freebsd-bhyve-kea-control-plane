#!/bin/sh
# Common functions for control plane scripts

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "run as root"
}

require_commands() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "missing command: $cmd"
    done
}

sql_literal() {
    printf '%s' "$1" | sed "s/'/''/g"
}

kea_request() {
    local payload="$1"
    local user="${KEA_API_USER:-}"
    local password="${KEA_API_PASSWORD:-}"
    local url="${KEA_CA_URL:-http://127.0.0.1:8000/}"
    
    [ -n "$user" ] || die "KEA_API_USER is not set for kea_request"
    [ -n "$password" ] || die "KEA_API_PASSWORD is not set for kea_request"
    
    curl -fsS \
        --user "${user}:${password}" \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "$url"
}

container_is_running() {
    name="$1"
    if command -v jls >/dev/null 2>&1; then
        jls -j "$name" >/dev/null 2>&1 || jls 2>/dev/null | awk -v name="$name" '$3 == name || $1 == name { found=1 } END { exit !found }'
    elif command -v container >/dev/null 2>&1; then
        container list 2>/dev/null | awk -v name="$name" '$1 == name || $2 == name { found=1 } END { exit !found }'
    else
        return 1
    fi
}

container_exec() {
    name="$1"
    shift
    if command -v jexec >/dev/null 2>&1; then
        jexec "$name" "$@"
    elif command -v container >/dev/null 2>&1; then
        container exec "$name" "$@"
    else
        die "No container or FreeBSD jail engine available"
    fi
}


