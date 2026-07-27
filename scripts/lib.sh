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
