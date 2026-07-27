SHELL = /bin/sh

EXT_IF ?= igb0
MGMT_IF ?= vlan10
LAN_IF ?= bridge0
MGMT_ADDR ?= 10.0.10.2
MGMT_NET ?= 10.0.10.0/24
LAN_NET ?= 10.0.20.0/24
VM_DATASET ?= zroot/vm
VM_DIR ?= zfs:${VM_DATASET}
MGMT_GROUP ?= wheel
TRUSTED_SSH_READY ?= no
PG_USER ?= postgres
PG_DATABASE ?= inventory
PG_DATA ?= /var/db/postgres/data16
IPAM_POOL ?= vm-lan
IPAM_SUBNET ?= 10.0.20.0/24
IPAM_FIRST_HOST ?= 10.0.20.10
IPAM_LAST_HOST ?= 10.0.20.99
IPAM_VLAN ?= 20
KEA_SUBNET_ID ?= 1
KEA_API_USER ?= control-plane
KEA_API_USER_FILE ?= /usr/local/etc/kea/kea-api-user
KEA_API_PASSWORD_FILE ?= /usr/local/etc/kea/kea-api-password
POSTGRES_EXPORTER_DSN ?=

SCRIPTS = scripts/01_host_setup.sh scripts/02_install_dependencies.sh scripts/03_init_ipam.sh scripts/provision_vm.sh scripts/rollback_vm.sh
TESTS = tests/test_pf.sh tests/test_kea.sh tests/test_observability.sh tests/test_provisioner.sh

.NOTPARALLEL:
.PHONY: all help syntax lint test check-root check-platform check-trust install install-dependencies configure-host configure-services init-postgresql init-ipam init-vm start-services validate-freebsd

all help:
	@echo "FreeBSD bhyve + Kea Control Plane"
	@echo "Run: make install TRUSTED_SSH_READY=yes EXT_IF=igb0 MGMT_IF=vlan10 LAN_IF=bridge0"

syntax:
	@set -e; for file in ${SCRIPTS} ${TESTS}; do echo "sh -n $$file"; sh -n "$$file"; done

lint: syntax
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck -s sh ${SCRIPTS} ${TESTS}; else echo "shellcheck unavailable; syntax passed"; fi

test: lint
	@sh tests/test_provisioner.sh
	@sh tests/test_observability.sh

check-root:
	@test "$$(id -u)" -eq 0 || { echo "ERROR: run make install as root" >&2; exit 1; }

check-platform:
	@test "$$(uname -s)" = FreeBSD || { echo "ERROR: FreeBSD required" >&2; exit 1; }
	@ifconfig "${EXT_IF}" >/dev/null 2>&1 || { echo "ERROR: missing ${EXT_IF}" >&2; exit 1; }
	@ifconfig "${MGMT_IF}" >/dev/null 2>&1 || { echo "ERROR: missing ${MGMT_IF}" >&2; exit 1; }
	@ifconfig "${LAN_IF}" >/dev/null 2>&1 || { echo "ERROR: missing ${LAN_IF}" >&2; exit 1; }

check-trust:
	@test "${TRUSTED_SSH_READY}" = yes || { echo "ERROR: confirm trusted SSH with TRUSTED_SSH_READY=yes" >&2; exit 1; }

install: check-root check-platform check-trust syntax install-dependencies configure-host configure-services init-postgresql init-ipam init-vm start-services validate-freebsd
	@echo "[+] Installation completed"

install-dependencies:
	@sh scripts/02_install_dependencies.sh

configure-host:
	@VM_DATASET="${VM_DATASET}" MGMT_GROUP="${MGMT_GROUP}" sh scripts/01_host_setup.sh

