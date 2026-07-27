#!/bin/sh
# Configure the FreeBSD host trust foundation and vm-bhyve datastore.
set -eu

VM_DATASET="${VM_DATASET:-zroot/vm}"
MGMT_GROUP="${MGMT_GROUP:-wheel}"
SSH_INCLUDE="/etc/ssh/sshd_config.d/99-hardening.conf"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v zfs >/dev/null 2>&1 || die "ZFS is required"

echo "[*] Configuring ZFS dataset ${VM_DATASET}"
if ! zfs list -H -o name "${VM_DATASET}" >/dev/null 2>&1; then
    zfs create -p "${VM_DATASET}"
fi
zfs set compression=lz4 "${VM_DATASET}"
zfs set atime=off "${VM_DATASET}"
if ! zfs set xattr=sa "${VM_DATASET}" 2>/dev/null; then
    echo "[!] xattr=sa is unsupported; falling back to xattr=on"
    zfs set xattr=on "${VM_DATASET}"
fi
zfs set primarycache=metadata "${VM_DATASET}"
zfs set sync=standard "${VM_DATASET}"

# volblocksize is a zvol creation-time property. Configure it in the
# vm-bhyve template or create the zvol explicitly; it is not inherited.

echo "[*] Hardening OpenSSH"
install -d -m 0755 /etc/ssh/sshd_config.d
cat > "${SSH_INCLUDE}" <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
AllowGroups ${MGMT_GROUP}
UsePAM yes
X11Forwarding no
# TrustedUserCAKeys /etc/ssh/ca.pub
EOF

if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*' /etc/ssh/sshd_config; then
    tmp=$(mktemp)
    {
        echo 'Include /etc/ssh/sshd_config.d/*'
        cat /etc/ssh/sshd_config
    } > "${tmp}"
    install -m 0600 "${tmp}" /etc/ssh/sshd_config
    rm -f "${tmp}"
fi

sshd -t
sysrc sshd_enable=YES >/dev/null

echo "[*] Configuring blacklistd"
sysrc blacklistd_enable=YES >/dev/null
cat > /etc/blacklistd.conf <<'EOF'
# location type proto owner name nfail disable
[local]
ssh stream * * * 3 24h
[remote]
EOF

service blacklistd restart 2>/dev/null || service blacklistd start
service sshd reload

echo "[+] Host setup complete"
