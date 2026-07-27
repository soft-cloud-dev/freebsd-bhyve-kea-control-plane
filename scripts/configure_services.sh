#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"
require_root

EXT_IF="${EXT_IF:-igb0}"
MGMT_IF="${MGMT_IF:-vlan10}"
LAN_IF="${LAN_IF:-bridge0}"
MGMT_NET="${MGMT_NET:-10.0.10.0/24}"
LAN_NET="${LAN_NET:-10.0.20.0/24}"
MGMT_ADDR="${MGMT_ADDR:-10.0.10.2}"
KEA_API_USER="${KEA_API_USER:-control-plane}"
KEA_API_USER_FILE="${KEA_API_USER_FILE:-/usr/local/etc/kea/kea-api-user}"
KEA_API_PASSWORD_FILE="${KEA_API_PASSWORD_FILE:-/usr/local/etc/kea/kea-api-password}"
POSTGRES_EXPORTER_DSN="${POSTGRES_EXPORTER_DSN:-}"

pf_tmp=$(mktemp)
kea_tmp=$(mktemp)
grafana_tmp=$(mktemp)
trap 'rm -f "$pf_tmp" "$kea_tmp" "$grafana_tmp"' EXIT HUP INT TERM

sed -e "s|^ext_if[[:space:]]*=.*|ext_if = \"${EXT_IF}\"|" \
    -e "s|^mgmt_if[[:space:]]*=.*|mgmt_if = \"${MGMT_IF}\"|" \
    -e "s|^lan_if[[:space:]]*=.*|lan_if = \"${LAN_IF}\"|" \
    -e "s|^mgmt_net[[:space:]]*=.*|mgmt_net = \"${MGMT_NET}\"|" \
    -e "s|^lan_net[[:space:]]*=.*|lan_net = \"${LAN_NET}\"|" config/pf.conf > "$pf_tmp"

pfctl -nf "$pf_tmp"
install -d -m 0755 /var/backups
if [ -f /etc/pf.conf ] && [ ! -f /var/backups/pf.conf.pre-control-plane ]; then
    install -m 0600 /etc/pf.conf /var/backups/pf.conf.pre-control-plane
fi
install -m 0600 "$pf_tmp" /etc/pf.conf

install -d -m 0750 /usr/local/etc/kea
if [ ! -s "${KEA_API_USER_FILE}" ]; then
    printf '%s\n' "${KEA_API_USER}" > "${KEA_API_USER_FILE}"
fi
if [ ! -s "${KEA_API_PASSWORD_FILE}" ]; then
    umask 077
    openssl rand -hex 24 > "${KEA_API_PASSWORD_FILE}"
fi
chmod 0600 "${KEA_API_USER_FILE}" "${KEA_API_PASSWORD_FILE}"

sed "s|\"interfaces\": \[ \"[^\"]*\" \]|\"interfaces\": [ \"${LAN_IF}\" ]|" config/kea-dhcp4.conf > "$kea_tmp"
if command -v kea-dhcp4 >/dev/null 2>&1; then
    kea-dhcp4 -t "$kea_tmp"
fi
install -m 0640 "$kea_tmp" /usr/local/etc/kea/kea-dhcp4.conf

install -m 0644 config/prometheus.yml /usr/local/etc/prometheus.yml
if command -v promtool >/dev/null 2>&1; then
    promtool check config /usr/local/etc/prometheus.yml
fi

install -d -m 0755 /usr/local/etc/grafana/provisioning/datasources \
    /usr/local/etc/grafana/provisioning/dashboards/json \
    /var/db/grafana \
    /var/db/grafana/plugins \
    /var/log/grafana

if id grafana >/dev/null 2>&1; then
    chown -R grafana:grafana /var/db/grafana /var/log/grafana /usr/local/etc/grafana
fi

sed -e "s|^http_addr[[:space:]]*=.*|http_addr = ${MGMT_ADDR}|" \
    -e "s|^domain[[:space:]]*=.*|domain = ${MGMT_ADDR}|" \
    -e "s|^root_url[[:space:]]*=.*|root_url = %(protocol)s://%(http_addr)s:%(http_port)s/|" config/grafana.ini > "$grafana_tmp"
install -m 0644 "$grafana_tmp" /usr/local/etc/grafana.ini
install -m 0644 "$grafana_tmp" /usr/local/etc/grafana/grafana.ini

install -m 0644 config/grafana/provisioning/datasources/prometheus.yml /usr/local/etc/grafana/provisioning/datasources/prometheus.yml
install -m 0644 config/grafana/provisioning/dashboards/default.yml /usr/local/etc/grafana/provisioning/dashboards/default.yml

for dashboard in config/grafana/provisioning/dashboards/json/*.json; do
    [ -e "$dashboard" ] || continue
    install -m 0644 "$dashboard" /usr/local/etc/grafana/provisioning/dashboards/json/
done

sysrc pf_enable=YES pflog_enable=YES jail_enable=YES >/dev/null
if [ -x /usr/local/etc/rc.d/kea ]; then
    sysrc kea_enable=YES >/dev/null
elif [ -x /usr/local/etc/rc.d/kea_dhcp4 ]; then
    sysrc kea_dhcp4_enable=YES >/dev/null
fi
[ ! -x /usr/local/etc/rc.d/node_exporter ] || sysrc node_exporter_enable=YES >/dev/null
[ ! -x /usr/local/etc/rc.d/prometheus ] || sysrc prometheus_enable=YES >/dev/null
[ ! -x /usr/local/etc/rc.d/grafana ] || sysrc grafana_enable=YES >/dev/null
if [ -n "${POSTGRES_EXPORTER_DSN}" ] && [ -x /usr/local/etc/rc.d/postgres_exporter ]; then
    sysrc postgres_exporter_enable=YES >/dev/null
fi

install -d -m 0755 /usr/local/jails

for j in postgres kea node_exporter prometheus postgres_exporter grafana; do
    install -d -m 0755 "/usr/local/jails/$j/dev"
    install -d -m 0755 "/usr/local/jails/$j/etc"
done

cat > /etc/jail.conf <<EOF
# Control plane FreeBSD Jails configuration
persist;
exec.start = "/bin/sh -c 'exit 0'";
exec.stop = "/bin/sh -c 'exit 0'";
exec.clean;
host.hostname = "\$name.control-plane.local";
path = "/";

postgres {
    ip4.addr = 127.0.0.1;
}

kea {
    ip4.addr = 127.0.0.1;
}

prometheus {
    ip4.addr = 127.0.0.1;
}

grafana {
    ip4.addr = ${MGMT_ADDR}, 127.0.0.1;
}

node_exporter {
    ip4.addr = 127.0.0.1;
}

postgres_exporter {
    ip4.addr = 127.0.0.1;
}
EOF

echo "[+] Control plane service configurations updated for FreeBSD Jail / container runtime."



