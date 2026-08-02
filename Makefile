SHELL = /bin/sh

EXT_IF ?= igb0
MGMT_IF ?= vlan10
LAN_IF ?= bridge0
LAN_MTU ?= 1496
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
SSH_PUBLIC_KEY_FILE ?=
SSH_PRIVATE_KEY_FILE ?=
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
KEA_HOST_DB_NAME ?= kea_hosts
KEA_HOST_DB_USER ?= kea_hosts
KEA_HOST_DB_PASSWORD_FILE ?= /usr/local/etc/kea/kea-host-db-password
KEA_PORTS_DIR ?= /usr/ports
KEA_PORTS_FALLBACK_DIR ?= /var/cache/control-plane/ports
POSTGRES_EXPORTER_DSN ?=
PF_ROLLBACK_TIMEOUT ?= 120
LOKI_READY_TIMEOUT ?= 60
DNS_READY_TIMEOUT ?= 15
STORK_ENABLE ?= yes
STORK_VERSION ?= 2.5.0
STORK_GIT_COMMIT ?= 43f1450d1260ce58c2c6c973b72199b6c6592513
STORK_SOURCE_DIR ?=
STORK_AGENT_PACKAGES_ENABLE ?= yes
STORK_AGENT_PACKAGE_ARCH ?=
STORK_DB_NAME ?= stork
STORK_DB_USER ?= stork-server
STORK_DB_PASSWORD_FILE ?= /usr/local/etc/stork/database-password
STORK_READY_TIMEOUT ?= 60
VM_NAME ?=
VM_OWNER ?= admin
CLOUD_INIT_USER ?= admin
TEMPLATE ?= freebsd
CONTROL_PLANE_ID ?=
FREEBSD_CLOUD_IMAGE_URL ?= https://download.freebsd.org/releases/VM-IMAGES/14.3-RELEASE/amd64/Latest/FreeBSD-14.3-RELEASE-amd64-BASIC-CLOUDINIT-ufs.raw.xz
FREEBSD_CLOUD_IMAGE_CACHE ?= /var/cache/control-plane/freebsd-cloud.raw
FREEBSD_CLOUD_IMAGE_SHA256 ?=
FREEBSD_CLOUD_IMAGE_CHECKSUM_URL ?=
CLUSTER_NODE_PREFIX ?= freebsd-node
CLUSTER_NODE_COUNT ?= 3
CLUSTER_PROFILE_FILE ?= config/cloud-init/freebsd-jail-node.yaml
CLUSTER_STATE_DIR ?= /var/db/freebsd-bhyve-kea-control-plane/clusters
CLUSTER_BOOT_TIMEOUT ?= 600
CLUSTER_POLL_INTERVAL ?= 5
CLUSTER_SSH_USER ?= ${CLOUD_INIT_USER}
KUBECTL_BOOTSTRAP ?= yes
KUBECONFIG_SOURCE ?=
KUBECONFIG_DEST ?= /root/.kube/config
KUBECONFIG_REFRESH ?= no
KUBECONFIG_REMOTE_HOST ?= ipa.softcloud.dev
KUBECONFIG_REMOTE_USER ?= fedora
KUBECONFIG_REMOTE_PATH ?= /etc/kubernetes/admin.conf
KUBECONFIG_REMOTE_SSH_KEY ?= ${SSH_PRIVATE_KEY_FILE}
KUBECONFIG_REMOTE_SUDO ?= yes
KUBECONFIG_KNOWN_HOSTS ?= ${CLUSTER_STATE_DIR}/kubernetes-control-plane.known_hosts
KUBECTL_VERIFY ?= yes

