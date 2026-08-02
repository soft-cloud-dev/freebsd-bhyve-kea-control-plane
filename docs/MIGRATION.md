# V1 to V2 migration

V2 is the only implementation developed on `main`. The complete pre-cleanup repository is preserved on `legacy/v1-shell` at commit `30068eac6c03ff813ed494739995846b8b8e74be`.

## Current phase

`cpctl` now owns its dedicated PostgreSQL schema, migration history, declared-state history, effective-state record, and operation journal. It can inspect and persist deterministic plans internally, but it still does not execute external infrastructure changes.

Existing V1 installations must remain pinned to the legacy branch until V2 import and adoption are implemented.

```sh
git fetch origin
git switch legacy/v1-shell
```

Do not mix files from the legacy branch into a V2 checkout.

## Initialize V2 state

1. Copy `config/site.example.toml` to `/usr/local/etc/bkcp/site.toml`.
2. Set a stable `control_plane_id`.
3. Replace the all-zero image digest with an independently verified SHA-256 value.
4. Run `cpctl doctor --offline`.
5. Run `cpctl migrate --dry-run` and review versions and checksums.
6. Run `cpctl migrate`.
7. Run `cpctl status`.
8. Convert intended guests to versioned VM manifests and inspect deterministic plans with `cpctl plan`.

The V2 schema is `bkcp`. V2 does not alter the legacy `public.ipam_pools`, `public.ipam_leases`, or `public.vms` objects.

## Adoption invariant

A future `cpctl adopt` must preserve existing IP addresses, MAC addresses, storage identity, and VM UUIDs. Adoption will require agreement between V1 inventory, `vm-bhyve`, ZFS, and Kea. A mismatch remains unmanaged and blocked until explicitly resolved.

## Data ownership during transition

- V1 deployments continue to use the V1 database and scripts from the legacy branch.
- V2 must not write V1 tables before the import contract is implemented.
- V2 state and operation history live only under `bkcp`.
- No V1 resource is considered managed by V2 without explicit adoption.
- A persisted V2 operation is not evidence that its external steps were executed.
