#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"
require_root

STORK_ENABLE="${STORK_ENABLE:-yes}"
STORK_VERSION="${STORK_VERSION:-2.5.0}"
STORK_GIT_COMMIT="${STORK_GIT_COMMIT:-43f1450d1260ce58c2c6c973b72199b6c6592513}"
STORK_SOURCE_DIR="${STORK_SOURCE_DIR:-}"

case "$STORK_ENABLE" in
    yes) ;;
    no)
        echo "[*] Stork installation disabled."
        exit 0
        ;;
    *) die "STORK_ENABLE must be yes or no" ;;
esac

case "$STORK_VERSION" in
    ''|*[!0-9A-Za-z._-]*) die "invalid STORK_VERSION" ;;
esac
case "$STORK_GIT_COMMIT" in
    ''|*[!0-9a-f]*) die "invalid STORK_GIT_COMMIT" ;;
esac

if command -v stork-server >/dev/null 2>&1 && \
    command -v stork-agent >/dev/null 2>&1 && \
    command -v stork-tool >/dev/null 2>&1 && \
    stork-server --version 2>&1 | grep -Fq "${STORK_VERSION}"; then
    echo "[*] Stork ${STORK_VERSION} is already installed."
    exit 0
fi

require_commands git rake

build_tmp=""
if [ -n "$STORK_SOURCE_DIR" ]; then
    [ -d "$STORK_SOURCE_DIR" ] || die "STORK_SOURCE_DIR does not exist: ${STORK_SOURCE_DIR}"
    source_dir="$STORK_SOURCE_DIR"
else
    build_tmp=$(mktemp -d /var/tmp/stork-build.XXXXXX)
    source_dir="${build_tmp}/source"
    trap '[ -z "$build_tmp" ] || rm -rf "$build_tmp"' EXIT HUP INT TERM
    git clone --depth 1 --branch "v${STORK_VERSION}" \
        https://gitlab.isc.org/isc-projects/stork.git "$source_dir"
fi

actual_commit=$(git -C "$source_dir" rev-parse HEAD)
[ "$actual_commit" = "$STORK_GIT_COMMIT" ] || \
    die "Stork source commit ${actual_commit} does not match expected ${STORK_GIT_COMMIT}"

(
    cd "$source_dir"
    rake build:server_dist build:agent_dist
)

server_dist="${source_dir}/dist/server"
agent_dist="${source_dir}/dist/agent"

for artifact in \
    "${server_dist}/usr/local/bin/stork-server" \
    "${server_dist}/usr/local/bin/stork-tool" \
    "${agent_dist}/usr/local/bin/stork-agent"
do
    [ -x "$artifact" ] || die "Stork build artifact is missing: ${artifact}"
done
[ -d "${server_dist}/usr/share/stork/www" ] || die "Stork web UI build is missing"

install -m 0755 "${server_dist}/usr/local/bin/stork-server" /usr/local/bin/stork-server
install -m 0755 "${server_dist}/usr/local/bin/stork-tool" /usr/local/bin/stork-tool
install -m 0755 "${agent_dist}/usr/local/bin/stork-agent" /usr/local/bin/stork-agent

install -d -m 0755 /usr/local/share/stork
cp -R "${server_dist}/usr/share/stork/www" /usr/local/share/stork/

install -d -m 0755 /usr/local/share/man/man8
install -m 0644 "${server_dist}/usr/share/man/man8/stork-server.8" /usr/local/share/man/man8/
install -m 0644 "${server_dist}/usr/share/man/man8/stork-tool.8" /usr/local/share/man/man8/
install -m 0644 "${agent_dist}/usr/share/man/man8/stork-agent.8" /usr/local/share/man/man8/

echo "[+] Stork ${STORK_VERSION} installed from ISC source."
