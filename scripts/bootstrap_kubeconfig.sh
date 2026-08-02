#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"

KUBECTL_BOOTSTRAP="${KUBECTL_BOOTSTRAP:-yes}"
KUBECTL_VERIFY="${KUBECTL_VERIFY:-yes}"
KUBECONFIG_SOURCE="${KUBECONFIG_SOURCE:-}"
KUBECONFIG_DEST="${KUBECONFIG_DEST:-/root/.kube/config}"
KUBECONFIG_REFRESH="${KUBECONFIG_REFRESH:-no}"
KUBECONFIG_REMOTE_HOST="${KUBECONFIG_REMOTE_HOST:-ipa.softcloud.dev}"
KUBECONFIG_REMOTE_USER="${KUBECONFIG_REMOTE_USER:-root}"
KUBECONFIG_REMOTE_PATH="${KUBECONFIG_REMOTE_PATH:-/etc/kubernetes/admin.conf}"
KUBECONFIG_REMOTE_SSH_KEY="${KUBECONFIG_REMOTE_SSH_KEY:-${SSH_PRIVATE_KEY_FILE:-}}"
KUBECONFIG_REMOTE_SUDO="${KUBECONFIG_REMOTE_SUDO:-no}"
KUBECONFIG_KNOWN_HOSTS="${KUBECONFIG_KNOWN_HOSTS:-/var/db/freebsd-bhyve-kea-control-plane/clusters/kubernetes-control-plane.known_hosts}"

case "$KUBECTL_BOOTSTRAP:$KUBECTL_VERIFY:$KUBECONFIG_REFRESH:$KUBECONFIG_REMOTE_SUDO" in
    yes:yes:yes:yes|yes:yes:yes:no|yes:yes:no:yes|yes:yes:no:no|\
    yes:no:yes:yes|yes:no:yes:no|yes:no:no:yes|yes:no:no:no|\
    no:yes:yes:yes|no:yes:yes:no|no:yes:no:yes|no:yes:no:no|\
    no:no:yes:yes|no:no:yes:no|no:no:no:yes|no:no:no:no) ;;
    *) die "KUBECTL_BOOTSTRAP, KUBECTL_VERIFY, KUBECONFIG_REFRESH, and KUBECONFIG_REMOTE_SUDO must be yes or no" ;;
esac

[ "$KUBECTL_BOOTSTRAP" = yes ] || exit 0
[ -n "$KUBECONFIG_DEST" ] || die "KUBECONFIG_DEST must not be empty"

case "$KUBECONFIG_REMOTE_HOST" in
    ''|*[!A-Za-z0-9._:-]*) die "invalid kubeconfig remote host: $KUBECONFIG_REMOTE_HOST" ;;
esac
case "$KUBECONFIG_REMOTE_USER" in
    ''|*[!A-Za-z0-9._-]*) die "invalid kubeconfig remote user: $KUBECONFIG_REMOTE_USER" ;;
esac
case "$KUBECONFIG_REMOTE_PATH" in
    /*) ;;
    *) die "KUBECONFIG_REMOTE_PATH must be absolute" ;;
esac
case "$KUBECONFIG_REMOTE_PATH" in
    *[!A-Za-z0-9_./-]*) die "invalid kubeconfig remote path: $KUBECONFIG_REMOTE_PATH" ;;
esac

require_root
require_commands install mktemp

if ! command -v kubectl >/dev/null 2>&1; then
    require_commands pkg
    ASSUME_ALWAYS_YES=yes pkg install -y kubectl
fi
kubectl version --client >/dev/null

kubeconfig_dir=$(dirname -- "$KUBECONFIG_DEST")
install -d -m 0700 "$kubeconfig_dir"

install_kubeconfig() {
    input_file=$1
    [ -s "$input_file" ] || die "kubeconfig source is empty: $input_file"
    kubeconfig_tmp=$(mktemp "${kubeconfig_dir}/.config.XXXXXX")
    trap 'rm -f "$kubeconfig_tmp"' EXIT INT TERM HUP
    install -m 0600 "$input_file" "$kubeconfig_tmp"
    mv "$kubeconfig_tmp" "$KUBECONFIG_DEST"
    trap - EXIT INT TERM HUP
}

if [ -n "$KUBECONFIG_SOURCE" ]; then
    [ -r "$KUBECONFIG_SOURCE" ] || die "kubeconfig is not readable: $KUBECONFIG_SOURCE"
    if [ "$KUBECONFIG_SOURCE" = "$KUBECONFIG_DEST" ]; then
        chmod 0600 "$KUBECONFIG_DEST"
    else
        install_kubeconfig "$KUBECONFIG_SOURCE"
    fi
    kubeconfig_origin=$KUBECONFIG_SOURCE
elif [ -s "$KUBECONFIG_DEST" ] && [ "$KUBECONFIG_REFRESH" = no ]; then
    chmod 0600 "$KUBECONFIG_DEST"
    kubeconfig_origin=$KUBECONFIG_DEST
else
    require_commands ssh ssh-keygen
    if [ -n "$KUBECONFIG_REMOTE_SSH_KEY" ]; then
        [ -r "$KUBECONFIG_REMOTE_SSH_KEY" ] || \
            die "kubeconfig SSH key is not readable: $KUBECONFIG_REMOTE_SSH_KEY"
    fi

    known_hosts_dir=$(dirname -- "$KUBECONFIG_KNOWN_HOSTS")
    install -d -m 0700 "$known_hosts_dir"
    touch "$KUBECONFIG_KNOWN_HOSTS"
    chmod 0600 "$KUBECONFIG_KNOWN_HOSTS"

    remote_tmp=$(mktemp "${kubeconfig_dir}/.remote-config.XXXXXX")
    trap 'rm -f "$remote_tmp"' EXIT INT TERM HUP

    remote_command=cat
    [ "$KUBECONFIG_REMOTE_SUDO" = yes ] && remote_command='sudo -n cat'

    echo "[+] Fetching kubeconfig from ${KUBECONFIG_REMOTE_USER}@${KUBECONFIG_REMOTE_HOST}:${KUBECONFIG_REMOTE_PATH}"
    if [ -n "$KUBECONFIG_REMOTE_SSH_KEY" ]; then
        ssh \
            -i "$KUBECONFIG_REMOTE_SSH_KEY" \
            -o BatchMode=yes \
            -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$KUBECONFIG_KNOWN_HOSTS" \
            "${KUBECONFIG_REMOTE_USER}@${KUBECONFIG_REMOTE_HOST}" \
            "$remote_command $KUBECONFIG_REMOTE_PATH" > "$remote_tmp"
    else
        ssh \
            -o BatchMode=yes \
            -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$KUBECONFIG_KNOWN_HOSTS" \
            "${KUBECONFIG_REMOTE_USER}@${KUBECONFIG_REMOTE_HOST}" \
            "$remote_command $KUBECONFIG_REMOTE_PATH" > "$remote_tmp"
    fi

    install_kubeconfig "$remote_tmp"
    rm -f "$remote_tmp"
    trap - EXIT INT TERM HUP
    kubeconfig_origin="${KUBECONFIG_REMOTE_USER}@${KUBECONFIG_REMOTE_HOST}:${KUBECONFIG_REMOTE_PATH}"
fi

KUBECONFIG="$KUBECONFIG_DEST" kubectl config current-context >/dev/null
if [ "$KUBECTL_VERIFY" = yes ]; then
    KUBECONFIG="$KUBECONFIG_DEST" kubectl cluster-info --request-timeout=10s >/dev/null
fi

echo "[+] kubectl configured at ${KUBECONFIG_DEST} from ${kubeconfig_origin}"
