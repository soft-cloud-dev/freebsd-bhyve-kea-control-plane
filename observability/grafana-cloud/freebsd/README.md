# Grafana Cloud FreeBSD node observability

This directory configures one Grafana Alloy process per FreeBSD host. It exports host metrics with Alloy's Unix exporter and tails selected system, bhyve, jail, Kea, PostgreSQL, and BKCP logs to Grafana Cloud.

The deployment is host-local. Do not enable Alloy clustering for this configuration.

## Requirements

- FreeBSD host with outbound HTTPS access to Grafana Cloud.
- Grafana Alloy installed as `/usr/local/bin/alloy`.
- A dedicated unprivileged `alloy` account.
- Grafana Cloud metrics and logs write endpoints, tenant IDs, and an access-policy token with only the required write scopes.

The Unix exporter collector set depends on the Alloy build and supported FreeBSD collectors. Validate the configuration on the target release before enabling the service.

## Install

```sh
pw usershow alloy >/dev/null 2>&1 || pw useradd alloy -d /var/db/alloy -s /usr/sbin/nologin -w no
install -d -m 0750 -o alloy -g alloy /usr/local/etc/alloy /var/db/alloy /var/cache/bkcp/node-exporter
install -m 0644 observability/grafana-cloud/freebsd/config.alloy /usr/local/etc/alloy/freebsd-node.alloy
install -m 0600 -o root -g wheel observability/grafana-cloud/freebsd/alloy.env.example /usr/local/etc/alloy/freebsd-node.env
install -m 0555 config/rc.d/bkcp_alloy_freebsd_node /usr/local/etc/rc.d/bkcp_alloy_freebsd_node
```

Edit `/usr/local/etc/alloy/freebsd-node.env`. Do not quote values and do not place shell expressions in this file.

The service reads protected system log files. Add the Alloy account to the group that owns the logs at the site, commonly `wheel`, or use ACLs to grant read-only access to the exact files. Avoid running Alloy as root.

Example using the existing log group:

```sh
pw groupmod wheel -m alloy
```

## Validate and enable

```sh
set -a
. /usr/local/etc/alloy/freebsd-node.env
set +a
/usr/local/bin/alloy validate /usr/local/etc/alloy/freebsd-node.alloy
sysrc bkcp_alloy_freebsd_node_enable=YES
service bkcp_alloy_freebsd_node start
service bkcp_alloy_freebsd_node status
fetch -qo - http://127.0.0.1:12346/-/ready
fetch -qo - http://127.0.0.1:12346/metrics | head
```

Verify in Grafana Cloud that `up{job="integrations/freebsd-node"}` is present and that log streams contain the expected `instance`, `site`, `cluster`, `role`, and `log_source` labels.

## Security boundaries

- Keep the Alloy HTTP listener loopback-bound.
- Store the environment file as root-owned mode `0600`.
- Use a token limited to metrics and logs write operations.
- Do not add credentials or full command lines as static labels.
- Keep label values low-cardinality and stable.
- Grant Alloy read access only to logs selected by `config.alloy`.

## Rollback

```sh
service bkcp_alloy_freebsd_node stop || true
sysrc -x bkcp_alloy_freebsd_node_enable
rm -f /usr/local/etc/rc.d/bkcp_alloy_freebsd_node
rm -f /usr/local/etc/alloy/freebsd-node.alloy
rm -f /usr/local/etc/alloy/freebsd-node.env
```
