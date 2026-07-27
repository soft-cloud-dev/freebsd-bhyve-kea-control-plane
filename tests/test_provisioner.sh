#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

for file in \
    "${ROOT}/scripts/01_host_setup.sh" \
    "${ROOT}/scripts/02_install_dependencies.sh" \
    "${ROOT}/scripts/03_init_ipam.sh" \
    "${ROOT}/scripts/apply_pf_safely.sh" \
    "${ROOT}/scripts/provision_vm.sh" \
    "${ROOT}/scripts/rollback_vm.sh"
do
    sh -n "${file}"
done

echo "PASS: shell syntax"
