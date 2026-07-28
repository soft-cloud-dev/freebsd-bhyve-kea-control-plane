#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"
require_root
require_commands jq unbound-anchor unbound-checkconf

EXT_IF="${EXT_IF:-igb0}"
MGMT_IF="${MGMT_IF:-vlan10}"
LAN_IF="${LAN_IF:-bridge0}"
MGMT_NET="${MGMT_NET:-10.0.10.0/24}"
LAN_NET="${LAN_NET:-10.0.20.0/24}"
MGMT_ADDR="${MGMT_ADDR:-10.0.10.2}"
DNS_ADDR="${DNS_ADDR:-10.0.20.1}"
UNBOUND_CHROOT="${UNBOUND_CHROOT:-/usr/local/etc/unbound}"
UNBOUND_USERNAME="${UNBOUND_USERNAME:-unbound}"
UNBOUND_ROOT_KEY_FILE="${UNBOUND_ROOT_KEY_FILE:-/usr/local/etc/unbound/var/root.key}"
KEA_API_USER="${KEA_API_USER:-stork-control-plane}"
KEA_API_USER_FILE="${KEA_API_USER_FILE:-/usr/local/etc/kea/kea-api-user}"
KEA_API_PASSWORD_FILE="${KEA_API_PASSWORD_FILE:-/usr/local/etc/kea/kea-api-password}"
POSTGRES_EXPORTER_DSN="${POSTGRES_EXPORTER_DSN:-}"
STORK_ENABLE="${STORK_ENABLE:-yes}"
STORK_DB_NAME="${STORK_DB_NAME:-stork}"
STORK_DB_USER="${STORK_DB_USER:-stork-server}"
STORK_DB_PASSWORD_FILE="${STORK_DB_PASSWORD_FILE:-/usr/local/etc/stork/database-password}"

case "$STORK_ENABLE" in
    yes|no) ;;
    *) die "STORK_ENABLE must be yes or no" ;;
esac
case "$STORK_DB_NAME" in
    ''|[0-9]*|*[!A-Za-z0-9_]*) die "invalid STORK_DB_NAME" ;;
esac
case "$STORK_DB_USER" in
    ''|[0-9]*|*[!A-Za-z0-9_-]*) die "invalid STORK_DB_USER" ;;
esac
case "$DNS_ADDR" in
    ''|*[!0-9.]*) die "DNS_ADDR must be an IPv4 address" ;;
esac
case "$LAN_NET" in
    ''|*[!0-9./]*) die "LAN_NET must be an IPv4 CIDR network" ;;
esac

pf_tmp=$(mktemp)
pf_stork_tmp=$(mktemp)
kea_tmp=$(mktemp)
unbound_tmp=$(mktemp)
grafana_tmp=$(mktemp)
prometheus_tmp=$(mktemp)
stork_server_tmp=$(mktemp)
stork_agent_tmp=$(mktemp)
trap 'rm -f "$pf_tmp" "$pf_stork_tmp" "$kea_tmp" "$unbound_tmp" "$grafana_tmp" "$prometheus_tmp" "$stork_server_tmp" "$stork_agent_tmp"' EXIT HUP INT TERM

sed -e "s|^ext_if[[:space:]]*=.*|ext_if = \"${EXT_IF}\"|" \
    -e "s|^mgmt_if[[:space:]]*=.*|mgmt_if = \"${MGMT_IF}\"|" \
    -e "s|^lan_if[[:space:]]*=.*|lan_if = \"${LAN_IF}\"|" \
    -e "s|^mgmt_net[[:space:]]*=.*|mgmt_net = \"${MGMT_NET}\"|" \
    -e "s|^lan_net[[:space:]]*=.*|lan_net = \"${LAN_NET}\"|" config/pf.conf > "$pf_tmp"

if [ "$STORK_ENABLE" = no ]; then
    sed 's/port { 3000 8080 }/port 3000/' "$pf_tmp" > "$pf_stork_tmp"
    install -m 0600 "$pf_stork_tmp" "$pf_tmp"
