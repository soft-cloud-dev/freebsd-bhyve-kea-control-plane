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

POSTGRES_EXPORTER_DSN ?=

SCRIPTS = \
	scripts/01_host_setup.sh \
	scripts/02_install_dependencies.sh \
	scripts/03_init_ipam.sh \
	scripts/provision_vm.sh \
	scripts/rollback_vm.sh

TESTS = \
	tests/test_pf.sh \
	tests/test_kea.sh \
	tests/test_observability.sh \
	tests/test_provisioner.sh

.NOTPARALLEL:
.PHONY: all help syntax lint test check-root check-platform check-trust \
	install install-dependencies configure-host configure-services \
	init-postgresql init-ipam init-vm start-services validate-freebsd

all help:
	@echo "FreeBSD bhyve + Kea Control Plane"
	@echo "---------------------------------"
	@echo "Run a guarded installation only after trusted SSH access is verified:"
	@echo "  make install TRUSTED_SSH_READY=yes EXT_IF=igb0 MGMT_IF=vlan10 LAN_IF=bridge0"
	@echo ""
	@echo "Important overrides:"
	@echo "  MGMT_ADDR=10.0.10.2 VM_DATASET=zroot/vm PG_DATA=/var/db/postgres/data16"
	@echo "  POSTGRES_EXPORTER_DSN='postgresql://prometheus:...@127.0.0.1:5432/inventory?sslmode=disable'"

syntax:
	@set -e; for file in ${SCRIPTS} ${TESTS}; do \
		echo "sh -n $$file"; \
		sh -n "$$file"; \
	done

lint: syntax
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -s sh ${SCRIPTS} ${TESTS}; \
	else \
		echo "shellcheck is not installed; syntax validation completed"; \
	fi

test: lint
	@sh tests/test_provisioner.sh
	@sh tests/test_observability.sh

check-root:
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "ERROR: make install must run as root" >&2; \
		exit 1; \
	fi

check-platform:
	@if [ "$$(uname -s)" != "FreeBSD" ]; then \
		echo "ERROR: installation target requires FreeBSD" >&2; \
		exit 1; \
	fi
	@if ! ifconfig "${EXT_IF}" >/dev/null 2>&1; then \
		echo "ERROR: external interface does not exist: ${EXT_IF}" >&2; \
		exit 1; \
	fi
	@if ! ifconfig "${MGMT_IF}" >/dev/null 2>&1; then \
		echo "ERROR: management interface does not exist: ${MGMT_IF}" >&2; \
		exit 1; \
	fi
	@if ! ifconfig "${LAN_IF}" >/dev/null 2>&1; then \
		echo "ERROR: VM bridge does not exist: ${LAN_IF}" >&2; \
		exit 1; \
	fi

check-trust:
	@if [ "${TRUSTED_SSH_READY}" != "yes" ]; then \
		echo "ERROR: trusted SSH access has not been explicitly confirmed" >&2; \
		echo "Verify a second key-authenticated session, then rerun with TRUSTED_SSH_READY=yes" >&2; \
		exit 1; \
	fi

install:
	@${MAKE} check-root
	@${MAKE} check-platform
	@${MAKE} check-trust
	@${MAKE} syntax
	@${MAKE} install-dependencies
	@${MAKE} configure-host
	@${MAKE} configure-services
	@${MAKE} init-postgresql
	@${MAKE} init-ipam
	@${MAKE} init-vm
	@${MAKE} start-services
	@${MAKE} validate-freebsd
	@echo ""
	@echo "[+] Control plane installation completed"
	@echo "Provision with SSH_PUBLIC_KEY_FILE set; see docs/operations.md"

install-dependencies:
	@printf '\n==> Installing dependencies\n'
	@sh scripts/02_install_dependencies.sh

configure-host:
	@printf '\n==> Hardening host and tuning storage\n'
	@VM_DATASET="${VM_DATASET}" MGMT_GROUP="${MGMT_GROUP}" sh scripts/01_host_setup.sh

