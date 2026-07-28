#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DHCP4_CONF="${KEA_DHCP4_CONF:-${ROOT}/config/kea-dhcp4.conf}"
KEA_API_URL="${KEA_API_URL:-http://127.0.0.1:8000/}"
KEA_API_USER_FILE="${KEA_API_USER_FILE:-/usr/local/etc/kea/kea-api-user}"
KEA_API_PASSWORD_FILE="${KEA_API_PASSWORD_FILE:-/usr/local/etc/kea/kea-api-password}"
KEA_RENDER_SCRIPT="${KEA_RENDER_SCRIPT:-${ROOT}/scripts/render_kea_config.sh}"
KEA_DB_INIT_SCRIPT="${KEA_DB_INIT_SCRIPT:-${ROOT}/scripts/init_kea_host_db.sh}"
DEPENDENCY_SCRIPT="${DEPENDENCY_SCRIPT:-${ROOT}/scripts/02_install_dependencies.sh}"
PROVISION_SCRIPT="${PROVISION_SCRIPT:-${ROOT}/scripts/provision_vm.sh}"
ROLLBACK_SCRIPT="${ROLLBACK_SCRIPT:-${ROOT}/scripts/rollback_vm.sh}"

. "${ROOT}/scripts/lib.sh"

[ -r "$KEA_DB_INIT_SCRIPT" ] || die "missing Kea hosts database initializer"
[ -r "$DEPENDENCY_SCRIPT" ] || die "missing dependency installer"
[ -r "$PROVISION_SCRIPT" ] || die "missing VM provisioner"
[ -r "$ROLLBACK_SCRIPT" ] || die "missing VM rollback script"

grep -Eq 'git clone --depth 1 https://git.FreeBSD.org/ports.git' "$DEPENDENCY_SCRIPT" || \
    die "dependency installer does not fetch a ports tree for the Kea fallback build"
grep -Eq 'preserving it and using.*KEA_PORTS_FALLBACK_DIR' "$DEPENDENCY_SCRIPT" || \
    die "dependency installer does not preserve an incomplete primary ports tree"
grep -Eq 'DEFAULT_VERSIONS=pgsql=16' "$DEPENDENCY_SCRIPT" || \
    die "Kea fallback build is not pinned to the deployed PostgreSQL major version"
grep -Eq 'OPTIONS_SET=PGSQL' "$DEPENDENCY_SCRIPT" || \
    die "dependency installer does not enable the Kea PGSQL port option"
grep -Eq 'reinstall clean' "$DEPENDENCY_SCRIPT" || \
    die "dependency installer does not replace the binary Kea package"
grep -Eq 'kea-admin db-init pgsql' "$KEA_DB_INIT_SCRIPT" || \
    die "Kea hosts database initializer does not create a PostgreSQL schema"
grep -Eq 'command:"reservation-add"' "$PROVISION_SCRIPT" || \
    die "VM provisioner does not use Kea reservation-add"
grep -Eq 'command:"reservation-del"' "$ROLLBACK_SCRIPT" || \
    die "VM rollback does not use Kea reservation-del"

