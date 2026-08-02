#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "${SCRIPT_DIR}/lib.sh"

ACTION="${1:-up}"
CLUSTER_NODE_PREFIX="${CLUSTER_NODE_PREFIX:-freebsd-node}"
CLUSTER_NODE_COUNT="${CLUSTER_NODE_COUNT:-3}"
CLUSTER_PROFILE_FILE="${CLUSTER_PROFILE_FILE:-${SCRIPT_DIR}/../config/cloud-init/freebsd-jail-node.yaml}"
CLUSTER_STATE_DIR="${CLUSTER_STATE_DIR:-/var/db/freebsd-bhyve-kea-control-plane/clusters}"
CLUSTER_BOOT_TIMEOUT="${CLUSTER_BOOT_TIMEOUT:-600}"
CLUSTER_POLL_INTERVAL="${CLUSTER_POLL_INTERVAL:-5}"
CLUSTER_NODE_PROVISIONER="${CLUSTER_NODE_PROVISIONER:-${SCRIPT_DIR}/provision_vm.sh}"
CLUSTER_NODE_DEPROVISIONER="${CLUSTER_NODE_DEPROVISIONER:-${SCRIPT_DIR}/deprovision_vm.sh}"
CLUSTER_SSH_USER="${CLUSTER_SSH_USER:-${CLOUD_INIT_USER:-admin}}"
SSH_PRIVATE_KEY_FILE="${SSH_PRIVATE_KEY_FILE:-}"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-}"
KUBECTL_BOOTSTRAP="${KUBECTL_BOOTSTRAP:-yes}"
KUBECONFIG_SOURCE="${KUBECONFIG_SOURCE:-}"
KUBECONFIG_DEST="${KUBECONFIG_DEST:-/root/.kube/config}"
KUBECTL_VERIFY="${KUBECTL_VERIFY:-yes}"

usage() {
    echo "Usage: $0 [up|down|status]" >&2
    exit 64
}

node_name() {
    printf '%s-%02d\n' "$CLUSTER_NODE_PREFIX" "$1"
}

active_inventory_count() {
    cluster_name=$(sql_literal "$1")
    psql -X -v ON_ERROR_STOP=1 -qAt <<SQL
SELECT count(*)
  FROM vms
 WHERE name = '${cluster_name}'
   AND status <> 'archived';
SQL
}

inventory_row() {
    cluster_name=$(sql_literal "$1")
    psql -X -v ON_ERROR_STOP=1 -qAt -F '|' <<SQL
SELECT name, host(ip_address), mac_address, status
  FROM vms
 WHERE name = '${cluster_name}'
   AND status <> 'archived'
 ORDER BY created_at DESC
 LIMIT 1;
SQL
}

resolve_private_key() {
    if [ -n "$SSH_PRIVATE_KEY_FILE" ]; then
        printf '%s\n' "$SSH_PRIVATE_KEY_FILE"
        return
    fi

    case "$SSH_PUBLIC_KEY_FILE" in
        *.pub)
            candidate=${SSH_PUBLIC_KEY_FILE%.pub}
            [ -r "$candidate" ] && printf '%s\n' "$candidate"
            ;;
    esac
}

prepare_kubectl() {
    [ "$KUBECTL_BOOTSTRAP" = yes ] || return 0

    if ! command -v kubectl >/dev/null 2>&1; then
        require_commands pkg
        ASSUME_ALWAYS_YES=yes pkg install -y kubectl
    fi

    kubectl version --client >/dev/null

    kubectl_config=""
    if [ -n "$KUBECONFIG_SOURCE" ]; then
        [ -r "$KUBECONFIG_SOURCE" ] || die "kubeconfig is not readable: $KUBECONFIG_SOURCE"
        kubeconfig_dir=$(dirname -- "$KUBECONFIG_DEST")
        install -d -m 0700 "$kubeconfig_dir"
        if [ "$KUBECONFIG_SOURCE" != "$KUBECONFIG_DEST" ]; then
            kubeconfig_tmp=$(mktemp "${kubeconfig_dir}/.config.XXXXXX")
            install -m 0600 "$KUBECONFIG_SOURCE" "$kubeconfig_tmp"
            mv "$kubeconfig_tmp" "$KUBECONFIG_DEST"
        else
            chmod 0600 "$KUBECONFIG_DEST"
        fi
        kubectl_config=$KUBECONFIG_DEST
    elif [ -r "$KUBECONFIG_DEST" ]; then
        chmod 0600 "$KUBECONFIG_DEST"
        kubectl_config=$KUBECONFIG_DEST
    fi

    if [ -n "$kubectl_config" ]; then
        KUBECONFIG="$kubectl_config" kubectl config current-context >/dev/null
        if [ "$KUBECTL_VERIFY" = yes ]; then
            KUBECONFIG="$kubectl_config" kubectl cluster-info --request-timeout=10s >/dev/null
        fi
        echo "[+] kubectl configured from ${kubectl_config}"
    else
        echo "[!] kubectl installed without a kubeconfig; set KUBECONFIG_SOURCE to configure cluster access" >&2
    fi
}

