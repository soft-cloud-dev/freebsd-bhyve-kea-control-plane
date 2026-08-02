# V2 implementation contract

The canonical architecture is defined in [streamlined-v2.md](streamlined-v2.md).

## Implemented

- Go module and `cpctl` entry point.
- Strict TOML site and VM manifest decoding. Unknown keys are rejected.
- Versioned JSON schemas for the parsed TOML representations.
- Deterministic VM normalization, specification digest, plan digest, per-step input digest, and idempotency key.
- Read-only `doctor` checks for the FreeBSD platform, required executables, ZFS dataset, PostgreSQL, and Kea Control Agent.
- Embedded immutable PostgreSQL migrations with advisory locking and SHA-256 checksum verification.
- Dedicated `bkcp` schema for declared, allocated, observed, effective, operation, and operation-step state.
- Transactional `PrepareApply` that assigns generations and persists plans before external execution.
- Read-only `migrate`, `status`, and `inspect` CLI commands.
- Stable JSON response envelope and documented exit codes.

## Deliberately not implemented

This implementation does not allocate IP or MAC addresses and does not mutate Kea, ZFS, PF, images, cloud-init media, or `vm-bhyve`. The persisted plan steps are not executable yet. Public `apply`, `delete`, import, adoption, observation collection, and reconciliation remain separate iterations.

## State contract

The four state classes are independent:

- declared state is append-only normalized intent by generation;
- allocated state contains durable assigned identities and is not recomputed on every run;
- observed state records evidence, including explicit unavailable and unknown values;
- effective state is derived and never substitutes missing evidence with absence.

Operations reference the exact declared generation. Ordered steps and their input digests are stored before a future executor may mutate external systems.

## Determinism contract

For identical values of normalized VM manifest, control-plane ID, generation, action, and ordered step contract, `cpctl plan` produces identical `spec_digest`, `plan_digest`, step `input_digest` values, and `idempotency_key`.

Identical declarations retain the current generation. A changed declaration increments the generation exactly once under a transaction-scoped advisory lock. Reverting to an older specification after an intervening change creates a later generation.

## JSON envelope

Every machine-readable response uses:

```json
{
  "schema": 1,
  "command": "status",
  "ok": true,
  "data": {},
  "errors": []
}
```

Fields may be added only in a backward-compatible way while `schema` remains `1`.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | success |
| 2 | invalid input or contract violation |
| 3 | required dependency unavailable |
| 4 | drift detected |
| 5 | operation or migration blocked |
| 6 | partial failure |
| 7 | resource not found |
| 70 | internal error |
