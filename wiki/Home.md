# FreeBSD bhyve + Kea Control Plane Wiki

This wiki documents the V2 control plane on `main`.

The project provides a declarative Go CLI, `cpctl`, for describing FreeBSD `vm-bhyve` guests, validating host dependencies, producing deterministic execution plans, and maintaining durable PostgreSQL state and operation journals.

## Current capability

Implemented:

- strict versioned TOML site and VM manifests;
- deterministic specification, plan, step-input, and idempotency digests;
- embedded checksummed PostgreSQL migrations;
- separate declared, allocated, observed, and effective state in the `bkcp` schema;
- concurrency-safe generation assignment and plan persistence;
- read-only `doctor`, `status`, and `inspect` commands;
- deterministic `plan` output;
- PostgreSQL 16 integration and concurrency tests.

Not implemented:

- IP or MAC allocation;
- image download or verification execution;
- cloud-init media creation;
- Kea reservation changes;
- ZFS, PF, service, or `vm-bhyve` mutation;
- public `apply`, `delete`, `adopt`, or `import-v1` commands.

A persisted operation is an execution contract. It is not evidence that infrastructure changed.

## Start here

1. [Getting Started](Getting-Started.md)
2. [Architecture](Architecture.md)
3. [Configuration](Configuration.md)
4. [State and Migrations](State-and-Migrations.md)
5. [CLI and Operations](CLI-and-Operations.md)
6. [Development and Testing](Development-and-Testing.md)
7. [Security and Safety](Security-and-Safety.md)
8. [Roadmap](Roadmap.md)

## Canonical sources

The wiki is an operator-oriented view. The repository remains authoritative:

- `docs/streamlined-v2.md` — canonical architecture;
- `docs/DESIGN.md` — executable implementation contract;
- `docs/STATE.md` — state and journal semantics;
- `docs/MIGRATION.md` — V1/V2 migration boundary;
- `config/` — checked-in configuration examples;
- `schemas/` — versioned configuration schemas;
- `migrations/` — embedded immutable SQL migrations.

## V1 boundary

The former shell implementation is frozen on `legacy/v1-shell`. Do not copy V1 runtime scripts back into `main`. Existing V1 resources remain unmanaged by V2 until explicit import and adoption are implemented.