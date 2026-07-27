#!/bin/sh
set -eu

PGDATABASE="${PGDATABASE:-inventory}"
PGUSER="${PGUSER:-postgres}"
KEA_CA_URL="${KEA_CA_URL:-http://127.0.0.1:8000/}"

[ "$#" -eq 1 ] || {
    echo "Usage: $0 <vm_name>" >&2
    exit 64
}

VM_NAME=$1
case "$VM_NAME" in
    *[!A-Za-z0-9._-]*|'') echo "ERROR: invalid VM name" >&2; exit 1 ;;
esac

sql_name=$(printf "%s" "$VM_NAME" | sed "s/'/''/g")
row=$(psql -X -v ON_ERROR_STOP=1 -qAt -F '|' <<SQL
SELECT v.mac_address, v.ip_address, v.pool_id, p.kea_subnet_id
  FROM vms v
  JOIN ipam_pools p ON p.id = v.pool_id
 WHERE v.name = '${sql_name}'
   AND v.status <> 'archived';
SQL
)

[ -n "$row" ] || {
    echo "ERROR: VM is not present in active inventory" >&2
    exit 1
}

IFS='|' read -r MAC_ADDRESS IP_ADDRESS POOL_ID KEA_SUBNET_ID <<EOF
$row
EOF

payload=$(jq -n \
    --arg mac "$MAC_ADDRESS" \
    --argjson subnet_id "$KEA_SUBNET_ID" \
    '{command:"reservation-del",service:["dhcp4"],arguments:{subnet-id:$subnet_id,"identifier-type":"hw-address","identifier":$mac}}')
response=$(curl -fsS -H 'Content-Type: application/json' -d "$payload" "$KEA_CA_URL")
result=$(printf '%s' "$response" | jq -er '.[0].result')
[ "$result" -eq 0 ] || {
    echo "ERROR: Kea rejected reservation removal: $response" >&2
    exit 1
}

vm stop "$VM_NAME" >/dev/null 2>&1 || true
vm destroy -f "$VM_NAME"

psql -X -v ON_ERROR_STOP=1 -qAt <<SQL >/dev/null
BEGIN;
UPDATE vms
   SET status = 'archived'
 WHERE name = '${sql_name}';
UPDATE ipam_leases
   SET released_at = CURRENT_TIMESTAMP
 WHERE pool_id = ${POOL_ID}
   AND ip_address = '${IP_ADDRESS}'::inet;
COMMIT;
SQL

echo "[+] ${VM_NAME} removed and ${IP_ADDRESS} released"
