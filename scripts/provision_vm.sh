#!/bin/sh
set -eu

PGDATABASE="${PGDATABASE:-inventory}"
PGUSER="${PGUSER:-postgres}"
KEA_CA_URL="${KEA_CA_URL:-http://127.0.0.1:8000/}"
KEA_API_USER_FILE="${KEA_API_USER_FILE:-/usr/local/etc/kea/kea-api-user}"
KEA_API_PASSWORD_FILE="${KEA_API_PASSWORD_FILE:-/usr/local/etc/kea/kea-api-password}"
VM_OWNER="${VM_OWNER:-admin}"
CLOUD_INIT_USER="${CLOUD_INIT_USER:-${VM_OWNER}}"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-}"
SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}"
CLOUD_INIT_EXTRA_FILE="${CLOUD_INIT_EXTRA_FILE:-}"
IPAM_POOL="${IPAM_POOL:-vm-lan}"
VM_DATASET="${VM_DATASET:-zroot/vm}"
VM_ROOT="${VM_ROOT:-}"
FREEBSD_CLOUD_IMAGE_URL="${FREEBSD_CLOUD_IMAGE_URL:-https://download.freebsd.org/releases/VM-IMAGES/14.3-RELEASE/amd64/Latest/FreeBSD-14.3-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz}"
FREEBSD_CLOUD_IMAGE_CACHE="${FREEBSD_CLOUD_IMAGE_CACHE:-/var/cache/control-plane/freebsd-cloud.raw}"

usage() {
    cat >&2 <<EOF
Usage: $0 <vm_name> <template>

Required cloud-init key input:
  SSH_PUBLIC_KEY_FILE=/path/to/id_ed25519.pub
or:
  SSH_AUTHORIZED_KEY='ssh-ed25519 AAAA... comment'

Optional cloud-init extension:
  CLOUD_INIT_EXTRA_FILE=/path/to/profile.yaml
EOF
    exit 64
}

. "$(dirname "$0")/lib.sh"

yaml_single_quote() {
    printf '%s' "$1" | sed "s/'/''/g"
}

resolve_ssh_key() {
    if [ -n "$SSH_PUBLIC_KEY_FILE" ]; then
        [ -r "$SSH_PUBLIC_KEY_FILE" ] || die "SSH public key file is not readable: $SSH_PUBLIC_KEY_FILE"
        awk 'NF { print; exit }' "$SSH_PUBLIC_KEY_FILE"
        return
    fi

    [ -n "$SSH_AUTHORIZED_KEY" ] || die "set SSH_PUBLIC_KEY_FILE or SSH_AUTHORIZED_KEY"
    printf '%s\n' "$SSH_AUTHORIZED_KEY"
}

resolve_vm_root() {
    if [ -n "$VM_ROOT" ]; then
        printf '%s\n' "$VM_ROOT"
        return
    fi

    mountpoint=$(zfs get -H -o value mountpoint "$VM_DATASET")
    case "$mountpoint" in
        ''|none|legacy) die "set VM_ROOT; ${VM_DATASET} has mountpoint ${mountpoint:-unset}" ;;
    esac
    printf '%s\n' "$mountpoint"
}



create_seed_iso() {
    seed_source=$1
    seed_output=$2

    rm -f "$seed_output"
    if command -v makefs >/dev/null 2>&1; then
        makefs -t cd9660 -o rockridge,label=cidata "$seed_output" "$seed_source"
    elif command -v genisoimage >/dev/null 2>&1; then
        (
            cd "$seed_source"
            genisoimage -quiet -output "$seed_output" -volid cidata -joliet -rock meta-data user-data
        )
    else
        die "neither makefs nor genisoimage is available"
    fi
    chmod 0644 "$seed_output"
}

[ "$#" -eq 2 ] || usage
VM_NAME=$1
TEMPLATE=$2

case "$VM_NAME" in
    *[!A-Za-z0-9._-]*|'') die "invalid VM name" ;;
esac
case "$TEMPLATE" in
    *[!A-Za-z0-9._/-]*|'') die "invalid template name" ;;
esac
case "$CLOUD_INIT_USER" in
    ''|*[!a-z0-9_-]*|[0-9-]*) die "invalid cloud-init user: $CLOUD_INIT_USER" ;;
esac

require_root
require_commands vm psql curl jq zfs mktemp sysrc

