SHELL = /bin/sh

EXT_IF ?= igb0
MGMT_IF ?= vlan10
LAN_IF ?= bridge0
MGMT_ADDR ?= 10.0.10.2
MGMT_NET ?= 10.0.10.0/24
LAN_NET ?= 10.0.20.0/24
DNS_ADDR ?= 10.0.20.1
VM_DATASET ?= zroot/vm
VM_DIR ?= zfs:${VM_DATASET}
MGMT_GROUP ?= wheel
MGMT_USER ?= admin
SSH_ADMIN_KEY_FILE ?=
SSH_ADMIN_AUTHORIZED_KEY ?=
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
KEA_API_USER ?= stork-control-plane
KEA_API_USER_FILE ?= /usr/local/etc/kea/kea-api-user
KEA_API_PASSWORD_FILE ?= /usr/local/etc/kea/kea-api-password
POSTGRES_EXPORTER_DSN ?=
PF_ROLLBACK_TIMEOUT ?= 120
LOKI_READY_TIMEOUT ?= 60
DNS_READY_TIMEOUT ?= 15
STORK_ENABLE ?= yes
STORK_VERSION ?= 2.5.0
STORK_GIT_COMMIT ?= 43f1450d1260ce58c2c6c973b72199b6c6592513
STORK_SOURCE_DIR ?=
STORK_DB_NAME ?= stork
STORK_DB_USER ?= stork-server
STORK_DB_PASSWORD_FILE ?= /usr/local/etc/stork/database-password
STORK_READY_TIMEOUT ?= 60

SCRIPTS = scripts/01_host_setup.sh scripts/02_install_dependencies.sh scripts/03_init_ipam.sh scripts/apply_pf_safely.sh scripts/configure_services.sh scripts/init_postgresql.sh scripts/init_stork.sh scripts/init_vm.sh scripts/install_stork.sh scripts/lib.sh scripts/provision_vm.sh scripts/render_kea_config.sh scripts/rollback_vm.sh scripts/start_services.sh config/rc.d/stork_server config/rc.d/stork_agent
TESTS = tests/test_pf.sh tests/test_kea.sh tests/test_unbound.sh tests/test_observability.sh tests/test_stork.sh

.NOTPARALLEL:
.PHONY: all help syntax lint test check-root check-platform check-trust install install-dependencies configure-host configure-services init-postgresql init-stork init-ipam init-vm start-services validate-freebsd

all help:
	@echo "FreeBSD bhyve + Kea Control Plane"
	@echo "Run: make install TRUSTED_SSH_READY=yes SSH_ADMIN_KEY_FILE=/root/id_ed25519.pub EXT_IF=igb0 MGMT_IF=vlan10 LAN_IF=bridge0"
	@echo "SSH after hardening: ssh -i <private-key> ${MGMT_USER}@${MGMT_ADDR}"

syntax:
	@set -e; for file in ${SCRIPTS} ${TESTS}; do echo "sh -n $$file"; sh -n "$$file"; done

lint: syntax
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck -s sh ${SCRIPTS} ${TESTS}; else echo "shellcheck unavailable; syntax passed"; fi

test: lint
	@sh tests/test_pf.sh
	@sh tests/test_kea.sh
	@sh tests/test_unbound.sh
	@sh tests/test_observability.sh
	@sh tests/test_stork.sh

check-root:
	@test "$$(id -u)" -eq 0 || { echo "ERROR: run make install as root" >&2; exit 1; }

check-platform:
	@test "$$(uname -s)" = FreeBSD || { echo "ERROR: FreeBSD required" >&2; exit 1; }
	@ifconfig "${EXT_IF}" >/dev/null 2>&1 || { echo "ERROR: missing ${EXT_IF}" >&2; exit 1; }
	@ifconfig "${MGMT_IF}" >/dev/null 2>&1 || { echo "ERROR: missing ${MGMT_IF}" >&2; exit 1; }
	@ifconfig "${LAN_IF}" >/dev/null 2>&1 || { echo "ERROR: missing ${LAN_IF}" >&2; exit 1; }

check-trust:
	@test "${TRUSTED_SSH_READY}" = yes || { echo "ERROR: confirm trusted SSH with TRUSTED_SSH_READY=yes" >&2; exit 1; }
	@test -n "${SSH_ADMIN_KEY_FILE}${SSH_ADMIN_AUTHORIZED_KEY}" || { echo "ERROR: set SSH_ADMIN_KEY_FILE or SSH_ADMIN_AUTHORIZED_KEY" >&2; exit 1; }

