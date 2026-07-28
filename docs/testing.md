# Testing strategy

The repository is implemented in POSIX shell and orchestrates FreeBSD-specific services. Testing is split into three layers because GitHub-hosted runners do not provide native bare-metal FreeBSD with bhyve virtualization extensions.

## 1. Portable CI

Workflow: `.github/workflows/ci.yml`

Runs on `ubuntu-latest` for every push and pull request.

It validates:

- POSIX shell syntax;
- ShellCheck findings;
- portable repository tests;
- JSON syntax;
- YAML syntax;
- accidental committed private keys, SSH public keys, or credential-bearing PostgreSQL DSNs.

This layer does not call real FreeBSD services, `vm-bhyve`, ZFS, PF, Kea, Unbound, PostgreSQL, Stork, Prometheus, or Grafana. It statically validates the Unbound listener and client boundary, Stork source pin, loopback agent/exporter bindings, database bootstrap, and startup readiness contract.

## 2. FreeBSD integration

Workflow: `.github/workflows/freebsd-integration.yml`

A FreeBSD VM is started through `vmactions/freebsd-vm`. The job installs Kea and executes the repository's shell validation on FreeBSD.

The workflow starts real instances of:

- `kea-dhcp4`;
- `kea-ctrl-agent`;
- the `libdhcp_host_cmds.so` reservation hook.
- the `libdhcp_subnet_cmds.so` subnet-management hook required by Stork.

It then verifies the complete reservation lifecycle through the loopback Control Agent:

1. service readiness;
2. `reservation-add`;
3. `reservation-get`;
4. `reservation-del`.

This proves FreeBSD shell compatibility and Kea API integration. It deliberately does not start bhyve because nested virtualization inside the FreeBSD VM is not a reliable test environment.

Third-party GitHub Actions must be reviewed and pinned to an immutable commit SHA before treating this workflow as a protected-branch supply-chain control.

## 3. Bare-metal bhyve E2E

Workflow: `.github/workflows/e2e-bhyve.yml`

This workflow is manually triggered and requires a self-hosted runner labelled:

```text
self-hosted
freebsd-baremetal
```

The runner must be a dedicated FreeBSD host with:

- hardware virtualization enabled;
- `vmm` support available;
- vm-bhyve initialized;
- the `freebsd` cloud-image template installed;
- PostgreSQL inventory initialized;
- Kea DHCP4 and Control Agent running;
- a test IPAM pool called `vm-lan`;
- network reachability from the runner to the allocated guest subnet.

The E2E workflow:

1. generates an ephemeral Ed25519 key;
2. provisions a VM through `scripts/provision_vm.sh`;
3. verifies PostgreSQL inventory state;
4. verifies the Kea reservation;
5. waits for cloud-init-provisioned SSH access;
6. collects diagnostics;
7. destroys the VM and releases its reservation and IP allocation.

Use a dedicated runner group and GitHub Environment approval for this workflow. Do not attach a general-purpose production hypervisor as an unrestricted repository runner.

## Local validation

Portable validation:

```sh
make lint
make test
```

FreeBSD configuration validation:

```sh
make validate-freebsd
```

The host-level validation does not replace the self-hosted E2E workflow because configuration parsers cannot prove VM boot, DHCP delivery, cloud-init execution, or guest SSH readiness.

## Cleanup requirements

Any new integration or E2E test must define cleanup for every external side effect it creates, including:

- bhyve processes and vm-bhyve guest definitions;
- ZFS datasets and zvols;
- Kea reservations;
- PostgreSQL inventory rows and IPAM allocations;
- temporary SSH keys and cloud-init media;
- temporary bridges, tap devices, and test configuration files.

Cleanup must run under success, failure, cancellation, and timeout paths where the execution environment permits it. A periodic reconciliation job on the self-hosted runner is still recommended because a host crash can bypass workflow cleanup.
