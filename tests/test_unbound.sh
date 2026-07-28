#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UNBOUND_TEMPLATE="${UNBOUND_TEMPLATE:-${ROOT}/config/unbound.conf.in}"
PF_CONF="${PF_CONF:-${ROOT}/config/pf.conf}"
INSTALL_SCRIPT="${INSTALL_SCRIPT:-${ROOT}/scripts/02_install_dependencies.sh}"
START_SCRIPT="${START_SCRIPT:-${ROOT}/scripts/start_services.sh}"
DNS_ADDR="${DNS_ADDR:-10.0.20.1}"
LAN_NET="${LAN_NET:-10.0.20.0/24}"

. "${ROOT}/scripts/lib.sh"

unbound_tmp=$(mktemp)
root_key_tmp=$(mktemp)
trap 'rm -f "$unbound_tmp" "$root_key_tmp"' EXIT HUP INT TERM

sed -e "s|@DNS_ADDR@|${DNS_ADDR}|g" \
    -e "s|@LAN_NET@|${LAN_NET}|g" \
    -e "s|@UNBOUND_CHROOT@||g" \
    -e "s|@UNBOUND_USERNAME@||g" \
    -e "s|@UNBOUND_ROOT_KEY_FILE@|${root_key_tmp}|g" \
    "$UNBOUND_TEMPLATE" > "$unbound_tmp"

grep -Fq "interface: ${DNS_ADDR}" "$unbound_tmp"
grep -Fq "access-control: ${LAN_NET} allow" "$unbound_tmp"
grep -Fq "access-control: 0.0.0.0/0 refuse" "$unbound_tmp"
grep -Fq "do-ip6: no" "$unbound_tmp"
grep -Fq "auto-trust-anchor-file:" "$unbound_tmp"
grep -Eq 'proto \{ tcp udp \}.*port 53' "$PF_CONF"
grep -Fq "pkg install -y unbound" "$INSTALL_SCRIPT"
grep -Fq "service unbound restart" "$START_SCRIPT"
if grep -Eq 'pkg install -y bind(918|920)' "$INSTALL_SCRIPT"; then
    die "the dependency stage still installs a BIND server package"
fi

if command -v unbound-checkconf >/dev/null 2>&1 && \
    command -v unbound-anchor >/dev/null 2>&1
then
    unbound-anchor -a "$root_key_tmp" >/dev/null 2>&1 || \
        [ -s "$root_key_tmp" ] || \
        die "unbound-anchor did not create a root trust anchor"
    unbound-checkconf "$unbound_tmp"
else
    echo "SKIP: Unbound tools are unavailable; static checks passed" >&2
fi

echo "PASS: Unbound listens on ${DNS_ADDR} for ${LAN_NET}"