wait_for_node() {
    wait_name=$1
    wait_ip=$2
    wait_key=$3

    [ -n "$wait_key" ] || {
        echo "[!] Skipping SSH readiness for ${wait_name}; set SSH_PRIVATE_KEY_FILE or use a readable key beside SSH_PUBLIC_KEY_FILE" >&2
        return 0
    }
    [ -r "$wait_key" ] || die "SSH private key is not readable: $wait_key"

    require_commands ssh ssh-keygen
    install -d -m 0700 "$CLUSTER_STATE_DIR"
    known_hosts="${CLUSTER_STATE_DIR}/${CLUSTER_NODE_PREFIX}.known_hosts"
    touch "$known_hosts"
    chmod 0600 "$known_hosts"
    ssh-keygen -f "$known_hosts" -R "$wait_ip" >/dev/null 2>&1 || true

    elapsed=0
    while [ "$elapsed" -lt "$CLUSTER_BOOT_TIMEOUT" ]; do
        if ssh \
            -i "$wait_key" \
            -o BatchMode=yes \
            -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$known_hosts" \
            "${CLUSTER_SSH_USER}@${wait_ip}" \
            'test -f /var/db/freebsd-jail-node-ready' \
            >/dev/null 2>&1
        then
            echo "[+] ${wait_name} ready at ${wait_ip}"
            return 0
        fi
        sleep "$CLUSTER_POLL_INTERVAL"
        elapsed=$((elapsed + CLUSTER_POLL_INTERVAL))
    done

    die "${wait_name} did not become SSH/cloud-init ready within ${CLUSTER_BOOT_TIMEOUT} seconds"
}

write_inventory() {
    install -d -m 0700 "$CLUSTER_STATE_DIR"
    inventory_file="${CLUSTER_STATE_DIR}/${CLUSTER_NODE_PREFIX}.tsv"
    inventory_tmp=$(mktemp "${CLUSTER_STATE_DIR}/.${CLUSTER_NODE_PREFIX}.XXXXXX")
    printf 'name\tip_address\tmac_address\tstatus\n' > "$inventory_tmp"

    inventory_index=1
    while [ "$inventory_index" -le "$CLUSTER_NODE_COUNT" ]; do
        inventory_name=$(node_name "$inventory_index")
        inventory_data=$(inventory_row "$inventory_name")
        [ -n "$inventory_data" ] || die "missing active inventory row for ${inventory_name}"
        printf '%s\n' "$inventory_data" | tr '|' '\t' >> "$inventory_tmp"
        inventory_index=$((inventory_index + 1))
    done

    chmod 0600 "$inventory_tmp"
    mv "$inventory_tmp" "$inventory_file"
    echo "[+] Cluster inventory: ${inventory_file}"
}

cluster_status() {
    printf 'name\tip_address\tmac_address\tstatus\n'
    status_index=1
    while [ "$status_index" -le "$CLUSTER_NODE_COUNT" ]; do
        status_name=$(node_name "$status_index")
        status_row=$(inventory_row "$status_name")
        if [ -n "$status_row" ]; then
            printf '%s\n' "$status_row" | tr '|' '\t'
        else
            printf '%s\t-\t-\tabsent\n' "$status_name"
        fi
        status_index=$((status_index + 1))
    done
}

cluster_down() {
    down_status=0
    down_index=$CLUSTER_NODE_COUNT
    while [ "$down_index" -ge 1 ]; do
        down_name=$(node_name "$down_index")
        down_active=$(active_inventory_count "$down_name")
        if [ "$down_active" -gt 0 ]; then
            echo "[cluster down] ${down_name}"
            if ! sh "$CLUSTER_NODE_DEPROVISIONER" "$down_name"; then
                down_status=1
            fi
        elif vm info "$down_name" >/dev/null 2>&1; then
            echo "ERROR: ${down_name} exists in vm-bhyve without active inventory; reconcile it manually" >&2
            down_status=1
        fi
        down_index=$((down_index - 1))
    done

    rm -f \
        "${CLUSTER_STATE_DIR}/${CLUSTER_NODE_PREFIX}.tsv" \
        "${CLUSTER_STATE_DIR}/${CLUSTER_NODE_PREFIX}.known_hosts"
    return "$down_status"
}