fi

pfctl -nf "$pf_tmp"
install -d -m 0755 /var/backups
if [ -f /etc/pf.conf ] && [ ! -f /var/backups/pf.conf.pre-control-plane ]; then
    install -m 0600 /etc/pf.conf /var/backups/pf.conf.pre-control-plane
fi
install -m 0600 "$pf_tmp" /etc/pf.conf

install -d -m 0750 /usr/local/etc/kea
if [ "$STORK_ENABLE" = yes ]; then
    pw groupshow stork-server >/dev/null 2>&1 || pw groupadd stork-server
    id stork-server >/dev/null 2>&1 || \
        pw useradd stork-server -g stork-server -d /nonexistent -s /usr/sbin/nologin \
            -c "ISC Stork server"

    pw groupshow stork-agent >/dev/null 2>&1 || pw groupadd stork-agent
    id stork-agent >/dev/null 2>&1 || \
        pw useradd stork-agent -g stork-agent -d /var/lib/stork-agent \
            -s /usr/sbin/nologin -c "ISC Stork agent"

    pw groupshow stork >/dev/null 2>&1 || pw groupadd stork
    pw groupmod stork -m stork-server
    pw groupmod stork -m stork-agent

    pw groupshow kea-control >/dev/null 2>&1 || pw groupadd kea-control
    pw groupmod kea-control -m stork-agent
    if id kea >/dev/null 2>&1; then
        pw groupmod kea-control -m kea
    fi
fi

if [ ! -s "${KEA_API_USER_FILE}" ]; then
    printf '%s\n' "${KEA_API_USER}" > "${KEA_API_USER_FILE}"
fi
if [ ! -s "${KEA_API_PASSWORD_FILE}" ]; then
    umask 077
    openssl rand -hex 24 > "${KEA_API_PASSWORD_FILE}"
fi
if [ "$STORK_ENABLE" = yes ]; then
    chown root:kea-control "${KEA_API_USER_FILE}" "${KEA_API_PASSWORD_FILE}"
    chmod 0640 "${KEA_API_USER_FILE}" "${KEA_API_PASSWORD_FILE}"
    chown root:kea-control /usr/local/etc/kea
else
    chmod 0600 "${KEA_API_USER_FILE}" "${KEA_API_PASSWORD_FILE}"
fi

kea_existing=""
if [ -r /usr/local/etc/kea/kea-dhcp4.conf ]; then
    kea_existing=/usr/local/etc/kea/kea-dhcp4.conf
fi
sh scripts/render_kea_config.sh \
    config/kea-dhcp4.conf "$LAN_IF" "$kea_existing" > "$kea_tmp"
if command -v kea-dhcp4 >/dev/null 2>&1; then
    kea-dhcp4 -t "$kea_tmp"
fi
install -m 0640 "$kea_tmp" /usr/local/etc/kea/kea-dhcp4.conf
if [ "$STORK_ENABLE" = yes ]; then
    chown root:kea-control /usr/local/etc/kea/kea-dhcp4.conf
fi

sed -e "s|@DNS_ADDR@|${DNS_ADDR}|g" \
    -e "s|@LAN_NET@|${LAN_NET}|g" \
    -e "s|@UNBOUND_CHROOT@|${UNBOUND_CHROOT}|g" \
    -e "s|@UNBOUND_USERNAME@|${UNBOUND_USERNAME}|g" \
    -e "s|@UNBOUND_ROOT_KEY_FILE@|${UNBOUND_ROOT_KEY_FILE}|g" \
    config/unbound.conf.in > "$unbound_tmp"
install -d -m 0755 /usr/local/etc/unbound
install -d -m 0750 "$(dirname "$UNBOUND_ROOT_KEY_FILE")"
if id unbound >/dev/null 2>&1; then
    chown unbound:unbound "$(dirname "$UNBOUND_ROOT_KEY_FILE")"
