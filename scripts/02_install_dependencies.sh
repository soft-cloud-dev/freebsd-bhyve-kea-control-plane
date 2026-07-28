#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"
require_root

STORK_ENABLE="${STORK_ENABLE:-yes}"
STORK_VERSION="${STORK_VERSION:-2.5.0}"
STORK_GIT_COMMIT="${STORK_GIT_COMMIT:-43f1450d1260ce58c2c6c973b72199b6c6592513}"
STORK_SOURCE_DIR="${STORK_SOURCE_DIR:-}"

case "$STORK_ENABLE" in
    yes|no) ;;
    *) die "STORK_ENABLE must be yes or no" ;;
esac

if ! command -v container >/dev/null 2>&1 && ! command -v jail >/dev/null 2>&1; then
    die "missing container or FreeBSD jail engine"
fi

pkg update -f || true
pkg install -y \
    ca_root_nss \
    curl \
    grafana \
    jq \
    kea \
    node_exporter \
    postgresql16-client \
    postgresql16-contrib \
    postgresql16-server \
    prometheus \
    py312-cloud-init \
    sudo \
    tmux \
    vm-bhyve \
    bhyve-firmware || true

# BIND 9.20 is the current stable FreeBSD package. Retain the 9.18 ESV
# fallback for supported quarterly package branches that do not yet ship 9.20.
pkg install -y bind920 || \
    pkg install -y bind918 || \
    die "failed to install a supported BIND 9 package"

# The FreeBSD sysutils/loki port is packaged as grafana-loki and includes
# both the Loki and Promtail binaries and rc.d scripts.
pkg install -y grafana-loki
require_commands loki promtail

if [ "$STORK_ENABLE" = yes ]; then
    pkg install -y \
        gcc \
        git \
        go \
        gtar \
        openjdk17-jre \
        protobuf \
        python3 \
        ruby \
        rubygem-rake \
        unzip \
        wget
    pkg install -y node20 npm-node20 || \
        pkg install -y node22 npm-node22 || \
        pkg install -y node npm
    STORK_ENABLE="$STORK_ENABLE" \
    STORK_VERSION="$STORK_VERSION" \
    STORK_GIT_COMMIT="$STORK_GIT_COMMIT" \
    STORK_SOURCE_DIR="$STORK_SOURCE_DIR" \
        sh scripts/install_stork.sh
fi

install -d -m 0750 /usr/local/etc/kea
if [ -f config/keactrl.conf ]; then
    install -m 0640 config/keactrl.conf /usr/local/etc/kea/keactrl.conf
fi

sysrc zfs_enable=YES >/dev/null
sysrc vm_enable=YES >/dev/null
sysrc vm_dir="zfs:zroot/vm" >/dev/null
sysrc jail_enable=YES >/dev/null
sysrc pf_enable=YES >/dev/null
sysrc pflog_enable=YES >/dev/null
sysrc named_enable=YES >/dev/null
sysrc named_conf="/usr/local/etc/namedb/named.conf" >/dev/null

echo "Dependencies installed. Control plane services are managed via FreeBSD Jails / container engine."
