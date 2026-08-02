#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROMETHEUS_CONF="${PROMETHEUS_CONF:-${ROOT}/config/prometheus.yml}"
GRAFANA_CONF="${GRAFANA_CONF:-${ROOT}/config/grafana.ini}"
DATASOURCE_CONF="${DATASOURCE_CONF:-${ROOT}/config/grafana/provisioning/datasources/prometheus.yml}"
LOKI_CONF="${LOKI_CONF:-${ROOT}/config/loki.yml}"
LOKI_DATASOURCE_CONF="${LOKI_DATASOURCE_CONF:-${ROOT}/config/grafana/provisioning/datasources/loki.yml}"
PROMTAIL_CONF="${PROMTAIL_CONF:-${ROOT}/config/promtail.yml}"
DASHBOARD_PROVIDER="${DASHBOARD_PROVIDER:-${ROOT}/config/grafana/provisioning/dashboards/default.yml}"
DASHBOARD_DIR="${DASHBOARD_DIR:-${ROOT}/config/grafana/provisioning/dashboards/json}"
GRAFANA_HEALTH_URL="${GRAFANA_HEALTH_URL:-http://10.0.10.2:3000/api/health}"
ALERTS_CONF="${ALERTS_CONF:-${ROOT}/config/alerts.yml}"
DEPENDENCY_SCRIPT="${DEPENDENCY_SCRIPT:-${ROOT}/scripts/02_install_dependencies.sh}"
CONFIGURE_SCRIPT="${CONFIGURE_SCRIPT:-${ROOT}/scripts/configure_services.sh}"
START_SCRIPT="${START_SCRIPT:-${ROOT}/scripts/start_services.sh}"

. "${ROOT}/scripts/lib.sh"

for file in \
    "$PROMETHEUS_CONF" \
    "$ALERTS_CONF" \
    "$GRAFANA_CONF" \
    "$DATASOURCE_CONF" \
    "$LOKI_CONF" \
    "$LOKI_DATASOURCE_CONF" \
    "$PROMTAIL_CONF" \
    "$DASHBOARD_PROVIDER" \
    "$DEPENDENCY_SCRIPT" \
    "$CONFIGURE_SCRIPT" \
    "$START_SCRIPT"
do
    [ -r "$file" ] || die "missing or unreadable file: $file"
done

[ -d "$DASHBOARD_DIR" ] || die "missing dashboard directory: $DASHBOARD_DIR"

grep -q '127\.0\.0\.1:9090' "$PROMETHEUS_CONF" || \
    die "Prometheus self target is not loopback-bound"
grep -q '127\.0\.0\.1:9100' "$PROMETHEUS_CONF" || \
    die "node_exporter target is not loopback-bound"
grep -q '127\.0\.0\.1:9187' "$PROMETHEUS_CONF" || \
    die "postgres_exporter target is not loopback-bound"
grep -q 'alerts\.yml' "$PROMETHEUS_CONF" || \
    die "Prometheus configuration missing alerts.yml rule file reference"
grep -q 'http_listen_port:[[:space:]]*3100' "$LOKI_CONF" || \
    die "Loki HTTP listen port is not configured to 3100"
grep -q 'url:[[:space:]]*http://127\.0\.0\.1:3100/loki/api/v1/push' "$PROMTAIL_CONF" || \
    die "Promtail client push URL does not target loopback Loki"
grep -A20 'pkg install -y' "$DEPENDENCY_SCRIPT" | grep -q 'postgres_exporter' || \
    die "dependency installer does not install postgres_exporter"
grep -Eq 'pkg install -y[[:space:]]+grafana-loki' "$DEPENDENCY_SCRIPT" || \
    die "dependency installer does not install the FreeBSD grafana-loki package"
grep -q 'POSTGRES_EXPORTER_DSN=' "$CONFIGURE_SCRIPT" || \
    die "configure_services.sh missing POSTGRES_EXPORTER_DSN configuration"
