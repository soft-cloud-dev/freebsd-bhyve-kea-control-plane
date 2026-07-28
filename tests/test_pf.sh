#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONF="${PF_CONF:-${ROOT}/config/pf.conf}"

. "${ROOT}/scripts/lib.sh"

grep -Eq '^nat on \$ext_if inet from \$lan_net to any -> \(\$ext_if\)$' "$CONF" || \
    die "PF must NAT the VM LAN through the external interface"
grep -Eq '^block in quick on \$lan_if inet from \$lan_net to \$mgmt_net$' "$CONF" || \
    die "PF must isolate the VM LAN from the management network"
grep -Eq '^pass in quick on \$lan_if inet from \$lan_net to any keep state$' "$CONF" || \
    die "PF must permit routed VM LAN traffic"

command -v pfctl >/dev/null 2>&1 || {
    echo "SKIP: pfctl is available only on FreeBSD; static routing checks passed" >&2
    exit 0
}

pfctl -nf "${CONF}"
echo "PASS: ${CONF}"
