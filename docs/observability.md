# Observability

## Topology

```text
node_exporter 127.0.0.1:9100 ----+
postgres_exporter 127.0.0.1:9187 +--> Prometheus 127.0.0.1:9090
Prometheus self-metrics ----------+              |
                                                 v
                                      Grafana 10.0.10.2:3000
```

Prometheus and both exporters bind to loopback. Grafana is the only component exposed on the management VLAN. PF permits TCP/3000 only from `mgmt_net`.

## Install configuration

```sh
install -m 0644 config/prometheus.yml /usr/local/etc/prometheus.yml
install -m 0644 config/grafana.ini /usr/local/etc/grafana/grafana.ini
install -d -m 0755 /usr/local/etc/grafana/provisioning/datasources
install -d -m 0755 /usr/local/etc/grafana/provisioning/dashboards/json
install -m 0644 config/grafana/provisioning/datasources/prometheus.yml \
  /usr/local/etc/grafana/provisioning/datasources/prometheus.yml
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

```sh
service postgresql start
service node_exporter start
service postgres_exporter start
service prometheus start
service grafana start
```

## Validation

```sh
promtool check config /usr/local/etc/prometheus.yml
sockstat -4 -6 -l | egrep ':(3000|9090|9100|9187)'
fetch -qo- http://127.0.0.1:9100/metrics | head
fetch -qo- http://127.0.0.1:9187/metrics | head
fetch -qo- http://127.0.0.1:9090/-/ready
grafana cli --config /usr/local/etc/grafana/grafana.ini admin reset-admin-password 'REPLACE-ME'
```

Expected bindings:

- Grafana: management address, TCP/3000
- Prometheus: `127.0.0.1:9090`
- node_exporter: `127.0.0.1:9100`
- postgres_exporter: `127.0.0.1:9187`

## Initial dashboards

Grafana provisions Prometheus as its default datasource. Import or provision dashboards only after reviewing their queries and variable definitions. Do not automatically download unsigned dashboard JSON during host installation.

Useful initial signals:

- host load, CPU, memory, filesystem capacity, and network errors;
- PostgreSQL availability, connections, transaction rate, locks, and database size;
- Prometheus target health and scrape duration;
- ZFS capacity through node-exporter-supported collectors or a reviewed textfile collector;
- vm-bhyve guest state through a future textfile collector generated from `vm list`.