configure-services:
	@set -eu; \
	pf_tmp=$$(mktemp); kea_tmp=$$(mktemp); grafana_tmp=$$(mktemp); \
	trap 'rm -f "$$pf_tmp" "$$kea_tmp" "$$grafana_tmp"' EXIT HUP INT TERM; \
	sed -e 's|^ext_if[[:space:]]*=.*|ext_if = "${EXT_IF}"|' \
	    -e 's|^mgmt_if[[:space:]]*=.*|mgmt_if = "${MGMT_IF}"|' \
	    -e 's|^lan_if[[:space:]]*=.*|lan_if = "${LAN_IF}"|' \
	    -e 's|^mgmt_net[[:space:]]*=.*|mgmt_net = "${MGMT_NET}"|' \
	    -e 's|^lan_net[[:space:]]*=.*|lan_net = "${LAN_NET}"|' config/pf.conf > "$$pf_tmp"; \
	pfctl -nf "$$pf_tmp"; install -m 0600 "$$pf_tmp" /etc/pf.conf; \
	install -d -m 0750 /usr/local/etc/kea; \
	if [ ! -s "${KEA_API_USER_FILE}" ]; then printf '%s\n' "${KEA_API_USER}" > "${KEA_API_USER_FILE}"; fi; \
	if [ ! -s "${KEA_API_PASSWORD_FILE}" ]; then umask 077; openssl rand -hex 24 > "${KEA_API_PASSWORD_FILE}"; fi; \
	chmod 0600 "${KEA_API_USER_FILE}" "${KEA_API_PASSWORD_FILE}"; \
	sed 's|"interfaces": \[ "[^"]*" \]|"interfaces": [ "${LAN_IF}" ]|' config/kea-dhcp4.conf > "$$kea_tmp"; \
	kea-dhcp4 -t "$$kea_tmp"; install -m 0640 "$$kea_tmp" /usr/local/etc/kea/kea-dhcp4.conf; \
	install -m 0644 config/prometheus.yml /usr/local/etc/prometheus.yml; \
	if command -v promtool >/dev/null 2>&1; then promtool check config /usr/local/etc/prometheus.yml; fi; \
	install -d -m 0755 /usr/local/etc/grafana/provisioning/datasources /usr/local/etc/grafana/provisioning/dashboards/json; \
	sed 's|^http_addr[[:space:]]*=.*|http_addr = ${MGMT_ADDR}|' config/grafana.ini > "$$grafana_tmp"; \
	install -m 0640 "$$grafana_tmp" /usr/local/etc/grafana/grafana.ini; \
	install -m 0644 config/grafana/provisioning/datasources/prometheus.yml /usr/local/etc/grafana/provisioning/datasources/prometheus.yml; \
	install -m 0644 config/grafana/provisioning/dashboards/default.yml /usr/local/etc/grafana/provisioning/dashboards/default.yml; \
	for dashboard in config/grafana/provisioning/dashboards/json/*.json; do [ -e "$$dashboard" ] || continue; install -m 0644 "$$dashboard" /usr/local/etc/grafana/provisioning/dashboards/json/; done; \
	sysrc pf_enable=YES pflog_enable=YES >/dev/null; \
	if [ -x /usr/local/etc/rc.d/kea ]; then \
	  sysrc kea_enable=YES >/dev/null; \
	  sysrc -x kea_dhcp4_enable >/dev/null 2>&1 || true; \
	elif [ -x /usr/local/etc/rc.d/kea_dhcp4 ]; then \
	  sysrc kea_dhcp4_enable=YES >/dev/null; \
	  sysrc -x kea_enable >/dev/null 2>&1 || true; \
	else \
	  echo 'ERROR: no Kea rc service found in /usr/local/etc/rc.d' >&2; \
	  exit 1; \
	fi; \
	sysrc -x kea_ctrl_agent_enable >/dev/null 2>&1 || true; \
	sysrc prometheus_enable=YES prometheus_config=/usr/local/etc/prometheus.yml prometheus_args='--web.listen-address=127.0.0.1:9090' >/dev/null; \
	sysrc node_exporter_enable=YES node_exporter_listen_address=127.0.0.1:9100 >/dev/null; \
	sysrc grafana_enable=YES grafana_config=/usr/local/etc/grafana/grafana.ini >/dev/null; \
	if [ -n "${POSTGRES_EXPORTER_DSN}" ]; then \
	  install -d -m 0700 /etc/rc.conf.d; umask 077; \
	  printf '%s\n' 'postgres_exporter_enable="YES"' 'postgres_exporter_listen_address="127.0.0.1:9187"' 'postgres_exporter_env="DATA_SOURCE_URI=${POSTGRES_EXPORTER_DSN}"' > /etc/rc.conf.d/postgres_exporter; \
	else sysrc postgres_exporter_enable=NO >/dev/null; fi

init-postgresql:
	@set -eu; sysrc postgresql_enable=YES >/dev/null; \
	if [ ! -s "${PG_DATA}/PG_VERSION" ]; then service postgresql initdb; fi; \
	service postgresql status >/dev/null 2>&1 || service postgresql start; \
	i=0; until pg_isready -q; do i=$$((i+1)); [ $$i -lt 30 ] || exit 1; sleep 1; done; \
	if ! sudo -u "${PG_USER}" psql -X -qAt -d postgres -c "SELECT 1 FROM pg_database WHERE datname='${PG_DATABASE}'" | grep -qx 1; then sudo -u "${PG_USER}" createdb "${PG_DATABASE}"; fi; \
	sudo -u "${PG_USER}" psql -X -v ON_ERROR_STOP=1 -d "${PG_DATABASE}" -f db/001_inventory.sql; \
	sudo -u "${PG_USER}" psql -X -v ON_ERROR_STOP=1 -d "${PG_DATABASE}" -f db/002_monitoring.sql

init-ipam:
	@PGDATABASE="${PG_DATABASE}" PGUSER="${PG_USER}" IPAM_POOL="${IPAM_POOL}" IPAM_SUBNET="${IPAM_SUBNET}" IPAM_FIRST_HOST="${IPAM_FIRST_HOST}" IPAM_LAST_HOST="${IPAM_LAST_HOST}" IPAM_VLAN="${IPAM_VLAN}" KEA_SUBNET_ID="${KEA_SUBNET_ID}" sh scripts/03_init_ipam.sh

init-vm:
	@set -eu; sysrc vm_enable=YES vm_dir="${VM_DIR}" >/dev/null; vm init; \
	vm_root=$$(zfs get -H -o value mountpoint "${VM_DATASET}"); \
	case "$$vm_root" in ''|none|legacy) echo "ERROR: invalid VM dataset mountpoint" >&2; exit 1;; esac; \
	install -d -m 0755 "$$vm_root/.templates"; install -m 0644 templates/vm-bhyve.conf "$$vm_root/.templates/freebsd.conf"; \
	if ! vm switch list | awk 'NR > 1 {print $$1}' | grep -qx public; then vm switch create -t manual -b "${LAN_IF}" public; fi

start-services:
	@service pf status >/dev/null 2>&1 && service pf reload || service pf start
	@set -eu; \
	if [ -x /usr/local/etc/rc.d/kea ]; then \
	  kea_service=kea; \
	elif [ -x /usr/local/etc/rc.d/kea_dhcp4 ]; then \
	  kea_service=kea_dhcp4; \
	else \
	  echo 'ERROR: no Kea rc service found in /usr/local/etc/rc.d' >&2; \
	  exit 1; \
	fi; \
	service "$$kea_service" restart 2>/dev/null || service "$$kea_service" start
	@service node_exporter restart 2>/dev/null || service node_exporter start
	@service prometheus restart 2>/dev/null || service prometheus start
	@if [ "$$(sysrc -n postgres_exporter_enable 2>/dev/null || true)" = YES ]; then service postgres_exporter restart 2>/dev/null || service postgres_exporter start; fi
	@service grafana restart 2>/dev/null || service grafana start
	@set -eu; user=$$(sed -n '1p' "${KEA_API_USER_FILE}"); password=$$(sed -n '1p' "${KEA_API_PASSWORD_FILE}"); \
	i=0; until curl -fsS --user "$$user:$$password" -H 'Content-Type: application/json' -d '{"command":"status-get"}' http://127.0.0.1:8000/ >/dev/null; do i=$$((i+1)); [ $$i -lt 15 ] || { echo 'ERROR: Kea API did not become ready' >&2; exit 1; }; sleep 1; done

validate-freebsd: lint
	@sh tests/test_pf.sh
	@sh tests/test_kea.sh
	@sh tests/test_observability.sh
	@sockstat -4 -6 -l