escaped_name=$(sql_literal "$VM_NAME")
active_vm=$(psql -X -v ON_ERROR_STOP=1 -qAt -F '|' <<SQL
SELECT status, ip_address, mac_address, dataset
  FROM vms
 WHERE name = '${escaped_name}'
   AND status <> 'archived'
 ORDER BY created_at DESC
 LIMIT 1;
SQL
)

guest_exists=0
if vm info "$VM_NAME" >/dev/null 2>&1; then
    guest_exists=1
fi

if [ -n "$active_vm" ]; then
    IFS='|' read -r active_status active_ip active_mac active_dataset <<EOF
$active_vm
EOF
    if [ "$guest_exists" -eq 1 ]; then
        die "VM '${VM_NAME}' already exists in active inventory and vm-bhyve (status=${active_status}, ip=${active_ip}, mac=${active_mac}, dataset=${active_dataset}); use the existing VM, deprovision it explicitly with scripts/deprovision_vm.sh, or choose another name"
    fi
    die "stale active inventory row for VM '${VM_NAME}': PostgreSQL reports status=${active_status}, ip=${active_ip}, mac=${active_mac}, dataset=${active_dataset}, but the vm-bhyve guest is absent; run PGDATABASE=${PGDATABASE} PGUSER=${PGUSER} sh scripts/deprovision_vm.sh '${VM_NAME}' before retrying"
fi

if [ "$guest_exists" -eq 1 ]; then
    die "vm-bhyve guest '${VM_NAME}' already exists without an active inventory row; reconcile or explicitly destroy that guest before provisioning"
fi

[ -r "$KEA_API_USER_FILE" ] || die "missing Kea API user file: $KEA_API_USER_FILE"
[ -r "$KEA_API_PASSWORD_FILE" ] || die "missing Kea API password file: $KEA_API_PASSWORD_FILE"
KEA_API_USER=$(sed -n '1p' "$KEA_API_USER_FILE")
KEA_API_PASSWORD=$(sed -n '1p' "$KEA_API_PASSWORD_FILE")
[ -n "$KEA_API_USER" ] || die "Kea API user is empty"
[ -n "$KEA_API_PASSWORD" ] || die "Kea API password is empty"

SSH_KEY=$(resolve_ssh_key)
case "$SSH_KEY" in
    "ssh-ed25519 "*|"sk-ssh-ed25519@openssh.com "*) ;;
    *) die "cloud-init key must be an Ed25519 OpenSSH public key" ;;
esac

VM_ROOT=$(resolve_vm_root)
VM_DIR="${VM_ROOT%/}/${VM_NAME}"
VM_CONFIG="${VM_DIR}/${VM_NAME}.conf"

created_vm=0
inserted_vm=0
kea_reserved=0
seed_dir=""
MAC_ADDRESS=""
IP_ADDRESS=""
POOL_ID=""
KEA_SUBNET_ID=""
VLAN=""
VM_UUID=""

