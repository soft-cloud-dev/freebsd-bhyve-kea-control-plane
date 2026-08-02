#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"
require_root

PG_USER="${PG_USER:-postgres}"
PG_DATABASE="${PG_DATABASE:-inventory}"
PG_DATA="${PG_DATA:-/var/db/postgres/data16}"

if command -v service >/dev/null 2>&1 && [ -x /usr/local/etc/rc.d/postgresql ]; then
    sysrc postgresql_enable=YES >/dev/null
    if [ ! -s "${PG_DATA}/PG_VERSION" ]; then
        service postgresql initdb
    fi
    service postgresql status >/dev/null 2>&1 || service postgresql start
elif command -v container >/dev/null 2>&1; then
    if ! container_is_running postgres; then
        echo "[*] Starting PostgreSQL container..."
        container run -d --name postgres -p 5432:5432 -v "${PG_DATA}:/var/lib/postgresql/data" postgres:16 || container start postgres || true
    fi
fi

i=0
until (command -v pg_isready >/dev/null 2>&1 && pg_isready -q) || \
      (command -v pg_isready >/dev/null 2>&1 && pg_isready -h 127.0.0.1 -U "${PG_USER}" -q) || \
      (command -v container >/dev/null 2>&1 && container exec postgres pg_isready -U "${PG_USER}" -q 2>/dev/null) || \
      sudo -u "${PG_USER}" pg_isready -q -d postgres 2>/dev/null; do
    i=$((i+1))
    [ "$i" -lt 30 ] || die "PostgreSQL did not become ready"
    sleep 1
done

run_sql() {
    local sql_file="$1"
    if command -v container >/dev/null 2>&1 && container_is_running postgres; then
        container exec -i postgres psql -U "${PG_USER}" -d "${PG_DATABASE}" -v ON_ERROR_STOP=1 < "$sql_file" 2>/dev/null || psql -h 127.0.0.1 -U "${PG_USER}" -d "${PG_DATABASE}" -v ON_ERROR_STOP=1 -f "$sql_file" 2>/dev/null || sudo -u "${PG_USER}" psql -X -v ON_ERROR_STOP=1 -d "${PG_DATABASE}" -f "$sql_file"
    elif command -v psql >/dev/null 2>&1; then
        psql -h 127.0.0.1 -U "${PG_USER}" -d "${PG_DATABASE}" -v ON_ERROR_STOP=1 -f "$sql_file" 2>/dev/null || sudo -u "${PG_USER}" psql -X -v ON_ERROR_STOP=1 -d "${PG_DATABASE}" -f "$sql_file"
    fi
}

create_db() {
    if command -v container >/dev/null 2>&1 && container_is_running postgres; then
        container exec postgres createdb -U "${PG_USER}" "${PG_DATABASE}" 2>/dev/null || true
    elif command -v createdb >/dev/null 2>&1; then
        createdb -h 127.0.0.1 -U "${PG_USER}" "${PG_DATABASE}" 2>/dev/null || sudo -u "${PG_USER}" createdb "${PG_DATABASE}" 2>/dev/null || true
    fi
}

create_db
run_sql db/001_inventory.sql
run_sql db/002_monitoring.sql
run_sql db/003_mac_allocator.sql

echo "[+] PostgreSQL initialized successfully."
