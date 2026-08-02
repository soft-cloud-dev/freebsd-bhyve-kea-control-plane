# V1 to v2 migration

The Go implementation is initially read-only. Existing shell workflows remain authoritative until state migrations and adoption are implemented.

## Current phase

1. Install or build `cpctl` without removing the v1 scripts.
2. Copy `config/site.example.toml` to `/usr/local/etc/bkcp/site.toml` and replace the placeholder image digest.
3. Run `cpctl doctor --offline` to validate configuration without touching services.
4. Run `cpctl doctor` on the FreeBSD host to inspect dependencies, ZFS, PostgreSQL, and Kea.
5. Convert desired VMs to versioned manifests and inspect deterministic plans with `cpctl plan`.

Do not use the plan output as proof that a VM was applied. This phase contains no writers.

## Adoption invariant

A future `cpctl adopt` must not reallocate an existing VM's IP or MAC address. Adoption will require agreement between v1 inventory, vm-bhyve, ZFS, and Kea. Mismatches remain unmanaged until resolved explicitly.
