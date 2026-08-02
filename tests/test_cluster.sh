#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CLUSTER_SCRIPT="${ROOT}/scripts/freebsd_cluster.sh"
PROFILE_FILE="${ROOT}/config/cloud-init/freebsd-jail-node.yaml"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
bin_dir="${work}/bin"
state_dir="${work}/state"
mkdir -p "$bin_dir" "$state_dir"

cat > "${bin_dir}/id" <<'EOF_ID'
#!/bin/sh
if [ "${1:-}" = "-u" ]; then
    echo 0
    exit 0
fi
exec /usr/bin/id "$@"
EOF_ID

cat > "${bin_dir}/vm" <<'EOF_VM'
#!/bin/sh
case "${1:-}" in
    info) exit 1 ;;
    *) exit 0 ;;
esac
EOF_VM

cat > "${bin_dir}/psql" <<'EOF_PSQL'
#!/bin/sh
sql=$(cat)
case "$sql" in
    *"SELECT count(*)"*)
        echo 0
        ;;
    *"WHERE name = 'test-node-01'"*)
        echo 'test-node-01|10.0.20.11|02:00:00:00:00:11|running'
        ;;
    *"WHERE name = 'test-node-02'"*)
        echo 'test-node-02|10.0.20.12|02:00:00:00:00:12|running'
        ;;
    *"WHERE name = 'test-node-03'"*)
        echo 'test-node-03|10.0.20.13|02:00:00:00:00:13|running'
        ;;
esac
EOF_PSQL

cat > "${bin_dir}/kubectl" <<'EOF_KUBECTL'
#!/bin/sh
case "${1:-} ${2:-}" in
    'version --client') exit 0 ;;
    'config current-context') echo test-context ;;
    'cluster-info --request-timeout=10s') echo 'Kubernetes control plane is reachable' ;;
    *) exit 0 ;;
esac
EOF_KUBECTL

cat > "${work}/provision.sh" <<'EOF_PROVISION'
#!/bin/sh
echo "$1" >> "$PROVISION_LOG"
if [ "${FAIL_NODE:-}" = "$1" ]; then
    exit 1
fi
EOF_PROVISION

cat > "${work}/deprovision.sh" <<'EOF_DEPROVISION'
#!/bin/sh
echo "$1" >> "$DEPROVISION_LOG"
EOF_DEPROVISION

chmod 0755 \
    "${bin_dir}/id" \
    "${bin_dir}/vm" \
    "${bin_dir}/psql" \
    "${bin_dir}/kubectl" \
    "${work}/provision.sh" \
    "${work}/deprovision.sh"

printf '%s\n' \
    'apiVersion: v1' \
    'kind: Config' \
    'current-context: test-context' \
    > "${work}/source-kubeconfig"

PROVISION_LOG="${work}/provision.log"
DEPROVISION_LOG="${work}/deprovision.log"
export PROVISION_LOG DEPROVISION_LOG

PATH="${bin_dir}:$PATH" \
CLUSTER_NODE_PREFIX=test-node \
CLUSTER_NODE_COUNT=3 \
CLUSTER_PROFILE_FILE="$PROFILE_FILE" \
CLUSTER_STATE_DIR="$state_dir" \
CLUSTER_NODE_PROVISIONER="${work}/provision.sh" \
CLUSTER_NODE_DEPROVISIONER="${work}/deprovision.sh" \
KUBECTL_BOOTSTRAP=yes \
KUBECTL_VERIFY=yes \
KUBECONFIG_SOURCE="${work}/source-kubeconfig" \
KUBECONFIG_DEST="${work}/kube/config" \
    sh "$CLUSTER_SCRIPT" up > "${work}/success.out" 2> "${work}/success.err"

[ "$(wc -l < "$PROVISION_LOG" | tr -d ' ')" -eq 3 ]
grep -qx 'test-node-01' "$PROVISION_LOG"
grep -qx 'test-node-02' "$PROVISION_LOG"
grep -qx 'test-node-03' "$PROVISION_LOG"
cmp "${work}/source-kubeconfig" "${work}/kube/config"

grep -q 'test-node-01' "${state_dir}/test-node.tsv"
grep -q 'test-node-02' "${state_dir}/test-node.tsv"
grep -q 'test-node-03' "${state_dir}/test-node.tsv"
grep -q 'FreeBSD cluster ready (3 nodes)' "${work}/success.out"
grep -q 'kubectl is a client only' "${work}/success.out"

: > "$PROVISION_LOG"
: > "$DEPROVISION_LOG"

if PATH="${bin_dir}:$PATH" \
    CLUSTER_NODE_PREFIX=test-node \
    CLUSTER_NODE_COUNT=3 \
    CLUSTER_PROFILE_FILE="$PROFILE_FILE" \
    CLUSTER_STATE_DIR="${work}/failure-state" \
    CLUSTER_NODE_PROVISIONER="${work}/provision.sh" \
    CLUSTER_NODE_DEPROVISIONER="${work}/deprovision.sh" \
    KUBECTL_BOOTSTRAP=no \
    FAIL_NODE=test-node-02 \
        sh "$CLUSTER_SCRIPT" up > "${work}/failure.out" 2> "${work}/failure.err"
then
    echo "ERROR: cluster provisioning unexpectedly succeeded" >&2
    exit 1
fi

[ "$(wc -l < "$PROVISION_LOG" | tr -d ' ')" -eq 2 ]
[ "$(wc -l < "$DEPROVISION_LOG" | tr -d ' ')" -eq 1 ]
grep -qx 'test-node-01' "$DEPROVISION_LOG"
grep -q 'Cluster provisioning failed; removing nodes created by this run' "${work}/failure.err"

echo "PASS: FreeBSD cluster lifecycle, kubectl bootstrap, and rollback"