grep -Eq 'sysrc loki_enable=YES loki_config=/usr/local/etc/loki\.yml' "$CONFIGURE_SCRIPT" || \
    die "Loki rc service is not configured to use /usr/local/etc/loki.yml"
grep -Eq 'sysrc promtail_enable=YES promtail_config=/usr/local/etc/promtail\.yml' "$CONFIGURE_SCRIPT" || \
    die "Promtail rc service is not configured to use /usr/local/etc/promtail.yml"
grep -q 'http://127\.0\.0\.1:3100/ready' "$START_SCRIPT" || \
    die "service startup does not check Loki readiness"
grep -q 'LOKI_READY_TIMEOUT="${LOKI_READY_TIMEOUT:-60}"' "$START_SCRIPT" || \
    die "service startup does not allow enough time for Loki readiness"

grep -Eq '^[[:space:]]*allow_sign_up[[:space:]]*=[[:space:]]*false[[:space:]]*$' "$GRAFANA_CONF" || \
    die "Grafana user sign-up is not disabled"
grep -A2 '^\[auth\.anonymous\]' "$GRAFANA_CONF" | \
    grep -Eq '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*false[[:space:]]*$' || \
    die "Grafana anonymous authentication is not disabled"
grep -A3 '^\[plugins\]' "$GRAFANA_CONF" | \
    grep -Eq '^[[:space:]]*preinstall_disabled[[:space:]]*=[[:space:]]*true[[:space:]]*$' || \
    die "Grafana plugin preinstallation is not disabled"
grep -A3 '^\[plugins\]' "$GRAFANA_CONF" | \
    grep -Eq '^[[:space:]]*disable_plugins[[:space:]]*=[[:space:]]*.*elasticsearch.*$' || \
    die "Grafana elasticsearch plugin is not disabled"

grep -q 'url:[[:space:]]*http://127\.0\.0\.1:9090' "$DATASOURCE_CONF" || \
    die "Grafana datasource does not use loopback Prometheus"
grep -q 'url:[[:space:]]*http://127\.0\.0\.1:3100' "$LOKI_DATASOURCE_CONF" || \
    die "Grafana datasource does not use loopback Loki"

grep -q 'path:[[:space:]]*/usr/local/etc/grafana/provisioning/dashboards/json' "$DASHBOARD_PROVIDER" || \
    die "Grafana dashboard provider path is incorrect"

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
            die "invalid Grafana dashboard: $dashboard"
        case "$dashboard" in
            *overview*)
                grep -q 'node_network_receive_bytes_total' "$dashboard" || \
                    die "Grafana dashboard missing network metrics: $dashboard"
                grep -q 'node_cpu_seconds_total' "$dashboard" || \
                    die "Grafana dashboard missing CPU metrics: $dashboard"
                grep -q 'Kea exporter' "$dashboard" || \
                    die "Grafana dashboard missing Kea exporter status panel: $dashboard"
                ;;
            *logs*)
                grep -q 'count_over_time' "$dashboard" || \
                    die "Grafana log dashboard missing count_over_time queries: $dashboard"
                ;;
        esac
    done
    [ "$found" -eq 1 ] || die "no Grafana dashboard JSON files found"
else
    echo "SKIP: jq is not installed; dashboard JSON was not parsed" >&2
fi

if (command -v service >/dev/null 2>&1 && [ -x /usr/local/etc/rc.d/grafana ]) || (command -v container >/dev/null 2>&1 && container_is_running grafana); then
    ready=0
    for i in $(seq 1 15); do
        response=$(fetch -qo- "$GRAFANA_HEALTH_URL" 2>/dev/null || curl -fsS "$GRAFANA_HEALTH_URL" 2>/dev/null || true)
        if [ -n "$response" ] && printf '%s' "$response" | jq -e '.database == "ok"' >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 1
    done
    [ "$ready" -eq 1 ] || die "Grafana health check failed on $GRAFANA_HEALTH_URL"
fi

echo "PASS: observability configuration"
