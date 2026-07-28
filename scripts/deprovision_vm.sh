#!/bin/sh
set -eu

[ "$#" -eq 1 ] || {
    echo "Usage: $0 <vm_name>" >&2
    exit 64
}

exec sh "$(dirname "$0")/rollback_vm.sh" "$1"
