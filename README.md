# Omnibus Ledger Starter (Cayman VASP / CIMA Rule 14)

This repository now includes an initial implementation baseline for a CIMA-aligned omnibus ledger for an execution-only OTC (riskless principal) operating model.

## What was added

- SQL migration for core ledger, trading, travel-rule, and reconciliation tables.
- Compliance-oriented constraints and trigger-based controls.
- Hash-chained immutable journal entries.
- Proof-of-entitlements and trial-balance views.
- Architecture/implementation notes linked to your FR/AR requirements.

## Files

- `db/migrations/0001_init_omnibus_ledger.sql`
- `docs/omnibus-ledger-architecture.md`

## How to apply

Run the migration in PostgreSQL 14+:

```bash
psql "$DATABASE_URL" -f db/migrations/0001_init_omnibus_ledger.sql
```

## Next steps

- Build application service layer for atomic posting bundles (deposit, withdrawal, trade, fee).
- Add RBAC + query audit logging for Rule 14 information barriers.
- Add daily reconciliation worker and automated withdrawal freeze policy.
- Add regulatory reporting exports.
