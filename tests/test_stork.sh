#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

. "${ROOT}/scripts/lib.sh"

SERVER_TEMPLATE="${ROOT}/config/stork/server.env.in"
AGENT_TEMPLATE="${ROOT}/config/stork/agent.env.in"
SERVER_RC="${ROOT}/config/rc.d/stork_server"
AGENT_RC="${ROOT}/config/rc.d/stork_agent"
INSTALL_SCRIPT="${ROOT}/scripts/install_stork.sh"
INSTALL_PACKAGES_SCRIPT="${ROOT}/scripts/install_stork_agent_packages.sh"
INIT_SCRIPT="${ROOT}/scripts/init_stork.sh"
CONFIGURE_SCRIPT="${ROOT}/scripts/configure_services.sh"
START_SCRIPT="${ROOT}/scripts/start_services.sh"
PROMETHEUS_CONF="${ROOT}/config/prometheus.yml"

for file in \
    "$SERVER_TEMPLATE" "$AGENT_TEMPLATE" "$SERVER_RC" "$AGENT_RC" \
    "$INSTALL_SCRIPT" "$INSTALL_PACKAGES_SCRIPT" "$INIT_SCRIPT" "$CONFIGURE_SCRIPT" "$START_SCRIPT" \
    "$PROMETHEUS_CONF"
do
    [ -r "$file" ] || die "missing or unreadable Stork file: $file"
done

grep -q '^STORK_REST_HOST=@MGMT_ADDR@$' "$SERVER_TEMPLATE" || \
    die "Stork UI does not advertise its canonical management address"
grep -q '^STORK_REST_PORT=8080$' "$SERVER_TEMPLATE" || \
    die "Stork UI port is not 8080"
grep -q '^STORK_DATABASE_PASSWORD=@STORK_DB_PASSWORD@$' "$SERVER_TEMPLATE" || \
    die "Stork database password is not rendered from the protected secret"
grep -q '^STORK_AGENT_HOST=127\.0\.0\.1$' "$AGENT_TEMPLATE" || \
    die "Stork agent control listener is not loopback-bound"
grep -q '^STORK_AGENT_PORT=8081$' "$AGENT_TEMPLATE" || \
    die "Stork agent must avoid the server's port 8080"
grep -q '^STORK_AGENT_PROMETHEUS_KEA_EXPORTER_ADDRESS=127\.0\.0\.1$' "$AGENT_TEMPLATE" || \
    die "Stork Kea exporter is not loopback-bound"
grep -q '^STORK_AGENT_HOOK_DIRECTORY=/usr/local/lib/stork-agent/hooks$' "$AGENT_TEMPLATE" || \
    die "Stork agent hook directory does not follow the FreeBSD local prefix"
grep -q '^STORK_SERVER_HOOK_DIRECTORY=/usr/local/lib/stork-server/hooks$' "$SERVER_TEMPLATE" || \
    die "Stork server hook directory does not follow the FreeBSD local prefix"
grep -q 'procname="/usr/sbin/daemon"' "$SERVER_RC" || \
    die "Stork server rc.d supervision PID is checked against the wrong process"
grep -q 'procname="/usr/sbin/daemon"' "$AGENT_RC" || \
    die "Stork agent rc.d supervision PID is checked against the wrong process"
if grep -q '^stork_server_program=' "$SERVER_RC"; then
    die "stork_server_program overrides rc.subr's daemon command"
fi
if grep -q '^stork_agent_program=' "$AGENT_RC"; then
    die "stork_agent_program overrides rc.subr's daemon command"
fi
grep -q '^stork_server_binary="/usr/local/bin/stork-server"$' "$SERVER_RC" || \
    die "Stork server binary is not assigned without an rc.subr override"
grep -q '^stork_agent_binary="/usr/local/bin/stork-agent"$' "$AGENT_RC" || \
    die "Stork agent binary is not assigned without an rc.subr override"
if grep -Eq '^(STORK_LOG_LEVEL|CLICOLOR)=' "$SERVER_TEMPLATE" "$AGENT_TEMPLATE"; then
    die "unsupported logging variables are present in a Stork environment file"
