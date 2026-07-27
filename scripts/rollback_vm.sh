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

cfg_response=$(kea_request '{"command":"config-get"}')
cfg_result=$(printf '%s' "$cfg_response" | jq -er '.[0].result')
if [ "$cfg_result" -eq 0 ]; then
    new_cfg=$(printf '%s' "$cfg_response" | jq --arg mac "$MAC_ADDRESS" \
        '.[0].arguments.Dhcp4.subnet4 |= map(.reservations |= ((. // []) | map(select(type == "object" and (."hw-address" // "") != $mac))))')
    set_payload=$(printf '%s' "$new_cfg" | jq '{command:"config-set",arguments:(.[0].arguments | del(.hash))}')
    set_response=$(kea_request "$(printf '%s' "$set_payload")")
    set_result=$(printf '%s' "$set_response" | jq -er '.[0].result')
    [ "$set_result" -eq 0 ] || {
        echo "ERROR: Kea config-set failed during rollback: $set_response" >&2
        exit 1
    }
    kea_request '{"command":"config-write"}' >/dev/null 2>&1 || true
else
    echo "WARNING: Kea config-get failed, reservation may remain: $cfg_response" >&2
fi

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
