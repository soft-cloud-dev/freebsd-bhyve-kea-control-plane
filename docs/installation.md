# Installation

Review interface names, networks, package versions, and service paths before applying this configuration.

## 1. Install dependencies

```sh
su -
sh scripts/02_install_dependencies.sh
```

## 2. Establish host trust and storage

Install a trusted SSH public key for the management account before disabling password authentication.

```sh
sh scripts/01_host_setup.sh
```

Keep the current root console open until a second SSH session succeeds with the trusted key.

## 3. Install configuration

```sh
install -m 0600 config/pf.conf /etc/pf.conf
install -m 0644 config/kea-dhcp4.conf /usr/local/etc/kea/kea-dhcp4.conf
install -m 0644 config/kea-ctrl-agent.conf /usr/local/etc/kea/kea-ctrl-agent.conf
```

Merge `config/rc.conf.example` into `/etc/rc.conf` after adapting hostnames and interfaces.

Validate before starting services:

```sh
pfctl -nf /etc/pf.conf
kea-dhcp4 -t /usr/local/etc/kea/kea-dhcp4.conf
kea-ctrl-agent -t /usr/local/etc/kea/kea-ctrl-agent.conf
```

## 4. Initialize PostgreSQL

```sh
service postgresql initdb
service postgresql start
sudo -u postgres createdb inventory
sudo -u postgres psql -d inventory -f db/001_inventory.sql
sudo -u postgres psql -d inventory <<'SQL'
INSERT INTO ipam_pools(name, subnet, first_host, last_host, vlan, kea_subnet_id)
VALUES ('vm-lan', '10.0.20.0/24', '10.0.20.10', '10.0.20.99', 20, 1)
ON CONFLICT (name) DO NOTHING;
SQL
```

Configure local PostgreSQL authentication for a dedicated provisioning role before production use.

## 5. Initialize vm-bhyve

Copy and adapt the example template:

```sh
install -m 0644 templates/vm-bhyve.conf /zroot/vm/.templates/freebsd.conf
vm init
```

Create the required vm-bhyve switch and confirm that it maps to the intended bridge.

## 6. Start services

```sh
service pf start
service kea_dhcp4 start
service kea_ctrl_agent start
```

## 7. Validate

```sh
make validate-freebsd
sockstat -4 -6 -l
service blacklistd status
service postgresql status
service kea_dhcp4 status
service kea_ctrl_agent status
vm list
```
