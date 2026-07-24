-- Operational requirement: apply this migration with PostgreSQL autocommit,
-- outside any explicit transaction, because CREATE INDEX CONCURRENTLY cannot
-- run inside a transaction block.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_lp_collect_history_transaction_hash
    ON lp_collect_history (transaction_hash);

CREATE TABLE IF NOT EXISTS txbot_collect_pending (
    singleton_id SMALLINT PRIMARY KEY CHECK (singleton_id = 1),
    state VARCHAR NOT NULL CHECK (state IN ('RESERVED', 'BROADCAST')),
    tx_hash VARCHAR(66) UNIQUE,
    token_ids VARCHAR(42)[] NOT NULL,
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    updated_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    CHECK (
        (state = 'RESERVED' AND tx_hash IS NULL)
        OR
        (state = 'BROADCAST' AND tx_hash IS NOT NULL)
    )
);