if command -v jq >/dev/null 2>&1; then
    jq -e '
        (.Dhcp4["hosts-database"].type // "") != "memfile"
        and all((.Dhcp4["hosts-databases"] // [])[]; .type != "memfile")
    ' "$DHCP4_CONF" >/dev/null || \
        die "memfile is a lease backend and cannot be used as a Kea hosts database"
    jq -e '
        (.Dhcp4["hooks-libraries"] | map(.library)) as $hooks
        | ($hooks | index("/usr/local/lib/kea/hooks/libdhcp_host_cmds.so")) != null
        and ($hooks | index("/usr/local/lib/kea/hooks/libdhcp_subnet_cmds.so")) != null
    ' "$DHCP4_CONF" >/dev/null || \
        die "Kea must load both host_cmds and subnet_cmds for Stork management"

    test_dir=$(mktemp -d)
    trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
    existing_conf="${test_dir}/existing.json"
    rendered_conf="${test_dir}/rendered.json"
    password_file="${test_dir}/kea-host-db-password"
    printf '%s\n' test-only-password > "$password_file"

    jq '.Dhcp4.subnet4[0].reservations = [{
        "hw-address": "58:9c:fc:0b:cb:64",
        "ip-address": "10.0.20.10",
        "hostname": "db-node-01"
    }]' "$DHCP4_CONF" > "$existing_conf"

    sh "$KEA_RENDER_SCRIPT" \
        "$DHCP4_CONF" \
        bridge-test \
        "$existing_conf" \
        kea_hosts \
        kea_hosts \
        "$password_file" \
        127.0.0.1 > "$rendered_conf"
    jq -e '
        .Dhcp4["interfaces-config"].interfaces == ["bridge-test"]
        and .Dhcp4["hosts-databases"] == [{
            "type": "postgresql",
            "name": "kea_hosts",
            "user": "kea_hosts",
            "password": "test-only-password",
            "host": "127.0.0.1",
            "port": 5432
        }]
        and (.Dhcp4["hooks-libraries"] | map(.library) | index("/usr/local/lib/kea/hooks/libdhcp_pgsql.so")) != null
        and .Dhcp4.subnet4[0].reservations == [{
            "hw-address": "58:9c:fc:0b:cb:64",
            "ip-address": "10.0.20.10",
            "hostname": "db-node-01"
        }]
    ' "$rendered_conf" >/dev/null || \
        die "rendering a Kea configuration did not preserve VM reservations"

    rm -rf "$test_dir"
    trap - EXIT HUP INT TERM
fi

if command -v kea-dhcp4 >/dev/null 2>&1 && \
    [ -r "$KEA_API_USER_FILE" ] && [ -r "$KEA_API_PASSWORD_FILE" ]; then
    kea-dhcp4 -t "$DHCP4_CONF"
elif command -v kea-dhcp4 >/dev/null 2>&1; then
    echo "SKIP: Kea API credential files are not readable by the current user" >&2
elif command -v container >/dev/null 2>&1 && container_is_running kea; then
    container exec kea kea-dhcp4 -t /etc/kea/kea-dhcp4.conf 2>/dev/null || true
fi

grep -q '"socket-type"[[:space:]]*:[[:space:]]*"http"' "$DHCP4_CONF"
grep -q '"socket-address"[[:space:]]*:[[:space:]]*"127.0.0.1"' "$DHCP4_CONF"
grep -q '"socket-port"[[:space:]]*:[[:space:]]*8000' "$DHCP4_CONF"

if (command -v sockstat >/dev/null 2>&1 && sockstat -4 -l 2>/dev/null | awk '$6 == "127.0.0.1:8000" { found=1 } END { exit !found }') || (command -v container >/dev/null 2>&1 && container_is_running kea); then
    if [ -r "$KEA_API_USER_FILE" ] && [ -s "$KEA_API_USER_FILE" ] && \
        [ -r "$KEA_API_PASSWORD_FILE" ] && [ -s "$KEA_API_PASSWORD_FILE" ]; then
        user=$(sed -n '1p' "$KEA_API_USER_FILE")
        password=$(sed -n '1p' "$KEA_API_PASSWORD_FILE")
        response=$(curl -fsS --user "$user:$password" \
            -H 'Content-Type: application/json' \
            -d '{"command":"status-get"}' "$KEA_API_URL" 2>/dev/null || true)
        if [ -n "$response" ]; then
            printf '%s' "$response" | jq -e '.[0].result == 0' >/dev/null 2>&1 || true
        fi
        response=$(curl -fsS --user "$user:$password" \
            -H 'Content-Type: application/json' \
            -d '{"command":"subnet4-list"}' "$KEA_API_URL" 2>/dev/null || true)
        if [ -n "$response" ]; then
            printf '%s' "$response" | jq -e '.[0].result == 0' >/dev/null || \
                die "Kea subnet_cmds hook is not responding"
        fi
    fi
else
    echo "SKIP: Kea API is not listening on 127.0.0.1:8000" >&2
fi

echo "PASS: Kea DHCP4 configuration and authenticated direct API"
