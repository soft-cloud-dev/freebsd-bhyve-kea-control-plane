# Grafana Cloud PostgreSQL Database Observability

This optional integration sends PostgreSQL query telemetry and the existing BKCP control-plane metrics to Grafana Cloud through Grafana Alloy. It complements the local Prometheus and Grafana deployment; it does not replace `cpctl metrics` or grant monitoring any lifecycle mutation authority.

Upstream setup reference:

- [Set up self-managed PostgreSQL for Grafana Cloud Database Observability](https://grafana.com/docs/grafana-cloud/observe-and-act/monitor-applications/database-observability/set-up/postgres/)
- [database_observability.postgres component](https://grafana.com/docs/alloy/latest/reference/components/database_observability/database_observability.postgres/)

## Architecture

```text
PostgreSQL 14+
  | direct SQL connection as db-o11y
  v
Grafana Alloy 1.17+
  |-- PostgreSQL metrics -----------------> Grafana Cloud Metrics
  |-- query details/samples/schema/plans -> Grafana Cloud Logs
  `-- cpctl metrics :9188 ---------------> Grafana Cloud Metrics
```

Alloy must connect directly to PostgreSQL. Do not place PgBouncer, a load balancer, or a transaction-pooling proxy between Alloy and the monitored server.

## Collected data

Enabled:

- PostgreSQL server and database metrics;
- `pg_stat_statements` query metrics;
- query details and redacted samples;
- wait-event samples;
- schema details;
- explain plans;
- BKCP `cpctl metrics` families.

Disabled by this repository configuration:

- PostgreSQL log ingestion;
- unredacted query parameters;
- monitoring of Alloy's own `db-o11y` queries.

The Database Observability component emits query details, samples, schemas, and explain plans through the Grafana Cloud Logs endpoint even when PostgreSQL log-file ingestion is disabled.

## Requirements

- self-managed PostgreSQL 14 or later;
- permission to change `postgresql.conf` and restart PostgreSQL;
- Grafana Alloy 1.17.0 or later;
- FreeBSD AMD64, Linux AMD64/ARM64, macOS, or Windows collector host;
- direct TCP or Unix-socket access from Alloy to PostgreSQL;
- outbound HTTPS to the Grafana Cloud metrics and logs endpoints;
- a Grafana Cloud access policy token limited to `metrics:write` and `logs:write`;
- `cpctl metrics` listening on `127.0.0.1:9188` when BKCP metrics are forwarded by the same Alloy process.

Grafana publishes a FreeBSD AMD64 standalone Alloy binary. A FreeBSD package may lag the minimum Database Observability version, so verify with:

```sh
alloy --version
```

Use a verified standalone release when the installed package is older than 1.17.0.

## 1. Configure PostgreSQL

Merge `postgresql.conf.example` into the active PostgreSQL configuration:

```conf
shared_preload_libraries = 'pg_stat_statements'
compute_query_id = on
pg_stat_statements.track = all
track_activity_query_size = 4096
```

Preserve any other entries already present in `shared_preload_libraries`. Restart PostgreSQL after changing startup-only settings:

```sh
service postgresql restart
```

Verify the active values:

```sh
psql controlplane <<'SQL'
SHOW shared_preload_libraries;
SHOW compute_query_id;
SHOW pg_stat_statements.track;
SHOW track_activity_query_size;
SQL
```

Expected values include `pg_stat_statements`, `on`, `all`, and `4096` or `4kB`.

## 2. Create the monitoring identity

Create a distinct login role with a generated password:

```sql
CREATE ROLE "db-o11y" LOGIN PASSWORD 'REPLACE_WITH_A_GENERATED_SECRET';
```

Then run the checked-in grants as the database owner:

```sh
psql -v ON_ERROR_STOP=1 \
  --dbname controlplane \
  --file observability/grafana-cloud/postgres/grants.sql
```

The repository grants:

- `pg_monitor`;
- `pg_read_all_stats`;
- schema `USAGE` on `bkcp`;
- table `SELECT` on `bkcp`;
- default table `SELECT` for future objects created by the role executing the default-privileges statement;
- `pg_stat_statements.track = none` for `db-o11y`.

Run the extension and object grants in each logical database that should be monitored. Granting `pg_read_all_data` is a broader upstream alternative, but is not the default here.

Allow only the collector host in `pg_hba.conf`. Prefer `scram-sha-256` and TLS for a network connection. Example:

```text
hostssl controlplane db-o11y 10.0.10.20/32 scram-sha-256
```

Reload PostgreSQL after an HBA-only change:

```sh
service postgresql reload
```

Validate with the monitoring identity:

```sh
psql 'postgresql://db-o11y@127.0.0.1:5432/controlplane?sslmode=require' \
  -c 'SELECT queryid, calls FROM pg_stat_statements LIMIT 1'
```

## 3. Install Alloy configuration and secrets

Create an unprivileged service account and directories:

```sh
pw usershow alloy >/dev/null 2>&1 || \
  pw useradd alloy -d /var/db/alloy -s /usr/sbin/nologin -w no

install -d -m 0750 -o root -g alloy /usr/local/etc/alloy
install -d -m 0750 -o alloy -g alloy /var/db/alloy
```

Install the configuration:

```sh
install -m 0644 \
  observability/grafana-cloud/postgres/config.alloy \
  /usr/local/etc/alloy/config.alloy
```

Install the PostgreSQL DSN. Percent-encode reserved characters in the password:

```sh
install -m 0640 -o root -g alloy \
  observability/grafana-cloud/postgres/postgres.dsn.example \
  /usr/local/etc/alloy/postgres.dsn
vi /usr/local/etc/alloy/postgres.dsn
```

The DSN should connect directly to the PostgreSQL server:

```text
postgresql://db-o11y:SECRET@127.0.0.1:5432/controlplane?sslmode=require
```

Install the Grafana Cloud environment file:

```sh
install -m 0640 -o root -g alloy \
  observability/grafana-cloud/postgres/alloy.env.example \
  /usr/local/etc/alloy/grafana-cloud.env
vi /usr/local/etc/alloy/grafana-cloud.env
```

Use a stable `BKCP_DB_INSTANCE` value. Changing it creates a new logical instance in Grafana Cloud.

## 4. Validate before starting

Load the environment into the validation shell without printing secrets:

```sh
set -a
. /usr/local/etc/alloy/grafana-cloud.env
set +a

alloy fmt --test /usr/local/etc/alloy/config.alloy
alloy validate /usr/local/etc/alloy/config.alloy
```

Validation checks component names, required fields, and unknown properties. It does not prove database connectivity or successful remote writes.

## 5. Run on FreeBSD

Install the repository rc.d service:

```sh
install -m 0555 config/rc.d/bkcp_alloy /usr/local/etc/rc.d/bkcp_alloy

sysrc bkcp_alloy_enable=YES
sysrc bkcp_alloy_user=alloy
sysrc bkcp_alloy_group=alloy
sysrc bkcp_alloy_binary=/usr/local/bin/alloy
sysrc bkcp_alloy_config=/usr/local/etc/alloy/config.alloy
sysrc bkcp_alloy_env_file=/usr/local/etc/alloy/grafana-cloud.env
sysrc bkcp_alloy_dsn_file=/usr/local/etc/alloy/postgres.dsn
sysrc bkcp_alloy_http_listen=127.0.0.1:12345

service bkcp_alloy start
service bkcp_alloy status
```

The Alloy diagnostic UI remains loopback-bound. Inspect it locally or through an authenticated SSH tunnel:

```sh
fetch -qo - http://127.0.0.1:12345/-/ready
fetch -qo - http://127.0.0.1:12345/-/healthy

tail -f /var/log/bkcp_alloy.log
```

## 6. Verify Grafana Cloud

In Grafana Cloud Database Observability:

1. Open the PostgreSQL setup or configuration page.
2. Confirm the instance named by `BKCP_DB_INSTANCE` reports telemetry.
3. Open the database overview and confirm query rate, errors, duration, and wait-event data.
4. Open a query details page and confirm samples remain redacted.
5. In Explore, query `up{job="integrations/db-o11y"}` and `up{job="bkcp"}`.

A healthy local Alloy process is insufficient if remote-write credentials, endpoint URLs, or egress policy are incorrect. Check component health and the service log together.

## PostgreSQL logs

`config.alloy` disables the `logs` collector because this repository does not mandate `logging_collector`, a log filename, or syslog routing. Enable logs only after selecting one explicit source:

- `loki.source.file` for PostgreSQL CSV/JSON/text files;
- `loki.source.syslog` for a controlled syslog path.

Forward that source to:

```text
database_observability.postgres.postgres_bkcp.logs_receiver
```

Do not grant Alloy broad access to `/var/log` merely to enable this feature.

## Security boundary

- `db-o11y` is separate from `bkcp_metrics` and the lifecycle database owner.
- The Alloy DSN and Grafana Cloud token are never committed.
- Query sample redaction remains enabled.
- Alloy's diagnostic HTTP endpoint is loopback-only.
- Cloud credentials have write-only telemetry scopes.
- The integration does not call `cpctl apply`, `reconcile`, `delete`, Kea, ZFS, PF, or `vm-bhyve` drivers.
- Grafana Cloud receives database metadata and query telemetry; assess organizational data-residency and retention requirements before enabling it.

## Rollback

Stop outbound telemetry without changing lifecycle operation:

```sh
service bkcp_alloy stop
sysrc bkcp_alloy_enable=NO
```

Optionally revoke the monitoring identity:

```sql
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA bkcp FROM "db-o11y";
REVOKE USAGE ON SCHEMA bkcp FROM "db-o11y";
REVOKE pg_read_all_stats FROM "db-o11y";
REVOKE pg_monitor FROM "db-o11y";
DROP ROLE "db-o11y";
```

Removing `pg_stat_statements` or startup settings is not required to stop Grafana Cloud transmission and should be evaluated separately because other local diagnostics may use them.