SCRIPTS = scripts/01_host_setup.sh scripts/02_install_dependencies.sh scripts/03_init_ipam.sh scripts/apply_pf_safely.sh scripts/bootstrap_kubeconfig.sh scripts/configure_services.sh scripts/deprovision_vm.sh scripts/fetch_freebsd_cloud_image.sh scripts/freebsd_cluster.sh scripts/init_kea_host_db.sh scripts/init_postgresql.sh scripts/init_stork.sh scripts/init_vm.sh scripts/install_stork.sh scripts/install_stork_agent_packages.sh scripts/lib.sh scripts/migrate_vm_to_bhyveload.sh scripts/provision_freebsd_jail_cluster.sh scripts/provision_freebsd_jail_node.sh scripts/provision_vm.sh scripts/render_kea_config.sh scripts/rollback_vm.sh scripts/start_services.sh config/rc.d/stork_server config/rc.d/stork_agent
TESTS = tests/test_pf.sh tests/test_kea.sh tests/test_unbound.sh tests/test_observability.sh tests/test_stork.sh tests/test_cloud_image.sh tests/test_cluster.sh tests/test_kubeconfig.sh

.NOTPARALLEL:
.PHONY: all help syntax lint test check-root check-platform check-trust install install-dependencies install-stork-agent-packages configure-host configure-services deprovision deprovision-vm provision-vm provision-jail-cluster bootstrap-kubectl cluster-up cluster-down cluster-status fetch-cloud-image init-postgresql init-kea-host-db init-stork init-ipam init-vm start-services validate-freebsd

all help:
	@echo "FreeBSD bhyve + Kea Control Plane"
	@echo "Run: make install TRUSTED_SSH_READY=yes SSH_ADMIN_KEY_FILE=/root/id_ed25519.pub EXT_IF=igb0 MGMT_IF=vlan10 LAN_IF=bridge0"
	@echo "SSH after hardening: ssh -i <private-key> ${MGMT_USER}@${MGMT_ADDR}"
	@echo "Provision VM: make provision-vm VM_NAME=<name> SSH_PUBLIC_KEY_FILE=/root/id_ed25519.pub CONTROL_PLANE_ID=<stable-id>"
	@echo "Bootstrap kubectl: make bootstrap-kubectl SSH_PRIVATE_KEY_FILE=/root/id_ed25519"
	@echo "FreeBSD cluster: make cluster-up SSH_PUBLIC_KEY_FILE=/root/id_ed25519.pub SSH_PRIVATE_KEY_FILE=/root/id_ed25519 CONTROL_PLANE_ID=<stable-id>"
	@echo "Cluster status: make cluster-status"
	@echo "Cluster removal: make cluster-down"
	@echo "Legacy jail cluster: make provision-jail-cluster SSH_PUBLIC_KEY_FILE=/root/id_ed25519.pub CONTROL_PLANE_ID=<stable-id>"
	@echo "Deprovision: make deprovision-vm VM_NAME=<name>"

syntax:
	@set -e; for file in ${SCRIPTS} ${TESTS}; do echo "sh -n $$file"; sh -n "$$file"; done

lint: syntax
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck -s sh -S error ${SCRIPTS} ${TESTS}; else echo "shellcheck unavailable; syntax passed"; fi

test: lint
	@sh tests/test_pf.sh
	@sh tests/test_kea.sh
	@sh tests/test_unbound.sh
	@sh tests/test_observability.sh
	@sh tests/test_stork.sh
	@sh tests/test_cloud_image.sh
	@sh tests/test_cluster.sh
	@sh tests/test_kubeconfig.sh

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

install: check-root check-platform check-trust syntax install-dependencies configure-host init-postgresql init-kea-host-db configure-services init-stork init-ipam init-vm start-services validate-freebsd
	@PF_ROLLBACK_TIMEOUT="${PF_ROLLBACK_TIMEOUT}" sh scripts/apply_pf_safely.sh confirm
	@echo "[+] Installation completed"
	@echo "[+] SSH login: ssh -i <private-key> ${MGMT_USER}@${MGMT_ADDR}"

install-dependencies:
	@STORK_ENABLE="${STORK_ENABLE}" STORK_VERSION="${STORK_VERSION}" STORK_GIT_COMMIT="${STORK_GIT_COMMIT}" STORK_SOURCE_DIR="${STORK_SOURCE_DIR}" STORK_AGENT_PACKAGES_ENABLE="${STORK_AGENT_PACKAGES_ENABLE}" STORK_AGENT_PACKAGE_ARCH="${STORK_AGENT_PACKAGE_ARCH}" KEA_PORTS_DIR="${KEA_PORTS_DIR}" KEA_PORTS_FALLBACK_DIR="${KEA_PORTS_FALLBACK_DIR}" sh scripts/02_install_dependencies.sh

