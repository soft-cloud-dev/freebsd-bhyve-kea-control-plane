# Prometheus and Grafana

The V2 observability add-on is read-only. `cpctl metrics` queries the PostgreSQL `bkcp` schema, exposes Prometheus text metrics, and never calls the lifecycle executor or infrastructure drivers.

## Endpoints

Default listen address: `127.0.0.1:9188`.

```text
/metrics      Prometheus exposition
/-/healthy    process liveness
/-/ready      PostgreSQL readiness
```

Keep the exporter and Prometheus loopback-bound unless an authenticated monitoring network or reverse proxy is configured.

## Build and install the exporter

```sh
make verify
make build

install -m 0755 bin/cpctl /usr/local/sbin/cpctl
install -m 0555 config/rc.d/bkcp_metrics /usr/local/etc/rc.d/bkcp_metrics
```

Create or select an unprivileged service account:

```sh
pw usershow bkcp >/dev/null 2>&1 || \
  pw useradd bkcp -d /nonexistent -s /usr/sbin/nologin -w no
```

## Create a read-only PostgreSQL role

Run as the database owner and replace the password and database name for the site:

```sql
CREATE ROLE bkcp_metrics LOGIN PASSWORD 'REPLACE_WITH_SECRET';
GRANT CONNECT ON DATABASE controlplane TO bkcp_metrics;
GRANT USAGE ON SCHEMA bkcp TO bkcp_metrics;
GRANT SELECT ON ALL TABLES IN SCHEMA bkcp TO bkcp_metrics;
ALTER DEFAULT PRIVILEGES IN SCHEMA bkcp
    GRANT SELECT ON TABLES TO bkcp_metrics;
```

Store the exporter DSN outside the site configuration so the metrics process does not inherit lifecycle write privileges:

```sh
install -m 0400 -o bkcp -g bkcp /dev/null /usr/local/etc/bkcp/metrics.dsn
printf '%s\n' \
  'postgresql://bkcp_metrics:REPLACE_WITH_SECRET@127.0.0.1:5432/controlplane?sslmode=disable' \
  > /usr/local/etc/bkcp/metrics.dsn
chown bkcp:bkcp /usr/local/etc/bkcp/metrics.dsn
chmod 0400 /usr/local/etc/bkcp/metrics.dsn
```

Prefer a protected password file, certificate authentication, or local socket policy where available.

## Enable the FreeBSD service

```sh
sysrc bkcp_metrics_enable=YES
sysrc bkcp_metrics_user=bkcp
sysrc bkcp_metrics_config=/usr/local/etc/bkcp/site.toml
sysrc bkcp_metrics_dsn_file=/usr/local/etc/bkcp/metrics.dsn
sysrc bkcp_metrics_listen=127.0.0.1:9188

service bkcp_metrics start
service bkcp_metrics status

fetch -qo - http://127.0.0.1:9188/-/healthy
fetch -qo - http://127.0.0.1:9188/-/ready
fetch -qo - http://127.0.0.1:9188/metrics | head
```

The service can also be run directly:

```sh
cpctl metrics \
  --config /usr/local/etc/bkcp/site.toml \
  --dsn-file /usr/local/etc/bkcp/metrics.dsn \
  --listen 127.0.0.1:9188
```

## Configure Prometheus

The checked-in configuration scrapes the exporter every 15 seconds and loads the BKCP alert rules.

```sh
install -d -m 0755 /usr/local/etc/prometheus
install -m 0644 \
  observability/prometheus/prometheus.yml \
  /usr/local/etc/prometheus.yml
install -m 0644 \
  observability/prometheus/bkcp.rules.yml \
  /usr/local/etc/prometheus/bkcp.rules.yml

promtool check config /usr/local/etc/prometheus.yml
promtool check rules /usr/local/etc/prometheus/bkcp.rules.yml
service prometheus restart
```

Merge the `scrape_configs` and `rule_files` entries into an existing Prometheus configuration rather than replacing unrelated site monitoring.

## Provision Grafana

The datasource and dashboard are file-provisioned and should remain version controlled.

```sh
install -d -m 0755 /usr/local/etc/grafana/provisioning/datasources
install -d -m 0755 /usr/local/etc/grafana/provisioning/dashboards
install -d -m 0755 -o grafana -g grafana /var/db/grafana/dashboards/bkcp

install -m 0644 \
  observability/grafana/provisioning/datasources/bkcp-prometheus.yml \
  /usr/local/etc/grafana/provisioning/datasources/bkcp-prometheus.yml
install -m 0644 \
  observability/grafana/provisioning/dashboards/bkcp.yml \
  /usr/local/etc/grafana/provisioning/dashboards/bkcp.yml
install -m 0644 -o grafana -g grafana \
  observability/grafana/dashboards/bkcp-overview.json \
  /var/db/grafana/dashboards/bkcp/bkcp-overview.json

service grafana restart
```

The provisioned datasource UID is `bkcp-prometheus`; its default URL is `http://127.0.0.1:9090`. Adjust the provisioning file when Prometheus runs elsewhere.

## Dashboard coverage

The `BKCP Control Plane` dashboard includes:

- active and converged resource counts;
- resources requiring attention;
- effective-state distribution;
- unavailable observation domains;
- latest operation statuses;
- observation and reconciliation age;
- operation journal totals;
- failed execution steps by driver;
- active allocations by pool.

## Metric contract

Primary metrics:

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

Resource names are labels. No credentials, DSNs, IP addresses, MAC addresses, specification bodies, error details, or persisted step inputs are exported.

## Alert coverage

The included rules detect:

- exporter or PostgreSQL snapshot failure;
- resources that remain non-converged;
- unavailable observation domains;
- failed or blocked latest operations;
- stale resource observations.

Tune alert durations to the reconciliation cadence and operational service-level objectives of the site.
