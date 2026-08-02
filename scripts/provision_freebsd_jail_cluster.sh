#!/bin/sh
set -eu

JAIL_NODE_PREFIX="${JAIL_NODE_PREFIX:-jail-node}"
JAIL_NODE_COUNT="${JAIL_NODE_COUNT:-3}"

. "$(dirname "$0")/lib.sh"
require_root
require_commands vm psql

case "$JAIL_NODE_PREFIX" in
    ''|*[!A-Za-z0-9._-]*) die "invalid jail-node prefix: $JAIL_NODE_PREFIX" ;;
esac
case "$JAIL_NODE_COUNT" in
    ''|*[!0-9]*) die "invalid jail-node count: $JAIL_NODE_COUNT" ;;
esac
[ "$JAIL_NODE_COUNT" -ge 1 ] && [ "$JAIL_NODE_COUNT" -le 99 ] || \
    die "jail-node count must be between 1 and 99"

node_index=1
while [ "$node_index" -le "$JAIL_NODE_COUNT" ]; do
    node_suffix=$(printf '%02d' "$node_index")
    node_name="${JAIL_NODE_PREFIX}-${node_suffix}"
    vm info "$node_name" >/dev/null 2>&1 && \
        die "vm-bhyve guest already exists: $node_name"
    escaped_node_name=$(sql_literal "$node_name")
    active_count=$(psql -X -v ON_ERROR_STOP=1 -qAt <<SQL
SELECT count(*)
  FROM vms
 WHERE name = '${escaped_node_name}'
   AND status <> 'archived';
SQL
)
    [ "$active_count" -eq 0 ] || die "active inventory row already exists: $node_name"
    node_index=$((node_index + 1))
done

provisioned_names=""
node_index=1
while [ "$node_index" -le "$JAIL_NODE_COUNT" ]; do
    node_suffix=$(printf '%02d' "$node_index")
    node_name="${JAIL_NODE_PREFIX}-${node_suffix}"
    echo "[cluster ${node_index}/${JAIL_NODE_COUNT}] Provisioning ${node_name}"
    sh "$(dirname "$0")/provision_freebsd_jail_node.sh" "$node_name"
    provisioned_names="${provisioned_names} ${node_name}"
    node_index=$((node_index + 1))
done

echo "[+] Provisioned:${provisioned_names}"
vm list | awk -v prefix="${JAIL_NODE_PREFIX}-" '
    NR == 1 || index($1, prefix) == 1
'
