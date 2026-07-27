#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROMETHEUS_CONF="${PROMETHEUS_CONF:-${ROOT}/config/prometheus.yml}"
GRAFANA_CONF="${GRAFANA_CONF:-${ROOT}/config/grafana.ini}"
DATASOURCE_CONF="${DATASOURCE_CONF:-${ROOT}/config/grafana/provisioning/datasources/prometheus.yml}"
DASHBOARD_PROVIDER="${DASHBOARD_PROVIDER:-${ROOT}/config/grafana/provisioning/dashboards/default.yml}"
DASHBOARD_DIR="${DASHBOARD_DIR:-${ROOT}/config/grafana/provisioning/dashboards/json}"
<<<<<<< HEAD
GRAFANA_HEALTH_URL="${GRAFANA_HEALTH_URL:-http://10.0.10.2:3000/api/health}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for file in \
    "$PROMETHEUS_CONF" \
    "$GRAFANA_CONF" \
    "$DATASOURCE_CONF" \
    "$DASHBOARD_PROVIDER"
do
    [ -r "$file" ] || fail "missing or unreadable file: $file"
done

grep -q '127\.0\.0\.1:9090' "$PROMETHEUS_CONF" || \
    fail "Prometheus self target is not loopback-bound"
grep -q '127\.0\.0\.1:9100' "$PROMETHEUS_CONF" || \
    fail "node_exporter target is not loopback-bound"
grep -q '127\.0\.0\.1:9187' "$PROMETHEUS_CONF" || \
    fail "postgres_exporter target is not loopback-bound"

grep -Eq '^[[:space:]]*allow_sign_up[[:space:]]*=[[:space:]]*false[[:space:]]*$' "$GRAFANA_CONF" || \
    fail "Grafana user sign-up is not disabled"
grep -A2 '^\[auth\.anonymous\]' "$GRAFANA_CONF" | \
    grep -Eq '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*false[[:space:]]*$' || \
    fail "Grafana anonymous authentication is not disabled"

grep -q 'url:[[:space:]]*http://127\.0\.0\.1:9090' "$DATASOURCE_CONF" || \
    fail "Grafana datasource does not use loopback Prometheus"

grep -q 'path:[[:space:]]*/usr/local/etc/grafana/provisioning/dashboards/json' "$DASHBOARD_PROVIDER" || \
    fail "Grafana dashboard provider path is incorrect"

if command -v promtool >/dev/null 2>&1; then
    promtool check config "$PROMETHEUS_CONF"
else
    echo "SKIP: promtool is not installed" >&2
fi

if command -v jq >/dev/null 2>&1; then
    found=0
    for dashboard in "$DASHBOARD_DIR"/*.json; do
        [ -e "$dashboard" ] || continue
        found=1
        jq -e '.title and .uid and (.panels | type == "array")' "$dashboard" >/dev/null || \
            fail "invalid Grafana dashboard: $dashboard"
    done
    [ "$found" -eq 1 ] || fail "no Grafana dashboard JSON files found"
else
    echo "SKIP: jq is not installed; dashboard JSON was not parsed" >&2
fi

if command -v service >/dev/null 2>&1 && [ -x /usr/local/etc/rc.d/grafana ]; then
    service grafana status >/dev/null 2>&1 || fail "Grafana service is not running"
    response=$(fetch -qo- "$GRAFANA_HEALTH_URL") || fail "Grafana health endpoint is unreachable"
    printf '%s' "$response" | jq -e '.database == "ok"' >/dev/null || \
        fail "Grafana database health is not ok"
fi

echo "PASS: observability configuration and runtime"
=======

for file in "$PROMETHEUS_CONF" "$GRAFANA_CONF" "$DATASOURCE_CONF" "$DASHBOARD_PROVIDER"; do
    [ -s "$file" ] || {
        echo "ERROR: missing or empty config file: $file" >&2
        exit 1
    }
done

[ -d "$DASHBOARD_DIR" ] || {
    echo "ERROR: missing dashboard directory: $DASHBOARD_DIR" >&2
    exit 1
}

if command -v promtool >/dev/null 2>&1; then
    promtool check config "$PROMETHEUS_CONF"
fi

if command -v jq >/dev/null 2>&1; then
    for json_file in "$DASHBOARD_DIR"/*.json; do
        [ -e "$json_file" ] || continue
        jq empty "$json_file" || {
            echo "ERROR: invalid JSON in $json_file" >&2
            exit 1
        }
    done
fi

grep -q '^\[server\]' "$GRAFANA_CONF"
grep -q 'http_port[[:space:]]*=[[:space:]]*3000' "$GRAFANA_CONF"

echo "PASS: Observability configuration"
>>>>>>> a83a865 (Fix multiple)