install: check-root check-platform check-trust syntax install-dependencies configure-host configure-services init-postgresql init-stork init-ipam init-vm start-services validate-freebsd
	@PF_ROLLBACK_TIMEOUT="${PF_ROLLBACK_TIMEOUT}" sh scripts/apply_pf_safely.sh confirm
	@echo "[+] Installation completed"
	@echo "[+] SSH login: ssh -i <private-key> ${MGMT_USER}@${MGMT_ADDR}"

install-dependencies:
	@STORK_ENABLE="${STORK_ENABLE}" STORK_VERSION="${STORK_VERSION}" STORK_GIT_COMMIT="${STORK_GIT_COMMIT}" STORK_SOURCE_DIR="${STORK_SOURCE_DIR}" sh scripts/02_install_dependencies.sh

configure-host:
	@EXT_IF="${EXT_IF}" MGMT_IF="${MGMT_IF}" LAN_IF="${LAN_IF}" MGMT_ADDR="${MGMT_ADDR}" VM_DATASET="${VM_DATASET}" MGMT_GROUP="${MGMT_GROUP}" MGMT_USER="${MGMT_USER}" SSH_ADMIN_KEY_FILE="${SSH_ADMIN_KEY_FILE}" SSH_ADMIN_AUTHORIZED_KEY="${SSH_ADMIN_AUTHORIZED_KEY}" sh scripts/01_host_setup.sh

configure-services:
	@EXT_IF="${EXT_IF}" MGMT_IF="${MGMT_IF}" LAN_IF="${LAN_IF}" MGMT_NET="${MGMT_NET}" LAN_NET="${LAN_NET}" MGMT_ADDR="${MGMT_ADDR}" DNS_ADDR="${DNS_ADDR}" KEA_API_USER="${KEA_API_USER}" KEA_API_USER_FILE="${KEA_API_USER_FILE}" KEA_API_PASSWORD_FILE="${KEA_API_PASSWORD_FILE}" POSTGRES_EXPORTER_DSN="${POSTGRES_EXPORTER_DSN}" STORK_ENABLE="${STORK_ENABLE}" STORK_DB_NAME="${STORK_DB_NAME}" STORK_DB_USER="${STORK_DB_USER}" STORK_DB_PASSWORD_FILE="${STORK_DB_PASSWORD_FILE}" sh scripts/configure_services.sh

init-postgresql:
	@PG_USER="${PG_USER}" PG_DATABASE="${PG_DATABASE}" PG_DATA="${PG_DATA}" sh scripts/init_postgresql.sh

init-stork:
	@STORK_ENABLE="${STORK_ENABLE}" STORK_DB_NAME="${STORK_DB_NAME}" STORK_DB_USER="${STORK_DB_USER}" STORK_DB_PASSWORD_FILE="${STORK_DB_PASSWORD_FILE}" PG_USER="${PG_USER}" sh scripts/init_stork.sh

init-ipam:
	@PGDATABASE="${PG_DATABASE}" PGUSER="${PG_USER}" IPAM_POOL="${IPAM_POOL}" IPAM_SUBNET="${IPAM_SUBNET}" IPAM_FIRST_HOST="${IPAM_FIRST_HOST}" IPAM_LAST_HOST="${IPAM_LAST_HOST}" IPAM_VLAN="${IPAM_VLAN}" KEA_SUBNET_ID="${KEA_SUBNET_ID}" sh scripts/03_init_ipam.sh

init-vm:
	@VM_DIR="${VM_DIR}" VM_DATASET="${VM_DATASET}" LAN_IF="${LAN_IF}" sh scripts/init_vm.sh

start-services:
	@PF_ROLLBACK_TIMEOUT="${PF_ROLLBACK_TIMEOUT}" LOKI_READY_TIMEOUT="${LOKI_READY_TIMEOUT}" DNS_READY_TIMEOUT="${DNS_READY_TIMEOUT}" STORK_READY_TIMEOUT="${STORK_READY_TIMEOUT}" STORK_ENABLE="${STORK_ENABLE}" MGMT_ADDR="${MGMT_ADDR}" DNS_ADDR="${DNS_ADDR}" KEA_API_USER_FILE="${KEA_API_USER_FILE}" KEA_API_PASSWORD_FILE="${KEA_API_PASSWORD_FILE}" sh scripts/start_services.sh

validate-freebsd: lint
	@sh tests/test_pf.sh
	@sh tests/test_kea.sh
	@sh tests/test_unbound.sh
	@sh tests/test_observability.sh
	@sh tests/test_stork.sh
	@sockstat -4 -6 -l