fi
if [ ! -s "$UNBOUND_ROOT_KEY_FILE" ]; then
    unbound-anchor -a "$UNBOUND_ROOT_KEY_FILE" >/dev/null 2>&1 || \
        [ -s "$UNBOUND_ROOT_KEY_FILE" ] || \
        die "failed to initialize the Unbound DNSSEC root trust anchor"
fi
if id unbound >/dev/null 2>&1; then
    chown unbound:unbound "$UNBOUND_ROOT_KEY_FILE"
fi
chmod 0644 "$UNBOUND_ROOT_KEY_FILE"
unbound-checkconf "$unbound_tmp"
install -m 0644 "$unbound_tmp" /usr/local/etc/unbound/unbound.conf

if [ "$STORK_ENABLE" = yes ]; then
    install -d -m 0750 /usr/local/etc/stork
    chown root:stork /usr/local/etc/stork
    stork_password_dir=$(dirname "$STORK_DB_PASSWORD_FILE")
    if [ "$stork_password_dir" != /usr/local/etc/stork ]; then
        [ -d "$stork_password_dir" ] || install -d -m 0750 "$stork_password_dir"
    fi
    if [ ! -s "$STORK_DB_PASSWORD_FILE" ]; then
        umask 077
        openssl rand -hex 32 > "$STORK_DB_PASSWORD_FILE"
    fi
    stork_password=$(sed -n '1p' "$STORK_DB_PASSWORD_FILE")
    case "$stork_password" in
        ''|*[!0-9a-f]*) die "invalid Stork database password" ;;
    esac

    sed -e "s|@STORK_DB_NAME@|${STORK_DB_NAME}|g" \
        -e "s|@STORK_DB_USER@|${STORK_DB_USER}|g" \
        -e "s|@STORK_DB_PASSWORD@|${stork_password}|g" \
        -e "s|@MGMT_ADDR@|${MGMT_ADDR}|g" \
        config/stork/server.env.in > "$stork_server_tmp"
    sed -e "s|@MGMT_ADDR@|${MGMT_ADDR}|g" \
        config/stork/agent.env.in > "$stork_agent_tmp"

    install -m 0640 "$stork_server_tmp" /usr/local/etc/stork/server.env
    install -m 0640 "$stork_agent_tmp" /usr/local/etc/stork/agent.env
    chmod 0640 "$STORK_DB_PASSWORD_FILE"
    chown root:stork-server /usr/local/etc/stork/server.env "$STORK_DB_PASSWORD_FILE"
    chown root:stork-agent /usr/local/etc/stork/agent.env

    install -d -m 0700 -o stork-agent -g stork-agent \
        /var/lib/stork-agent \
        /var/lib/stork-agent/certs \
        /var/lib/stork-agent/tokens
    chown -R stork-agent:stork-agent /var/lib/stork-agent
    chmod 0700 \
        /var/lib/stork-agent \
        /var/lib/stork-agent/certs \
        /var/lib/stork-agent/tokens
    find /var/lib/stork-agent/certs /var/lib/stork-agent/tokens \
        -type f -exec chmod 0600 {} +
    install -d -m 0755 /var/log/stork
    touch /var/log/stork/server.log /var/log/stork/agent.log
    chown stork-server:stork-server /var/log/stork/server.log
    chown stork-agent:stork-agent /var/log/stork/agent.log
    chmod 0640 /var/log/stork/server.log /var/log/stork/agent.log

    install -m 0555 config/rc.d/stork_server /usr/local/etc/rc.d/stork_server
    install -m 0555 config/rc.d/stork_agent /usr/local/etc/rc.d/stork_agent
fi

if [ "$STORK_ENABLE" = yes ]; then
    install -m 0644 config/prometheus.yml "$prometheus_tmp"
else
    sed '/^  - job_name: kea/,$d' config/prometheus.yml > "$prometheus_tmp"
fi
install -m 0644 "$prometheus_tmp" /usr/local/etc/prometheus.yml
if command -v promtool >/dev/null 2>&1; then
    promtool check config /usr/local/etc/prometheus.yml
fi

if [ -f config/loki.yml ]; then
    install -m 0644 config/loki.yml /usr/local/etc/loki.yml