[ "$#" -le 1 ] || usage
case "$ACTION" in
    up|down|status) ;;
    *) usage ;;
esac
case "$CLUSTER_NODE_PREFIX" in
    ''|*[!A-Za-z0-9._-]*) die "invalid cluster node prefix: $CLUSTER_NODE_PREFIX" ;;
esac
case "$CLUSTER_NODE_COUNT" in
    ''|*[!0-9]*) die "invalid cluster node count: $CLUSTER_NODE_COUNT" ;;
esac
[ "$CLUSTER_NODE_COUNT" -ge 1 ] && [ "$CLUSTER_NODE_COUNT" -le 99 ] || \
    die "cluster node count must be between 1 and 99"
case "$CLUSTER_BOOT_TIMEOUT" in
    ''|*[!0-9]*|0) die "CLUSTER_BOOT_TIMEOUT must be a positive integer" ;;
esac
case "$CLUSTER_POLL_INTERVAL" in
    ''|*[!0-9]*|0) die "CLUSTER_POLL_INTERVAL must be a positive integer" ;;
esac
case "$KUBECTL_BOOTSTRAP:$KUBECTL_VERIFY" in
    yes:yes|yes:no|no:yes|no:no) ;;
    *) die "KUBECTL_BOOTSTRAP and KUBECTL_VERIFY must be yes or no" ;;
esac
case "$CLUSTER_SSH_USER" in
    ''|*[!a-z0-9_-]*|[0-9-]*) die "invalid cluster SSH user: $CLUSTER_SSH_USER" ;;
esac

require_root
require_commands vm psql install mktemp
[ -r "$CLUSTER_PROFILE_FILE" ] || die "cluster cloud-init profile is not readable: $CLUSTER_PROFILE_FILE"
[ -r "$CLUSTER_NODE_PROVISIONER" ] || die "cluster provisioner is not readable: $CLUSTER_NODE_PROVISIONER"
[ -r "$CLUSTER_NODE_DEPROVISIONER" ] || die "cluster deprovisioner is not readable: $CLUSTER_NODE_DEPROVISIONER"

case "$ACTION" in
    status)
        cluster_status
        exit 0
        ;;
    down)
        cluster_down
        exit $?
        ;;
esac

preflight_index=1
while [ "$preflight_index" -le "$CLUSTER_NODE_COUNT" ]; do
    preflight_name=$(node_name "$preflight_index")
    vm info "$preflight_name" >/dev/null 2>&1 && \
        die "vm-bhyve guest already exists: $preflight_name"
    preflight_active=$(active_inventory_count "$preflight_name")
    [ "$preflight_active" -eq 0 ] || die "active inventory row already exists: $preflight_name"
    preflight_index=$((preflight_index + 1))
done

prepare_kubectl

created_nodes=""
rollback_cluster() {
    rollback_status=$?
    trap - EXIT INT TERM HUP
    if [ "$rollback_status" -ne 0 ] && [ -n "$created_nodes" ]; then
        echo "[!] Cluster provisioning failed; removing nodes created by this run" >&2
        for rollback_name in $created_nodes; do
            sh "$CLUSTER_NODE_DEPROVISIONER" "$rollback_name" >/dev/null 2>&1 || \
                echo "WARNING: failed to deprovision ${rollback_name}" >&2
        done
    fi
    exit "$rollback_status"
}
trap rollback_cluster EXIT INT TERM HUP

cluster_key=$(resolve_private_key || true)
cluster_index=1
while [ "$cluster_index" -le "$CLUSTER_NODE_COUNT" ]; do
    cluster_name=$(node_name "$cluster_index")
    echo "[cluster ${cluster_index}/${CLUSTER_NODE_COUNT}] Provisioning ${cluster_name}"
    CLOUD_INIT_EXTRA_FILE="$CLUSTER_PROFILE_FILE" \
        sh "$CLUSTER_NODE_PROVISIONER" "$cluster_name" freebsd
    created_nodes="${cluster_name} ${created_nodes}"

    cluster_row=$(inventory_row "$cluster_name")
    cluster_ip=$(printf '%s\n' "$cluster_row" | awk -F '|' '{print $2}')
    [ -n "$cluster_ip" ] || die "inventory did not return an IP address for ${cluster_name}"
    wait_for_node "$cluster_name" "$cluster_ip" "$cluster_key"
    cluster_index=$((cluster_index + 1))
done

write_inventory
trap - EXIT INT TERM HUP

echo "[+] FreeBSD cluster ready (${CLUSTER_NODE_COUNT} nodes)"
cluster_status
if [ "$KUBECTL_BOOTSTRAP" = yes ]; then
    echo "[i] kubectl is a client only; these FreeBSD guests are not configured as Kubernetes kubelet workers"
fi
