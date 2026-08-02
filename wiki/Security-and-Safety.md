# Security and Safety

## Trust boundary

`cpctl` coordinates privileged infrastructure but should not become a general-purpose root automation shell.

Future execution must expose typed driver operations with explicit preconditions and postconditions rather than arbitrary command strings.

## Secrets

Do not store or emit:

- PostgreSQL passwords;
- Kea API passwords;
- SSH private keys;
- SSH public-key contents when a path is sufficient;
- credential-file contents;
- bearer tokens or session cookies.

The site configuration may reference credential files. State and operation payloads must contain only non-secret configuration and bounded error information.

Connection failures must not echo the complete DSN.

## PostgreSQL

- Use a dedicated database role with only the privileges required for the `bkcp` schema.
- Keep V1 `public` objects outside the V2 write boundary.
- Use local socket or TLS-protected connections as appropriate.
- Back up the database before migration or future execution upgrades.
- Never edit applied migration checksum rows to force acceptance.

## Kea

Kea's hosts database remains authoritative for reservations.

Future drivers must:

- authenticate through referenced credential files;
- verify the target subnet and reservation identity;
- use idempotent create/update/delete semantics;
- confirm postconditions through Kea after mutation;
- avoid exposing credentials in logs or error details.

## FreeBSD privileges

ZFS, PF, service control, and `vm-bhyve` require elevated privileges. Prefer a narrowly scoped execution boundary rather than running unrelated parsing or rendering code as root.

Potential separation:

```text
unprivileged cpctl planning/state process
              |
              v
typed privileged local executor
              |
      ZFS / PF / services / vm-bhyve
```

Any such split must authenticate requests and bind them to persisted operation and step identities.

## PF

PF integration is anchor-scoped.

- Use the configured `bkcp` anchor.
- Validate generated anchor rules before loading.
- Do not overwrite `/etc/pf.conf`.
- Preserve site-owned policy and ordering.
- Record the rule-set digest and verify the loaded postcondition.

## Images and cloud-init

- Require an independently verified compressed artifact SHA-256 digest.
- Reject the all-zero example sentinel.
- Download to a temporary path and verify before promotion.
- Avoid embedding secrets in reusable image or cloud-init artifacts.
- Set restrictive permissions on generated seed media and temporary files.

## Operation safety

Before external mutation, a future executor must verify:

1. the operation is persisted and targets the current generation;
2. the plan and step input digests match the implementation contract;
3. the prior step postcondition is satisfied;
4. no conflicting operation is running;
5. required dependencies are available;
6. the requested action remains authorized.

After mutation, it must collect evidence and record the postcondition before advancing the journal.

## Manual repair

Do not mark an operation or step successful merely to unblock execution. First verify external state through the authoritative system, then record a documented repair or reconciliation action.

Unknown or unavailable evidence must remain explicit. It must never be rewritten as confirmed absence.