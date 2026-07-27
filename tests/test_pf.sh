#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONF="${PF_CONF:-${ROOT}/config/pf.conf}"

command -v pfctl >/dev/null 2>&1 || {
    echo "SKIP: pfctl is available only on FreeBSD" >&2
    exit 0
}

pfctl -nf "${CONF}"
echo "PASS: ${CONF}"
