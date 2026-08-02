# Observability

V2 provides a read-only Prometheus exporter and file-provisioned Grafana dashboard.

```text
PostgreSQL bkcp schema
        |
        | SELECT only
        v
cpctl metrics :9188
        |
        v
Prometheus :9090
        |
        v
Grafana
```

Monitoring does not invoke lifecycle drivers and does not mutate VM, Kea, ZFS, PF, or operation state.

## Start the exporter

The service binds to loopback by default:

```sh
cpctl metrics \
  --config /usr/local/etc/bkcp/site.toml \
  --dsn-file /usr/local/etc/bkcp/metrics.dsn \
  --listen 127.0.0.1:9188
```

Endpoints:

```text
/metrics      Prometheus exposition
/-/healthy    process liveness
/-/ready      PostgreSQL readiness
```

Use a dedicated PostgreSQL role with `CONNECT`, schema `USAGE`, and table `SELECT` only. Store its DSN in a mode `0400` file readable by the exporter account. When `--dsn-file` is omitted, the exporter uses the site database DSN.

## FreeBSD service

Install and enable the included rc.d script:

```sh
install -m 0555 config/rc.d/bkcp_metrics /usr/local/etc/rc.d/bkcp_metrics

sysrc bkcp_metrics_enable=YES
sysrc bkcp_metrics_user=bkcp
sysrc bkcp_metrics_config=/usr/local/etc/bkcp/site.toml
sysrc bkcp_metrics_dsn_file=/usr/local/etc/bkcp/metrics.dsn
sysrc bkcp_metrics_listen=127.0.0.1:9188

service bkcp_metrics start
service bkcp_metrics status
```

## Prometheus

Checked-in assets:

```text
observability/prometheus/prometheus.yml
observability/prometheus/bkcp.rules.yml
```

The default scrape target is `127.0.0.1:9188`. Validate before restart:

```sh
promtool check config /usr/local/etc/prometheus.yml
promtool check rules /usr/local/etc/prometheus/bkcp.rules.yml
```

The alert rules cover exporter failure, failed snapshots, non-converged resources, unavailable observation domains, failed latest operations, and stale observations.

## Grafana

Checked-in provisioning assets:

```text
observability/grafana/provisioning/datasources/bkcp-prometheus.yml
observability/grafana/provisioning/dashboards/bkcp.yml
observability/grafana/dashboards/bkcp-overview.json
```

The dashboard datasource UID is `bkcp-prometheus`. The default Prometheus URL is `http://127.0.0.1:9090`.

The `BKCP Control Plane` dashboard shows:

- active, converged, and attention-required resources;
- effective-state distribution;
- unavailable observation domains;
- latest operation status;
- observation and reconciliation age;
- operation and step journal state;
- active allocations by pool.

Provisioned dashboards are repository-owned. Do not treat UI edits as canonical.

## Metric families

```text
bkcp_resource_info
bkcp_resource_generation
bkcp_resource_effective_state
bkcp_resource_observation_state
bkcp_resource_last_observation_timestamp_seconds
bkcp_resource_last_successful_reconciliation_timestamp_seconds
bkcp_resource_latest_operation_info
bkcp_resource_latest_operation_attempts
bkcp_operations
bkcp_operation_steps
bkcp_allocations
bkcp_exporter_scrape_success
bkcp_exporter_scrape_duration_seconds
```

The exporter omits credentials, DSNs, IP addresses, MAC addresses, specification bodies, persisted step inputs, and error details.

Full installation commands and the read-only role example are in [`observability/README.md`](https://github.com/soft-cloud-dev/freebsd-bhyve-kea-control-plane/blob/main/observability/README.md).