install-stork-agent-packages:
	@STORK_VERSION="${STORK_VERSION}" STORK_AGENT_PACKAGES_ENABLE="${STORK_AGENT_PACKAGES_ENABLE}" STORK_AGENT_PACKAGE_ARCH="${STORK_AGENT_PACKAGE_ARCH}" sh scripts/install_stork_agent_packages.sh

configure-host:
	@EXT_IF="${EXT_IF}" MGMT_IF="${MGMT_IF}" LAN_IF="${LAN_IF}" LAN_MTU="${LAN_MTU}" MGMT_ADDR="${MGMT_ADDR}" VM_DATASET="${VM_DATASET}" MGMT_GROUP="${MGMT_GROUP}" MGMT_USER="${MGMT_USER}" SSH_ADMIN_KEY_FILE="${SSH_ADMIN_KEY_FILE}" SSH_ADMIN_AUTHORIZED_KEY="${SSH_ADMIN_AUTHORIZED_KEY}" sh scripts/01_host_setup.sh

configure-services:
	@EXT_IF="${EXT_IF}" MGMT_IF="${MGMT_IF}" LAN_IF="${LAN_IF}" MGMT_NET="${MGMT_NET}" LAN_NET="${LAN_NET}" MGMT_ADDR="${MGMT_ADDR}" DNS_ADDR="${DNS_ADDR}" KEA_API_USER="${KEA_API_USER}" KEA_API_USER_FILE="${KEA_API_USER_FILE}" KEA_API_PASSWORD_FILE="${KEA_API_PASSWORD_FILE}" KEA_HOST_DB_NAME="${KEA_HOST_DB_NAME}" KEA_HOST_DB_USER="${KEA_HOST_DB_USER}" KEA_HOST_DB_PASSWORD_FILE="${KEA_HOST_DB_PASSWORD_FILE}" POSTGRES_EXPORTER_DSN="${POSTGRES_EXPORTER_DSN}" STORK_ENABLE="${STORK_ENABLE}" STORK_DB_NAME="${STORK_DB_NAME}" STORK_DB_USER="${STORK_DB_USER}" STORK_DB_PASSWORD_FILE="${STORK_DB_PASSWORD_FILE}" sh scripts/configure_services.sh

init-postgresql:
	@PG_USER="${PG_USER}" PG_DATABASE="${PG_DATABASE}" PG_DATA="${PG_DATA}" sh scripts/init_postgresql.sh

init-kea-host-db:
	@KEA_HOST_DB_NAME="${KEA_HOST_DB_NAME}" KEA_HOST_DB_USER="${KEA_HOST_DB_USER}" KEA_HOST_DB_PASSWORD_FILE="${KEA_HOST_DB_PASSWORD_FILE}" PG_USER="${PG_USER}" sh scripts/init_kea_host_db.sh

init-stork:
	@STORK_ENABLE="${STORK_ENABLE}" STORK_DB_NAME="${STORK_DB_NAME}" STORK_DB_USER="${STORK_DB_USER}" STORK_DB_PASSWORD_FILE="${STORK_DB_PASSWORD_FILE}" PG_USER="${PG_USER}" sh scripts/init_stork.sh

init-ipam:
	@PGDATABASE="${PG_DATABASE}" PGUSER="${PG_USER}" IPAM_POOL="${IPAM_POOL}" IPAM_SUBNET="${IPAM_SUBNET}" IPAM_FIRST_HOST="${IPAM_FIRST_HOST}" IPAM_LAST_HOST="${IPAM_LAST_HOST}" IPAM_VLAN="${IPAM_VLAN}" KEA_SUBNET_ID="${KEA_SUBNET_ID}" sh scripts/03_init_ipam.sh

init-vm:
	@VM_DIR="${VM_DIR}" VM_DATASET="${VM_DATASET}" LAN_IF="${LAN_IF}" LAN_MTU="${LAN_MTU}" sh scripts/init_vm.sh

deprovision: deprovision-vm

deprovision-vm:
	@test -n "${VM_NAME}" || { echo "ERROR: set VM_NAME=<name>" >&2; exit 64; }
	@PGDATABASE="${PG_DATABASE}" PGUSER="${PG_USER}" sh scripts/deprovision_vm.sh "${VM_NAME}"

