#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"
require_root

VM_DATASET="${VM_DATASET:-zroot/vm}"
LAN_IF="${LAN_IF:-bridge0}"
LAN_MTU="${LAN_MTU:-1496}"

case "$LAN_MTU" in
    ''|*[!0-9]*) die "invalid LAN MTU: $LAN_MTU" ;;
esac
[ "$LAN_MTU" -ge 1280 ] && [ "$LAN_MTU" -le 9000 ] || \
    die "LAN MTU must be between 1280 and 9000"

ifconfig "$LAN_IF" >/dev/null 2>&1 || die "missing vm-bhyve bridge: $LAN_IF"
ifconfig "$LAN_IF" mtu "$LAN_MTU" up || \
    die "could not enforce MTU $LAN_MTU on $LAN_IF"

if command -v zfs >/dev/null 2>&1 && zfs list -H -o name "${VM_DATASET}" >/dev/null 2>&1; then
    vm_root=$(zfs get -H -o value mountpoint "${VM_DATASET}" 2>/dev/null || echo "")
    if [ "$vm_root" = "none" ] || [ "$vm_root" = "legacy" ] || [ -z "$vm_root" ] || [ ! -d "$vm_root" ]; then
        zfs set mountpoint=/${VM_DATASET} "${VM_DATASET}" 2>/dev/null || true
        zfs mount "${VM_DATASET}" 2>/dev/null || true
        vm_root=$(zfs get -H -o value mountpoint "${VM_DATASET}" 2>/dev/null || echo "/${VM_DATASET}")
    fi
    VM_DIR="zfs:${VM_DATASET}"
else
    vm_root="/usr/local/vm"
    install -d -m 0755 "$vm_root"
    VM_DIR="dir:${vm_root}"
fi

sysrc vm_enable=YES vm_dir="${VM_DIR}" >/dev/null
vm init

install -d -m 0755 "$vm_root/.templates"
install -m 0644 templates/vm-bhyve.conf "$vm_root/.templates/freebsd.conf"

if ! vm switch list | awk 'NR > 1 {print $1}' | grep -qx public; then
    vm switch create -t manual -b "${LAN_IF}" public
fi
