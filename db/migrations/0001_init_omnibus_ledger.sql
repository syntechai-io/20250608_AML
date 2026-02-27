BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'entity_type_enum') THEN
        CREATE TYPE entity_type_enum AS ENUM ('INDIVIDUAL', 'CORPORATE', 'TRUST');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'kyc_status_enum') THEN
        CREATE TYPE kyc_status_enum AS ENUM ('PENDING', 'APPROVED', 'SUSPENDED');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'aml_risk_rating_enum') THEN
        CREATE TYPE aml_risk_rating_enum AS ENUM ('LOW', 'MEDIUM', 'HIGH');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'owner_scope_enum') THEN
        CREATE TYPE owner_scope_enum AS ENUM ('CLIENT', 'FIRM');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'account_type_enum') THEN
        CREATE TYPE account_type_enum AS ENUM ('CLIENT_LIABILITY', 'FIRM_ASSET', 'FIRM_REVENUE', 'SUSPENSE');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'account_status_enum') THEN
        CREATE TYPE account_status_enum AS ENUM ('ACTIVE', 'FROZEN');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'event_type_enum') THEN
        CREATE TYPE event_type_enum AS ENUM (
            'CLIENT_DEPOSIT',
            'CLIENT_WITHDRAWAL',
            'TRADE_CLIENT_SETTLEMENT',
            'TRADE_HEDGE_SETTLEMENT',
            'FEE_ACCRUAL',
            'INTERNAL_TRANSFER',
            'RECON_ADJUSTMENT'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'trade_side_enum') THEN
        CREATE TYPE trade_side_enum AS ENUM ('BUY', 'SELL');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'transfer_direction_enum') THEN
        CREATE TYPE transfer_direction_enum AS ENUM ('INBOUND', 'OUTBOUND');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'travel_rule_status_enum') THEN
        CREATE TYPE travel_rule_status_enum AS ENUM ('REQUIRED', 'NOTABENE_PENDING', 'CLEARED', 'REJECTED');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'reconciliation_status_enum') THEN
        CREATE TYPE reconciliation_status_enum AS ENUM ('PASSED', 'INVESTIGATING', 'ESCALATED');
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS clients (
    client_id UUID PRIMARY KEY,
    entity_type entity_type_enum NOT NULL,
    jurisdiction CHAR(2) NOT NULL,
    kyc_status kyc_status_enum NOT NULL DEFAULT 'PENDING',
    aml_risk_rating aml_risk_rating_enum NOT NULL DEFAULT 'MEDIUM',
    onboarding_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_review_date TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (jurisdiction ~ '^[A-Z]{2}$')
);