fetch-cloud-image:
	@FREEBSD_CLOUD_IMAGE_URL="${FREEBSD_CLOUD_IMAGE_URL}" FREEBSD_CLOUD_IMAGE_CACHE="${FREEBSD_CLOUD_IMAGE_CACHE}" FREEBSD_CLOUD_IMAGE_SHA256="${FREEBSD_CLOUD_IMAGE_SHA256}" FREEBSD_CLOUD_IMAGE_CHECKSUM_URL="${FREEBSD_CLOUD_IMAGE_CHECKSUM_URL}" sh scripts/fetch_freebsd_cloud_image.sh

provision-vm: fetch-cloud-image
	@test -n "${VM_NAME}" || { echo "ERROR: set VM_NAME=<name>" >&2; exit 64; }
	@PGDATABASE="${PG_DATABASE}" PGUSER="${PG_USER}" VM_OWNER="${VM_OWNER}" CLOUD_INIT_USER="${CLOUD_INIT_USER}" CONTROL_PLANE_ID="${CONTROL_PLANE_ID}" SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE}" FREEBSD_CLOUD_IMAGE_URL="${FREEBSD_CLOUD_IMAGE_URL}" FREEBSD_CLOUD_IMAGE_CACHE="${FREEBSD_CLOUD_IMAGE_CACHE}" FREEBSD_CLOUD_IMAGE_SHA256="${FREEBSD_CLOUD_IMAGE_SHA256}" FREEBSD_CLOUD_IMAGE_CHECKSUM_URL="${FREEBSD_CLOUD_IMAGE_CHECKSUM_URL}" sh scripts/provision_vm.sh "${VM_NAME}" "${TEMPLATE}"

bootstrap-kubectl:
	@KUBECTL_BOOTSTRAP="${KUBECTL_BOOTSTRAP}" KUBECTL_VERIFY="${KUBECTL_VERIFY}" KUBECONFIG_SOURCE="${KUBECONFIG_SOURCE}" KUBECONFIG_DEST="${KUBECONFIG_DEST}" KUBECONFIG_REFRESH="${KUBECONFIG_REFRESH}" KUBECONFIG_REMOTE_HOST="${KUBECONFIG_REMOTE_HOST}" KUBECONFIG_REMOTE_USER="${KUBECONFIG_REMOTE_USER}" KUBECONFIG_REMOTE_PATH="${KUBECONFIG_REMOTE_PATH}" KUBECONFIG_REMOTE_SSH_KEY="${KUBECONFIG_REMOTE_SSH_KEY}" KUBECONFIG_REMOTE_SUDO="${KUBECONFIG_REMOTE_SUDO}" KUBECONFIG_KNOWN_HOSTS="${KUBECONFIG_KNOWN_HOSTS}" SSH_PRIVATE_KEY_FILE="${SSH_PRIVATE_KEY_FILE}" sh scripts/bootstrap_kubeconfig.sh

cluster-up: fetch-cloud-image bootstrap-kubectl
	@PGDATABASE="${PG_DATABASE}" PGUSER="${PG_USER}" IPAM_POOL="${IPAM_POOL}" VM_OWNER="${VM_OWNER}" CLOUD_INIT_USER="${CLOUD_INIT_USER}" CONTROL_PLANE_ID="${CONTROL_PLANE_ID}" SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE}" SSH_PRIVATE_KEY_FILE="${SSH_PRIVATE_KEY_FILE}" CLUSTER_NODE_PREFIX="${CLUSTER_NODE_PREFIX}" CLUSTER_NODE_COUNT="${CLUSTER_NODE_COUNT}" CLUSTER_PROFILE_FILE="${CLUSTER_PROFILE_FILE}" CLUSTER_STATE_DIR="${CLUSTER_STATE_DIR}" CLUSTER_BOOT_TIMEOUT="${CLUSTER_BOOT_TIMEOUT}" CLUSTER_POLL_INTERVAL="${CLUSTER_POLL_INTERVAL}" CLUSTER_SSH_USER="${CLUSTER_SSH_USER}" KUBECTL_BOOTSTRAP="${KUBECTL_BOOTSTRAP}" KUBECONFIG_SOURCE="" KUBECONFIG_DEST="${KUBECONFIG_DEST}" KUBECTL_VERIFY="${KUBECTL_VERIFY}" FREEBSD_CLOUD_IMAGE_URL="${FREEBSD_CLOUD_IMAGE_URL}" FREEBSD_CLOUD_IMAGE_CACHE="${FREEBSD_CLOUD_IMAGE_CACHE}" FREEBSD_CLOUD_IMAGE_SHA256="${FREEBSD_CLOUD_IMAGE_SHA256}" FREEBSD_CLOUD_IMAGE_CHECKSUM_URL="${FREEBSD_CLOUD_IMAGE_CHECKSUM_URL}" sh scripts/freebsd_cluster.sh up

