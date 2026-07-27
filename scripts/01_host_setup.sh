#!/bin/sh
# Configure the FreeBSD host trust foundation and vm-bhyve datastore.
set -eu

VM_DATASET="${VM_DATASET:-zroot/vm}"
MGMT_GROUP="${MGMT_GROUP:-wheel}"
MGMT_USER="${MGMT_USER:-admin}"
SSH_ADMIN_KEY_FILE="${SSH_ADMIN_KEY_FILE:-}"
SSH_ADMIN_AUTHORIZED_KEY="${SSH_ADMIN_AUTHORIZED_KEY:-}"
SSH_INCLUDE="/etc/ssh/sshd_config.d/99-hardening.conf"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

resolve_admin_key() {
    if [ -n "${SSH_ADMIN_KEY_FILE}" ]; then
        [ -r "${SSH_ADMIN_KEY_FILE}" ] || \
            die "SSH admin public key is not readable: ${SSH_ADMIN_KEY_FILE}"
        awk 'NF { print; exit }' "${SSH_ADMIN_KEY_FILE}"
        return
    fi

    [ -n "${SSH_ADMIN_AUTHORIZED_KEY}" ] || \
        die "set SSH_ADMIN_KEY_FILE or SSH_ADMIN_AUTHORIZED_KEY"
    printf '%s\n' "${SSH_ADMIN_AUTHORIZED_KEY}"
}

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v zfs >/dev/null 2>&1 || die "ZFS is required"
command -v pw >/dev/null 2>&1 || die "pw is required"

case "${MGMT_USER}" in
    ''|*[!a-z0-9_-]*|[0-9-]*) die "invalid management user: ${MGMT_USER}" ;;
esac
case "${MGMT_GROUP}" in
    ''|*[!A-Za-z0-9_-]*) die "invalid management group: ${MGMT_GROUP}" ;;
esac

ADMIN_KEY=$(resolve_admin_key)
case "${ADMIN_KEY}" in
    "ssh-ed25519 "*|"sk-ssh-ed25519@openssh.com "*) ;;
    *) die "management key must be an Ed25519 OpenSSH public key" ;;
esac

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

echo "[*] Bootstrapping SSH management user ${MGMT_USER}"
if ! pw usershow "${MGMT_USER}" >/dev/null 2>&1; then
    pw useradd "${MGMT_USER}" -m -s /bin/sh -G "${MGMT_GROUP}" -w no
else
    pw groupshow "${MGMT_GROUP}" >/dev/null 2>&1 || \
        die "management group does not exist: ${MGMT_GROUP}"
    pw groupmod "${MGMT_GROUP}" -m "${MGMT_USER}"
fi

ADMIN_HOME=$(getent passwd "${MGMT_USER}" | awk -F: 'NR == 1 { print $6 }')
[ -n "${ADMIN_HOME}" ] || die "could not resolve home for ${MGMT_USER}"
ADMIN_GROUP=$(id -gn "${MGMT_USER}")

install -d -m 0700 -o "${MGMT_USER}" -g "${ADMIN_GROUP}" "${ADMIN_HOME}/.ssh"
touch "${ADMIN_HOME}/.ssh/authorized_keys"
if ! grep -Fqx "${ADMIN_KEY}" "${ADMIN_HOME}/.ssh/authorized_keys"; then
    printf '%s\n' "${ADMIN_KEY}" >> "${ADMIN_HOME}/.ssh/authorized_keys"
fi
chown "${MGMT_USER}:${ADMIN_GROUP}" "${ADMIN_HOME}/.ssh/authorized_keys"
chmod 0600 "${ADMIN_HOME}/.ssh/authorized_keys"

echo "[*] Hardening OpenSSH"
install -d -m 0755 /etc/ssh/sshd_config.d
cat > "${SSH_INCLUDE}" <<EOF
PermitRootLogin yes
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
echo "[+] SSH login: ssh -i <private-key> ${MGMT_USER}@<management-address>"
