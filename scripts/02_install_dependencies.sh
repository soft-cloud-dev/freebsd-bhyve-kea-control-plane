#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"
require_root

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
    postgresql16-server \
    prometheus \
    py312-cloud-init \
    sudo \
    tmux \
    vm-bhyve \
    bhyve-firmware || true

# The FreeBSD sysutils/loki port is packaged as grafana-loki and includes
# both the Loki and Promtail binaries and rc.d scripts.
pkg install -y grafana-loki
require_commands loki promtail

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

echo "Dependencies installed. Control plane services are managed via FreeBSD Jails / container engine."

