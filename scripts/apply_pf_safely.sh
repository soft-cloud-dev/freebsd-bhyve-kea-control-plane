#!/bin/sh
# Load PF with an automatic rollback guard for remote installations.
set -eu

MODE="${1:-apply}"
PF_CONF="${PF_CONF:-/etc/pf.conf}"
PF_BACKUP="${PF_BACKUP:-/var/backups/pf.conf.pre-control-plane}"
PF_STATE_DIR="${PF_STATE_DIR:-/var/run/control-plane-pf}"
PF_CONFIRM_FILE="${PF_STATE_DIR}/confirmed"
PF_ROLLBACK_PID="${PF_STATE_DIR}/rollback.pid"
PF_WAS_ENABLED_FILE="${PF_STATE_DIR}/was-enabled"
PF_ROLLBACK_LOG="${PF_ROLLBACK_LOG:-/var/log/control-plane-pf-rollback.log}"
PF_ROLLBACK_TIMEOUT="${PF_ROLLBACK_TIMEOUT:-120}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

pf_is_enabled() {
    pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'
}

stop_worker() {
    if [ -s "${PF_ROLLBACK_PID}" ]; then
        pid=$(sed -n '1p' "${PF_ROLLBACK_PID}")
        case "${pid}" in
            ''|*[!0-9]*) ;;
            *) kill "${pid}" 2>/dev/null || true ;;
        esac
    fi
    rm -f "${PF_ROLLBACK_PID}"
}

restore_previous_state() {
    was_enabled=no
    if [ -s "${PF_WAS_ENABLED_FILE}" ]; then
        was_enabled=$(sed -n '1p' "${PF_WAS_ENABLED_FILE}")
    fi

    if [ "${was_enabled}" = yes ] && [ -s "${PF_BACKUP}" ]; then
        echo "[!] Restoring previous PF configuration" >&2
        install -m 0600 "${PF_BACKUP}" "${PF_CONF}"
        pfctl -nf "${PF_CONF}"
        pfctl -f "${PF_CONF}"
    else
        echo "[!] Disabling PF to restore remote access" >&2
        pfctl -d 2>/dev/null || true
    fi
}

case "${MODE}" in
    apply)
        [ "$(id -u)" -eq 0 ] || die "run as root"
        command -v pfctl >/dev/null 2>&1 || die "pfctl is required"
        command -v nohup >/dev/null 2>&1 || die "nohup is required"
        [ -r "${PF_CONF}" ] || die "PF configuration is not readable: ${PF_CONF}"
        case "${PF_ROLLBACK_TIMEOUT}" in
            ''|*[!0-9]*) die "PF_ROLLBACK_TIMEOUT must be an integer" ;;
        esac
        [ "${PF_ROLLBACK_TIMEOUT}" -ge 30 ] || die "PF_ROLLBACK_TIMEOUT must be at least 30 seconds"

        pfctl -nf "${PF_CONF}"
        install -d -m 0755 "${PF_STATE_DIR}"
        install -d -m 0755 "$(dirname "${PF_BACKUP}")"
        rm -f "${PF_CONFIRM_FILE}"
        stop_worker

        if pf_is_enabled; then
            printf '%s\n' yes > "${PF_WAS_ENABLED_FILE}"
        else
            printf '%s\n' no > "${PF_WAS_ENABLED_FILE}"
        fi

        nohup sh "$0" rollback-after-timeout \
            > "${PF_ROLLBACK_LOG}" 2>&1 < /dev/null &
        printf '%s\n' "$!" > "${PF_ROLLBACK_PID}"

        if pf_is_enabled; then
            pfctl -f "${PF_CONF}"
        else
            pfctl -e -f "${PF_CONF}"
        fi

        pf_is_enabled || {
            restore_previous_state
            stop_worker
            die "PF did not become enabled"
        }

        echo "[+] PF enabled with a ${PF_ROLLBACK_TIMEOUT}-second rollback guard"
        ;;

    confirm)
        [ "$(id -u)" -eq 0 ] || die "run as root"
        install -d -m 0755 "${PF_STATE_DIR}"
        : > "${PF_CONFIRM_FILE}"
        stop_worker
        rm -f "${PF_WAS_ENABLED_FILE}"
        echo "[+] PF activation confirmed"
        ;;

    rollback)
        [ "$(id -u)" -eq 0 ] || die "run as root"
        stop_worker
        restore_previous_state
        rm -f "${PF_CONFIRM_FILE}" "${PF_WAS_ENABLED_FILE}"
        ;;

    rollback-after-timeout)
        sleep "${PF_ROLLBACK_TIMEOUT}"
        [ -e "${PF_CONFIRM_FILE}" ] && exit 0
        echo "[!] PF activation was not confirmed; rolling back" >&2
        restore_previous_state
        rm -f "${PF_ROLLBACK_PID}" "${PF_WAS_ENABLED_FILE}"
        ;;

    *)
        echo "Usage: $0 {apply|confirm|rollback}" >&2
        exit 64
        ;;
esac