configure-services:
	@printf '\n==> Rendering and installing service configuration\n'
	@set -eu; \
	pf_tmp=$$(mktemp); \
	grafana_tmp=$$(mktemp); \
	kea_tmp=$$(mktemp); \
	trap 'rm -f "$$pf_tmp" "$$grafana_tmp" "$$kea_tmp"' EXIT HUP INT TERM; \
	sed \
	  -e 's|^ext_if[[:space:]]*=.*|ext_if = "${EXT_IF}"|' \
	  -e 's|^mgmt_if[[:space:]]*=.*|mgmt_if = "${MGMT_IF}"|' \
	  -e 's|^lan_if[[:space:]]*=.*|lan_if = "${LAN_IF}"|' \
	  -e 's|^mgmt_net[[:space:]]*=.*|mgmt_net = "${MGMT_NET}"|' \
	  -e 's|^lan_net[[:space:]]*=.*|lan_net = "${LAN_NET}"|' \
	  config/pf.conf > "$$pf_tmp"; \
	pfctl -nf "$$pf_tmp"; \
	install -m 0600 "$$pf_tmp" /etc/pf.conf; \
	install -d -m 0755 /usr/local/etc/kea; \
	sed 's|"interfaces": \[ "[^"]*" \]|"interfaces": [ "${LAN_IF}" ]|' \
	  config/kea-dhcp4.conf > "$$kea_tmp"; \
	kea-dhcp4 -t "$$kea_tmp"; \
	install -m 0644 "$$kea_tmp" /usr/local/etc/kea/kea-dhcp4.conf; \
	kea-ctrl-agent -t config/kea-ctrl-agent.conf; \
	install -m 0644 config/kea-ctrl-agent.conf /usr/local/etc/kea/kea-ctrl-agent.conf; \
	install -m 0644 config/prometheus.yml /usr/local/etc/prometheus.yml; \
	if command -v promtool >/dev/null 2>&1; then promtool check config /usr/local/etc/prometheus.yml; fi; \
	install -d -m 0755 /usr/local/etc/grafana/provisioning/datasources; \
	install -d -m 0755 /usr/local/etc/grafana/provisioning/dashboards; \
	sed 's|^http_addr[[:space:]]*=.*|http_addr = ${MGMT_ADDR}|' config/grafana.ini > "$$grafana_tmp"; \
	install -m 0640 "$$grafana_tmp" /usr/local/etc/grafana/grafana.ini; \
	install -m 0644 config/grafana/provisioning/datasources/prometheus.yml \
	  /usr/local/etc/grafana/provisioning/datasources/prometheus.yml; \
	install -m 0644 config/grafana/provisioning/dashboards/default.yml \
	  /usr/local/etc/grafana/provisioning/dashboards/default.yml; \
	sysrc pf_enable=YES pflog_enable=YES >/dev/null; \
	sysrc kea_dhcp4_enable=YES kea_ctrl_agent_enable=YES >/dev/null; \
	sysrc prometheus_enable=YES prometheus_config=/usr/local/etc/prometheus.yml >/dev/null; \
	sysrc prometheus_args='--web.listen-address=127.0.0.1:9090' >/dev/null; \
	sysrc node_exporter_enable=YES node_exporter_listen_address=127.0.0.1:9100 >/dev/null; \
	sysrc grafana_enable=YES grafana_config=/usr/local/etc/grafana/grafana.ini >/dev/null; \
	if [ -n "${POSTGRES_EXPORTER_DSN}" ]; then \
	  case "${POSTGRES_EXPORTER_DSN}" in *\"*|*\\*) echo 'ERROR: unsupported quote in POSTGRES_EXPORTER_DSN' >&2; exit 1;; esac; \
	  install -d -m 0700 /etc/rc.conf.d; \
	  umask 077; \
	  printf '%s\n' \
	    'postgres_exporter_enable="YES"' \
	    'postgres_exporter_listen_address="127.0.0.1:9187"' \
	    'postgres_exporter_env="DATA_SOURCE_URI=${POSTGRES_EXPORTER_DSN}"' \
	    > /etc/rc.conf.d/postgres_exporter; \
	else \
	  sysrc postgres_exporter_enable=NO >/dev/null; \
	  echo '[!] postgres_exporter disabled: POSTGRES_EXPORTER_DSN was not supplied'; \
	fi

