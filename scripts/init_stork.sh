#!/bin/sh
set -eu

. "$(dirname "$0")/lib.sh"
require_root

STORK_ENABLE="${STORK_ENABLE:-yes}"
STORK_DB_NAME="${STORK_DB_NAME:-stork}"
STORK_DB_USER="${STORK_DB_USER:-stork-server}"
STORK_DB_PASSWORD_FILE="${STORK_DB_PASSWORD_FILE:-/usr/local/etc/stork/database-password}"
PG_USER="${PG_USER:-postgres}"

[ "$STORK_ENABLE" = yes ] || {
    echo "[*] Stork database initialization disabled."
    exit 0
}

case "$STORK_DB_NAME" in
    ''|[0-9]*|*[!A-Za-z0-9_]*) die "invalid STORK_DB_NAME" ;;
esac
case "$STORK_DB_USER" in
    ''|[0-9]*|*[!A-Za-z0-9_-]*) die "invalid STORK_DB_USER" ;;
esac

[ -s "$STORK_DB_PASSWORD_FILE" ] || die "missing Stork database password file"
require_commands psql createdb

password=$(sed -n '1p' "$STORK_DB_PASSWORD_FILE")
case "$password" in
    ''|*[!0-9a-f]*) die "invalid Stork database password" ;;
esac

run_as_postgres() {
    if [ "$(id -un)" = "$PG_USER" ]; then
        "$@"
    else
        sudo -u "$PG_USER" "$@"
    fi
}

role_sql=$(sql_literal "$STORK_DB_USER")
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

database_sql=$(sql_literal "$STORK_DB_NAME")
database_exists=$(run_as_postgres psql -X -qAt -d postgres \
    -c "SELECT 1 FROM pg_database WHERE datname = '${database_sql}';")
if [ "$database_exists" != 1 ]; then
    run_as_postgres createdb --owner="$STORK_DB_USER" "$STORK_DB_NAME"
else
    run_as_postgres psql -X -v ON_ERROR_STOP=1 -d postgres \
        -c "ALTER DATABASE \"${database_sql}\" OWNER TO \"${role_sql}\";"
fi

run_as_postgres psql -X -v ON_ERROR_STOP=1 -d "$STORK_DB_NAME" \
    -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

echo "[+] Stork PostgreSQL database initialized."
