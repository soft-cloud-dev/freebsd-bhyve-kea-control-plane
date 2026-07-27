#!/bin/sh
# scripts/01_host_setup.sh
set -eu

VM_DATASET="zroot/vm"

echo "[*] Tuning ZFS dataset: ${VM_DATASET}"
zfs create -p "${VM_DATASET}" || true
zfs set compression=lz4 "${VM_DATASET}"
zfs set atime=off "${VM_DATASET}"
zfs set xattr=sa "${VM_DATASET}"             # Modern OpenZFS native SA xattrs
zfs set primarycache=metadata "${VM_DATASET}"
zfs set sync=standard "${VM_DATASET}"
# Note: volblocksize cannot be inherited dynamically for future zvols in the same
# way standard properties are. It MUST be defined at zvol creation time via
# vm-bhyve templates (e.g., `disk0_opts="volblocksize=16k"`).

# (SSH and blacklistd setup remains identical to the previous implementation)
