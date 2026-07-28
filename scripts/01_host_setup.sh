#!/bin/sh
# Configure the FreeBSD host trust foundation and vm-bhyve datastore.
set -eu

VM_DATASET="${VM_DATASET:-zroot/vm}"
MGMT_GROUP="${MGMT_GROUP:-wheel}"
MGMT_USER="${MGMT_USER:-admin}"
EXT_IF="${EXT_IF:-igb0}"
MGMT_IF="${MGMT_IF:-vlan10}"
LAN_IF="${LAN_IF:-bridge0}"
MGMT_ADDR="${MGMT_ADDR:-10.0.10.2}"
MGMT_VLAN="${MGMT_VLAN:-10}"
LAN_ADDR="${LAN_ADDR:-10.0.20.1}"
SSH_ADMIN_KEY_FILE="${SSH_ADMIN_KEY_FILE:-}"
SSH_ADMIN_AUTHORIZED_KEY="${SSH_ADMIN_AUTHORIZED_KEY:-}"
SSH_INCLUDE="/etc/ssh/sshd_config.d/99-hardening.conf"

. "$(dirname "$0")/lib.sh"

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

require_root
require_commands zfs pw

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
pool_name=$(echo "${VM_DATASET}" | cut -d/ -f1)
if command -v zpool >/dev/null 2>&1 && zpool list "${pool_name}" >/dev/null 2>&1; then
    if ! zfs list -H -o name "${VM_DATASET}" >/dev/null 2>&1; then
        zfs create -p "${VM_DATASET}"
    fi
    mp=$(zfs get -H -o value mountpoint "${VM_DATASET}" 2>/dev/null || echo "")
    if [ "$mp" = "none" ] || [ "$mp" = "legacy" ] || [ -z "$mp" ]; then
        zfs set mountpoint=/${VM_DATASET} "${VM_DATASET}" 2>/dev/null || true
    fi
    zfs mount "${VM_DATASET}" 2>/dev/null || true
    zfs set compression=lz4 "${VM_DATASET}" 2>/dev/null || true
    zfs set atime=off "${VM_DATASET}" 2>/dev/null || true
    if ! zfs set xattr=sa "${VM_DATASET}" 2>/dev/null; then
        zfs set xattr=on "${VM_DATASET}" 2>/dev/null || true
    fi
    zfs set primarycache=metadata "${VM_DATASET}" 2>/dev/null || true
    zfs set sync=standard "${VM_DATASET}" 2>/dev/null || true
else
    echo "[!] ZFS pool ${pool_name} not found; skipping ZFS dataset configuration"
fi

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

echo "[*] Configuring management interface ${MGMT_IF} and bridge ${LAN_IF}"
if command -v kldload >/dev/null 2>&1; then
    kldload if_vlan 2>/dev/null || true
fi

if command -v ifconfig >/dev/null 2>&1; then
    if [ -n "${EXT_IF}" ] && ifconfig "${EXT_IF}" >/dev/null 2>&1; then
        ifconfig "${EXT_IF}" up || true
    fi
    if ! ifconfig "${MGMT_IF}" >/dev/null 2>&1; then
        echo "[*] Creating ${MGMT_IF} on ${EXT_IF} (VLAN ${MGMT_VLAN})"
        ifconfig "${MGMT_IF}" create vlan "${MGMT_VLAN}" vlandev "${EXT_IF}" inet "${MGMT_ADDR}/24" mtu 1496 up || true
    fi
    if ! ifconfig "${LAN_IF}" >/dev/null 2>&1; then
        echo "[*] Creating ${LAN_IF}"
        ifconfig "${LAN_IF}" create inet "${LAN_ADDR}/24" mtu 1496 up || true
    fi
fi

if command -v sysrc >/dev/null 2>&1; then
    cloned=$(sysrc -n cloned_interfaces 2>/dev/null || true)
    for iface in "${MGMT_IF}" "${LAN_IF}"; do
        case " ${cloned} " in
            *" ${iface} "*) ;;
            *)
                sysrc cloned_interfaces+="${iface}" >/dev/null 2>&1 || true
                cloned="${cloned} ${iface}"
                ;;
        esac
    done
    sysrc "ifconfig_${MGMT_IF}=inet ${MGMT_ADDR}/24 vlan ${MGMT_VLAN} vlandev ${EXT_IF} mtu 1496" >/dev/null 2>&1 || true
    sysrc "ifconfig_${LAN_IF}=inet ${LAN_ADDR}/24 mtu 1496 up" >/dev/null 2>&1 || true
    sysrc gateway_enable=YES >/dev/null
fi

sysctl net.inet.ip.forwarding=1 >/dev/null

echo "[+] Host setup complete"
echo "[+] SSH login: ssh -i <private-key> ${MGMT_USER}@<management-address>"
