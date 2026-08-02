#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONF="${PF_CONF:-${ROOT}/config/pf.conf}"
HOST_SETUP="${HOST_SETUP:-${ROOT}/scripts/01_host_setup.sh}"
VM_INIT="${VM_INIT:-${ROOT}/scripts/init_vm.sh}"
RC_CONF="${RC_CONF:-${ROOT}/config/rc.conf.example}"

. "${ROOT}/scripts/lib.sh"

[ -r "$HOST_SETUP" ] || die "missing host setup script"
[ -r "$VM_INIT" ] || die "missing vm-bhyve initializer"
[ -r "$RC_CONF" ] || die "missing rc.conf example"

grep -Eq 'ifconfig.*LAN_IF.*mtu.*LAN_MTU' "$HOST_SETUP" || \
    die "host setup does not enforce the configured bridge MTU"
grep -Eq 'ifconfig.*LAN_IF.*mtu.*LAN_MTU' "$VM_INIT" || \
    die "vm-bhyve initialization does not enforce the configured bridge MTU"
grep -Eq '^ifconfig_bridge0="inet 10\.0\.20\.1/24 mtu 1496 up"$' "$RC_CONF" || \
    die "rc.conf does not persist bridge0 MTU 1496"

grep -Eq '^nat on \$ext_if inet from \$lan_net to any -> \(\$ext_if\)$' "$CONF" || \
    die "PF must NAT the VM LAN through the external interface"
grep -Eq '^block in quick on \$lan_if inet from \$lan_net to \$mgmt_net$' "$CONF" || \
    die "PF must isolate the VM LAN from the management network"
grep -Eq '^pass in quick on \$lan_if inet from \$lan_net to any keep state$' "$CONF" || \
    die "PF must permit routed VM LAN traffic"
grep -Eq '^pass in quick on \$lan_if proto tcp from \$lan_net to \(\$mgmt_if\) port 8080 keep state$' "$CONF" || \
    die "PF must expose Stork to the VM LAN"
awk '
    /^pass in quick on \$lan_if proto tcp from \$lan_net to \(\$mgmt_if\) port 8080 keep state$/ {
        stork_allow = NR
    }
    /^block in quick on \$lan_if inet from \$lan_net to self$/ {
        host_block = NR
    }
    END {
        exit !(stork_allow && host_block && stork_allow < host_block)
    }
' "$CONF" || die "PF must allow VM-LAN Stork access before blocking other host services"

command -v pfctl >/dev/null 2>&1 || {
    echo "SKIP: pfctl is available only on FreeBSD; static routing checks passed" >&2
    exit 0
}

pfctl -nf "${CONF}"
echo "PASS: ${CONF}"
