# Testing strategy

The repository is implemented in POSIX shell and orchestrates FreeBSD-specific services. Testing is split into three layers because GitHub-hosted runners do not provide native bare-metal FreeBSD with bhyve virtualization extensions.

## 1. Portable CI

Workflow: `.github/workflows/ci.yml`

Runs on `ubuntu-latest` for every push and pull request.

It validates:

- POSIX shell syntax and error-level ShellCheck findings;
- portable repository tests;
- JSON and YAML syntax;
- accidental committed key or credential material;
- verified cloud-image caching, tamper detection, and checksum rejection;
- PostgreSQL-only Kea reservation authority;
- transactional MAC allocator wiring and advisory-lock serialization;
- three-node cluster naming, kubeconfig installation, inventory output, and rollback after a partial provisioning failure.

`tests/test_cluster.sh` replaces vm-bhyve, PostgreSQL, kubectl, and node lifecycle commands with deterministic fakes. It proves orchestration behavior without claiming that bhyve guests boot on the Linux runner.

This layer does not call real FreeBSD services, vm-bhyve, ZFS, PF, Kea, Unbound, PostgreSQL, Stork, Prometheus, or Grafana.

## 2. FreeBSD integration

Workflow: `.github/workflows/freebsd-integration.yml`

A FreeBSD VM is started through `vmactions/freebsd-vm`. The job installs Kea and executes repository validation on FreeBSD.

It starts real Kea DHCP4 with the host-command and subnet-command hooks, then verifies the authenticated Control Agent lifecycle:

1. service readiness;
2. `reservation-add`;
3. `reservation-get`;
4. `reservation-del`.

The workflow uses the `memory` operation target because the official FreeBSD binary package omits PostgreSQL support. Portable tests verify that production rendering selects PostgreSQL and clears inline reservations. Target-host validation remains required after rebuilding `net/kea` with `PGSQL`.

The workflow deliberately does not start bhyve because nested virtualization inside the FreeBSD VM is not a reliable test environment.

Third-party actions must be reviewed and pinned to immutable commit SHAs before this workflow is treated as a protected-branch supply-chain control.

## 3. Bare-metal bhyve E2E

Workflow: `.github/workflows/e2e-bhyve.yml`

This manually triggered workflow requires a dedicated self-hosted runner labelled:

```text
self-hosted
freebsd-baremetal
```

The runner requires hardware virtualization, vm-bhyve, initialized PostgreSQL inventory, Kea with its PostgreSQL hosts backend, a `vm-lan` pool, and guest-network reachability.

The current E2E workflow provisions one VM, verifies inventory and the authenticated database-backed reservation, waits for SSH/cloud-init, collects diagnostics, and deprovisions all external state.

A cluster-level E2E extension should invoke `make cluster-up` with an ephemeral SSH key, verify all three rows in the generated TSV inventory, test SSH readiness for each node, and always invoke `make cluster-down`. Do not attach a general-purpose production hypervisor as an unrestricted repository runner.

## Local validation

```sh
make lint
make test
```

On the target FreeBSD host:

```sh
make validate-freebsd
```

Configuration validation cannot prove VM boot, DHCP delivery, cloud-init execution, SSH readiness, or Kubernetes API reachability. Those require the bare-metal workflow or an equivalent disposable host test.

## Cleanup requirements

Any integration or E2E test must clean up every external side effect it creates, including:

- bhyve processes and vm-bhyve guest definitions;
- ZFS datasets and zvols;
- Kea reservations and leases;
- PostgreSQL inventory rows and IPAM allocations;
- temporary SSH keys, kubeconfigs, known-hosts files, and cloud-init media;
- temporary bridges, tap devices, and test configuration files.

Cleanup must run on success, failure, cancellation, and timeout where the execution environment permits it. A periodic reconciliation job remains necessary because a host crash can bypass workflow cleanup.
