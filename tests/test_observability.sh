#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROMETHEUS_CONF="${PROMETHEUS_CONF:-${ROOT}/config/prometheus.yml}"
GRAFANA_CONF="${GRAFANA_CONF:-${ROOT}/config/grafana.ini}"
DATASOURCE_CONF="${DATASOURCE_CONF:-${ROOT}/config/grafana/provisioning/datasources/prometheus.yml}"
DASHBOARD_PROVIDER="${DASHBOARD_PROVIDER:-${ROOT}/config/g