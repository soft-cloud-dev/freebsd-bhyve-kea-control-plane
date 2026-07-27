#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"
require_root

PF_ROLLBACK_TIMEOUT="${PF_ROLLBACK_TIMEOUT:-120}"
KEA_API_USER_FILE="${KEA_API_USER_FILE:-/usr/local/etc/kea/kea-api-user}"
KEA_API_PASSWORD_FILE="${KEA_API_PASSWORD_FILE:-/usr/local/etc/kea/kea-api-password}"

PF_ROLLBACK_TIMEOUT="${PF_ROLLBACK_TIMEOUT}" sh "$(dirname "$0")/apply_pf_safely.sh" apply

if [ -x /usr/local/etc/rc.d/kea ]; then
    kea_service=kea
elif [ -x /usr/local/etc/rc.d/kea_dhcp4 ]; then
    kea_service=kea_dhcp4
else
    die "no Kea rc service found in /usr/local/etc/rc.d"
fi

service "$kea_service" restart 2>/dev/null || service "$kea_service" start
service node_exporter restart 2>/dev/null || service node_exporter start
service prometheus restart 2>/dev/null || service prometheus start

if [ "$(sysrc -n postgres_exporter_enable 2>/dev/null || true)" = YES ]; then
    service postgres_exporter restart 2>/dev/null || service postgres_exporter start
fi

service grafana restart 2>/dev/null || service grafana start

user=$(sed -n '1p' "${KEA_API_USER_FILE}")
password=$(sed -n '1p' "${KEA_API_PASSWORD_FILE}")

i=0
until curl -fsS --user "${user}:${password}" -H 'Content-Type: application/json' -d '{"command":"status-get"}' http://127.0.0.1:8000/ >/dev/null; do
    i=$((i+1))
    [ "$i" -lt 15 ] || die "Kea API did not become ready"
    sleep 1
done