fi

if [ -f config/promtail.yml ]; then
    install -m 0644 config/promtail.yml /usr/local/etc/promtail.yml
fi

install -d -m 0755 /var/db/loki /var/log/loki /var/db/promtail /var/log/promtail
if id loki >/dev/null 2>&1; then
    chown -R loki:loki /var/db/loki /var/log/loki
fi
if id promtail >/dev/null 2>&1; then
    chown -R promtail:promtail /var/db/promtail /var/log/promtail
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
if [ -f config/grafana/provisioning/datasources/loki.yml ]; then
    install -m 0644 config/grafana/provisioning/datasources/loki.yml /usr/local/etc/grafana/provisioning/datasources/loki.yml
fi
install -m 0644 config/grafana/provisioning/dashboards/default.yml /usr/local/etc/grafana/provisioning/dashboards/default.yml

for dashboard in config/grafana/provisioning/dashboards/json/*.json; do
    [ -e "$dashboard" ] || continue
    install -m 0644 "$dashboard" /usr/local/etc/grafana/provisioning/dashboards/json/
done

sysrc pf_enable=YES pflog_enable=YES jail_enable=YES >/dev/null
sysrc -x named_enable >/dev/null 2>&1 || true
sysrc -x named_conf >/dev/null 2>&1 || true
sysrc local_unbound_enable=NO >/dev/null
sysrc unbound_enable=YES unbound_conf=/usr/local/etc/unbound/unbound.conf >/dev/null
if [ -x /usr/local/etc/rc.d/kea ]; then
    sysrc kea_enable=YES >/dev/null
elif [ -x /usr/local/etc/rc.d/kea_dhcp4 ]; then
    sysrc kea_dhcp4_enable=YES >/dev/null
fi
[ ! -x /usr/local/etc/rc.d/node_exporter ] || sysrc node_exporter_enable=YES >/dev/null
[ ! -x /usr/local/etc/rc.d/prometheus ] || sysrc prometheus_enable=YES >/dev/null
[ ! -x /usr/local/etc/rc.d/grafana ] || sysrc grafana_enable=YES >/dev/null
if [ "$STORK_ENABLE" = yes ]; then
    sysrc stork_server_enable=YES stork_agent_enable=YES >/dev/null
fi
if [ -x /usr/local/etc/rc.d/loki ]; then
    sysrc loki_enable=YES loki_config=/usr/local/etc/loki.yml >/dev/null
elif [ -x /usr/local/etc/rc.d/grafana_loki ]; then
    sysrc grafana_loki_enable=YES grafana_loki_config=/usr/local/etc/loki.yml >/dev/null
elif [ -x /usr/local/etc/rc.d/grafana-loki ]; then
    sysrc grafana_loki_enable=YES grafana_loki_config=/usr/local/etc/loki.yml >/dev/null
fi
if [ -x /usr/local/etc/rc.d/promtail ]; then
    sysrc promtail_enable=YES promtail_config=/usr/local/etc/promtail.yml >/dev/null
elif [ -x /usr/local/etc/rc.d/grafana_promtail ]; then
    sysrc grafana_promtail_enable=YES grafana_promtail_config=/usr/local/etc/promtail.yml >/dev/null
elif [ -x /usr/local/etc/rc.d/grafana-promtail ]; then
    sysrc grafana_promtail_enable=YES grafana_promtail_config=/usr/local/etc/promtail.yml >/dev/null
fi
if [ -n "${POSTGRES_EXPORTER_DSN}" ] && [ -x /usr/local/etc/rc.d/postgres_exporter ]; then
    sysrc postgres_exporter_enable=YES >/dev/null
fi

install -d -m 0755 /usr/local/jails

for j in postgres kea node_exporter prometheus postgres_exporter grafana loki promtail; do
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

loki {
    ip4.addr = 127.0.0.1;
}

promtail {
    ip4.addr = 127.0.0.1;
}
EOF

echo "[+] Control plane service configurations updated for FreeBSD Jail / container runtime."
