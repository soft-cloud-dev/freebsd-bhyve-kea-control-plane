#!/bin/sh
set -eu

PGDATABASE="${PGDATABASE:-inventory}"
PGUSER="${PGUSER:-postgres}"
IPAM_POOL="${IPAM_POOL:-vm-lan}"
IPAM_SUBNET="${IPAM_SUBNET:-10.0.20.0/24}"
IPAM_FIRST_HOST="${IPAM_FIRST_HOST:-10.0.20.10}"
IPAM_LAST_HOST="${IPAM_LAST_HOST:-10.0.20.99}"
IPAM_VLAN="${IPAM_VLAN:-20}"
KEA_SUBNET_ID="${KEA_SUBNET_ID:-1}"

case "$IPAM_POOL" in
    ''|*[!A-Za-z0-9._-]*) echo "ERROR: invalid IPAM_POOL" >&2; exit 1 ;;
esac
case "$IPAM_VLAN" in
    ''|*[!0-9]*) echo "ERROR: invalid IPAM_VLAN" >&2; exit 1 ;;
esac
case "$KEA_SUBNET_ID" in
    ''|*[!0-9]*) echo "ERROR: invalid KEA_SUBNET_ID" >&2; exit 1 ;;
esac

. "$(dirname "$0")/lib.sh"
require_commands psql

pool=$(sql_literal "$IPAM_POOL")
subnet=$(sql_literal "$IPAM_SUBNET")
first_host=$(sql_literal "$IPAM_FIRST_HOST")
last_host=$(sql_literal "$IPAM_LAST_HOST")

psql -X -v ON_ERROR_STOP=1 -qAt <<SQL
INSERT INTO ipam_pools (
    name, subnet, first_host, last_host, vlan, kea_subnet_id
)
VALUES (
    '${pool}', '${subnet}'::cidr, '${first_host}'::inet, '${last_host}'::inet,
    ${IPAM_VLAN}, ${KEA_SUBNET_ID}
)
ON CONFLICT (name) DO UPDATE
SET subnet = EXCLUDED.subnet,
    first_host = EXCLUDED.first_host,
    last_host = EXCLUDED.last_host,
    vlan = EXCLUDED.vlan,
    kea_subnet_id = EXCLUDED.kea_subnet_id;
SQL

echo "[+] IPAM pool ${IPAM_POOL} initialized"
