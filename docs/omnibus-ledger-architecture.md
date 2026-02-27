# Omnibus Ledger (CIMA VASP) - Implementation Starter

## Scope of this first build
This starter implementation provides the **regulated ledger core** for an execution-only OTC (riskless principal) Cayman VASP:

- Immutable double-entry journal foundation.
- Logical segregation of client liabilities vs firm assets/revenue.
- Travel Rule transfer records.
- Reconciliation evidence model with withdrawal-freeze indicators.
- Baseline reports for proof-of-entitlements and trial balance.

## Regulatory mapping in the schema

### FR-1 Strict account segregation
- `ledger_accounts` enforces ownership and account-type consistency (`CLIENT` only for `CLIENT_LIABILITY`; `FIRM` for `FIRM_ASSET`/`FIRM_REVENUE`/`SUSPENSE`).
- Journal validation blocks account-status violations and invalid posting routes.

### FR-2 Double-entry EOTC trade booking
- `journal_entries` supports event types for client settlement, hedge settlement, and fee accrual.
- Trigger rules enforce that hedge settlements are firm-to-firm and fee accrual credits firm revenue.
- `trades` captures timestamps and stores calculated slippage in bps for fairness surveillance.

### FR-3 Daily custody reconciliation
- `reconciliations` stores run outputs, variance, and incident controls.
- Mutation trigger makes reconciliation records append-only.

### FR-4 Travel Rule / AML integration
- `external_transfers` stores `nota_bene_transfer_id`, sanctions-screening snapshot IDs, and lifecycle statuses.

### FR-5 Information barriers and access logging
- RBAC and query-level audit logs are not yet implemented in SQL in this starter.
- Next sprint should introduce DB roles + API access logs (see backlog below).

## Data integrity and immutability design

1. **Append-only journal entries**
   - Updates/deletes are blocked on `journal_entries`.
2. **Hash-chained audit trail**
   - Insert trigger computes each `audit_hash` using previous row hash + current row payload.
3. **Append-only reconciliations**
   - Updates/deletes are blocked on `reconciliations`.

## Suggested transaction workflows

### 1) Client deposit
1. Insert `external_transfers` (direction = INBOUND).
2. Post journal entry from firm omnibus asset account -> client liability account (`CLIENT_DEPOSIT`).
3. Include transaction metadata (screening snapshot / tx hash reference).

### 2) EOTC trade booking (riskless principal)
For one client trade, post at least three journal entries:
1. Client settlement leg.
2. Firm hedge leg.
3. Fee accrual leg (credit must be `FIRM_REVENUE`).

### 3) Daily reconciliation
1. Aggregate internal balances by asset.
2. Pull on-chain omnibus balances.
3. Insert one `reconciliations` row per asset.
4. If `variance <> 0`, set status to `INVESTIGATING` or `ESCALATED`, set `freeze_withdrawals = true`, and include incident ticket.

## Immediate backlog (next milestones)

1. Add `rfqs` table and enforce information barriers between RFQ access and hedge traders.
2. Add API service with idempotent posting endpoints and transaction bundles.
3. Add withdrawal policy engine (auto-freeze enforcement when reconciliation variance exists).
4. Add month-end close export (NetSuite/Xero mappings).
5. Add periodic CIMA prudential/stats report materialization pipeline.
