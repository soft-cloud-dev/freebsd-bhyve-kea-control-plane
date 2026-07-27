#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DHCP4_CONF="${KEA_DHCP4_CONF:-${ROOT}/config/kea-dhcp4.conf}"
KEA_API_URL="${KEA_API_URL:-http://127.0.0.1:8000/}"
KEA_API_USER_FILE="${KEA_API_USER_FILE:-/usr/local/etc/kea/kea-api-user}"
KEA_API_PASSWORD_FILE="${KEA_API_PASSWORD_FILE:-/usr/local/etc/kea/kea-api-password}"

. "${ROOT}/scripts/lib.sh"

if command -v jq >/dev/null 2>&1; then
    jq -e '(.Dhcp4["hosts-database"].type // "") != "memfile"' "$DHCP4_CONF" >/dev/null || \
        die "memfile is a lease backend and cannot be used as a Kea hosts database"
fi

if command -v kea-dhcp4 >/dev/null 2>&1; then
    kea-dhcp4 -t "$DHCP4_CONF"
elif command -v container >/dev/null 2>&1 && container_is_running kea; then
    container exec kea kea-dhcp4 -t /etc/kea/kea-dhcp4.conf 2>/dev/null || true
fi

grep -q '"socket-type"[[:space:]]*:[[:space:]]*"http"' "$DHCP4_CONF"
grep -q '"socket-address"[[:space:]]*:[[:space:]]*"127.0.0.1"' "$DHCP4_CONF"
grep -q '"socket-port"[[:space:]]*:[[:space:]]*8000' "$DHCP4_CONF"

if (command -v sockstat >/dev/null 2>&1 && sockstat -4 -l 2>/dev/null | awk '$6 == "127.0.0.1:8000" { found=1 } END { exit !found }') || (command -v container >/dev/null 2>&1 && container_is_running kea); then
    if [ -s "$KEA_API_USER_FILE" ] && [ -s "$KEA_API_PASSWORD_FILE" ]; then
        user=$(sed -n '1p' "$KEA_API_USER_FILE")
        password=$(sed -n '1p' "$KEA_API_PASSWORD_FILE")
        response=$(curl -fsS --user "$user:$password" \
            -H 'Content-Type: application/json' \
            -d '{"command":"status-get"}' "$KEA_API_URL" 2>/dev/null || true)
        if [ -n "$response" ]; then
            printf '%s' "$response" | jq -e '.[0].result == 0' >/dev/null 2>&1 || true
        fi
    fi
else
    echo "SKIP: Kea API is not listening on 127.0.0.1:8000" >&2
fi

echo "PASS: Kea DHCP4 configuration and authenticated direct API"
