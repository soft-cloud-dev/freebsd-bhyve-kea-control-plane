#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"
require_root

PF_ROLLBACK_TIMEOUT="${PF_ROLLBACK_TIMEOUT:-120}"
KEA_API_USER_FILE="${KEA_API_USER_FILE:-/usr/local/etc/kea/kea-api-user}"
KEA_API_PASSWORD_FILE="${KEA_API_PASSWORD_FILE:-/usr/local/etc/kea/kea-api-password}"

PF_ROLLBACK_TIMEOUT="${PF_ROLLBACK_TIMEOUT}" sh "$(dirname "$0")/apply_pf_safely.sh" apply

if command -v jail >/dev/null 2>&1 && [ -f /etc/jail.conf ]; then
    echo "[*] Starting control plane FreeBSD service jails..."
    for j in postgres kea node_exporter prometheus postgres_exporter grafana loki promtail; do
        install -d -m 0755 "/usr/local/jails/$j/dev"
        container_is_running "$j" || jail -c "$j" 2>/dev/null || service jail start "$j" 2>/dev/null || true
    done
fi

if command -v container >/dev/null 2>&1 && ! command -v jail >/dev/null 2>&1; then
    echo "[*] Starting control plane containerized services..."
    container_is_running kea || container run -d --name kea -p 8000:8000 -v /usr/local/etc/kea:/etc/kea kea:latest || container start kea || true
    container_is_running node-exporter || container run -d --name node-exporter -p 9100:9100 prom/node-exporter:latest || container start node-exporter || true
    container_is_running prometheus || container run -d --name prometheus -p 9090:9090 -v /usr/local/etc/prometheus.yml:/etc/prometheus/prometheus.yml prom/prometheus:latest || container start prometheus || true
    container_is_running postgres-exporter || container run -d --name postgres-exporter -p 9187:9187 prometheuscommunity/postgres-exporter:latest || container start postgres-exporter || true
    container_is_running grafana || container run -d --name grafana -p 3000:3000 -v /usr/local/etc/grafana:/etc/grafana grafana/grafana:latest || container start grafana || true
    container_is_running loki || container run -d --name loki -p 3100:3100 -v /usr/local/etc/loki.yml:/etc/loki/local-config.yaml grafana/loki:latest || container start loki || true
    container_is_running promtail || container run -d --name promtail -v /var/log:/var/log:ro -v /usr/local/etc/promtail.yml:/etc/promtail/config.yml grafana/promtail:latest || container start promtail || true
elif ! command -v container >/dev/null 2>&1 || command -v jail >/dev/null 2>&1; then
    if [ -x /usr/local/etc/rc.d/kea ]; then
        kea_service=kea
    elif [ -x /usr/local/etc/rc.d/kea_dhcp4 ]; then
        kea_service=kea_dhcp4
    else
        kea_service=""
    fi
    [ -z "$kea_service" ] || service "$kea_service" restart 2>/dev/null || service "$kea_service" start 2>/dev/null || true
    [ ! -x /usr/local/etc/rc.d/node_exporter ] || service node_exporter restart 2>/dev/null || service node_exporter start 2>/dev/null || true
    [ ! -x /usr/local/etc/rc.d/prometheus ] || service prometheus restart 2>/dev/null || service prometheus start 2>/dev/null || true
    if [ "$(sysrc -n postgres_exporter_enable 2>/dev/null || true)" = YES ] && [ -x /usr/local/etc/rc.d/postgres_exporter ]; then
        service postgres_exporter restart 2>/dev/null || service postgres_exporter start 2>/dev/null || true
    fi
    [ ! -x /usr/local/etc/rc.d/grafana ] || service grafana restart 2>/dev/null || service grafana start 2>/dev/null || true
    loki_service=""
    if [ -x /usr/local/etc/rc.d/loki ]; then
        loki_service="loki"
    elif [ -x /usr/local/etc/rc.d/grafana_loki ]; then
        loki_service="grafana_loki"
    elif [ -x /usr/local/etc/rc.d/grafana-loki ]; then
        loki_service="grafana-loki"
    fi
    [ -z "$loki_service" ] || service "$loki_service" restart 2>/dev/null || service "$loki_service" start 2>/dev/null || true

    promtail_service=""
    if [ -x /usr/local/etc/rc.d/promtail ]; then
        promtail_service="promtail"
    elif [ -x /usr/local/etc/rc.d/grafana_promtail ]; then
        promtail_service="grafana_promtail"
    elif [ -x /usr/local/etc/rc.d/grafana-promtail ]; then
        promtail_service="grafana-promtail"
    fi
    [ -z "$promtail_service" ] || service "$promtail_service" restart 2>/dev/null || service "$promtail_service" start 2>/dev/null || true
fi

user=$(sed -n '1p' "${KEA_API_USER_FILE}")
password=$(sed -n '1p' "${KEA_API_PASSWORD_FILE}")

i=0
until curl -fsS --user "${user}:${password}" -H 'Content-Type: application/json' -d '{"command":"status-get"}' http://127.0.0.1:8000/ >/dev/null 2>&1; do
    i=$((i+1))
    [ "$i" -lt 15 ] || {
        echo "WARNING: Kea API did not respond on 127.0.0.1:8000 within 15 seconds" >&2
        break
    }
    sleep 1
done

MGMT_ADDR="${MGMT_ADDR:-10.0.10.2}"
if [ -x /usr/local/etc/rc.d/grafana ] || (command -v container >/dev/null 2>&1 && container_is_running grafana); then
    i=0
    until curl -fsS "http://${MGMT_ADDR}:3000/login" >/dev/null 2>&1 || curl -fsS "http://127.0.0.1:3000/login" >/dev/null 2>&1; do
        i=$((i+1))
        [ "$i" -lt 15 ] || {
            echo "WARNING: Grafana did not respond on port 3000 within 15 seconds" >&2
            break
        }
        sleep 1
    done
fi

echo "[+] Service startup sequence completed."

