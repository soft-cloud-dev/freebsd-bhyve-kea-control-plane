#!/bin/sh
set -eu

TEMPLATE=${1:?usage: render_kea_config.sh TEMPLATE LAN_IF [EXISTING_CONFIG [HOST_DB_NAME HOST_DB_USER HOST_DB_PASSWORD_FILE HOST_DB_HOST]]}
LAN_IF=${2:?usage: render_kea_config.sh TEMPLATE LAN_IF [EXISTING_CONFIG [HOST_DB_NAME HOST_DB_USER HOST_DB_PASSWORD_FILE HOST_DB_HOST]]}
EXISTING_CONFIG=${3:-}
HOST_DB_NAME=${4:-}
HOST_DB_USER=${5:-}
HOST_DB_PASSWORD_FILE=${6:-}
HOST_DB_HOST=${7:-127.0.0.1}

if [ -n "$EXISTING_CONFIG" ] && [ -r "$EXISTING_CONFIG" ]; then
    rendered=$(jq --arg lan_if "$LAN_IF" --slurpfile existing "$EXISTING_CONFIG" '
        ($existing[0].Dhcp4.subnet4 // []) as $existing_subnets
        | .Dhcp4["interfaces-config"].interfaces = [$lan_if]
        | .Dhcp4.subnet4 |= map(
            . as $subnet
            | .reservations = (
                (
                    $existing_subnets
                    | map(select(.id == $subnet.id))
                    | first
                    | .reservations
                ) // $subnet.reservations // []
            )
        )
    ' "$TEMPLATE")
else
    rendered=$(jq --arg lan_if "$LAN_IF" \
        '.Dhcp4["interfaces-config"].interfaces = [$lan_if]' \
        "$TEMPLATE")
fi

if [ -n "$HOST_DB_NAME" ]; then
    [ -n "$HOST_DB_USER" ] || {
        echo "ERROR: HOST_DB_USER is required when HOST_DB_NAME is set" >&2
        exit 1
    }
    [ -r "$HOST_DB_PASSWORD_FILE" ] || {
        echo "ERROR: host database password file is not readable: $HOST_DB_PASSWORD_FILE" >&2
        exit 1
    }

    printf '%s' "$rendered" | jq \
        --arg db_name "$HOST_DB_NAME" \
        --arg db_user "$HOST_DB_USER" \
        --arg db_host "$HOST_DB_HOST" \
        --rawfile db_password "$HOST_DB_PASSWORD_FILE" '
        .Dhcp4["hosts-databases"] = [{
            type: "postgresql",
            name: $db_name,
            user: $db_user,
            password: ($db_password | sub("[\r\n]+$"; "")),
            host: $db_host,
            port: 5432
        }]
        | del(.Dhcp4["hosts-database"])
        | .Dhcp4["hooks-libraries"] |= (
            map(select(.library != "/usr/local/lib/kea/hooks/libdhcp_pgsql.so" and .library != "/usr/local/lib/kea/hooks/libdhcp_lease_cmds.so"))
            | [{"library":"/usr/local/lib/kea/hooks/libdhcp_pgsql.so"}, {"library":"/usr/local/lib/kea/hooks/libdhcp_lease_cmds.so"}] + .
        )
    '
else
    printf '%s\n' "$rendered"
fi
