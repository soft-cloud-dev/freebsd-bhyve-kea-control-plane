#!/bin/sh
set -eu

VM_DATASET="${VM_DATASET:-zroot/vm}"
VM_ROOT="${VM_ROOT:-}"

[ "$#" -eq 1 ] || {
    echo "Usage: $0 <vm_name>" >&2
    exit 64
}

. "$(dirname "$0")/lib.sh"
require_root
require_commands vm sysrc zfs mktemp cp

VM_NAME=$1
case "$VM_NAME" in
    *[!A-Za-z0-9._-]*|'') die "invalid VM name" ;;
esac

if [ -z "$VM_ROOT" ]; then
    VM_ROOT=$(zfs get -H -o value mountpoint "$VM_DATASET")
    case "$VM_ROOT" in
        ''|none|legacy) die "set VM_ROOT; ${VM_DATASET} has mountpoint ${VM_ROOT:-unset}" ;;
    esac
fi

VM_CONFIG="${VM_ROOT%/}/${VM_NAME}/${VM_NAME}.conf"
[ -f "$VM_CONFIG" ] || die "vm-bhyve configuration not found: $VM_CONFIG"
vm info "$VM_NAME" >/dev/null 2>&1 || die "vm-bhyve guest not found: $VM_NAME"

current_loader=$(sysrc -f "$VM_CONFIG" -n loader 2>/dev/null || true)
case "$current_loader" in
    bhyveload)
        echo "[+] ${VM_NAME} already uses bhyveload"
        exit 0
        ;;
    uefi|uefi-csm) ;;
    *) die "refusing to replace unexpected loader '${current_loader:-unset}'" ;;
esac

vm_is_running() {
    vm list | awk -v name="$VM_NAME" '
        NR > 1 && $1 == name && $0 ~ /Running/ { found=1 }
        END { exit !found }
    '
}

was_running=0
if vm_is_running; then
    was_running=1
fi

config_backup=$(mktemp "${TMPDIR:-/tmp}/${VM_NAME}.conf.XXXXXX")
cp -p "$VM_CONFIG" "$config_backup"
config_changed=0

rollback() {
    status=$?
    trap - EXIT INT TERM HUP

    if [ "$status" -ne 0 ]; then
        echo "[!] Loader migration failed; restoring ${current_loader}" >&2
        if [ "$config_changed" -eq 1 ]; then
            cp -p "$config_backup" "$VM_CONFIG" || true
        fi
        if [ "$was_running" -eq 1 ] && ! vm_is_running; then
            vm start "$VM_NAME" >/dev/null 2>&1 || true
        fi
    fi

    rm -f "$config_backup"
    exit "$status"
}
trap rollback EXIT INT TERM HUP

if [ "$was_running" -eq 1 ]; then
    echo "[1/3] Stopping ${VM_NAME}"
    vm stop "$VM_NAME"
fi

echo "[2/3] Changing loader from ${current_loader} to bhyveload"
sysrc -f "$VM_CONFIG" loader=bhyveload >/dev/null
config_changed=1
[ "$(sysrc -f "$VM_CONFIG" -n loader)" = "bhyveload" ] || die "loader change did not persist"

if [ "$was_running" -eq 1 ]; then
    echo "[3/3] Starting ${VM_NAME}"
    vm start "$VM_NAME"
    vm_is_running || die "${VM_NAME} did not remain running with bhyveload"
else
    echo "[3/3] Leaving ${VM_NAME} stopped"
fi

trap - EXIT INT TERM HUP
rm -f "$config_backup"
echo "[+] ${VM_NAME} now uses bhyveload"
