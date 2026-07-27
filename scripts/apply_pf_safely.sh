#!/bin/sh
# Load PF with an automatic rollback guard for remote installations.
set -eu

MODE="${1:-apply}"
PF_CONF="${PF_CONF:-/etc/pf.conf}"
PF_BACKUP="${PF_BACKUP:-/var/backups/pf.conf.pre-control-plane}"
PF_CONFIRM_FILE="${PF_CONFIRM_FILE:-/var/run/control-plane-pf.confirmed}"
PF_ROLLBACK_PID="${PF_ROLLBACK_PID:-/var/run/control-plane-pf-rollback.pid}"
PF_ROLLBACK_LOG="${PF_ROLLBACK_LOG:-/var/log/control-plane-pf