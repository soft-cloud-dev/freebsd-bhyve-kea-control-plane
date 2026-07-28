#!/bin/sh
set -eu

PGDATABASE="${PGDATABASE:-inventory}"
PGUSER="${PGUSER:-postgres}"
KEA_CA_URL="${KEA_CA_URL:-http://127.0.0.1:8000/}"
KEA_API_USER_FILE="${KEA_API_USER_FILE:-/usr/local/etc/kea/kea-api-user}"
KEA_API_PASSWORD_FILE="${KEA_API_PASSWORD_FILE:-/usr/local/etc/kea/kea-api-password}"

[ "$#" -eq 1 ] || {
    echo "Usage: $0 <vm_name>" >&2
    exit 64
}

. "$(dirname "$0")/lib.sh"
require_root

[ -r "$KEA_API_USER_FILE" ] || { echo "ERROR: missing Kea API user file" >&2; exit 1; }
[ -r "$KEA_API_PASSWORD_FILE" ] || { echo "ERROR: missing Kea API password file" >&2; exit 1; }
KEA_API_USER=$(sed -n '1p' "$KEA_API_USER_FILE")
KEA_API_PASSWORD=$(sed -n '1p' "$KEA_API_PASSWORD_FILE")

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
delete_response=$(kea_request "$delete_payload")
delete_result=$(printf '%s' "$delete_response" | jq -er '.[0].result')
[ "$delete_result" -eq 0 ] || {
    echo "ERROR: Kea reservation-del failed during rollback: $delete_response" >&2
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
