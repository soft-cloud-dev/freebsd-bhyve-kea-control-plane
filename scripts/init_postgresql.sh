#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"
require_root

PG_USER="${PG_USER:-postgres}"
PG_DATABASE="${PG_DATABASE:-inventory}"
PG_DATA="${PG_DATA:-/var/db/postgres/data16}"

sysrc postgresql_enable=YES >/dev/null

if [ ! -s "${PG_DATA}/PG_VERSION" ]; then
    service postgresql initdb
fi

service postgresql status >/dev/null 2>&1 || service postgresql start

i=0
until sudo -u "${PG_USER}" pg_isready -q -d postgres; do
    i=$((i+1))
    [ "$i" -lt 30 ] || die "PostgreSQL did not become ready"
    sleep 1
done

if ! sudo -u "${PG_USER}" psql -X -qAt -d postgres -c "SELECT 1 FROM pg_database WHERE datname='${PG_DATABASE}'" | grep -qx 1; then
    sudo -u "${PG_USER}" createdb "${PG_DATABASE}"
fi

sudo -u "${PG_USER}" psql -X -v ON_ERROR_STOP=1 -d "${PG_DATABASE}" -f db/001_inventory.sql
sudo -u "${PG_USER}" psql -X -v ON_ERROR_STOP=1 -d "${PG_DATABASE}" -f db/002_monitoring.sql