fi
grep -q '127\.0\.0\.1:9547' "$PROMETHEUS_CONF" || \
    die "Prometheus does not scrape the Stork Kea exporter"

grep -q 'https://gitlab\.isc\.org/isc-projects/stork\.git' "$INSTALL_SCRIPT" || \
    die "Stork installer does not use the official ISC source"
grep -q 'STORK_VERSION="${STORK_VERSION:-2\.5\.0}"' "$INSTALL_SCRIPT" || \
    die "Stork installer does not pin the supported version"
grep -q 'https://dl\.cloudsmith\.io/public/isc/stork-dev/' "$INSTALL_PACKAGES_SCRIPT" || \
    die "Stork agent package installer does not use ISC Cloudsmith"
grep -q 'sha256 -q' "$INSTALL_PACKAGES_SCRIPT" || \
    die "Stork agent package installer does not verify package checksums"
grep -q 'STORK_AGENT_PACKAGE_ARCH.*amd64.*arm64' "$INSTALL_PACKAGES_SCRIPT" || \
    die "Stork agent package installer does not constrain package architecture"
for package_extension in deb rpm apk; do
    grep -q "isc-stork-agent.*\\.${package_extension}" "$INSTALL_PACKAGES_SCRIPT" || \
        die "Stork agent package installer is missing ${package_extension} support"
done
grep -q 'install_stork_agent_packages\.sh' "$INSTALL_SCRIPT" || \
    die "Stork source installer does not populate its Linux package directory"
grep -q 'KEA_API_USER="${KEA_API_USER:-stork-control-plane}"' "$CONFIGURE_SCRIPT" || \
    die "default Kea API username is not discoverable by the Stork agent"
grep -q 'CREATE EXTENSION IF NOT EXISTS pgcrypto' "$INIT_SCRIPT" || \
    die "Stork database initialization does not enable pgcrypto"
if grep -Eq -- '-c ".*PASSWORD' "$INIT_SCRIPT"; then
    die "Stork database password is exposed in a process argument"
fi
grep -q 'chmod 0640.*KEA_API_USER_FILE.*KEA_API_PASSWORD_FILE' "$CONFIGURE_SCRIPT" || \
    die "Kea API credentials are not made readable to the Stork agent group"
grep -q 'pw groupmod stork -m stork-server' "$CONFIGURE_SCRIPT" || \
    die "Stork server cannot traverse the shared configuration directory"
grep -q 'pw groupmod stork -m stork-agent' "$CONFIGURE_SCRIPT" || \
    die "Stork agent cannot traverse the shared configuration directory"
grep -q 'chown root:stork /usr/local/etc/stork' "$CONFIGURE_SCRIPT" || \
    die "Stork configuration directory does not use the shared service group"
grep -q 'chown -R stork-agent:stork-agent /var/lib/stork-agent' "$CONFIGURE_SCRIPT" || \
    die "Stork configuration does not repair existing agent state ownership"
grep -q 'chown -R stork-agent:stork-agent /var/lib/stork-agent' "$START_SCRIPT" || \
    die "Stork startup does not repair existing agent state ownership"
grep -q 'chmod 0755 /var/lib' "$CONFIGURE_SCRIPT" || \
    die "Stork configuration does not make the agent state parent traversable"
grep -q '/usr/local/lib/stork-agent/hooks' "$INSTALL_SCRIPT" || \
    die "Stork installer does not create the configured agent hook directory"
grep -q 'install -d -m 0755 /usr/local/share/stork/www/assets/pkgs' "$INSTALL_SCRIPT" || \
    die "Stork installer does not create the optional Linux agent package directory"
grep -q 'install -d -m 0755 /usr/local/share/stork/www/assets/pkgs' "$CONFIGURE_SCRIPT" || \
    die "Stork configuration does not repair the Linux agent package directory"
grep -q 'http://${MGMT_ADDR}:8080/' "$START_SCRIPT" || \
    die "Stork UI readiness is not checked"

echo "PASS: Stork dashboard configuration"
