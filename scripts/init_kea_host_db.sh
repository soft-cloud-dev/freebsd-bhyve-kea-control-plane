#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"
require_root

KEA_HOST_DB_NAME="${KEA_HOST_DB_NAME:-kea_hosts}"
KEA_HOST_DB_USER="${KEA_HOST_DB_USER:-kea_hosts}"
KEA_HOST_DB_PASSWORD_FILE="${KEA_HOST_DB_PASSWORD_FILE:-/usr/local/etc/kea/kea-host-db-password}"
PG_USER="${PG_USER:-postgres}"

case "$KEA_HOST_DB_NAME" in
    ''|[0-9]*|*[!A-Za-z0-9_]*) die "invalid KEA_HOST_DB_NAME" ;;
esac
case "$KEA_HOST_DB_USER" in
    ''|[0-9]*|*[!A-Za-z0-9_]*) die "invalid KEA_HOST_DB_USER" ;;
esac

require_commands createdb kea-admin openssl psql sudo

install -d -m 0750 /usr/local/etc/kea
if [ ! -s "$KEA_HOST_DB_PASSWORD_FILE" ]; then
    umask 077
    openssl rand -hex 32 > "$KEA_HOST_DB_PASSWORD_FILE"
fi
chmod 0600 "$KEA_HOST_DB_PASSWORD_FILE"

password=$(sed -n '1p' "$KEA_HOST_DB_PASSWORD_FILE")
case "$password" in
    ''|*[!0-9a-f]*) die "invalid Kea hosts database password" ;;
esac

run_as_postgres() {
    if [ "$(id -un)" = "$PG_USER" ]; then
        "$@"
    else
        sudo -u "$PG_USER" "$@"
    fi
}

role_sql=$(sql_literal "$KEA_HOST_DB_USER")
password_sql=$(sql_literal "$password")
role_exists=$(run_as_postgres psql -X -qAt -d postgres \
    -c "SELECT 1 FROM pg_roles WHERE rolname = '${role_sql}';")
if [ "$role_exists" != 1 ]; then
    run_as_postgres psql -X -v ON_ERROR_STOP=1 -d postgres <<SQL
CREATE ROLE "${role_sql}" LOGIN PASSWORD '${password_sql}';
SQL
else
    run_as_postgres psql -X -v ON_ERROR_STOP=1 -d postgres <<SQL
ALTER ROLE "${role_sql}" WITH LOGIN PASSWORD '${password_sql}';
SQL
fi

database_sql=$(sql_literal "$KEA_HOST_DB_NAME")
database_exists=$(run_as_postgres psql -X -qAt -d postgres \
    -c "SELECT 1 FROM pg_database WHERE datname = '${database_sql}';")
if [ "$database_exists" != 1 ]; then
    run_as_postgres createdb --owner="$KEA_HOST_DB_USER" "$KEA_HOST_DB_NAME"
else
    run_as_postgres psql -X -v ON_ERROR_STOP=1 -d postgres \
        -c "ALTER DATABASE \"${database_sql}\" OWNER TO \"${role_sql}\";"
fi

table_count=$(run_as_postgres psql -X -qAt -d "$KEA_HOST_DB_NAME" \
    -c "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname = 'public';")
if [ "$table_count" -eq 0 ]; then
    kea-admin db-init pgsql \
        -h 127.0.0.1 \
        -u "$KEA_HOST_DB_USER" \
        -p "$password" \
        -n "$KEA_HOST_DB_NAME"
else
    kea-admin db-version pgsql \
        -h 127.0.0.1 \
        -u "$KEA_HOST_DB_USER" \
        -p "$password" \
        -n "$KEA_HOST_DB_NAME" >/dev/null
fi

echo "[+] Kea PostgreSQL hosts database initialized."