rollback() {
    status=$?
    trap - EXIT INT TERM HUP

    if [ -n "$seed_dir" ] && [ -d "$seed_dir" ]; then
        rm -rf "$seed_dir"
    fi

    if [ "$status" -ne 0 ]; then
        echo "[!] Provisioning failed; rolling back" >&2

        if [ "$kea_reserved" -eq 1 ]; then
            delete_payload=$(jq -n \
                --arg mac "$MAC_ADDRESS" \
                --argjson subnet_id "$KEA_SUBNET_ID" \
                '{
                    command:"reservation-del",
                    arguments:{
                        "subnet-id":$subnet_id,
                        "identifier-type":"hw-address",
                        identifier:$mac
                    }
                }')
            kea_request "$delete_payload" >/dev/null 2>&1 || true

            if [ -w "/usr/local/etc/kea/kea-dhcp4.conf" ] || [ -f "/usr/local/etc/kea/kea-dhcp4.conf" ]; then
                tmp_conf=$(mktemp)
                jq --arg mac "$MAC_ADDRESS" \
                   --argjson subnet_id "$KEA_SUBNET_ID" '
                   .Dhcp4.subnet4 |= map(
                       if .id == $subnet_id then
                           .reservations = ((.reservations // []) | map(select(.["hw-address"] != $mac)))
                       else
                           .
                       end
                   )
                ' /usr/local/etc/kea/kea-dhcp4.conf > "$tmp_conf" 2>/dev/null && \
                cat "$tmp_conf" > /usr/local/etc/kea/kea-dhcp4.conf 2>/dev/null && \
                rm -f "$tmp_conf"
            fi
        fi

        if [ "$inserted_vm" -eq 1 ]; then
            psql -X -v ON_ERROR_STOP=1 -qAt <<SQL >/dev/null 2>&1 || true
BEGIN;
UPDATE ipam_leases
   SET released_at = CURRENT_TIMESTAMP
 WHERE pool_id = ${POOL_ID}
   AND ip_address = '${IP_ADDRESS}'::inet;
DELETE FROM vms WHERE uuid = '${VM_UUID}'::uuid;
COMMIT;
SQL
        fi

        if [ "$created_vm" -eq 1 ]; then
            vm stop "$VM_NAME" >/dev/null 2>&1 || true
            vm destroy -f "$VM_NAME" >/dev/null 2>&1 || true
        fi
    fi

    exit "$status"
}
trap rollback EXIT INT TERM HUP

echo "[1/7] Creating VM"
vm create -t "$TEMPLATE" "$VM_NAME"
created_vm=1
[ -d "$VM_DIR" ] || die "vm-bhyve guest directory not found: $VM_DIR"
[ -f "$VM_CONFIG" ] || die "vm-bhyve guest configuration not found: $VM_CONFIG"
created_loader=$(sysrc -f "$VM_CONFIG" -n loader 2>/dev/null || true)
if [ "$created_loader" != "bhyveload" ]; then
    echo " - enforcing bhyveload (template selected ${created_loader:-no loader})"
    sysrc -f "$VM_CONFIG" loader=bhyveload >/dev/null
fi
[ "$(sysrc -f "$VM_CONFIG" -n loader)" = "bhyveload" ] || \
    die "could not enforce bhyveload in $VM_CONFIG"

zvol_dev="/dev/zvol/${VM_DATASET}/${VM_NAME}/disk0"
if [ -c "$zvol_dev" ] || [ -b "$zvol_dev" ]; then
    if [ ! -f "$FREEBSD_CLOUD_IMAGE_CACHE" ]; then
        if [ -f "/tmp/freebsd-cloud.raw" ]; then
            FREEBSD_CLOUD_IMAGE_CACHE="/tmp/freebsd-cloud.raw"
        else
            echo " - caching FreeBSD cloud image..."
            mkdir -p "$(dirname "$FREEBSD_CLOUD_IMAGE_CACHE")" 2>/dev/null || true
            tmp_xz="${FREEBSD_CLOUD_IMAGE_CACHE}.xz"
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL -o "$tmp_xz" "$FREEBSD_CLOUD_IMAGE_URL"
            elif command -v fetch >/dev/null 2>&1; then
                fetch -o "$tmp_xz" "$FREEBSD_CLOUD_IMAGE_URL"
            else
                die "neither curl nor fetch is available to download cloud image"
            fi
            unxz -f "$tmp_xz"
        fi
    fi
    echo " - writing FreeBSD cloud image to $zvol_dev"
    dd if="$FREEBSD_CLOUD_IMAGE_CACHE" of="$zvol_dev" bs=1M status=none
fi

echo "[2/7] Reading VM MAC address"
MAC_ADDRESS=$(vm info "$VM_NAME" | awk '
    tolower($0) ~ /mac/ {
        for (i = 1; i <= NF; i++) {
            val = tolower($i)
            sub(/^mac=/, "", val)
            if (val ~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/) {
                print val
                exit
            }
        }
    }
')
[ -n "$MAC_ADDRESS" ] || die "could not determine VM MAC address"

echo "[3/7] Creating cloud-init NoCloud seed"
seed_dir=$(mktemp -d "${TMPDIR:-/tmp}/${VM_NAME}.cloud-init.XXXXXX")
cat > "${seed_dir}/meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

cloud_user=$(yaml_single_quote "$CLOUD_INIT_USER")
cloud_key=$(yaml_single_quote "$SSH_KEY")
cat > "${seed_dir}/user-data" <<EOF
#cloud-config
users:
  - default
  - name: '${cloud_user}'
    lock_passwd: true
    shell: /bin/sh
    ssh_authorized_keys:
      - '${cloud_key}'
EOF

if [ -n "$CLOUD_INIT_EXTRA_FILE" ]; then
    [ -r "$CLOUD_INIT_EXTRA_FILE" ] || \
        die "cloud-init extension is not readable: $CLOUD_INIT_EXTRA_FILE"
    printf '\n' >> "${seed_dir}/user-data"
    cat "$CLOUD_INIT_EXTRA_FILE" >> "${seed_dir}/user-data"
fi

if command -v cloud-init >/dev/null 2>&1; then
    cloud-init schema -c "${seed_dir}/user-data" >/dev/null
fi
create_seed_iso "$seed_dir" "${VM_DIR}/seed.iso"
rm -rf "$seed_dir"
seed_dir=""

echo "[4/7] Allocating address and recording inventory"
escaped_owner=$(sql_literal "$VM_OWNER")
escaped_template=$(sql_literal "$TEMPLATE")
escaped_pool=$(sql_literal "$IPAM_POOL")
escaped_dataset=$(sql_literal "${VM_DATASET}/${VM_NAME}")

DB_RESULT=$(psql -X -v ON_ERROR_STOP=1 -qAt -F '|' <<SQL
BEGIN;
WITH allocation AS (
    SELECT * FROM allocate_ip('${escaped_pool}')
), inserted AS (
    INSERT INTO vms (
        name, owner_name, dataset, mac_address, ip_address,
        pool_id, vlan, template, status
    )
    SELECT
        '${escaped_name}', '${escaped_owner}', '${escaped_dataset}',
        '${MAC_ADDRESS}'::macaddr, allocation.ip_address,
        allocation.pool_id, allocation.vlan, '${escaped_template}', 'provisioning'
    FROM allocation
    RETURNING uuid, ip_address, pool_id, vlan
)
SELECT inserted.uuid, inserted.ip_address, inserted.pool_id, inserted.vlan, pools.kea_subnet_id
  FROM inserted
  JOIN ipam_pools pools ON pools.id = inserted.pool_id;
COMMIT;
SQL
)

IFS='|' read -r VM_UUID IP_ADDRESS POOL_ID VLAN KEA_SUBNET_ID <<EOF
$DB_RESULT
EOF
[ -n "$VM_UUID" ] || die "database did not return a VM UUID"
[ -n "$IP_ADDRESS" ] || die "database did not return an IP address"
inserted_vm=1

echo "[5/7] Adding Kea reservation"
add_payload=$(jq -n \
    --arg mac "$MAC_ADDRESS" \
    --arg ip "$IP_ADDRESS" \
    --arg hostname "$VM_NAME" \
    --argjson subnet_id "$KEA_SUBNET_ID" \
    '{
        command:"reservation-add",
        arguments:{
            reservation:{
                "subnet-id":$subnet_id,
                "hw-address":$mac,
                "ip-address":$ip,
                hostname:$hostname
            }
        }
    }')
add_response=$(kea_request "$add_payload")
add_result=$(printf '%s' "$add_response" | jq -er '.[0].result')
[ "$add_result" -eq 0 ] || die "Kea reservation-add failed: $add_response"
kea_reserved=1

if [ -w "/usr/local/etc/kea/kea-dhcp4.conf" ] || [ -f "/usr/local/etc/kea/kea-dhcp4.conf" ]; then
    tmp_conf=$(mktemp)
    jq --arg mac "$MAC_ADDRESS" \
       --arg ip "$IP_ADDRESS" \
       --arg hostname "$VM_NAME" \
       --argjson subnet_id "$KEA_SUBNET_ID" '
       .Dhcp4.subnet4 |= map(
           if .id == $subnet_id then
               .reservations = (.reservations // []) + [{"hw-address": $mac, "ip-address": $ip, "hostname": $hostname}]
           else
               .
           end
       )
    ' /usr/local/etc/kea/kea-dhcp4.conf > "$tmp_conf" && \
    cat "$tmp_conf" > /usr/local/etc/kea/kea-dhcp4.conf && \
    rm -f "$tmp_conf"
fi

echo "[6/7] Starting VM"
vm start "$VM_NAME"

echo "[7/7] Marking VM running"
FINALIZED_VM=$(psql -X -v ON_ERROR_STOP=1 -qAt <<SQL
UPDATE vms
   SET status = 'running', last_error = NULL
 WHERE uuid = '${VM_UUID}'::uuid
   AND status = 'provisioning'
RETURNING uuid;
SQL
)
[ "$FINALIZED_VM" = "$VM_UUID" ] || die "new inventory row ${VM_UUID} was not in provisioning state"

trap - EXIT INT TERM HUP
echo "[+] ${VM_NAME} is running at ${IP_ADDRESS} on VLAN ${VLAN}"
