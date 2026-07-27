#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DHCP4_CONF="${KEA_DHCP4_CONF:-${ROOT}/config/kea-dhcp4.conf}"
KEA_API_URL="${KEA_API_URL:-http://127.0.0.1:8000/}"

if ! command -v kea-dhcp4 >/dev/null 2>&1; then
    echo "SKIP: kea-dhcp4 is not installed" >&2
    exit 0
fi

kea-dhcp4 -t "$DHCP4_CONF"
grep -q '"socket-type"[[:space:]]*:[[:space:]]*"http"' "$DHCP4_CONF"
grep -q '"socket-address"[[:space:]]*:[[:space:]]*"127.0.0.1"' "$DHCP4_CONF"
grep -q '"socket-port"[[:space:]]*:[[:space:]]*8000' "$DHCP4_CONF"

if service kea_dhcp4 status >/dev/null 2>&1; then
    response=$(curl -fsS -H 'Content-Type: application/json' \
        -d '{"command":"status-get"}' "$KEA_API_URL")
    printf '%s' "$response" | jq -e '.[0].result == 0' >/dev/null
else
    echo "SKIP: kea_dhcp4 is not running; API readiness not tested" >&2
fi

echo "PASS: Kea DHCP4 configuration and direct API"