init-postgresql:
	@printf '\n==> Initializing PostgreSQL\n'
	@set -eu; \
	sysrc postgresql_enable=YES >/dev/null; \
	if [ ! -s "${PG_DATA}/PG_VERSION" ]; then service postgresql initdb; fi; \
	service postgresql status >/dev/null 2>&1 || service postgresql start; \
	i=0; until pg_isready -q; do i=$$((i + 1)); [ $$i -lt 30 ] || { echo 'ERROR: PostgreSQL did not become ready' >&2; exit 1; }; sleep 1; done; \
	if ! sudo -u "${PG_USER}" psql -X -qAt -d postgres \
	  -c "SELECT 1 FROM pg_database WHERE datname='${PG_DATABASE}'" | grep -qx 1; then \
	  sudo -u "${PG_USER}" createdb "${PG_DATABASE}"; \
	fi; \
	sudo -u "${PG_USER}" psql -X -v ON_ERROR_STOP=1 -d "${PG_DATABASE}" -f db/001_inventory.sql; \
	sudo -u "${PG_USER}" psql -X -v ON_ERROR_STOP=1 -d "${PG_DATABASE}" -f db/002_monitoring.sql

init-ipam:
	@printf '\n==> Initializing IPAM pool\n'
	@PGDATABASE="${PG_DATABASE}" PGUSER="${PG_USER}" \
	 IPAM_POOL="${IPAM_POOL}" IPAM_SUBNET="${IPAM_SUBNET}" \
	 IPAM_FIRST_HOST="${IPAM_FIRST_HOST}" IPAM_LAST_HOST="${IPAM_LAST_HOST}" \
	 IPAM_VLAN="${IPAM_VLAN}" KEA_SUBNET_ID="${KEA_SUBNET_ID}" \
	 sh scripts/03_init_ipam.sh

init-vm:
	@printf '\n==> Initializing vm-bhyve\n'
	@set -eu; \
	sysrc vm_enable=YES vm_dir="${VM_DIR}" >/dev/null; \
	vm init; \
	vm_root=$$(zfs get -H -o value mountpoint "${VM_DATASET}"); \
	case "$$vm_root" in ''|none|legacy) echo 'ERROR: VM dataset requires a mounted path' >&2; exit 1;; esac; \
	install -d -m 0755 "$$vm_root/.templates"; \
	install -m 0644 templates/vm-bhyve.conf "$$vm_root/.templates/freebsd.conf"; \
	if ! vm switch list | awk 'NR > 1 { print $$1 }' | grep -qx public; then \
	  vm switch create -t manual -b "${LAN_IF}" public; \
	else \
	  echo '[*] vm-bhyve switch public already exists; leaving it unchanged'; \
	fi

start-services:
	@printf '\n==> Starting services\n'
	@service pf status >/dev/null 2>&1 && service pf reload || service pf start
	@service kea_dhcp4 restart 2>/dev/null || service kea_dhcp4 start
	@service kea_ctrl_agent restart 2>/dev/null || service kea_ctrl_agent start
	@service node_exporter restart 2>/dev/null || service node_exporter start
	@service prometheus restart 2>/dev/null || service prometheus start
	@if [ "$$(sysrc -n postgres_exporter_enable 2>/dev/null || true)" = YES ]; then \
		service postgres_exporter restart 2>/dev/null || service postgres_exporter start; \
	fi
	@service grafana restart 2>/dev/null || service grafana start

validate-freebsd: lint
	@sh tests/test_pf.sh
	@sh tests/test_kea.sh
	@sh tests/test_observability.sh
	@sockstat -4 -6 -l
