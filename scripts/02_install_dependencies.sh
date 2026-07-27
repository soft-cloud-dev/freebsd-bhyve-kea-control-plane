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
    grafana \
    jq \
    kea \
    node_exporter \
    postgresql16-client \
    postgresql16-server \
    prometheus \
    prometheus-postgres-exporter \
    py312-cloud-init \
    sudo \
    tmux \
    vm-bhyve

install -d -m 0750 /usr/local/etc/kea
install -m 0640 config/keactrl.conf /usr/local/etc/kea/keactrl.conf

sysrc zfs_enable=YES >/dev/null
sysrc vm_enable=YES >/dev/null
sysrc vm_dir="zfs:zroot/vm" >/dev/null
sysrc postgresql_enable=YES >/dev/null
sysrc kea_enable=YES >/dev/null
sysrc -x kea_dhcp4_enable >/dev/null 2>&1 || true
sysrc -x kea_ctrl_agent_enable >/dev/null 2>&1 || true
sysrc pf_enable=YES >/dev/null
sysrc pflog_enable=YES >/dev/null
sysrc prometheus_enable=YES >/dev/null
sysrc prometheus_config="/usr/local/etc/prometheus.yml" >/dev/null
sysrc prometheus_args="--web.listen-address=127.0.0.1:9090" >/dev/null
sysrc node_exporter_enable=YES >/dev/null
sysrc node_exporter_listen_address="127.0.0.1:9100" >/dev/null
sysrc postgres_exporter_enable=YES >/dev/null
sysrc postgres_exporter_listen_address="127.0.0.1:9187" >/dev/null
sysrc grafana_enable=YES >/dev/null
sysrc grafana_config="/usr/local/etc/grafana/grafana.ini" >/dev/null
sysrc grafana_homepath="/usr/local/share/grafana" >/dev/null

echo "Dependencies installed. Kea DHCP4 exposes its management API on 127.0.0.1:8000."
