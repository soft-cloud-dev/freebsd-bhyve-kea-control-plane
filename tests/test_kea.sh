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
DEPROVISION_SCRIPT="${DEPROVISION_SCRIPT:-${ROOT}/scripts/deprovision_vm.sh}"
VM_TEMPLATE="${VM_TEMPLATE:-${ROOT}/templates/vm-bhyve.conf}"
VM_LOADER_MIGRATION_SCRIPT="${VM_LOADER_MIGRATION_SCRIPT:-${ROOT}/scripts/migrate_vm_to_bhyveload.sh}"
FREEBSD_JAIL_PROVISION_SCRIPT="${FREEBSD_JAIL_PROVISION_SCRIPT:-${ROOT}/scripts/provision_freebsd_jail_node.sh}"
FREEBSD_JAIL_CLUSTER_SCRIPT="${FREEBSD_JAIL_CLUSTER_SCRIPT:-${ROOT}/scripts/provision_freebsd_jail_cluster.sh}"
FREEBSD_JAIL_PROFILE="${FREEBSD_JAIL_PROFILE:-${ROOT}/config/cloud-init/freebsd-jail-node.yaml}"

. "${ROOT}/scripts/lib.sh"

[ -r "$KEA_DB_INIT_SCRIPT" ] || die "missing Kea hosts database initializer"
[ -r "$DEPENDENCY_SCRIPT" ] || die "missing dependency installer"
[ -r "$PROVISION_SCRIPT" ] || die "missing VM provisioner"
[ -r "$ROLLBACK_SCRIPT" ] || die "missing VM rollback script"
[ -r "$DEPROVISION_SCRIPT" ] || die "missing VM deprovision script"
[ -r "$VM_TEMPLATE" ] || die "missing vm-bhyve template"
[ -r "$VM_LOADER_MIGRATION_SCRIPT" ] || die "missing VM loader migration script"
[ -r "$FREEBSD_JAIL_PROVISION_SCRIPT" ] || die "missing FreeBSD jail-node provisioner"
[ -r "$FREEBSD_JAIL_CLUSTER_SCRIPT" ] || die "missing FreeBSD jail-cluster provisioner"
[ -r "$FREEBSD_JAIL_PROFILE" ] || die "missing FreeBSD jail-node cloud-init profile"

grep -Eq 'git clone --depth 1 https://git.FreeBSD.org/ports.git' "$DEPENDENCY_SCRIPT" || \
    die "dependency installer does not fetch a ports tree for the Kea fallback build"
grep -Eq 'preserving it and using.*KEA_PORTS_FALLBACK_DIR' "$DEPENDENCY_SCRIPT" || \
    die "dependency installer does not preserve an incomplete primary ports tree"
grep -Eq 'pkg install -y meson.*kea_python_flavor.*-docutils' "$DEPENDENCY_SCRIPT" || \
    die "dependency installer does not use binary Python build tools for Kea"
grep -Eq 'require_commands meson rst2man' "$DEPENDENCY_SCRIPT" || \
    die "dependency installer does not verify the Kea build tools"
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
grep -Eq "status <> 'archived'" "$PROVISION_SCRIPT" || \
    die "VM provisioner does not reject an active inventory name"
preflight_line=$(grep -n 'active_vm=.*psql' "$PROVISION_SCRIPT" | sed -n '1s/:.*//p')
create_line=$(grep -n 'vm create -t' "$PROVISION_SCRIPT" | sed -n '1s/:.*//p')
[ -n "$preflight_line" ] && [ -n "$create_line" ] && [ "$preflight_line" -lt "$create_line" ] || \
    die "VM inventory preflight must run before vm-bhyve creation"
grep -Eq 'delete_result.*-eq 3' "$ROLLBACK_SCRIPT" || \
    die "VM rollback does not tolerate an already-absent Kea reservation"
grep -Eq 'if vm info "\$VM_NAME"' "$ROLLBACK_SCRIPT" || \
    die "VM rollback does not tolerate an already-absent vm-bhyve guest"
grep -Eq 'RETURNING uuid, ip_address, pool_id, vlan' "$PROVISION_SCRIPT" || \
    die "VM provisioner does not retain the inserted inventory UUID"
grep -Eq "DELETE FROM vms WHERE uuid = .*VM_UUID.*::uuid" "$PROVISION_SCRIPT" || \
    die "VM provisioning compensation is not scoped to the inserted inventory UUID"
grep -Eq "WHERE uuid = .*VM_UUID.*::uuid" "$PROVISION_SCRIPT" || \
    die "VM finalization is not scoped to the inserted inventory UUID"
grep -Eq "AND status = 'provisioning'" "$PROVISION_SCRIPT" || \
    die "VM finalization does not require provisioning state"
grep -Eq "WHERE uuid = .*VM_UUID.*::uuid" "$ROLLBACK_SCRIPT" || \
    die "VM rollback is not scoped to the active inventory UUID"
grep -Eq 'exec sh .*rollback_vm.sh.*"\$1"' "$DEPROVISION_SCRIPT" || \
    die "VM deprovision command does not delegate to transactional rollback"
grep -Eq '^loader="bhyveload"$' "$VM_TEMPLATE" || \
    die "FreeBSD vm-bhyve template does not use bhyveload"
