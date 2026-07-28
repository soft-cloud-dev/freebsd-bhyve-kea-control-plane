#!/bin/sh
set -eu

[ "$#" -eq 1 ] || {
    echo "Usage: $0 <vm_name>" >&2
    exit 64
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROFILE_FILE="${FREEBSD_JAIL_PROFILE_FILE:-${SCRIPT_DIR}/../config/cloud-init/freebsd-jail-node.yaml}"

[ -r "$PROFILE_FILE" ] || {
    echo "ERROR: FreeBSD jail-node cloud-init profile is not readable: $PROFILE_FILE" >&2
    exit 1
}

CLOUD_INIT_EXTRA_FILE="$PROFILE_FILE"
export CLOUD_INIT_EXTRA_FILE
exec sh "${SCRIPT_DIR}/provision_vm.sh" "$1" freebsd
