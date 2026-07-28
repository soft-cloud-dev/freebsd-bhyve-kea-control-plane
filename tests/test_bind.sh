#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NAMED_TEMPLATE="${NAMED_TEMPLATE:-${ROOT}/config/named.conf.in}"
DNS_ADDR="${DNS_ADDR:-10.0.20.1}"
LAN_NET="${LAN_NET:-10.0.20.0/24}"

. "${ROOT}/scripts/lib.sh"

named_tmp=$(mktemp)
trap 'rm -f "$named_tmp"' EXIT HUP INT TERM

sed -e "s|@DNS_ADDR@|${DNS_ADDR}|g" \
    -e "s|@LAN_NET@|${LAN_NET}|g" \
    "$NAMED_TEMPLATE" > "$named_tmp"

grep -Fq "listen-on port 53 {" "$named_tmp"
grep -Fq "${DNS_ADDR};" "$named_tmp"
grep -Fq "${LAN_NET};" "$named_tmp"
grep -Fq "listen-on-v6 {" "$named_tmp"
grep -Fq "allow-query-cache {" "$named_tmp"
grep -Fq "allow-recursion {" "$named_tmp"

if command -v named-checkconf >/dev/null 2>&1; then
    named-checkconf "$named_tmp"
else
    echo "SKIP: named-checkconf is unavailable; static BIND checks passed" >&2
fi

echo "PASS: BIND listens on ${DNS_ADDR} for ${LAN_NET}"
