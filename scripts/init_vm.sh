#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"
require_root

VM_DIR="${VM_DIR:-zfs:zroot/vm}"
VM_DATASET="${VM_DATASET:-zroot/vm}"
LAN_IF="${LAN_IF:-bridge0}"

sysrc vm_enable=YES vm_dir="${VM_DIR}" >/dev/null
vm init

vm_root=$(zfs get -H -o value mountpoint "${VM_DATASET}")
case "$vm_root" in
    ''|none|legacy) die "invalid VM dataset mountpoint" ;;
esac

install -d -m 0755 "$vm_root/.templates"
install -m 0644 templates/vm-bhyve.conf "$vm_root/.templates/freebsd.conf"

if ! vm switch list | awk 'NR > 1 {print $1}' | grep -qx public; then
    vm switch create -t manual -b "${LAN_IF}" public
fi