grep -Eq 'sysrc -f "\$VM_CONFIG" loader=bhyveload' "$PROVISION_SCRIPT" || \
    die "VM provisioner does not enforce bhyveload independently of the installed template"
loader_line=$(grep -n 'sysrc -f "\$VM_CONFIG" loader=bhyveload' "$PROVISION_SCRIPT" | sed -n '1s/:.*//p')
start_line=$(grep -n 'vm start "\$VM_NAME"$' "$PROVISION_SCRIPT" | sed -n '1s/:.*//p')
[ -n "$loader_line" ] && [ -n "$start_line" ] && [ "$loader_line" -lt "$start_line" ] || \
    die "VM provisioner must enforce bhyveload before first start"
grep -Eq 'cp -p "\$config_backup" "\$VM_CONFIG"' "$VM_LOADER_MIGRATION_SCRIPT" || \
    die "VM loader migration does not restore its configuration backup on failure"
grep -Eq 'CLOUD_INIT_EXTRA_FILE=.*PROFILE_FILE' "$FREEBSD_JAIL_PROVISION_SCRIPT" || \
    die "FreeBSD jail-node provisioner does not attach its cloud-init profile"
grep -Eq 'provision_vm.sh.*freebsd' "$FREEBSD_JAIL_PROVISION_SCRIPT" || \
    die "FreeBSD jail-node provisioner does not use the bhyveload FreeBSD profile"
grep -Eq 'wireguard-tools' "$FREEBSD_JAIL_PROFILE" || \
    die "FreeBSD jail-node profile does not install WireGuard tooling"
grep -Eq 'jail_enable=YES' "$FREEBSD_JAIL_PROFILE" || \
    die "FreeBSD jail-node profile does not enable native jails"
grep -Eq 'kld_list\+=if_wg' "$FREEBSD_JAIL_PROFILE" || \
    die "FreeBSD jail-node profile does not persist the WireGuard kernel module"
grep -Eq 'CLOUD_INIT_EXTRA_FILE' "$PROVISION_SCRIPT" || \
    die "VM provisioner does not support a cloud-init extension"
grep -Eq 'JAIL_NODE_COUNT.*:-3' "$FREEBSD_JAIL_CLUSTER_SCRIPT" || \
    die "FreeBSD jail-cluster provisioner does not default to three nodes"
grep -Eq "printf '%02d'" "$FREEBSD_JAIL_CLUSTER_SCRIPT" || \
    die "FreeBSD jail-cluster provisioner does not use stable two-digit node names"
preflight_loop=$(grep -n 'active_count=.*psql' "$FREEBSD_JAIL_CLUSTER_SCRIPT" | sed -n '1s/:.*//p')
provision_loop=$(grep -n '^provisioned_names=' "$FREEBSD_JAIL_CLUSTER_SCRIPT" | sed -n '1s/:.*//p')
[ -n "$preflight_loop" ] && [ -n "$provision_loop" ] && [ "$preflight_loop" -lt "$provision_loop" ] || \
    die "FreeBSD jail-cluster inventory preflight must complete before provisioning"
jq -e '
    .Dhcp4.subnet4[0]["option-data"]
    | any(.name == "interface-mtu" and .data == "1496")
' "$DHCP4_CONF" >/dev/null || \
    die "Kea does not advertise the bridge MTU to VM guests"

preflight_dir=$(mktemp -d)
trap 'rm -rf "$preflight_dir"' EXIT HUP INT TERM
mock_bin="${preflight_dir}/bin"
mkdir "$mock_bin"

for mock_command in curl jq mktemp sysrc zfs; do
    printf '#!/bin/sh\nexit 99\n' > "${mock_bin}/${mock_command}"
    chmod +x "${mock_bin}/${mock_command}"
done
cat > "${mock_bin}/id" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-u" ] && {
    printf '0\n'
    exit 0
}
exit 99
EOF
cat > "${mock_bin}/psql" <<'EOF'
#!/bin/sh
printf '%s\n' 'running|10.0.20.10|58:9c:fc:0b:cb:64|zroot/vm/db-node-01'
EOF
cat > "${mock_bin}/vm" <<'EOF'
#!/bin/sh
[ "$#" -gt 0 ] && printf '%s\n' "$*" >> "$VM_CALL_LOG"
[ "${1:-}" = "info" ] && exit 1
exit 99
EOF
chmod +x "${mock_bin}/id" "${mock_bin}/psql" "${mock_bin}/vm"

if PATH="${mock_bin}:${PATH}" \
    VM_CALL_LOG="${preflight_dir}/vm-called" \
    sh "$PROVISION_SCRIPT" db-node-01 freebsd \
    >"${preflight_dir}/output" 2>&1; then
    die "VM provisioner accepted an active inventory name"
fi
grep -q "stale active inventory row" "${preflight_dir}/output" || \
    die "VM provisioner did not identify an inventory row without a vm-bhyve guest"
if [ -e "${preflight_dir}/vm-called" ]; then
    ! grep -q '^create ' "${preflight_dir}/vm-called" || \
        die "VM provisioner created a guest before rejecting the active inventory name"
fi

rm -rf "$preflight_dir"
trap - EXIT HUP INT TERM

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
