#!/bin/sh
set -eu

TEMPLATE=${1:?usage: render_kea_config.sh TEMPLATE LAN_IF [EXISTING_CONFIG]}
LAN_IF=${2:?usage: render_kea_config.sh TEMPLATE LAN_IF [EXISTING_CONFIG]}
EXISTING_CONFIG=${3:-}

if [ -n "$EXISTING_CONFIG" ] && [ -r "$EXISTING_CONFIG" ]; then
    jq --arg lan_if "$LAN_IF" --slurpfile existing "$EXISTING_CONFIG" '
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
    ' "$TEMPLATE"
else
    jq --arg lan_if "$LAN_IF" \
        '.Dhcp4["interfaces-config"].interfaces = [$lan_if]' \
        "$TEMPLATE"
fi