cluster-status:
	@PGDATABASE="${PG_DATABASE}" PGUSER="${PG_USER}" CLUSTER_NODE_PREFIX="${CLUSTER_NODE_PREFIX}" CLUSTER_NODE_COUNT="${CLUSTER_NODE_COUNT}" CLUSTER_PROFILE_FILE="${CLUSTER_PROFILE_FILE}" CLUSTER_STATE_DIR="${CLUSTER_STATE_DIR}" sh scripts/freebsd_cluster.sh status

cluster-down:
	@PGDATABASE="${PG_DATABASE}" PGUSER="${PG_USER}" CLUSTER_NODE_PREFIX="${CLUSTER_NODE_PREFIX}" CLUSTER_NODE_COUNT="${CLUSTER_NODE_COUNT}" CLUSTER_PROFILE_FILE="${CLUSTER_PROFILE_FILE}" CLUSTER_STATE_DIR="${CLUSTER_STATE_DIR}" sh scripts/freebsd_cluster.sh down

provision-jail-cluster: fetch-cloud-image bootstrap-kubectl
	@PGDATABASE="${PG_DATABASE}" PGUSER="${PG_USER}" IPAM_POOL="${IPAM_POOL}" VM_OWNER="${VM_OWNER}" CLOUD_INIT_USER="${CLOUD_INIT_USER}" CONTROL_PLANE_ID="${CONTROL_PLANE_ID}" SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE}" SSH_PRIVATE_KEY_FILE="${SSH_PRIVATE_KEY_FILE}" KUBECONFIG_SOURCE="" KUBECONFIG_DEST="${KUBECONFIG_DEST}" FREEBSD_CLOUD_IMAGE_URL="${FREEBSD_CLOUD_IMAGE_URL}" FREEBSD_CLOUD_IMAGE_CACHE="${FREEBSD_CLOUD_IMAGE_CACHE}" FREEBSD_CLOUD_IMAGE_SHA256="${FREEBSD_CLOUD_IMAGE_SHA256}" FREEBSD_CLOUD_IMAGE_CHECKSUM_URL="${FREEBSD_CLOUD_IMAGE_CHECKSUM_URL}" sh scripts/provision_freebsd_jail_cluster.sh

start-services:
	@PF_ROLLBACK_TIMEOUT="${PF_ROLLBACK_TIMEOUT}" LOKI_READY_TIMEOUT="${LOKI_READY_TIMEOUT}" DNS_READY_TIMEOUT="${DNS_READY_TIMEOUT}" STORK_READY_TIMEOUT="${STORK_READY_TIMEOUT}" STORK_ENABLE="${STORK_ENABLE}" MGMT_ADDR="${MGMT_ADDR}" DNS_ADDR="${DNS_ADDR}" KEA_API_USER_FILE="${KEA_API_USER_FILE}" KEA_API_PASSWORD_FILE="${KEA_API_PASSWORD_FILE}" sh scripts/start_services.sh

validate-freebsd: lint
	@sh tests/test_pf.sh
	@sh tests/test_kea.sh
	@sh tests/test_unbound.sh
	@sh tests/test_observability.sh
	@sh tests/test_stork.sh
	@sh tests/test_cloud_image.sh
	@sh tests/test_cluster.sh
	@sh tests/test_kubeconfig.sh
	@sockstat -4 -6 -l
