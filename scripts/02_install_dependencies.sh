#!/bin/sh
set -eu

[ "$(id -u)" -eq 0 ] || {
    echo "ERROR: run as root" >&2
    exit 1
}

pkg update -f
pkg install -y \
    ca_root_nss \
    curl \
    jq \
    kea \
    postgresql16-client \
    postgresql16-server \
    py311-cloud-init \
    sudo \
    tmux \
    vm-bhyve

sysrc zfs_enable=YES >/dev/null
sysrc vm_enable=YES >/dev/null
sysrc vm_dir="zfs:zroot/vm" >/dev/null
sysrc postgresql_enable=YES >/dev/null
sysrc kea_dhcp4_enable=YES >/dev/null
sysrc kea_ctrl_agent_enable=YES >/dev/null
sysrc pf_enable=YES >/dev/null
sysrc pflog_enable=YES >/dev/null

echo "Dependencies installed. Review config/ before starting services."
