#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DHCP4_CONF="${KEA_DHCP4_CONF:-${ROOT}/config/kea-dhcp4.conf}"
CA_CONF="${KEA_CA_CONF:-${ROOT}/config/kea-ctrl-agent.conf}"

if ! command -v kea-dhcp4 >/dev/null 2>&1; then
    echo "SKIP: kea-dhcp4 is not installed" >&2
    exit 0
fi
if ! command -v kea-ctrl-agent >/dev/null 2>&1; then
    echo "SKIP: kea-ctrl-agent is not installed" >&2
    exit 0
fi

kea-dhcp4 -t "${DHCP4_CONF}"
kea-ctrl-agent -t "${CA_CONF}"
echo "PASS: Kea configuration"
