# V2 implementation contract

The canonical architecture is defined in [streamlined-v2.md](streamlined-v2.md). This file records the executable contract introduced by the first implementation slice.

## Implemented

- Go module and `cpctl` entry point.
- Strict TOML site and VM manifest decoding. Unknown keys are rejected.
- Versioned JSON schemas for the parsed TOML representations.
- Deterministic VM normalization, specification digest, plan digest, and idempotency key.
- Read-only `doctor` checks for the FreeBSD platform, required executables, ZFS dataset, PostgreSQL, and Kea Control Agent.
- Stable JSON response envelope and documented exit codes.

## Deliberately not implemented

This slice does not mutate PostgreSQL, Kea, ZFS, PF, or vm-bhyve. It does not claim that plan steps are executable. State migrations, allocation, journaling, drivers, apply, delete, import, and reconciliation remain separate pull requests.

## Determinism contract

For identical values of:

- normalized VM manifest;
- control-plane ID;
- generation;
- action;
- ordered plan-step contract;

`cpctl plan` must produce identical `spec_digest`, `plan_digest`, and `idempotency_key` values.

Changing the generation, normalized specification, control-plane ID, action, or step contract must change the idempotency key.

## JSON envelope

Every machine-readable response uses:

```json
{
  "schema": 1,
  "command": "plan",
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
| 5 | operation blocked |
| 6 | partial failure |
| 70 | internal error |