CREATE TABLE IF NOT EXISTS ledger_accounts (
    account_id UUID PRIMARY KEY,
    owner_scope owner_scope_enum NOT NULL,
    owner_id UUID,
    asset_id VARCHAR(10) NOT NULL,
    account_type account_type_enum NOT NULL,
    status account_status_enum NOT NULL DEFAULT 'ACTIVE',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    frozen_reason TEXT,
    CONSTRAINT fk_ledger_account_client FOREIGN KEY (owner_id) REFERENCES clients(client_id),
    CONSTRAINT chk_owner_consistency CHECK (
        (owner_scope = 'CLIENT' AND owner_id IS NOT NULL)
        OR
        (owner_scope = 'FIRM' AND owner_id IS NULL)
    ),
    CONSTRAINT chk_account_ownership CHECK (
        (owner_scope = 'CLIENT' AND account_type = 'CLIENT_LIABILITY')
        OR
        (owner_scope = 'FIRM' AND account_type IN ('FIRM_ASSET', 'FIRM_REVENUE', 'SUSPENSE'))
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_ledger_account_uniqueness
    ON ledger_accounts(owner_scope, owner_id, asset_id, account_type);

CREATE TABLE IF NOT EXISTS trades (
    trade_id UUID PRIMARY KEY,
    client_id UUID NOT NULL REFERENCES clients(client_id),
    asset_pair VARCHAR(20) NOT NULL,
    side trade_side_enum NOT NULL,
    client_executed_price DECIMAL(36, 18) NOT NULL CHECK (client_executed_price > 0),
    client_executed_qty DECIMAL(36, 18) NOT NULL CHECK (client_executed_qty > 0),
    hedge_lp_id VARCHAR(50) NOT NULL,
    hedge_executed_price DECIMAL(36, 18) NOT NULL CHECK (hedge_executed_price > 0),
    client_execution_timestamp TIMESTAMPTZ NOT NULL,
    hedge_execution_timestamp TIMESTAMPTZ NOT NULL,
    fee_charged_usd DECIMAL(18, 4) NOT NULL DEFAULT 0,
    execution_slippage_bps DECIMAL(12, 4) GENERATED ALWAYS AS
        (((client_executed_price - hedge_executed_price) / NULLIF(hedge_executed_price, 0)) * 10000) STORED,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (fee_charged_usd >= 0)
);

CREATE INDEX IF NOT EXISTS idx_trades_client_timestamp
    ON trades(client_id, client_execution_timestamp DESC);

CREATE TABLE IF NOT EXISTS external_transfers (
    transfer_id UUID PRIMARY KEY,
    client_id UUID NOT NULL REFERENCES clients(client_id),
    direction transfer_direction_enum NOT NULL,
    asset_id VARCHAR(10) NOT NULL,
    amount DECIMAL(36, 18) NOT NULL CHECK (amount > 0),
    on_chain_tx_hash VARCHAR(100),
    wallet_address VARCHAR(100) NOT NULL,
    travel_rule_status travel_rule_status_enum NOT NULL,
    nota_bene_transfer_id VARCHAR(100),
    screening_snapshot_id VARCHAR(100),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (
        (travel_rule_status IN ('NOTABENE_PENDING', 'CLEARED') AND nota_bene_transfer_id IS NOT NULL)
        OR
        (travel_rule_status IN ('REQUIRED', 'REJECTED'))
    )
);

CREATE TABLE IF NOT EXISTS journal_entries (
    entry_id UUID PRIMARY KEY,
    transaction_id UUID NOT NULL,
    debit_account_id UUID NOT NULL REFERENCES ledger_accounts(account_id),
    credit_account_id UUID NOT NULL REFERENCES ledger_accounts(account_id),
    asset_id VARCHAR(10) NOT NULL,
    amount DECIMAL(36, 18) NOT NULL CHECK (amount > 0),
    event_type event_type_enum NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    actor_id VARCHAR(50) NOT NULL,
    event_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    prior_audit_hash VARCHAR(256),
    audit_hash VARCHAR(256) NOT NULL,
    CONSTRAINT chk_different_accounts CHECK (debit_account_id <> credit_account_id)
);

CREATE INDEX IF NOT EXISTS idx_journal_transaction
    ON journal_entries(transaction_id, created_at);

CREATE INDEX IF NOT EXISTS idx_journal_created_at
    ON journal_entries(created_at, entry_id);

CREATE TABLE IF NOT EXISTS reconciliations (
    recon_id UUID PRIMARY KEY,
    asset_id VARCHAR(10) NOT NULL,
    run_timestamp TIMESTAMPTZ NOT NULL,
    total_client_liabilities DECIMAL(36, 18) NOT NULL,
    total_firm_assets DECIMAL(36, 18) NOT NULL,
    total_on_chain_balance DECIMAL(36, 18) NOT NULL,
    variance DECIMAL(36, 18) NOT NULL,
    status reconciliation_status_enum NOT NULL,
    mlro_signoff_id VARCHAR(50),
    freeze_withdrawals BOOLEAN NOT NULL DEFAULT FALSE,
    incident_ticket_id VARCHAR(100),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (
        (status = 'PASSED' AND variance = 0)
        OR
        (status <> 'PASSED')
    ),
    CHECK (
        (variance = 0 AND mlro_signoff_id IS NULL)
        OR
        (variance <> 0)
    )
);

CREATE OR REPLACE FUNCTION fn_validate_journal_entry() RETURNS TRIGGER AS $$
DECLARE
    debit_rec ledger_accounts%ROWTYPE;
    credit_rec ledger_accounts%ROWTYPE;
BEGIN
    SELECT * INTO debit_rec FROM ledger_accounts WHERE account_id = NEW.debit_account_id;
    SELECT * INTO credit_rec FROM ledger_accounts WHERE account_id = NEW.credit_account_id;

    IF debit_rec.status <> 'ACTIVE' OR credit_rec.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Journal posting blocked: one or more ledger accounts are not ACTIVE';
    END IF;

    IF debit_rec.asset_id <> NEW.asset_id OR credit_rec.asset_id <> NEW.asset_id THEN
        RAISE EXCEPTION 'Journal posting blocked: asset mismatch between journal and account definitions';
    END IF;

    IF NEW.event_type IN ('CLIENT_DEPOSIT', 'CLIENT_WITHDRAWAL', 'TRADE_CLIENT_SETTLEMENT')
       AND (debit_rec.account_type = 'FIRM_REVENUE' OR credit_rec.account_type = 'FIRM_REVENUE') THEN
        RAISE EXCEPTION 'Client settlement flows cannot post directly to firm revenue accounts';
    END IF;

    IF NEW.event_type = 'TRADE_HEDGE_SETTLEMENT'
       AND (debit_rec.owner_scope <> 'FIRM' OR credit_rec.owner_scope <> 'FIRM') THEN
        RAISE EXCEPTION 'Hedge settlement entries must be firm-to-firm postings';
    END IF;

    IF NEW.event_type = 'FEE_ACCRUAL' AND credit_rec.account_type <> 'FIRM_REVENUE' THEN
        RAISE EXCEPTION 'Fee accrual must credit FIRM_REVENUE';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_set_journal_audit_hash() RETURNS TRIGGER AS $$
DECLARE
    prev_hash TEXT;
BEGIN
    SELECT audit_hash
    INTO prev_hash
    FROM journal_entries
    ORDER BY created_at DESC, entry_id DESC
    LIMIT 1;

    NEW.prior_audit_hash := prev_hash;

    NEW.audit_hash := encode(
        digest(
            concat_ws('|',
                COALESCE(prev_hash, 'GENESIS'),
                NEW.entry_id::TEXT,
                NEW.transaction_id::TEXT,
                NEW.debit_account_id::TEXT,
                NEW.credit_account_id::TEXT,
                NEW.asset_id,
                NEW.amount::TEXT,
                NEW.event_type::TEXT,
                NEW.created_at::TEXT,
                NEW.actor_id,
                NEW.event_metadata::TEXT
            ),
            'sha256'
        ),
        'hex'
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_prevent_mutation() RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Mutations are disabled for immutable table %', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_journal_entry ON journal_entries;
CREATE TRIGGER trg_validate_journal_entry
BEFORE INSERT ON journal_entries
FOR EACH ROW EXECUTE FUNCTION fn_validate_journal_entry();

DROP TRIGGER IF EXISTS trg_set_journal_audit_hash ON journal_entries;
CREATE TRIGGER trg_set_journal_audit_hash
BEFORE INSERT ON journal_entries
FOR EACH ROW EXECUTE FUNCTION fn_set_journal_audit_hash();

DROP TRIGGER IF EXISTS trg_no_update_journal_entries ON journal_entries;
CREATE TRIGGER trg_no_update_journal_entries
BEFORE UPDATE OR DELETE ON journal_entries
FOR EACH ROW EXECUTE FUNCTION fn_prevent_mutation();

DROP TRIGGER IF EXISTS trg_no_update_reconciliations ON reconciliations;
CREATE TRIGGER trg_no_update_reconciliations
BEFORE UPDATE OR DELETE ON reconciliations
FOR EACH ROW EXECUTE FUNCTION fn_prevent_mutation();

CREATE OR REPLACE VIEW v_proof_of_entitlements AS
SELECT
    la.asset_id,
    SUM(CASE WHEN la.account_type = 'CLIENT_LIABILITY' THEN je.amount ELSE 0 END)
        FILTER (WHERE je.credit_account_id = la.account_id)
    -
    SUM(CASE WHEN la.account_type = 'CLIENT_LIABILITY' THEN je.amount ELSE 0 END)
        FILTER (WHERE je.debit_account_id = la.account_id)
        AS net_client_liabilities,
    SUM(CASE WHEN la.account_type = 'FIRM_ASSET' THEN je.amount ELSE 0 END)
        FILTER (WHERE je.credit_account_id = la.account_id)
    -
    SUM(CASE WHEN la.account_type = 'FIRM_ASSET' THEN je.amount ELSE 0 END)
        FILTER (WHERE je.debit_account_id = la.account_id)
        AS net_firm_assets
FROM ledger_accounts la
LEFT JOIN journal_entries je
    ON je.debit_account_id = la.account_id OR je.credit_account_id = la.account_id
GROUP BY la.asset_id;

CREATE OR REPLACE VIEW v_trial_balance AS
SELECT
    la.account_id,
    la.owner_scope,
    la.owner_id,
    la.asset_id,
    la.account_type,
    COALESCE(SUM(CASE WHEN je.debit_account_id = la.account_id THEN je.amount ELSE 0 END), 0)
        AS total_debits,
    COALESCE(SUM(CASE WHEN je.credit_account_id = la.account_id THEN je.amount ELSE 0 END), 0)
        AS total_credits,
    COALESCE(SUM(CASE WHEN je.credit_account_id = la.account_id THEN je.amount ELSE 0 END), 0)
    - COALESCE(SUM(CASE WHEN je.debit_account_id = la.account_id THEN je.amount ELSE 0 END), 0)
        AS ending_balance
FROM ledger_accounts la
LEFT JOIN journal_entries je
    ON je.debit_account_id = la.account_id OR je.credit_account_id = la.account_id
GROUP BY la.account_id, la.owner_scope, la.owner_id, la.asset_id, la.account_type;

COMMIT;
