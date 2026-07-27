#!/bin/sh
set -eu

PGDATABASE="${PGDATABASE:-inventory}"
PGUSER="${PGUSER:-postgres}"
KEA_CA_URL="${KEA_CA_URL:-http://127.0.0.1:8000/}"
VM_OWNER="${VM_OWNER:-admin}"
IPAM_POOL="${IPAM_POOL:-vm-lan}"
VM_DATASET="${VM_DATASET:-zroot/vm}"

usage() {
    echo "Usage: $0 <vm_name> <template>" >&2
    exit 64
}

die() {
    echo "ERROR: $*" >&2
    exit 1
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

for command in vm psql curl jq; do
    command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

created_vm=0
inserted_vm=0
kea_reserved=0
MAC_ADDRESS=""
IP_ADDRESS=""
POOL_ID=""
KEA_SUBNET_ID=""
VLAN=""

sql_literal() {
    printf "%s" "$1" | sed "s/'/''/g"
}

rollback() {
    status=$?
    trap - EXIT INT TERM HUP

    if [ "$status" -ne 0 ]; then
        echo "[!] Provisioning failed; rolling back" >&2

        if [ "$kea_reserved" -eq 1 ]; then
            payload=$(jq -n \
                --arg mac "$MAC_ADDRESS" \
                --argjson subnet_id "$KEA_SUBNET_ID" \
                '{command:"reservation-del",service:["dhcp4"],arguments:{subnet-id:$subnet_id,"identifier-type":"hw-address","identifier":$mac}}')
            curl -fsS -H 'Content-Type: application/json' -d "$payload" "$KEA_CA_URL" >/dev/null 2>&1 || true
        fi

        if [ "$inserted_vm" -eq 1 ]; then
            escaped_name=$(sql_literal "$VM_NAME")
            psql -X -v ON_ERROR_STOP=1 -qAt <<SQL >/dev/null 2>&1 || true
BEGIN;
UPDATE ipam_leases
   SET released_at = CURRENT_TIMESTAMP
 WHERE pool_id = ${POOL_ID}
   AND ip_address = '${IP_ADDRESS}'::inet;
DELETE FROM vms WHERE name = '${escaped_name}';
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

echo "[1/6] Creating VM"
vm create -t "$TEMPLATE" "$VM_NAME"
created_vm=1

echo "[2/6] Reading VM MAC address"
MAC_ADDRESS=$(vm info "$VM_NAME" | awk '
    BEGIN { IGNORECASE=1 }
    /mac/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$/) {
                print tolower($i)
                exit
            }
        }
    }
')
[ -n "$MAC_ADDRESS" ] || die "could not determine VM MAC address"

echo "[3/6] Allocating address and recording inventory"
escaped_name=$(sql_literal "$VM_NAME")
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
    RETURNING ip_address, pool_id, vlan
)
SELECT inserted.ip_address, inserted.pool_id, inserted.vlan, pools.kea_subnet_id
  FROM inserted
  JOIN ipam_pools pools ON pools.id = inserted.pool_id;
COMMIT;
SQL
)

IFS='|' read -r IP_ADDRESS POOL_ID VLAN KEA_SUBNET_ID <<EOF
$DB_RESULT
EOF
[ -n "$IP_ADDRESS" ] || die "database did not return an IP address"
inserted_vm=1

echo "[4/6] Adding Kea reservation"
payload=$(jq -n \
    --arg mac "$MAC_ADDRESS" \
    --arg ip "$IP_ADDRESS" \
    --arg hostname "$VM_NAME" \
    --argjson subnet_id "$KEA_SUBNET_ID" \
    '{command:"reservation-add",service:["dhcp4"],arguments:{reservation:{"subnet-id":$subnet_id,"hw-address":$mac,"ip-address":$ip,"hostname":$hostname}}}')
response=$(curl -fsS -H 'Content-Type: application/json' -d "$payload" "$KEA_CA_URL")
result=$(printf '%s' "$response" | jq -er '.[0].result')
[ "$result" -eq 0 ] || die "Kea rejected reservation: $response"
kea_reserved=1

echo "[5/6] Starting VM"
vm start "$VM_NAME"

echo "[6/6] Marking VM running"
psql -X -v ON_ERROR_STOP=1 -qAt <<SQL >/dev/null
UPDATE vms
   SET status = 'running', last_error = NULL
 WHERE name = '${escaped_name}';
SQL

trap - EXIT INT TERM HUP
echo "[+] ${VM_NAME} is running at ${IP_ADDRESS} on VLAN ${VLAN}"
