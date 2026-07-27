# Observability

## Topology

```text
node_exporter 127.0.0.1:9100 ----+
postgres_exporter 127.0.0.1:9187 +--> Prometheus 127.0.0.1:9090 --+
Stork Kea exporter 127.0.0.1:9547 +                              |
Prometheus self-metrics ----------+                              |
                                                                 v
Promtail 127.0.0.1:9080 (/var/log/*) --> Loki 127.0.0.1:3100 -> Grafana 10.0.10.2:3000
```

Prometheus, Loki, Promtail, and all exporters bind to loopback. Grafana and the Stork Kea dashboard are exposed on the management VLAN. PF permits TCP/3000 and TCP/8080 only from `mgmt_net`.

## Install configuration

```sh
install -m 0644 config/prometheus.yml /usr/local/etc/prometheus.yml
install -m 0644 config/loki.yml /usr/local/etc/loki.yml
install -m 0644 config/promtail.yml /usr/local/etc/promtail.yml
install -m 0644 config/grafana.ini /usr/local/etc/grafana/grafana.ini
install -d -m 0755 /usr/local/etc/grafana/provisioning/datasources
install -d -m 0755 /usr/local/etc/grafana/provisioning/dashboards/json
install -m 0644 config/grafana/provisioning/datasources/prometheus.yml \
  /usr/local/etc/grafana/provisioning/datasources/prometheus.yml
install -m 0644 config/grafana/provisioning/datasources/loki.yml \
  /usr/local/etc/grafana/provisioning/datasources/loki.yml
install -m 0644 config/grafana/provisioning/dashboards/default.yml \
  /usr/local/etc/grafana/provisioning/dashboards/default.yml
```

Adapt `config/grafana.ini` to the real management address and hostname. For production, terminate TLS at Grafana or an authenticated management reverse proxy and then enable secure cookies and HSTS.

## PostgreSQL exporter role

Apply the monitoring role after creating `inventory`:

```sh
sudo -u postgres psql -d inventory -f db/002_monitoring.sql
```

The example rc configuration connects through the local PostgreSQL Unix socket. Set a password or certificate-based DSN when local peer authentication is not appropriate. Do not expose PostgreSQL solely to support metrics.

## Start order

Control plane services are managed via `container` CLI:

```sh
sh scripts/start_services.sh
# or manage individual containers:
container list
container start prometheus
container start loki
container start grafana
service stork_server status
service stork_agent status
```

## Validation

```sh
promtool check config /usr/local/etc/prometheus.yml
sockstat -4 -6 -l | egrep ':(3000|3100|8080|8081|9090|9100|9187|9547)'
fetch -qo- http://127.0.0.1:9100/metrics | head
fetch -qo- http://127.0.0.1:9187/metrics | head
fetch -qo- http://127.0.0.1:9547/metrics | head
fetch -qo- http://127.0.0.1:9090/-/ready
fetch -qo- http://127.0.0.1:3100/ready
grafana cli --config /usr/local/etc/grafana/grafana.ini admin reset-admin-password 'REPLACE-ME'
```

Expected bindings:

- Grafana: management address, TCP/3000
- Stork dashboard: management address, TCP/8080
- Stork agent: `127.0.0.1:8081`
- Prometheus: `127.0.0.1:9090`
- Loki: `127.0.0.1:3100`
- node_exporter: `127.0.0.1:9100`
- postgres_exporter: `127.0.0.1:9187`
- Stork Kea exporter: `127.0.0.1:9547`

## Initial dashboards

Grafana provisions Prometheus as its default metrics datasource and Loki as its log datasource. The control plane provides pre-provisioned JSON dashboards:

1. **FreeBSD Control Plane Overview** (`control-plane-overview.json`):
   - Host load, CPU, memory, filesystem capacity, and extended network signals (throughput RX/TX, packet rates, errors & drops);
   - PostgreSQL availability, connections, transaction rate, locks, and database size;
   - Prometheus target health and scrape duration.

2. **Control Plane Logs** (`control-plane-logs.json`):
   - Aggregated log volume and log entry rates over time;
   - Error and warning event rates;
   - Full-text search log stream viewer with interactive filtering.
