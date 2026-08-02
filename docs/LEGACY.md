# V1 legacy policy

The V1 shell implementation was removed from `main` after the V2 Go foundation became the canonical development line.

## Preserved snapshot

- branch: `legacy/v1-shell`
- snapshot commit: `30068eac6c03ff813ed494739995846b8b8e74be`

The snapshot contains the former installer, service configuration, database schema, VM lifecycle scripts, cluster and kubeconfig workflows, observability stack, shell tests, and FreeBSD integration workflows.

## Rules

- Do not add V1 scripts, templates, dashboards, or service configuration back to `main`.
- V1 receives only narrowly scoped security or migration fixes on the legacy branch.
- New functionality belongs in `cpctl` and the V2 contracts.
- V2 must import or adopt V1 state without reallocating IP or MAC addresses.
- Historical V1 documentation is authoritative only for checkouts of the legacy branch.

## Recovery

```sh
git fetch origin
git switch legacy/v1-shell
```

Pin production use to an explicit commit rather than following the branch head.
