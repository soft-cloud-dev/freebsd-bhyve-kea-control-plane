#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BOOTSTRAP_SCRIPT="${ROOT}/scripts/bootstrap_kubeconfig.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
bin_dir="${work}/bin"
mkdir -p "$bin_dir"

cat > "${bin_dir}/id" <<'EOF_ID'
#!/bin/sh
if [ "${1:-}" = "-u" ]; then
    echo 0
    exit 0
fi
exec /usr/bin/id "$@"
EOF_ID

cat > "${bin_dir}/kubectl" <<'EOF_KUBECTL'
#!/bin/sh
printf '%s|%s\n' "${KUBECONFIG:-}" "$*" >> "$KUBECTL_LOG"
case "${1:-} ${2:-}" in
    'version --client') exit 0 ;;
    'config current-context') echo softcloud ;;
    'cluster-info --request-timeout=10s') echo 'Kubernetes control plane is reachable' ;;
    *) exit 0 ;;
esac
EOF_KUBECTL

cat > "${bin_dir}/ssh" <<'EOF_SSH'
#!/bin/sh
printf '%s\n' "$*" >> "$SSH_LOG"
printf '%s\n' \
    'apiVersion: v1' \
    'kind: Config' \
    'current-context: softcloud'
EOF_SSH

chmod 0755 \
    "${bin_dir}/id" \
    "${bin_dir}/kubectl" \
    "${bin_dir}/ssh"

SSH_LOG="${work}/ssh.log"
KUBECTL_LOG="${work}/kubectl.log"
export SSH_LOG KUBECTL_LOG

printf 'test-private-key\n' > "${work}/id_ed25519"
chmod 0600 "${work}/id_ed25519"

remote_dest="${work}/remote/config"
PATH="${bin_dir}:$PATH" \
KUBECONFIG_DEST="$remote_dest" \
KUBECONFIG_REMOTE_HOST=ipa.softcloud.dev \
KUBECONFIG_REMOTE_USER=fedora \
KUBECONFIG_REMOTE_PATH=/etc/kubernetes/admin.conf \
KUBECONFIG_REMOTE_SSH_KEY="${work}/id_ed25519" \
KUBECONFIG_REMOTE_SUDO=yes \
KUBECONFIG_KNOWN_HOSTS="${work}/state/known_hosts" \
KUBECTL_VERIFY=yes \
    sh "$BOOTSTRAP_SCRIPT" > "${work}/remote.out"

grep -q '^apiVersion: v1$' "$remote_dest"
grep -q 'fedora@ipa.softcloud.dev' "$SSH_LOG"
grep -q 'sudo -n cat /etc/kubernetes/admin.conf' "$SSH_LOG"
grep -q "${remote_dest}|config current-context" "$KUBECTL_LOG"
grep -q "${remote_dest}|cluster-info --request-timeout=10s" "$KUBECTL_LOG"
grep -q 'kubectl configured at' "${work}/remote.out"

if stat -f '%Lp' "$remote_dest" >/dev/null 2>&1; then
    [ "$(stat -f '%Lp' "$remote_dest")" = 600 ]
else
    [ "$(stat -c '%a' "$remote_dest")" = 600 ]
fi

ssh_calls_before=$(wc -l < "$SSH_LOG" | tr -d ' ')
PATH="${bin_dir}:$PATH" \
KUBECONFIG_DEST="$remote_dest" \
KUBECONFIG_REMOTE_HOST=ipa.softcloud.dev \
KUBECONFIG_KNOWN_HOSTS="${work}/state/known_hosts" \
KUBECTL_VERIFY=no \
    sh "$BOOTSTRAP_SCRIPT" > "${work}/reuse.out"
ssh_calls_after=$(wc -l < "$SSH_LOG" | tr -d ' ')
[ "$ssh_calls_before" -eq "$ssh_calls_after" ]

PATH="${bin_dir}:$PATH" \
KUBECONFIG_DEST="$remote_dest" \
KUBECONFIG_REFRESH=yes \
KUBECONFIG_REMOTE_HOST=ipa.softcloud.dev \
KUBECONFIG_KNOWN_HOSTS="${work}/state/known_hosts" \
KUBECTL_VERIFY=no \
    sh "$BOOTSTRAP_SCRIPT" > "${work}/refresh.out"
ssh_calls_refreshed=$(wc -l < "$SSH_LOG" | tr -d ' ')
[ "$ssh_calls_refreshed" -eq $((ssh_calls_after + 1)) ]

printf '%s\n' \
    'apiVersion: v1' \
    'kind: Config' \
    'current-context: local' \
    > "${work}/local-source"
local_dest="${work}/local/config"
PATH="${bin_dir}:$PATH" \
KUBECONFIG_SOURCE="${work}/local-source" \
KUBECONFIG_DEST="$local_dest" \
KUBECTL_VERIFY=no \
    sh "$BOOTSTRAP_SCRIPT" > "${work}/local.out"
cmp "${work}/local-source" "$local_dest"

echo "PASS: automatic kubeconfig fetch, install, reuse, refresh, and verification"
