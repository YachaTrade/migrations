-- ============================================================================
-- 0001_init.sql — GIWA observer fresh-DB consolidated migration
--
-- Generated 2026-07-19 from giwa/observer migrations, concatenated in the
-- order the observer test harness applies them
-- (tests/common/mod.rs::apply_baseline_migrations), with GIWA-runtime pruning:
--
--   * numbered 0001..0036, excluding 1000_delete.sql and 0018_api_keys.sql
--     (prod-only pgactive extension)
--   * 0015_v2_events.sql: only v2_sniping_history kept — the v2 fee tables
--     (v2_fee_collect/settle/to_claim_history, v2_creator_fee_distribution)
--     and v2_lp_allocate_history are NOT indexed by the GIWA 6-handler
--     runtime (LpManager writes the v1 lp_allocate_history instead)
--   * vault.sql, dividend.sql: dropped — no vault/dividend handlers in the
--     GIWA runtime; nothing writes these tables
--   * v2_upgrade_new_tables.sql: dropped — duplicate IF NOT EXISTS copies of
--     0014/0031 tables plus the dropped v2 fee tables (prod-upgrade script)
--   * v2_upgrade_alter.sql and other v2_upgrade_* backfills: dropped —
--     Monad-era prod-DB upgrade scripts, invalid on a fresh GIWA database
--
-- Target: fresh PostgreSQL 17 database for GIWA Sepolia indexing.
-- Quote defaults/seeds reference the GIWA WETH predeploy
-- 0x4200000000000000000000000000000000000006.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ============================================================================
-- >>> 0001_account.sql
-- ============================================================================

-- =====================================================
-- OBSERVER 전용 최적화된 데이터베이스 스키마
-- 불필요한 인덱스 제거로 쓰기 성능 최적화
-- =====================================================

-- Account Management Tables
CREATE TABLE IF NOT EXISTS account (
    account_id VARCHAR(42) PRIMARY KEY,
    nickname VARCHAR(42) NOT NULL,
    bio VARCHAR(255) NOT NULL DEFAULT '',
    image_uri VARCHAR NOT NULL,
    follower_count INT NOT NULL DEFAULT 0,
    following_count INT NOT NULL DEFAULT 0
);

-- API Search 모듈 최적화: nickname 검색 + follower_count 정렬을 위한 복합 인덱스  
CREATE INDEX IF NOT EXISTS idx_account_nickname_follower ON account (nickname, follower_count DESC);

-- API Social 모듈 최적화: get_follows에서 follower_count 정렬용 인덱스
CREATE INDEX IF NOT EXISTS idx_account_follower_count ON account (follower_count DESC);

-- Search 모듈 최적화: nickname 조회하는 쿼리용 인덱스
CREATE INDEX IF NOT EXISTS idx_account_nickname_gin ON account USING gin (nickname gin_trgm_ops);
-- EVM 주소 대소문자 무관 검색용 LOWER 인덱스
CREATE INDEX IF NOT EXISTS idx_account_account_id_lower ON account (LOWER(account_id));

-- 불필요한 trigram 인덱스 제거 (LOWER 방식으로 대체됨)
DROP INDEX IF EXISTS idx_account_account_id_gin;



-- Session Management
CREATE TABLE IF NOT EXISTS account_session (
    id VARCHAR(64) NOT NULL,
    account_id VARCHAR(42) PRIMARY KEY
);

-- API Auth 모듈 최적화: session_id로 조회하는 쿼리용 인덱스
CREATE INDEX IF NOT EXISTS idx_account_session_id ON account_session (id);

CREATE TABLE IF NOT EXISTS account_x(
    account_id VARCHAR(42) NOT NULL,
    x_handle VARCHAR(16) NOT NULL,
    x_image_uri VARCHAR NOT NULL,
    is_blue_label BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (account_id)
);

-- API Search 모듈 최적화: Twitter 핸들 검색 시 account 테이블과의 JOIN 성능을 위한 인덱스
CREATE INDEX IF NOT EXISTS idx_account_x_account_id ON account_x (account_id);
CREATE INDEX IF NOT EXISTS idx_account_x_handle ON account_x (x_handle);


-- Search 모듈 최적화: Twitter 핸들 gin_trgm_ops 조회하는 쿼리용 인덱스
 CREATE INDEX IF NOT EXISTS idx_account_x_handle_gin ON account_x USING GIN (x_handle gin_trgm_ops);



CREATE TABLE IF NOT EXISTS account_verified(
    x_handle VARCHAR(16) NOT NULL,
    PRIMARY KEY (x_handle)
);



CREATE TABLE IF NOT EXISTS account_wallet(
    account_id VARCHAR(42) NOT NULL,
    wallet VARCHAR(10) NOT NULL CHECK (wallet IN ('METAMASK', 'KEPLR', 'BACKPACK', 'HAHA', 'OKX', 'PHANTOM', 'RABBY', 'OTHER')),
    PRIMARY KEY (account_id)
);
-- Account Wallet 테이블은 PRIMARY KEY 외에 추가 인덱스 불필요


CREATE TABLE IF NOT EXISTS auth_nonce (
    address VARCHAR(42) PRIMARY KEY,
    message TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);







































-- Hype Token 테이블은 PRIMARY KEY 외에 추가 인덱스 불필요 (INSERT만 수행)

CREATE OR REPLACE FUNCTION search_everything(
    search_query TEXT,
    token_limit INT DEFAULT 50,
    account_limit INT DEFAULT 20
)
RETURNS TABLE (
    result_type VARCHAR,
    token_id VARCHAR(42),
    name VARCHAR,
    symbol VARCHAR,
    image_uri VARCHAR,
    created_at BIGINT,
    total_supply NUMERIC,
    market_type VARCHAR,
    price NUMERIC,
    account_id VARCHAR(42),
    nickname VARCHAR,
    follower_count INT,
    following_count INT,
    similarity_score REAL
) AS $$
BEGIN
    -- 토큰 검색 결과
    RETURN QUERY
    SELECT 
        'token'::VARCHAR as result_type,
        t.token_id,
        t.name,
        t.symbol,
        t.image_uri,
        t.created_at,
        t.total_supply,
        m.market_type,
        m.price,
        NULL::VARCHAR(42) as account_id,
        NULL::VARCHAR as nickname,
        NULL::INT as follower_count,
        NULL::INT as following_count,
        GREATEST(
            similarity(LOWER(t.name), LOWER(search_query)),
            similarity(LOWER(t.symbol), LOWER(search_query)),
            similarity(LOWER(t.token_id), LOWER(search_query))
        ) as similarity_score
    FROM token t
    JOIN market m ON t.token_id = m.token_id
    WHERE 
        -- 정확한 매칭 (최우선)
        LOWER(t.name) = LOWER(search_query)
        OR LOWER(t.symbol) = LOWER(search_query)
        OR LOWER(t.token_id) = LOWER(search_query)
        -- Trigram 매칭
        OR LOWER(t.name) % LOWER(search_query)
        OR LOWER(t.symbol) % LOWER(search_query)
        OR LOWER(t.token_id) % LOWER(search_query)
    ORDER BY 
        CASE 
            WHEN LOWER(t.name) = LOWER(search_query) 
            OR LOWER(t.symbol) = LOWER(search_query)
            OR LOWER(t.token_id) = LOWER(search_query) THEN 0
            ELSE 1
        END,
        similarity_score DESC,
        m.price DESC
    LIMIT token_limit;

    -- 계정 검색 결과
    RETURN QUERY
    SELECT 
        'account'::VARCHAR as result_type,
        NULL::VARCHAR(42) as token_id,
        NULL::VARCHAR as name,
        NULL::VARCHAR as symbol,
        a.image_uri,
        NULL::BIGINT as created_at,
        NULL::NUMERIC as total_supply,
        NULL::VARCHAR as market_type,
        NULL::NUMERIC as price,
        a.account_id,
        a.nickname,
        a.follower_count,
        a.following_count,
        GREATEST(
            similarity(LOWER(a.nickname), LOWER(search_query)),
            similarity(LOWER(a.account_id), LOWER(search_query))
        ) as similarity_score
    FROM account a
    WHERE 
        -- 정확한 매칭
        LOWER(a.nickname) = LOWER(search_query)
        OR LOWER(a.account_id) = LOWER(search_query)
        -- Trigram 매칭
        OR LOWER(a.nickname) % LOWER(search_query)
        OR LOWER(a.account_id) % LOWER(search_query)
    ORDER BY 
        CASE 
            WHEN LOWER(a.nickname) = LOWER(search_query)
            OR LOWER(a.account_id) = LOWER(search_query) THEN 0
            ELSE 1
        END,
        similarity_score DESC,
        a.follower_count DESC
    LIMIT account_limit;
END;
$$ LANGUAGE plpgsql;





-- =====================================================
-- Observer 최적화 완료
-- 총 인덱스 수: 최소화 (쓰기 성능 우선)
-- 주요 최적화:
-- 1. Primary Key 외 불필요한 인덱스 대부분 제거
-- 2. 실제 WHERE 조건에서만 사용하는 인덱스만 유지
-- 3. 쓰기 성능 최적화 완료
-- =====================================================



-- ============================================================================
-- >>> 0002_token.sql
-- ============================================================================

CREATE TABLE IF NOT EXISTS token (
    token_id VARCHAR(42) PRIMARY KEY,
    name VARCHAR NOT NULL,
    symbol VARCHAR NOT NULL,
    image_uri VARCHAR NOT NULL,
    creator VARCHAR(42)NOT NULL,
    description TEXT NULL,
    twitter VARCHAR NULL,
    telegram VARCHAR NULL,
    website VARCHAR NULL,
    is_nsfw BOOLEAN NOT NULL DEFAULT FALSE,
    is_graduated BOOLEAN NOT NULL DEFAULT FALSE,
    is_cto BOOLEAN NOT NULL DEFAULT FALSE,
    created_at BIGINT NOT NULL,
    transaction_hash VARCHAR NOT NULL,
    total_supply NUMERIC NOT NULL, -- token raw (wei): ERC20 raw supply (init 1e9 * 1e18), decremented by burns

    token_holder_count BIGINT NOT NULL DEFAULT 0,
    version VARCHAR NOT NULL DEFAULT 'V1' CHECK (version IN ('V1', 'V2'))
);


-- Token 테이블 복합 인덱스 (cache에서 token_id와 creator 동시 조회)
CREATE INDEX IF NOT EXISTS idx_token_token_id_creator ON token (token_id, creator);


-- API New Content 모듈 최적화: latest token 조회용 인덱스
CREATE INDEX IF NOT EXISTS idx_token_created_at ON token (created_at DESC);

-- API Token 모듈 최적화: creator로 조회하는 쿼리용 인덱스
CREATE INDEX IF NOT EXISTS idx_token_creator ON token (creator);
CREATE INDEX IF NOT EXISTS idx_token_creator_created_at ON token (creator, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_token_symbol ON token (symbol);
CREATE INDEX IF NOT EXISTS idx_token_name ON token (name);
-- Search 모듈 최적화: name, symbol lower로 조회하는 쿼리용 인덱스
CREATE INDEX IF NOT EXISTS idx_token_name_gin ON token USING GIN (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_token_symbol_gin ON token USING GIN (symbol gin_trgm_ops);  
CREATE INDEX IF NOT EXISTS idx_token_token_id_lower ON token (LOWER(token_id));
CREATE INDEX IF NOT EXISTS idx_token_version ON token (version);
CREATE INDEX IF NOT EXISTS idx_token_is_nsfw ON token (is_nsfw);





-- Count Tables
CREATE TABLE IF NOT EXISTS token_count (
    total_count BIGINT NOT NULL DEFAULT 0,
    graduated_count BIGINT NOT NULL DEFAULT 0,
    nsfw_count BIGINT NOT NULL DEFAULT 0,
    sfw_count BIGINT NOT NULL DEFAULT 0,
    id SERIAL PRIMARY KEY
);
-- 단일 행 테이블이므로 인덱스 불필요

-- 초기 데이터 삽입
INSERT INTO token_count (total_count, graduated_count, nsfw_count, sfw_count)
SELECT
    (SELECT COUNT(*) FROM token),
    (SELECT COUNT(*) FROM token WHERE is_graduated = true),
    (SELECT COUNT(*) FROM token WHERE is_nsfw = true),
    (SELECT COUNT(*) FROM token WHERE is_nsfw IS NOT true);

-- 트리거 함수들
CREATE OR REPLACE FUNCTION update_token_count_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE public.token_count
    SET
        total_count = total_count + 1,
        nsfw_count = CASE WHEN NEW.is_nsfw = true THEN nsfw_count + 1 ELSE nsfw_count END,
        sfw_count = CASE WHEN NEW.is_nsfw IS NOT true THEN sfw_count + 1 ELSE sfw_count END,
        graduated_count = CASE WHEN NEW.is_graduated = true THEN graduated_count + 1 ELSE graduated_count END;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION update_token_count_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE public.token_count
    SET
        total_count = total_count - 1,
        nsfw_count = CASE WHEN OLD.is_nsfw = true THEN nsfw_count - 1 ELSE nsfw_count END,
        sfw_count = CASE WHEN OLD.is_nsfw IS NOT true THEN sfw_count - 1 ELSE sfw_count END,
        graduated_count = CASE WHEN OLD.is_graduated = true THEN graduated_count - 1 ELSE graduated_count END;
    RETURN OLD;
END;
$$;

CREATE OR REPLACE FUNCTION update_graduated_count()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.is_graduated IS NOT true AND NEW.is_graduated = true THEN
        UPDATE public.token_count SET graduated_count = graduated_count + 1;
    ELSIF OLD.is_graduated = true AND NEW.is_graduated IS NOT true THEN
        UPDATE public.token_count SET graduated_count = graduated_count - 1;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION update_nsfw_count()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.is_nsfw IS NOT true AND NEW.is_nsfw = true THEN
        UPDATE public.token_count
        SET
            nsfw_count = nsfw_count + 1,
            sfw_count = sfw_count - 1;
    ELSIF OLD.is_nsfw = true AND NEW.is_nsfw IS NOT true THEN
        UPDATE public.token_count
        SET
            nsfw_count = nsfw_count - 1,
            sfw_count = sfw_count + 1;
    END IF;
    RETURN NEW;
END;
$$;

-- 트리거 생성
DROP TRIGGER IF EXISTS token_insert_trigger ON public.token;
CREATE TRIGGER token_insert_trigger
AFTER INSERT ON public.token
FOR EACH ROW EXECUTE FUNCTION update_token_count_insert();

DROP TRIGGER IF EXISTS token_delete_trigger ON public.token;
CREATE TRIGGER token_delete_trigger
AFTER DELETE ON public.token
FOR EACH ROW EXECUTE FUNCTION update_token_count_delete();

DROP TRIGGER IF EXISTS token_graduated_count_trigger ON public.token;
CREATE TRIGGER token_graduated_count_trigger
AFTER UPDATE OF is_graduated ON public.token
FOR EACH ROW EXECUTE FUNCTION update_graduated_count();

DROP TRIGGER IF EXISTS token_nsfw_count_trigger ON public.token;
CREATE TRIGGER token_nsfw_count_trigger
AFTER UPDATE OF is_nsfw ON public.token
FOR EACH ROW EXECUTE FUNCTION update_nsfw_count();

ALTER TABLE public.token ENABLE TRIGGER token_insert_trigger;
ALTER TABLE public.token ENABLE TRIGGER token_delete_trigger;
ALTER TABLE public.token ENABLE TRIGGER token_graduated_count_trigger;
ALTER TABLE public.token ENABLE TRIGGER token_nsfw_count_trigger;


CREATE TABLE IF NOT EXISTS token_metadata(
    metadata_url VARCHAR PRIMARY KEY,
    name VARCHAR NOT NULL,
    symbol VARCHAR NOT NULL,
    description TEXT NULL,
    image_url VARCHAR,
    website VARCHAR,
    twitter VARCHAR,
    telegram VARCHAR,
    is_nsfw BOOLEAN NOT NULL DEFAULT FALSE
);





-- Market
CREATE TABLE IF NOT EXISTS market (
    market_type VARCHAR NOT NULL CHECK (market_type IN ('CURVE', 'DEX', 'V2_CURVE', 'V2_DEX')),
    token_id VARCHAR NOT NULL,
    pool_id VARCHAR NULL,
    reserve_quote NUMERIC NULL, --liquidity; quote raw (wei): raw on-chain reserve of the quote token
    reserve_token NUMERIC NULL, -- token raw (wei): raw on-chain reserve of the traded token
    volume NUMERIC NOT NULL DEFAULT 0, -- quote raw (wei): cumulative sum of swap.quote_amount (raw on-chain amount_in/out)
    ath_price NUMERIC(15,10) NOT NULL DEFAULT 0, --USD; USD per token (ath_price_quote * quote USD price)
    ath_price_quote NUMERIC(15,10) NOT NULL DEFAULT 0, --Quote; quote per token (all-time-high in quote terms)
    price NUMERIC(15,10) NOT NULL, -- quote per token: virtual_quote_reserve / virtual_token_reserve (NOT USD)
    quote_id VARCHAR(42) NOT NULL DEFAULT '0x4200000000000000000000000000000000000006',
    latest_trade_at BIGINT NOT NULL,
    created_at BIGINT NOT NULL,
    PRIMARY KEY (token_id)
);

-- Market 테이블 복합 인덱스 (observer는 쓰기 위주이므로 필요한 것만)
CREATE INDEX IF NOT EXISTS idx_market_token_id_market_type ON market (token_id, market_type) WHERE market_type = 'DEX';
CREATE INDEX IF NOT EXISTS idx_market_pool_dex ON market (pool_id, market_type) WHERE market_type = 'DEX';

-- API Token 모듈 최적화: 정렬 쿼리용 인덱스
CREATE INDEX IF NOT EXISTS idx_market_price ON market (price DESC);
CREATE INDEX IF NOT EXISTS idx_market_latest_trade_at ON market (latest_trade_at DESC);



-- Burn History
CREATE TABLE IF NOT EXISTS burn_history(
    token_id VARCHAR(42) NOT NULL ,
    account_id VARCHAR(42) NOT NULL,
    token_amount NUMERIC NOT NULL, -- token raw (wei): ERC20 Transfer value burned to zero address
    transaction_hash VARCHAR NOT NULL,
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    log_index INT NOT NULL,
    PRIMARY KEY(token_id,account_id,transaction_hash,log_index)
);
-- Burn History 테이블은 PRIMARY KEY 외에 추가 인덱스 불필요 (INSERT만 수행)



CREATE TABLE IF NOT EXISTS set_creator_history(
    token_id VARCHAR(42) NOT NULL,
    old_creator VARCHAR(42) NOT NULL,
    new_creator VARCHAR(42) NOT NULL,
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL,
    tx_index INT NOT NULL,
    log_index INT NOT NULL,
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY(transaction_hash, tx_index, log_index)
);


-- ============================================================================
-- >>> 0003_chart.sql
-- ============================================================================


-- =====================================================
-- PRICE HISTORY 트리거 기반 차트 업데이트 시스템
-- price_history 테이블 INSERT → 자동으로 모든 차트 테이블 업데이트
-- =====================================================

-- Price History 테이블 생성
CREATE TABLE IF NOT EXISTS price_history (
    token_id VARCHAR(42) NOT NULL,
    price NUMERIC(15,10) NOT NULL,   -- UNIT: quote per token (chart price = virtual_native/virtual_token; observer src/types/chart.rs:19)
    volume NUMERIC NOT NULL DEFAULT 0,   -- UNIT: quote raw (wei) (amount_in on buy / amount_out on sell; observer src/types/chart.rs:35,48)
    created_at BIGINT NOT NULL,
    block_number BIGINT NOT NULL,
    transaction_hash VARCHAR NOT NULL,
    tx_index INT NOT NULL,
    log_index INT NOT NULL,
    PRIMARY KEY (token_id, block_number, transaction_hash, tx_index,log_index)
);
CREATE INDEX IF NOT EXISTS idx_price_history_token_id_created_at ON price_history (token_id, created_at DESC);

-- Trend job optimization: 24h gain rate query
-- Query: WHERE created_at <= $1 ORDER BY token_id, created_at DESC
CREATE INDEX IF NOT EXISTS idx_price_history_created_at_token
ON price_history (created_at DESC, token_id);

CREATE INDEX IF NOT EXISTS idx_price_history_token_created_asc
ON price_history (token_id, created_at ASC);


-- Chart 테이블 (파티션)
CREATE TABLE IF NOT EXISTS chart (
    token_id VARCHAR(42) NOT NULL,
    interval_type VARCHAR(2) NOT NULL CHECK (interval_type IN ('1', '5', '15', '30', '1H', '4H', 'D', 'W', 'M')),
    open_price NUMERIC(15,10) NOT NULL,   -- UNIT: quote per token (OHLC of price_history.price; 0003_chart.sql trigger lines 199-202)
    close_price NUMERIC(15,10) NOT NULL,   -- UNIT: quote per token
    high_price NUMERIC(15,10) NOT NULL,   -- UNIT: quote per token
    low_price NUMERIC(15,10) NOT NULL,   -- UNIT: quote per token
    volume NUMERIC NOT NULL DEFAULT 0,   -- UNIT: quote raw (wei) (sum of price_history.volume; trigger line 203,216)
    usd_open_price NUMERIC(15,10) NOT NULL,   -- UNIT: USD per token (price * latest_usd_price, USD-per-quote; trigger line 205)
    usd_close_price NUMERIC(15,10) NOT NULL,   -- UNIT: USD per token (trigger line 206)
    usd_high_price NUMERIC(15,10) NOT NULL,   -- UNIT: USD per token (trigger line 207)
    usd_low_price NUMERIC(15,10) NOT NULL,   -- UNIT: USD per token (trigger line 208)
    usd_volume NUMERIC NOT NULL DEFAULT 0,   -- UNIT: USD scaled by 10^quote_decimals -- NOT human USD! (= volume[quote raw wei] * USD-per-quote; divide by 10^quote_decimals for human USD; trigger line 209)
    total_supply NUMERIC NOT NULL,   -- UNIT: token raw (wei) (copied from token.total_supply; trigger line 204)
    time_stamp BIGINT NOT NULL,   -- UNIT: unix seconds (interval-bucketed candle start; convert_chart_timestamp)
    PRIMARY KEY (token_id, interval_type, time_stamp)
) PARTITION BY HASH (token_id);

-- 파티션 생성
CREATE TABLE IF NOT EXISTS chart_0 PARTITION OF chart FOR VALUES WITH (modulus 16, remainder 0);
CREATE TABLE IF NOT EXISTS chart_1 PARTITION OF chart FOR VALUES WITH (modulus 16, remainder 1);
CREATE TABLE IF NOT EXISTS chart_2 PARTITION OF chart FOR VALUES WITH (modulus 16, remainder 2);
CREATE TABLE IF NOT EXISTS chart_3 PARTITION OF chart FOR VALUES WITH (modulus 16, remainder 3);
CREATE TABLE IF NOT EXISTS chart_4 PARTITION OF chart FOR VALUES WITH (modulus 16, remainder 4);
CREATE TABLE IF NOT EXISTS chart_5 PARTITION OF chart FOR VALUES WITH (modulus 16, remainder 5);
CREATE TABLE IF NOT EXISTS chart_6 PARTITION OF chart FOR VALUES WITH (modulus 16, remainder 6);
CREATE TABLE IF NOT EXISTS chart_7 PARTITION OF chart FOR VALUES WITH (modulus 16, remainder 7);
CREATE TABLE IF NOT EXISTS chart_8 PARTITION OF chart FOR VALUES WITH (modulus 16, remainder 8);
CREATE TABLE IF NOT EXISTS chart_9 PARTITION OF chart FOR VALUES WITH (modulus 16, remainder 9);
CREATE TABLE IF NOT EXISTS chart_10 PARTITION OF chart FOR VALUES WITH (modulus 16, remainder 10);
CREATE TABLE IF NOT EXISTS chart_11 PARTITION OF chart FOR VALUES WITH (modulus 16, remainder 11);
CREATE TABLE IF NOT EXISTS chart_12 PARTITION OF chart FOR VALUES WITH (modulus 16, remainder 12);
CREATE TABLE IF NOT EXISTS chart_13 PARTITION OF chart FOR VALUES WITH (modulus 16, remainder 13);
CREATE TABLE IF NOT EXISTS chart_14 PARTITION OF chart FOR VALUES WITH (modulus 16, remainder 14);
CREATE TABLE IF NOT EXISTS chart_15 PARTITION OF chart FOR VALUES WITH (modulus 16, remainder 15);

-- Chart 복합 인덱스 (observer의 INSERT에는 불필요하지만 API 조회용)
CREATE INDEX IF NOT EXISTS idx_chart_lookup ON chart (token_id, interval_type, time_stamp DESC);

-- Trend job optimization: 4h volume query
-- Query: WHERE interval_type = '4H' AND time_stamp >= $1 ORDER BY volume DESC
CREATE INDEX IF NOT EXISTS idx_chart_interval_timestamp
ON chart (interval_type, time_stamp);




-- Rust convert_chart_timestamp와 동일한 PostgreSQL 함수
CREATE OR REPLACE FUNCTION convert_chart_timestamp(
    input_timestamp BIGINT, 
    interval_type TEXT
) RETURNS BIGINT AS $$
DECLARE
    total_minutes BIGINT;
    rounded_minutes BIGINT;
BEGIN
    -- 1단계: 초를 분으로 변환
    total_minutes := input_timestamp / 60;
    
    -- 2단계: interval에 따라 분 단위 반올림
    CASE interval_type
        WHEN '1' THEN 
            rounded_minutes := total_minutes;
        WHEN '5' THEN 
            rounded_minutes := (total_minutes / 5) * 5;
        WHEN '15' THEN 
            rounded_minutes := (total_minutes / 15) * 15;
        WHEN '30' THEN 
            rounded_minutes := (total_minutes / 30) * 30;
        WHEN '1H' THEN 
            rounded_minutes := (total_minutes / 60) * 60;
        WHEN '4H' THEN 
            rounded_minutes := (total_minutes / 240) * 240;
        WHEN 'D' THEN 
            rounded_minutes := (total_minutes / 1440) * 1440;
        WHEN 'W' THEN 
            -- 주 단위: 월요일 자정 기준 (분 단위로 변환)
            rounded_minutes := EXTRACT(EPOCH FROM DATE_TRUNC('week', TO_TIMESTAMP(input_timestamp)))::BIGINT / 60;
        WHEN 'M' THEN 
            -- 월 단위: 월초 자정 기준 (분 단위로 변환)
            rounded_minutes := EXTRACT(EPOCH FROM DATE_TRUNC('month', TO_TIMESTAMP(input_timestamp)))::BIGINT / 60;
        ELSE 
            rounded_minutes := total_minutes;
    END CASE;
    
    -- 3단계: 분을 다시 초로 변환
    RETURN rounded_minutes * 60;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 6단계: 트리거 함수 업데이트 (USD OHLC 지원)
CREATE OR REPLACE FUNCTION update_charts_on_price_insert()
RETURNS TRIGGER AS $$
DECLARE
    interval_val TEXT;
    converted_timestamp BIGINT;
    prev_close_price NUMERIC(15,10);
    prev_usd_close_price NUMERIC(15,10);
    token_supply NUMERIC;
    latest_usd_price NUMERIC;
    token_quote_id VARCHAR(42);
BEGIN
    -- token total_supply + market quote_id 1회 PK 조회로 통합
    SELECT t.total_supply, m.quote_id
      INTO token_supply, token_quote_id
      FROM token t
      JOIN market m ON m.token_id = t.token_id
     WHERE t.token_id = NEW.token_id;

    -- USD 가격 조회 (해당 quote_id의 해당 블록 이하 최신)
    -- quote_id 등호 필터로 idx_price_quote_block 인덱스 사용
    SELECT price INTO latest_usd_price
    FROM price
    WHERE quote_id = token_quote_id
      AND block_number <= NEW.block_number
    ORDER BY block_number DESC
    LIMIT 1;

    -- 해당 블록 이하에 USD 가격이 없으면 최신 USD 가격 사용 (같은 quote 한정)
    IF latest_usd_price IS NULL THEN
        SELECT price INTO latest_usd_price
        FROM price
        WHERE quote_id = token_quote_id
        ORDER BY block_number DESC
        LIMIT 1;
    END IF;

    -- USD 환율이 없으면 1로 설정
    IF latest_usd_price IS NULL THEN
        latest_usd_price := 1;
    END IF;

    -- 각 시간대별로 차트 업데이트
    FOREACH interval_val IN ARRAY ARRAY['1', '5', '15', '30', '1H', '4H', 'D', 'W', 'M']
    LOOP
        -- 타임스탬프 변환
        converted_timestamp := convert_chart_timestamp(NEW.created_at, interval_val);

        -- 이전 캔들의 close_price, usd_close_price 조회 (새 캔들의 open_price로 사용)
        SELECT close_price, usd_close_price INTO prev_close_price, prev_usd_close_price
        FROM chart
        WHERE chart.token_id = NEW.token_id
          AND chart.interval_type = interval_val
          AND chart.time_stamp < converted_timestamp
        ORDER BY chart.time_stamp DESC
        LIMIT 1;

        -- OHLCV + Market Cap + USD OHLCV 업데이트
        INSERT INTO chart (
            token_id,
            interval_type,
            time_stamp,
            open_price,
            close_price,
            high_price,
            low_price,
            volume,
            total_supply,
            usd_open_price,
            usd_close_price,
            usd_high_price,
            usd_low_price,
            usd_volume
        )
        VALUES (
            NEW.token_id,
            interval_val,
            converted_timestamp,
            COALESCE(prev_close_price, NEW.price),                                      -- open_price
            NEW.price,                                                                  -- close_price
            NEW.price,                                                                  -- high_price
            NEW.price,                                                                  -- low_price
            NEW.volume,                                                                 -- volume
            COALESCE(token_supply, 0),                                                  -- total_supply
            COALESCE(prev_usd_close_price, NEW.price * latest_usd_price),              -- usd_open_price
            NEW.price * latest_usd_price,                                              -- usd_close_price
            NEW.price * latest_usd_price,                                              -- usd_high_price
            NEW.price * latest_usd_price,                                              -- usd_low_price
            NEW.volume * latest_usd_price                                               -- usd_volume
        )
        ON CONFLICT (token_id, interval_type, time_stamp)
        DO UPDATE SET
            close_price = EXCLUDED.close_price,
            high_price = GREATEST(chart.high_price, EXCLUDED.high_price),
            low_price = LEAST(chart.low_price, EXCLUDED.low_price),
            volume = chart.volume + EXCLUDED.volume,
            total_supply = EXCLUDED.total_supply,
            usd_close_price = EXCLUDED.usd_close_price,
            usd_high_price = GREATEST(chart.usd_high_price, EXCLUDED.usd_high_price),
            usd_low_price = LEAST(chart.usd_low_price, EXCLUDED.usd_low_price),
            usd_volume = chart.usd_volume + EXCLUDED.usd_volume;
    END LOOP;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- price_history INSERT 트리거 생성
DROP TRIGGER IF EXISTS trigger_update_charts_on_price_insert ON price_history;
CREATE TRIGGER trigger_update_charts_on_price_insert
    AFTER INSERT ON price_history
    FOR EACH ROW
    EXECUTE FUNCTION update_charts_on_price_insert();

-- 트리거 활성화
ALTER TABLE price_history ENABLE TRIGGER trigger_update_charts_on_price_insert;




-- Chart count table
CREATE TABLE IF NOT EXISTS chart_count(
    token_id VARCHAR(42) NOT NULL,
    interval_type VARCHAR(2) NOT NULL CHECK (interval_type IN ('1', '5', '15', '30', '1H', '4H', 'D', 'W', 'M')),
    count BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (token_id, interval_type)
);
-- Chart Count 테이블은 PRIMARY KEY 외에 추가 인덱스 불필요

-- Chart Count 트리거
CREATE OR REPLACE FUNCTION update_chart_count()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO chart_count (token_id, interval_type, count)
    VALUES (NEW.token_id, NEW.interval_type, 1)
    ON CONFLICT (token_id, interval_type)
    DO UPDATE SET count = chart_count.count + 1;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS chart_count_trigger ON public.chart;
CREATE TRIGGER chart_count_trigger
    AFTER INSERT OR UPDATE ON chart
    FOR EACH ROW
    EXECUTE FUNCTION update_chart_count();

ALTER TABLE chart ENABLE TRIGGER chart_count_trigger;





-- ============================================================================
-- >>> 0004_swap.sql
-- ============================================================================

-- Swap History
CREATE TABLE IF NOT EXISTS swap (
    account_id VARCHAR(42) NOT NULL,
    token_id VARCHAR(42) NOT NULL,
    -- market type
    market_type VARCHAR NOT NULL CHECK (market_type IN ('CURVE', 'DEX', 'V2_CURVE', 'V2_DEX')),
    is_buy BOOLEAN NOT NULL,
    quote_amount NUMERIC NOT NULL,   -- UNIT: quote raw (wei) (buy=amount_in / sell=amount_out; observer src/event/v1/curve/receive.rs:431,530)
    token_amount NUMERIC NOT NULL,   -- UNIT: token raw (wei) (buy=amount_out / sell=amount_in; observer src/event/v1/curve/receive.rs:432,531)
    reserve_quote NUMERIC NULL,   -- UNIT: quote raw (wei) (curve/pool quote reserve snapshot; observer src/event/v1/curve/receive.rs:433)
    reserve_token NUMERIC NULL,   -- UNIT: token raw (wei) (curve/pool token reserve snapshot; observer src/event/v1/curve/receive.rs:434)
    value NUMERIC NOT NULL DEFAULT 0,   -- UNIT: USD (human) ((quote_amount / 10^decimals) * USD-per-quote price; observer src/event/v1/curve/receive.rs:409-410)
    created_at BIGINT NOT NULL,
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL DEFAULT 0,
    tx_index INT NOT NULL,
    log_index INT NOT NULL,
    PRIMARY KEY (account_id,token_id, transaction_hash,tx_index,log_index)
);

CREATE INDEX IF NOT EXISTS idx_swap_account_created_at ON swap (account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_swap_token_account_buy_created ON swap (token_id, account_id, is_buy, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_swap_token_buy_volume_created ON swap (token_id, is_buy, quote_amount DESC, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_swap_is_buy_created_at ON swap (is_buy, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_swap_block_number_tx_index_log_index ON swap (block_number ASC, tx_index ASC, log_index ASC);
CREATE INDEX IF NOT EXISTS idx_swap_token_created ON swap (token_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_swap_block_number_tx_index_log_index_desc
ON swap (block_number DESC, tx_index DESC, log_index DESC);

-- Trend job optimization: 4h tx count query
-- Query: WHERE created_at >= $1 GROUP BY token_id ORDER BY COUNT(*) DESC
CREATE INDEX IF NOT EXISTS idx_swap_created_at_token
ON swap (created_at, token_id);


-- 1. 트리거 함수 생성 (swap INSERT 시 market volume 증가)
CREATE OR REPLACE FUNCTION update_market_volume()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE market
    SET volume = volume + NEW.quote_amount
    WHERE token_id = NEW.token_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 2. 트리거 생성
CREATE TRIGGER trg_update_market_volume
AFTER INSERT ON swap
FOR EACH ROW
EXECUTE FUNCTION update_market_volume();

-- 3. 기존 데이터로 market의 volume 업데이트
UPDATE market m
SET volume = COALESCE(
    (
        SELECT SUM(s.quote_amount)
        FROM swap s
        WHERE s.token_id = m.token_id
    ),
    0
);



-- -- API New Content 모듈 최적화: latest buy/sell 조회용 인덱스
-- CREATE INDEX IF NOT EXISTS idx_swap_is_buy_created_at ON swap (is_buy, created_at DESC);

-- CREATE INDEX IF NOT EXISTS idx_swap_time_token_buy ON swap (token_id , created_at DESC, is_buy);
-- -- API Trading 모듈 최적화: swap history 조회용 복합 인덱스들
-- CREATE INDEX IF NOT EXISTS idx_swap_account_created_at ON swap (account_id, created_at DESC);
-- CREATE INDEX IF NOT EXISTS idx_swap_token_created_at ON swap (token_id, created_at DESC);
-- CREATE INDEX IF NOT EXISTS idx_swap_token_account ON swap (token_id, account_id, created_at DESC);
-- CREATE INDEX IF NOT EXISTS idx_swap_token_buy ON swap (token_id, is_buy, created_at DESC);
-- CREATE INDEX IF NOT EXISTS idx_swap_token_volume ON swap (token_id, quote_amount, created_at DESC);
-- CREATE INDEX IF NOT EXISTS idx_swap_token_account_buy_created_at ON swap (token_id, account_id, is_buy, created_at DESC);
-- CREATE INDEX IF NOT EXISTS idx_swap_token_buy_amount_created_at ON swap (token_id, is_buy, quote_amount, created_at DESC);

CREATE TABLE IF NOT EXISTS swap_count (
    token_id VARCHAR(42) PRIMARY KEY,
    count BIGINT NOT NULL DEFAULT 0,
    buy_count BIGINT NOT NULL DEFAULT 0,
    sell_count BIGINT NOT NULL DEFAULT 0
);
-- Swap Count 테이블은 PRIMARY KEY 외에 추가 인덱스 불필요

-- 기존 데이터 초기화
UPDATE swap_count SET 
    count = (
        SELECT COUNT(*) FROM swap 
        WHERE token_id = swap_count.token_id
    ),
    buy_count = (
        SELECT COUNT(*) FROM swap 
        WHERE token_id = swap_count.token_id AND is_buy = true
    ),
    sell_count = (
        SELECT COUNT(*) FROM swap 
        WHERE token_id = swap_count.token_id AND is_buy = false
    );

-- Swap Count 트리거
CREATE OR REPLACE FUNCTION update_swap_count()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.token_id IS NULL THEN
        RETURN NEW;
    END IF;

    INSERT INTO public.swap_count (token_id, count, buy_count, sell_count)
    VALUES (
        NEW.token_id, 
        1,
        CASE WHEN NEW.is_buy THEN 1 ELSE 0 END,
        CASE WHEN NEW.is_buy THEN 0 ELSE 1 END
    )
    ON CONFLICT (token_id)
    DO UPDATE SET 
        count = public.swap_count.count + 1,
        buy_count = public.swap_count.buy_count + CASE WHEN NEW.is_buy THEN 1 ELSE 0 END,
        sell_count = public.swap_count.sell_count + CASE WHEN NEW.is_buy THEN 0 ELSE 1 END;
    
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS swap_count_trigger ON public.swap;
CREATE TRIGGER swap_count_trigger
    AFTER INSERT ON public.swap
    FOR EACH ROW
    EXECUTE FUNCTION update_swap_count();

ALTER TABLE public.swap ENABLE TRIGGER swap_count_trigger;



-- Account Swap Count 집계 테이블 (Trading 모듈 최적화)
CREATE TABLE IF NOT EXISTS account_swap_count (
    account_id VARCHAR(42) PRIMARY KEY,
    total_count BIGINT NOT NULL DEFAULT 0,
    last_updated TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);


-- Account Swap Count 초기 데이터 삽입
INSERT INTO account_swap_count (account_id, total_count)
SELECT 
    s.account_id,
    COUNT(*) as total_count
FROM swap s
GROUP BY s.account_id
ON CONFLICT (account_id) DO UPDATE 
SET total_count = EXCLUDED.total_count,
    last_updated = NOW();

-- Account Swap Count 트리거 함수
CREATE OR REPLACE FUNCTION update_account_swap_count() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO account_swap_count (account_id, total_count)
    VALUES (NEW.account_id, 1)
    ON CONFLICT (account_id) 
    DO UPDATE SET 
        total_count = account_swap_count.total_count + 1,
        last_updated = NOW();
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_update_account_swap_count ON swap;
CREATE TRIGGER trg_update_account_swap_count
AFTER INSERT ON swap
FOR EACH ROW
EXECUTE FUNCTION update_account_swap_count();



CREATE TABLE IF NOT EXISTS mint(
    token_id VARCHAR(42) NOT NULL,
    account_id VARCHAR(42) NOT NULL,
    market_id VARCHAR(42) NOT NULL,
    quote_amount NUMERIC NOT NULL,   -- UNIT: quote raw (wei) (decoded log amount; observer src/event/v1/dex/receive.rs:570)
    token_amount NUMERIC NOT NULL,   -- UNIT: token raw (wei) (decoded log amount; observer src/event/v1/dex/receive.rs:571)
    reserve_quote NUMERIC NOT NULL,   -- UNIT: quote raw (wei) (pool reserve snapshot; observer src/event/v1/dex/receive.rs:572)
    reserve_token NUMERIC NOT NULL,   -- UNIT: token raw (wei) (pool reserve snapshot; observer src/event/v1/dex/receive.rs:573)
    created_at BIGINT NOT NULL,
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL,
    tx_index INT NOT NULL,
    log_index INT NOT NULL,
    PRIMARY KEY (token_id, transaction_hash, tx_index, log_index)
);

CREATE INDEX IF NOT EXISTS idx_mint_block_number_tx_index_log_index ON mint (block_number ASC, tx_index ASC, log_index ASC);


CREATE TABLE IF NOT EXISTS burn(
    token_id VARCHAR(42) NOT NULL,
    account_id VARCHAR(42) NOT NULL,
    market_id VARCHAR(42) NOT NULL,
    quote_amount NUMERIC NOT NULL,   -- UNIT: quote raw (wei) (decoded log amount; observer src/event/v1/dex/receive.rs:590)
    token_amount NUMERIC NOT NULL,   -- UNIT: token raw (wei) (decoded log amount; observer src/event/v1/dex/receive.rs:591)
    reserve_quote NUMERIC NOT NULL,   -- UNIT: quote raw (wei) (pool reserve snapshot; observer src/event/v1/dex/receive.rs:592)
    reserve_token NUMERIC NOT NULL,   -- UNIT: token raw (wei) (pool reserve snapshot; observer src/event/v1/dex/receive.rs:593)
    created_at BIGINT NOT NULL,
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL,
    tx_index INT NOT NULL,
    log_index INT NOT NULL,
    PRIMARY KEY (token_id, transaction_hash, tx_index, log_index)
);

CREATE INDEX IF NOT EXISTS idx_burn_block_number_tx_index_log_index ON burn (block_number ASC, tx_index ASC, log_index ASC);




-- ============================================================================
-- >>> 0005_balance.sql
-- ============================================================================


-- =====================================================
-- 참고: 이제 Rust 코드에서는 balance_history만 INSERT하면 됨
-- balance 테이블은 트리거가 자동으로 관리
-- =====================================================



-- =====================================================
-- balance_history INSERT 시 자동으로 balance 테이블 업데이트
-- =====================================================

CREATE TABLE IF NOT EXISTS balance_history(
    token_id VARCHAR(42) NOT NULL ,
    account_id VARCHAR(42) NOT NULL,
    balance NUMERIC NOT NULL,   -- UNIT: token raw (wei) (ERC20 balanceOf at block, no scaling; observer src/event/common/token/stream.rs:702-713)
    block_number BIGINT NOT NULL,
    transaction_hash VARCHAR NOT NULL,
    log_index INT NOT NULL,
    tx_index INT NOT NULL,
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (token_id, account_id, transaction_hash,tx_index, log_index)
);

-- Backfill / migration support: DISTINCT ON (account_id, token_id) ORDER BY
-- block_number DESC, tx_index DESC, log_index DESC is the canonical
-- "latest balance per (account, token)" query (used by
-- v2_upgrade_triggers_and_backfill.sql). Without this index the sort spills
-- to disk on production-size history tables.
CREATE INDEX IF NOT EXISTS idx_balance_history_acct_token_block
    ON balance_history (account_id, token_id, block_number DESC, tx_index DESC, log_index DESC);



-- 1. 트리거 함수 생성
-- The `WHERE balance.created_at <= EXCLUDED.created_at` guard prevents an
-- out-of-order balance_history INSERT (older row arriving after a newer one,
-- e.g., from parallel indexer workers or a backfill) from overwriting the
-- current balance with stale data. Without the guard, the ON CONFLICT path
-- would unconditionally write the older `balance` value.
CREATE OR REPLACE FUNCTION update_balance_from_history()
RETURNS TRIGGER AS $$
BEGIN
    -- 새로 INSERT된 balance로 balance 테이블 업데이트
    INSERT INTO balance (account_id, token_id, balance, created_at)
    VALUES (NEW.account_id, NEW.token_id, NEW.balance, NEW.created_at)
    ON CONFLICT (account_id, token_id)
    DO UPDATE SET
        balance = EXCLUDED.balance,
        created_at = EXCLUDED.created_at
    WHERE balance.created_at <= EXCLUDED.created_at;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 2. 트리거 생성
DROP TRIGGER IF EXISTS trigger_update_balance_from_history ON balance_history;
CREATE TRIGGER trigger_update_balance_from_history
    AFTER INSERT ON balance_history
    FOR EACH ROW
    EXECUTE FUNCTION update_balance_from_history();

-- 3. 트리거 활성화
ALTER TABLE balance_history ENABLE TRIGGER trigger_update_balance_from_history;

CREATE TABLE IF NOT EXISTS balance(
    account_id VARCHAR(42) NOT NULL,
    token_id VARCHAR(42) NOT NULL,
    balance NUMERIC NOT NULL DEFAULT 0,   -- UNIT: token raw (wei) (latest balance_history.balance; trigger update_balance_from_history)
    created_at BIGINT NOT NULL,
    PRIMARY KEY (account_id, token_id)
);

-- API Search 모듈 최적화: 계정별 총 자산 계산 서브쿼리용 인덱스
CREATE INDEX IF NOT EXISTS idx_balance_account_balance ON balance (account_id, balance DESC) WHERE balance >= 1000000000000000000;
CREATE INDEX IF NOT EXISTS idx_balance_account_token ON balance (account_id,token_id,balance DESC);
CREATE INDEX IF NOT EXISTS idx_balance_token_account ON balance (token_id,account_id,balance DESC);

-- API Trading 모듈 최적화: position 조회용 복합 인덱스들
CREATE INDEX IF NOT EXISTS idx_balance_token_balance ON balance (token_id, balance DESC) WHERE balance > 0;
CREATE INDEX IF NOT EXISTS idx_balance_account_positive ON balance (account_id, balance DESC) WHERE balance > 0;
-- (Two unconditional duplicates of idx_balance_token_balance and
--  idx_balance_account_balance used to live here. CREATE INDEX IF NOT EXISTS
--  checks the name only, so on fresh DBs the partial-index versions above
--  always won and the unconditional copies were dead code. Removed.)

CREATE OR REPLACE FUNCTION delete_zero_balance()
  RETURNS TRIGGER AS $$
  BEGIN
      IF NEW.balance = 0 THEN
          DELETE FROM balance WHERE account_id = NEW.account_id AND token_id = NEW.token_id;
          RETURN NULL;
      END IF;
      RETURN NEW;
  END;
  $$ LANGUAGE plpgsql;

  CREATE TRIGGER trigger_delete_zero_balance
  AFTER UPDATE ON balance
  FOR EACH ROW
  EXECUTE FUNCTION delete_zero_balance();


CREATE OR REPLACE FUNCTION update_token_holder_count_v2() 
RETURNS TRIGGER AS $$
DECLARE
  v_old_positive BOOLEAN;
  v_new_positive BOOLEAN;
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- INSERT: balance > 0이면 holder_count 증가
    IF NEW.balance > 0 THEN
      UPDATE token 
      SET token_holder_count = token_holder_count + 1
      WHERE token_id = NEW.token_id;
    END IF;
    
  ELSIF TG_OP = 'UPDATE' THEN
    v_old_positive := OLD.balance > 0;
    v_new_positive := NEW.balance > 0;
    
    IF NOT v_old_positive AND v_new_positive THEN
      -- 0 이하 → 양수: holder 증가
      UPDATE token 
      SET token_holder_count = token_holder_count + 1
      WHERE token_id = NEW.token_id;
      
    ELSIF v_old_positive AND NOT v_new_positive THEN
      -- 양수 → 0 이하: holder 감소
      UPDATE token 
      SET token_holder_count = GREATEST(token_holder_count - 1, 0)
      WHERE token_id = NEW.token_id;
    END IF;
    
  ELSIF TG_OP = 'DELETE' THEN
    -- DELETE: balance > 0이었으면 holder_count 감소
    IF OLD.balance > 0 THEN
      UPDATE token 
      SET token_holder_count = GREATEST(token_holder_count - 1, 0)
      WHERE token_id = OLD.token_id;
    END IF;
  END IF;
  
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- 새로운 트리거 생성
CREATE TRIGGER trg_update_holder_count
AFTER INSERT OR UPDATE OR DELETE ON balance
FOR EACH ROW
EXECUTE FUNCTION update_token_holder_count_v2();


-- ============================================================================
-- >>> 0006_lp.sql
-- ============================================================================


-- LP Manager
CREATE TABLE IF NOT EXISTS lp_allocate_history(
    token_id VARCHAR(42) NOT NULL,
    quote_amount NUMERIC NOT NULL, -- quote raw (wei); LpManagerAllocate.monAmount
    token_amount NUMERIC NOT NULL, -- token raw (wei); LpManagerAllocate.tokenAmount
    transaction_hash VARCHAR NOT NULL,
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (token_id,transaction_hash)
);
-- LP Allocate History 테이블은 PRIMARY KEY 외에 추가 인덱스 불필요 (INSERT만 수행)

-- 1. 트리거 함수 생성                                                                                                                                                                                                                                                                                                                                                                                                                       
CREATE OR REPLACE FUNCTION update_lp_collect_status_from_allocate()                                                                                                                                                                                                                                                                                                                                                                          
RETURNS TRIGGER AS $$                                                                                                                                                                                                                                                                                                                                                                                                                        
BEGIN                                                                                                                                                                                                                                                                                                                                                                                                                                        
    -- 새로 INSERT된 allocate 정보로 lp_collect_status 업데이트                                                                                                                                                                                                                                                                                                                                                                              
    INSERT INTO lp_collect_status (token_id, last_collect_at)                                                                                                                                                                                                                                                                                                                                                                                
    VALUES (NEW.token_id, NEW.created_at)                                                                                                                                                                                                                                                                                                                                                                                                    
    ON CONFLICT (token_id)                                                                                                                                                                                                                                                                                                                                                                                                                   
    DO NOTHING;  -- 이미 존재하면 아무것도 하지 않음 (collect가 더 최신일 수 있음)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 
    RETURN NEW;                                                                                                                                                                                                                                                                                                                                                                                                                              
END;                                                                                                                                                                                                                                                                                                                                                                                                                                         
$$ LANGUAGE plpgsql;                                                                                                                                                                                                                                                                                                                                                                                                                         
                                                                                                                                                                                                                                                                                                                                                                                                                                             
-- 2. 트리거 생성                                                                                                                                                                                                                                                                                                                                                                                                                            
DROP TRIGGER IF EXISTS trigger_update_lp_collect_status_from_allocate ON lp_allocate_history;                                                                                                                                                                                                                                                                                                                                                
CREATE TRIGGER trigger_update_lp_collect_status_from_allocate                                                                                                                                                                                                                                                                                                                                                                                
    AFTER INSERT ON lp_allocate_history                                                                                                                                                                                                                                                                                                                                                                                                      
    FOR EACH ROW                                                                                                                                                                                                                                                                                                                                                                                                                             
    EXECUTE FUNCTION update_lp_collect_status_from_allocate();                                                                                                                                                                                                                                                                                                                                                                               
                                                                                                                                                                                                                                                                                                                                                                                                                                             
-- 3. 트리거 활성화                                                                                                                                                                                                                                                                                                                                                                                                                          
ALTER TABLE lp_allocate_history ENABLE TRIGGER trigger_update_lp_collect_status_from_allocate;    





CREATE TABLE IF NOT EXISTS lp_collect_history(
    token_id VARCHAR(42) NOT NULL,
    quote_amount NUMERIC NOT NULL, -- quote raw (wei); LpManagerCollect.monAmount
    token_amount NUMERIC NOT NULL, --token treasury -- token raw (wei); LpManagerCollect.tokenAmount
    c_amount NUMERIC NOT NULL, --creator treasury -- quote raw (wei); quote_amount * creatorTreasuryFeeRate / 1e6
    ft_amount NUMERIC NOT NULL, --foundation treasury -- quote raw (wei); quote_amount * foundationTreasuryFeeRate / 1e6
    ct_amount NUMERIC NOT NULL, --community treasury -- quote raw (wei); quote_amount * communityTreasuryFeeRate / 1e6
    transaction_hash VARCHAR NOT NULL,
    tx_index INT NOT NULL,
    log_index INT NOT NULL,
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (token_id,transaction_hash,tx_index,log_index)
);
-- LP Collect History 테이블은 PRIMARY KEY 외에 추가 인덱스 불필요 (INSERT만 수행)


CREATE OR REPLACE FUNCTION update_lp_collect_status_from_collect()
RETURNS TRIGGER AS $$
BEGIN
    -- 새로 INSERT된 collect 정보로 lp_collect_status 업데이트
    INSERT INTO lp_collect_status (token_id, last_collect_at)
    VALUES (NEW.token_id, NEW.created_at)
    ON CONFLICT (token_id)
    DO UPDATE SET
        last_collect_at = NEW.created_at;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 2. 트리거 생성
DROP TRIGGER IF EXISTS trigger_update_lp_collect_status_from_collect ON lp_collect_history;
CREATE TRIGGER trigger_update_lp_collect_status_from_collect
    AFTER INSERT ON lp_collect_history
    FOR EACH ROW
    EXECUTE FUNCTION update_lp_collect_status_from_collect();

-- 3. 트리거 활성화
ALTER TABLE lp_collect_history ENABLE TRIGGER trigger_update_lp_collect_status_from_collect;




CREATE TABLE IF NOT EXISTS lp_collect_status(
    token_id VARCHAR(42) NOT NULL,
    last_collect_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (token_id)
);
-- LP Collect Status는 UPDATE에서 WHERE token_id = $1 사용하므로 PRIMARY KEY만으로 충분





-- Fee Distribution History (Distributed event)
CREATE TABLE IF NOT EXISTS fee_distribute_history (
    transaction_hash VARCHAR(66) NOT NULL,
    tx_index INT NOT NULL DEFAULT 0,
    log_index INT NOT NULL,
    token_id VARCHAR(42) NOT NULL,
    token_amount NUMERIC(78, 0) NOT NULL, -- token raw (wei); Distributed.tokenAmount
    mon_received NUMERIC(78, 0) NOT NULL, -- quote raw (wei); Distributed.monReceived
    foundation_amount NUMERIC(78, 0) NOT NULL, -- quote raw (wei); Distributed.foundationAmount (split of monReceived)
    creator_amount NUMERIC(78, 0) NOT NULL, -- quote raw (wei); Distributed.creatorAmount (split of monReceived)
    block_number BIGINT NOT NULL,
    created_at BIGINT NOT NULL,
    PRIMARY KEY (transaction_hash, tx_index, log_index)
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_fee_distribute_history_token ON fee_distribute_history(token_id);
CREATE INDEX IF NOT EXISTS idx_fee_distribute_history_block ON fee_distribute_history(block_number);
CREATE INDEX IF NOT EXISTS idx_fee_distribute_history_created_at ON fee_distribute_history(created_at);

-- =====================================================
-- Trigger: Update creator_treasury_balance from fee_distribute_history
-- =====================================================

-- 1. 트리거 함수 생성
CREATE OR REPLACE FUNCTION update_creator_treasury_balance_from_distribute()
RETURNS TRIGGER AS $$
BEGIN
    -- token 테이블에서 creator를 조회하여 creator_treasury_balance 업데이트
    INSERT INTO creator_treasury_balance (account_id, token_id, amount)
    SELECT creator, NEW.token_id, NEW.creator_amount
    FROM token
    WHERE token_id = NEW.token_id
    ON CONFLICT (account_id, token_id)
    DO UPDATE SET
        amount = creator_treasury_balance.amount + EXCLUDED.amount;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 2. 트리거 생성
DROP TRIGGER IF EXISTS trigger_update_creator_treasury_balance_from_distribute ON fee_distribute_history;
CREATE TRIGGER trigger_update_creator_treasury_balance_from_distribute
    AFTER INSERT ON fee_distribute_history
    FOR EACH ROW
    EXECUTE FUNCTION update_creator_treasury_balance_from_distribute();

-- 3. 트리거 활성화
ALTER TABLE fee_distribute_history ENABLE TRIGGER trigger_update_creator_treasury_balance_from_distribute;


-- ============================================================================
-- >>> 0007_price.sql
-- ============================================================================

-- Price table: multi-quote aware.
-- Supports multiple quote tokens (WMON, USDC, etc.) via a composite
-- primary key (quote_id, block_number). The default quote_id is the
-- GIWA WETH predeploy address, matching the legacy V1 single-quote behavior.
CREATE TABLE IF NOT EXISTS price (
    quote_id VARCHAR(42) NOT NULL DEFAULT '0x4200000000000000000000000000000000000006',
    block_number BIGINT NOT NULL,
    price NUMERIC NOT NULL, -- USD per quote: Pyth oracle USD price of quote_id at this block

    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (quote_id, block_number)
);

-- Per-quote range scan index (descending block for latest-first queries)
CREATE INDEX IF NOT EXISTS idx_price_quote_block ON price (quote_id, block_number DESC);
CREATE INDEX IF NOT EXISTS idx_price_created_at ON price (created_at DESC);


-- ============================================================================
-- >>> 0008_treasury.sql
-- ============================================================================




CREATE TABLE IF NOT EXISTS token_treasury_balance(
    token_id VARCHAR(42) NOT NULL,
    amount NUMERIC NOT NULL, -- UNIT: token raw (wei); accumulates lp_collect_history.token_amount (LpManagerCollect.tokenAmount). --collect history 가 insert 되면 업데이트
    PRIMARY KEY (token_id)
);


-- =====================================================
-- lp_collect_history INSERT 시 token_treasury_balance 업데이트
-- =====================================================

-- 1. 트리거 함수 생성
CREATE OR REPLACE FUNCTION update_token_treasury_balance_from_collect()
RETURNS TRIGGER AS $$
BEGIN
    -- token_treasury_balance 업데이트 (token_amount 누적)
    INSERT INTO token_treasury_balance (token_id, amount)
    VALUES (NEW.token_id, NEW.token_amount)
    ON CONFLICT (token_id)
    DO UPDATE SET
        amount = token_treasury_balance.amount + EXCLUDED.amount;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 2. 트리거 생성
DROP TRIGGER IF EXISTS trigger_update_token_treasury_balance_from_collect ON lp_collect_history;
CREATE TRIGGER trigger_update_token_treasury_balance_from_collect
    AFTER INSERT ON lp_collect_history
    FOR EACH ROW
    EXECUTE FUNCTION update_token_treasury_balance_from_collect();

-- 3. 트리거 활성화
ALTER TABLE lp_collect_history ENABLE TRIGGER trigger_update_token_treasury_balance_from_collect;



-- Creator Treasury Balance(각 creator 가 받아야할 양)
CREATE TABLE IF NOT EXISTS creator_treasury_balance(
    account_id VARCHAR(42) NOT NULL,
    token_id VARCHAR(42) NOT NULL,
    amount NUMERIC NOT NULL, -- UNIT: quote raw (wei); accumulates lp_collect_history.c_amount = monAmount * creatorTreasuryFeeRate / 1e6. --collect history 가 insert 되면 업데이트(token_id 로 token의 creator 로 accuont_id 찾음)
    PRIMARY KEY (account_id, token_id)
);

 -- 1. 트리거 함수 생성                                                                                                                                                                                                                                                                                                                                                                                                                       
 CREATE OR REPLACE FUNCTION update_creator_treasury_balance_from_collect()                                                                                                                                                                                                                                                                                                                                                                    
 RETURNS TRIGGER AS $$                                                                                                                                                                                                                                                                                                                                                                                                                        
 BEGIN                                                                                                                                                                                                                                                                                                                                                                                                                                        
     -- token 테이블에서 creator를 조회하여 creator_treasury_balance 업데이트                                                                                                                                                                                                                                                                                                                                                                 
     INSERT INTO creator_treasury_balance (account_id, token_id, amount)                                                                                                                                                                                                                                                                                                                                                                      
     SELECT creator, NEW.token_id, NEW.c_amount                                                                                                                                                                                                                                                                                                                                                                                               
     FROM token                                                                                                                                                                                                                                                                                                                                                                                                                               
     WHERE token_id = NEW.token_id                                                                                                                                                                                                                                                                                                                                                                                                            
     ON CONFLICT (account_id, token_id)                                                                                                                                                                                                                                                                                                                                                                                                       
     DO UPDATE SET                                                                                                                                                                                                                                                                                                                                                                                                                            
         amount = creator_treasury_balance.amount + EXCLUDED.amount;                                                                                                                                                                                                                                                                                                                                                                          
                                                                                                                                                                                                                                                                                                                                                                                                                                              
     RETURN NEW;                                                                                                                                                                                                                                                                                                                                                                                                                              
 END;                                                                                                                                                                                                                                                                                                                                                                                                                                         
 $$ LANGUAGE plpgsql;                                                                                                                                                                                                                                                                                                                                                                                                                         
                                                                                                                                                                                                                                                                                                                                                                                                                                              
 -- 2. 트리거 생성                                                                                                                                                                                                                                                                                                                                                                                                                            
 DROP TRIGGER IF EXISTS trigger_update_creator_treasury_balance_from_collect ON lp_collect_history;                                                                                                                                                                                                                                                                                                                                           
 CREATE TRIGGER trigger_update_creator_treasury_balance_from_collect                                                                                                                                                                                                                                                                                                                                                                          
     AFTER INSERT ON lp_collect_history                                                                                                                                                                                                                                                                                                                                                                                                       
     FOR EACH ROW                                                                                                                                                                                                                                                                                                                                                                                                                             
     EXECUTE FUNCTION update_creator_treasury_balance_from_collect();                                                                                                                                                                                                                                                                                                                                                                         
                                                                                                                                                                                                                                                                                                                                                                                                                                              
 -- 3. 트리거 활성화                                                                                                                                                                                                                                                                                                                                                                                                                          
 ALTER TABLE lp_collect_history ENABLE TRIGGER trigger_update_creator_treasury_balance_from_collect;  






CREATE TABLE IF NOT EXISTS creator_treasury_claim_history(
    token_id VARCHAR(42) NOT NULL,
    account_id VARCHAR(42) NOT NULL,
    amount NUMERIC NOT NULL, -- UNIT: quote raw (wei); claimed amount deducted from creator_treasury_balance.amount (same unit).
    transaction_hash VARCHAR NOT NULL,
    tx_index INT NOT NULL,
    log_index INT NOT NULL,
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (token_id,account_id,transaction_hash,tx_index,log_index)
);

CREATE INDEX IF NOT EXISTS idx_creator_treasury_claim_history_account_id ON creator_treasury_claim_history (account_id,created_at DESC);

-- =====================================================
-- creator_treasury_claim_history INSERT 시 creator_treasury_balance 차감
-- =====================================================

-- 1. 트리거 함수 생성
CREATE OR REPLACE FUNCTION deduct_creator_treasury_balance_from_claim()
RETURNS TRIGGER AS $$
BEGIN
    -- creator_treasury_balance에서 amount 차감
    UPDATE creator_treasury_balance
    SET amount = amount - NEW.amount
    WHERE account_id = NEW.account_id
      AND token_id = NEW.token_id;

    -- 차감 후 잔액이 0 이하인 경우 행 삭제 (선택사항)
    DELETE FROM creator_treasury_balance
    WHERE account_id = NEW.account_id
      AND token_id = NEW.token_id
      AND amount <= 0;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 2. 트리거 생성
DROP TRIGGER IF EXISTS trigger_deduct_creator_treasury_balance_from_claim ON creator_treasury_claim_history;
CREATE TRIGGER trigger_deduct_creator_treasury_balance_from_claim
    AFTER INSERT ON creator_treasury_claim_history
    FOR EACH ROW
    EXECUTE FUNCTION deduct_creator_treasury_balance_from_claim();

-- 3. 트리거 활성화
ALTER TABLE creator_treasury_claim_history ENABLE TRIGGER trigger_deduct_creator_treasury_balance_from_claim;


-- =====================================================
-- 참고:
-- - creator_treasury_claim_history INSERT 시 자동으로 creator_treasury_balance 차감
-- - claim한 amount만큼 차감됨
-- =====================================================



CREATE TABLE IF NOT EXISTS creator_treasury_merkle_root(
    merkle_root VARCHAR NOT NULL,
    transaction_hash VARCHAR NOT NULL,
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (merkle_root)
);

CREATE INDEX IF NOT EXISTS idx_creator_treasury_merkle_root_created_at ON creator_treasury_merkle_root (created_at DESC);




CREATE TABLE IF NOT EXISTS creator_reward(
    account_id VARCHAR(42) NOT NULL,
    token_id VARCHAR(42) NOT NULL,
    amount NUMERIC(38, 0) NOT NULL, -- UNIT: quote raw (wei); sourced from creator_treasury_balance.amount, floored to integer (with_scale(0)) for merkle/contract.
    status VARCHAR NOT NULL CHECK (status IN ('AWAITING', 'CLAIMED')),
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    proof TEXT[] NOT NULL,
    PRIMARY KEY (account_id, token_id)
);





-- =====================================================
-- creator_treasury_claim_history INSERT 시 creator_reward status를 CLAIMED로 업데이트
-- =====================================================

-- 1. 트리거 함수 생성
CREATE OR REPLACE FUNCTION update_creator_reward_status_from_claim()
RETURNS TRIGGER AS $$
BEGIN
    -- creator_reward의 status를 CLAIMED로 업데이트
    UPDATE creator_reward
    SET status = 'CLAIMED'
    WHERE account_id = NEW.account_id
      AND token_id = NEW.token_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 2. 트리거 생성
DROP TRIGGER IF EXISTS trigger_update_creator_reward_status_from_claim ON creator_treasury_claim_history;
CREATE TRIGGER trigger_update_creator_reward_status_from_claim
    AFTER INSERT ON creator_treasury_claim_history
    FOR EACH ROW
    EXECUTE FUNCTION update_creator_reward_status_from_claim();

-- 3. 트리거 활성화
ALTER TABLE creator_treasury_claim_history ENABLE TRIGGER trigger_update_creator_reward_status_from_claim;


-- =====================================================
-- 참고:
-- - lp_collect_history INSERT 시 자동으로 token_treasury_balance 업데이트
-- - token_amount를 누적 합산
-- =====================================================





-- ============================================================================
-- >>> 0009_hype.sql
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- HYPE BOARD

CREATE TABLE IF NOT EXISTS hype_token(
    epoch BIGINT NOT NULL,
    token_id VARCHAR(42) NOT NULL,
    vote NUMERIC NOT NULL DEFAULT 0, -- UNIT: points (int); total hype points voted on this token (api-server vote(): hype_token.vote += amount, where amount moves from point.round_point to point.hype_point).
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (epoch, token_id)
);




-- HYPE BOARD
CREATE TABLE IF NOT EXISTS epoch (
    epoch BIGINT PRIMARY KEY,
    start_at BIGINT NOT NULL,
    end_at BIGINT NOT NULL,
    status VARCHAR NOT NULL CHECK (status IN ('ACTIVE', 'COMPLETED','READY')),
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    -- 시간 범위 겹침 방지
    EXCLUDE USING gist (int8range(start_at, end_at) WITH &&)
);


CREATE UNIQUE INDEX IF NOT EXISTS idx_epoch_single_active
  ON epoch ((1)) WHERE status = 'ACTIVE';



CREATE TABLE IF NOT EXISTS point_history(
    account_id VARCHAR(42) NOT NULL,
    point_type VARCHAR NOT NULL CHECK (point_type IN ('CREATE', 'GRADUATE', 'CURVE', 'DEX')),
    value NUMERIC NOT NULL, -- UNIT: USD (human); activity volume in USD (observer PointBatchData.value = quote_amount/decimals * price), later multiplied by point rate to derive points.
    transaction_hash VARCHAR NOT NULL,
    tx_index INT NOT NULL,
    log_index INT NOT NULL,
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (account_id, transaction_hash, tx_index,log_index)
);
-- Point History 테이블은 PRIMARY KEY 외에 추가 인덱스 불필요 (INSERT만 수행)

CREATE TABLE IF NOT EXISTS point (
    account_id VARCHAR(42) NOT NULL,
    round_point BIGINT NOT NULL DEFAULT 0, --unused point
    hype_point BIGINT NOT NULL DEFAULT 0, --used point
    raffle_count BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id)
);
-- Point 테이블은 PRIMARY KEY 외에 추가 인덱스 불필요


CREATE TABLE IF NOT EXISTS total_hype_point(
    id INTEGER PRIMARY KEY DEFAULT 1,
    hype_point BIGINT NOT NULL DEFAULT 0,
    CONSTRAINT single_row CHECK (id = 1)
);

INSERT INTO total_hype_point (id, hype_point) 
SELECT 1, 0 
WHERE NOT EXISTS (SELECT 1 FROM total_hype_point WHERE id = 1);


-- 트리거 함수 생성
CREATE OR REPLACE FUNCTION update_total_hype_point()
RETURNS TRIGGER AS $$
BEGIN
    -- INSERT 시: 새로운 spend_point 추가
    IF TG_OP = 'INSERT' THEN
        UPDATE total_hype_point 
        SET hype_point = hype_point + NEW.hype_point
        WHERE id = 1;
        RETURN NEW;
    END IF;
    
    -- UPDATE 시: 차이만큼 업데이트
    IF TG_OP = 'UPDATE' THEN
        UPDATE total_hype_point 
        SET hype_point = hype_point + (NEW.hype_point - OLD.hype_point)
        WHERE id = 1;
        RETURN NEW;
    END IF;
    
    
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- 트리거 생성
DROP TRIGGER IF EXISTS point_hype_trigger ON point;
CREATE TRIGGER point_hype_trigger
    AFTER INSERT OR UPDATE ON point
    FOR EACH ROW
    EXECUTE FUNCTION update_total_hype_point();

-- 기존 데이터가 있다면 총합 계산해서 초기화
UPDATE total_hype_point 
SET hype_point = (
    SELECT COALESCE(SUM(hype_point), 0) 
    FROM point
) 
WHERE id = 1;



-- 1. 테이블 생성
CREATE TABLE hype_point_leaderboard_count (
    id INTEGER NOT NULL DEFAULT 1 PRIMARY KEY,
    total_count BIGINT NOT NULL DEFAULT 0,
    CONSTRAINT single_row_leaderboard CHECK (id = 1)
);

-- 2. 초기 row 삽입 (기존 point 테이블 count로 초기화)
INSERT INTO hype_point_leaderboard_count (id, total_count)
VALUES (1, (SELECT COUNT(*) FROM point));

-- 3. 트리거 함수 생성
CREATE OR REPLACE FUNCTION update_hype_point_leaderboard_count()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE hype_point_leaderboard_count SET total_count = total_count + 1 WHERE id = 1;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE hype_point_leaderboard_count SET total_count = total_count - 1 WHERE id = 1;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- 4. 트리거 생성
CREATE TRIGGER hype_point_leaderboard_count_trigger
    AFTER INSERT OR DELETE ON point
    FOR EACH ROW
    EXECUTE FUNCTION update_hype_point_leaderboard_count();



CREATE TABLE IF NOT EXISTS point_distribution(
    epoch BIGINT NOT NULL,
    account_id VARCHAR(42) NOT NULL,
    activity_type VARCHAR NOT NULL CHECK (activity_type IN ('CREATE','CURVE','GRADUATE','DEX','HYPEBOARD','RAFFLE')),
    amount BIGINT NOT NULL,
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (account_id, activity_type, epoch, created_at)
);
CREATE INDEX IF NOT EXISTS idx_point_distribution_account_id ON point_distribution (account_id);
CREATE INDEX IF NOT EXISTS idx_point_distribution_account_epoch ON point_distribution (account_id, epoch);
CREATE INDEX IF NOT EXISTS idx_point_distribution_created_at ON point_distribution (created_at DESC);


-- Update trigger function to handle RAFFLE type (update hype_point instead of round_point)
CREATE OR REPLACE FUNCTION update_point_on_distribution_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.activity_type = 'RAFFLE' THEN
        -- RAFFLE updates hype_point
        INSERT INTO point (account_id, hype_point)
        VALUES (NEW.account_id, NEW.amount)
        ON CONFLICT (account_id)
        DO UPDATE SET hype_point = point.hype_point + NEW.amount;
    ELSE
        -- Other activities update round_point
        INSERT INTO point (account_id, round_point)
        VALUES (NEW.account_id, NEW.amount)
        ON CONFLICT (account_id)
        DO UPDATE SET round_point = point.round_point + NEW.amount;
    END IF;

    RETURN NEW;
END;
$$;

  -- Create trigger to automatically update point table
  DROP TRIGGER IF EXISTS point_update_trigger ON point_distribution;
  CREATE TRIGGER point_update_trigger
      AFTER INSERT ON point_distribution
      FOR EACH ROW
      EXECUTE FUNCTION update_point_on_distribution_insert();

 CREATE TABLE IF NOT EXISTS account_point_distribution_count (
      account_id VARCHAR(42) PRIMARY KEY,
      total_count BIGINT NOT NULL DEFAULT 0,
      last_updated_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT
  );

  -- point_distribution에 INSERT될 때 카운트 증가
  CREATE OR REPLACE FUNCTION update_point_distribution_count_on_insert()
  RETURNS trigger
  LANGUAGE plpgsql
  AS $$
  BEGIN
      INSERT INTO account_point_distribution_count (account_id, total_count, last_updated_at)
      VALUES (NEW.account_id, 1, EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT)
      ON CONFLICT (account_id)
      DO UPDATE SET
          total_count = account_point_distribution_count.total_count + 1,
          last_updated_at = EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT;
      RETURN NEW;
  END;
  $$;

CREATE TRIGGER point_distribution_count_trigger
AFTER INSERT ON point_distribution
FOR EACH ROW EXECUTE FUNCTION update_point_distribution_count_on_insert();



-- Point Distribution Records 테이블은 PRIMARY KEY 외에 추가 인덱스 불필요
CREATE TABLE IF NOT EXISTS reward_add_history(
      epoch BIGINT NOT NULL,
      token_id VARCHAR(42) NOT NULL,
      account_id VARCHAR(42) NOT NULL,
      amount NUMERIC NOT NULL, -- UNIT: token raw (wei); on-chain RewardPool AddReward.amount (reward/buy-back token, e.g. HYPE) stored raw by observer.
      total_amount NUMERIC NOT NULL DEFAULT 0, -- UNIT: token raw (wei); running SUM of amount per (epoch, account_id, token_id), computed by calculate_reward_total_amount() trigger.
      transaction_hash VARCHAR(66) NOT NULL,
      log_index BIGINT NOT NULL,
      created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
      PRIMARY KEY (epoch, account_id, token_id, transaction_hash, log_index)
);
CREATE INDEX IF NOT EXISTS idx_reward_add_history_sum_lookup
  ON reward_add_history(epoch, account_id, token_id, amount);

CREATE INDEX IF NOT EXISTS idx_reward_add_history_account_created_at
ON reward_add_history(account_id, created_at DESC);

CREATE OR REPLACE FUNCTION calculate_reward_total_amount()
RETURNS TRIGGER AS $$
BEGIN
    -- INSERT시 total_amount 계산
    NEW.total_amount := (
        SELECT COALESCE(SUM(amount), 0) + NEW.amount
        FROM reward_add_history
        WHERE epoch = NEW.epoch
        AND account_id = NEW.account_id
        AND token_id = NEW.token_id
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 트리거 생성
CREATE TRIGGER trigger_calculate_reward_total
BEFORE INSERT ON reward_add_history
FOR EACH ROW
EXECUTE FUNCTION calculate_reward_total_amount();


CREATE TABLE IF NOT EXISTS reward_add_history_count(
    account_id VARCHAR(42) PRIMARY KEY,
    total_count BIGINT NOT NULL DEFAULT 0,
    updated_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT
);


CREATE OR REPLACE FUNCTION update_reward_add_history_count()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO reward_add_history_count (account_id, total_count, updated_at)
    VALUES (NEW.account_id, 1, EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT)
    ON CONFLICT (account_id) 
    DO UPDATE SET 
        total_count = reward_add_history_count.total_count + 1,
        updated_at = EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 트리거 생성
CREATE TRIGGER trigger_update_reward_add_history_count
    AFTER INSERT ON reward_add_history
    FOR EACH ROW
    EXECUTE FUNCTION update_reward_add_history_count();

-- 기존 데이터에 대한 초기 카운트 계산 (필요한 경우)
INSERT INTO reward_add_history_count (account_id, total_count, updated_at)
SELECT 
    account_id,
    COUNT(*) as total_count,
    EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT as updated_at
FROM reward_add_history
GROUP BY account_id
ON CONFLICT (account_id) DO NOTHING;


CREATE TABLE IF NOT EXISTS reward_pool(
    epoch BIGINT NOT NULL,
    token_id VARCHAR(42) NOT NULL,
    amount NUMERIC NOT NULL, -- UNIT: token raw (wei); SUM of reward_add_history.amount per (epoch, token_id) (observer reward.rs pool upsert) = total reward pool to split among voters.
    merkle_root VARCHAR(66) DEFAULT NULL,
    PRIMARY KEY (epoch, token_id)
);


CREATE TABLE IF NOT EXISTS reward(
    epoch BIGINT NOT NULL,
    token_id VARCHAR(42) NOT NULL,
    account_id VARCHAR(42) NOT NULL,
    amount NUMERIC NOT NULL, -- UNIT: token raw (wei); voter's share of reward_pool.amount, = account_vote * total_reward / total_votes, floored (with_scale(0)) for contract.
    status VARCHAR NOT NULL CHECK (status IN ('AWAITING', 'CLAIMED')),
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    proof TEXT[] NOT NULL,
    vote_amount NUMERIC NOT NULL, -- UNIT: points (int); account's total votes in this epoch/token (sum of vote_history.vote = spent hype points), used as reward split weight.
    transaction_hash VARCHAR NULL, -- Claim 시 기록
    claim_at BIGINT NULL,
    PRIMARY KEY (epoch, token_id, account_id)
);


CREATE INDEX IF NOT EXISTS idx_reward_account_id ON reward (account_id);
CREATE INDEX IF NOT EXISTS idx_reward_epoch_token_account ON reward (epoch, token_id, account_id);

-- Reward Claimed History 테이블은 PRIMARY KEY 외에 추가 인덱스 불필요 (INSERT만 수행)

CREATE TABLE IF NOT EXISTS vote_history(
    id SERIAL PRIMARY KEY,
    epoch BIGINT NOT NULL,
    token_id VARCHAR(42) NOT NULL,
    account_id VARCHAR(42) NOT NULL,
    vote NUMERIC NOT NULL, -- UNIT: points (int); hype points spent on this single vote (api-server vote(): deducted from point.round_point, added to point.hype_point).
    total_vote_amount NUMERIC NOT NULL, -- UNIT: points (int); hype_token.vote running total after this vote (hype_token.vote + amount at insert time).
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT
);
-- Vote History 테이블은 PRIMARY KEY 외에 추가 인덱스 불필요 (INSERT만 수행)

CREATE INDEX IF NOT EXISTS idx_vote_history_account_epoch_token ON vote_history (account_id, epoch DESC, token_id);


CREATE TABLE IF NOT EXISTS account_vote_history_count (
      account_id VARCHAR(42) NOT NULL,
      total_count BIGINT NOT NULL DEFAULT 0,
      PRIMARY KEY (account_id)
);


INSERT INTO account_vote_history_count (account_id, total_count)
  SELECT
      account_id,
      COUNT(*) as total_count
  FROM vote_history
  GROUP BY account_id
  ON CONFLICT (account_id)
  DO UPDATE SET total_count = EXCLUDED.total_count;

CREATE OR REPLACE FUNCTION update_vote_history_count()
  RETURNS TRIGGER AS $$
  BEGIN
      IF TG_OP = 'INSERT' THEN
          INSERT INTO account_vote_history_count (account_id, total_count)
          VALUES (NEW.account_id, 1)
          ON CONFLICT (account_id)
          DO UPDATE SET total_count = account_vote_history_count.total_count + 1;
          RETURN NEW;
      ELSIF TG_OP = 'DELETE' THEN
          UPDATE account_vote_history_count
          SET total_count = GREATEST(total_count - 1, 0)
          WHERE account_id = OLD.account_id;
          RETURN OLD;
      END IF;
      RETURN NULL;
  END;
  $$ LANGUAGE plpgsql;

CREATE TRIGGER vote_history_count_trigger
AFTER INSERT OR DELETE ON vote_history
FOR EACH ROW EXECUTE FUNCTION update_vote_history_count();


CREATE TABLE IF NOT EXISTS total_buy_back(
    epoch BIGINT NOT NULL,
    token_id VARCHAR(42) NOT NULL,
    amount NUMERIC NOT NULL DEFAULT 0, -- UNIT? (unverified: token raw (wei)); no reader/writer found in observer/scheduler/api-server — appears unused/legacy.
    PRIMARY KEY (epoch, token_id)
);

-- ============================================================================
-- >>> 0010_raffle.sql
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE IF NOT EXISTS monad_airdrop(
   account_id VARCHAR(42) PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS raffle_round(
   round BIGINT NOT NULL,
   start_at BIGINT NOT NULL,
   end_at BIGINT NOT NULL,
   status VARCHAR NOT NULL CHECK (status IN ('ACTIVE', 'COMPLETED','READY')),
   sequence_number BIGINT,
   random_number VARCHAR(66),
   created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
   PRIMARY KEY (round),
   -- 시간 범위 겹침 방지
   EXCLUDE USING gist (int8range(start_at, end_at) WITH &&)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_round_single_active
  ON raffle_round ((1)) WHERE status = 'ACTIVE';


CREATE TABLE IF NOT EXISTS raffle(
    id SERIAL PRIMARY KEY,
    round BIGINT NOT NULL,
    epoch BIGINT NOT NULL,
    account_id VARCHAR(42) NOT NULL,
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT
);

CREATE INDEX IF NOT EXISTS idx_raffle_account_created_at ON raffle (account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_raffle_round_account ON raffle (round, account_id);
CREATE INDEX IF NOT EXISTS idx_raffle_epoch ON raffle (epoch);
CREATE INDEX IF NOT EXISTS idx_raffle_round_epoch_account ON raffle (round, epoch, account_id);

-- Create raffle_winner table
-- GENERAL_MONAD: General raffle, MON prize
-- GENERAL_HYPE: General raffle, HYPE prize
-- MONAD_AIRDROP_MONAD: Monad Airdrop raffle, MON prize
-- MONAD_AIRDROP_HYPE: Monad Airdrop raffle, HYPE prize
CREATE TABLE IF NOT EXISTS raffle_winner (
    id SERIAL PRIMARY KEY,
    round BIGINT NOT NULL,
    raffle_id INT NOT NULL,
    account_id VARCHAR(42) NOT NULL,
    rank INT NOT NULL,
    type VARCHAR(25) NOT NULL DEFAULT 'GENERAL_MONAD' CHECK (type IN ('GENERAL_MONAD', 'GENERAL_HYPE', 'MONAD_AIRDROP_MONAD', 'MONAD_AIRDROP_HYPE','WHALE_MONAD','WHALE_HYPE')),
    transaction_hash VARCHAR(66),
    amount NUMERIC NOT NULL, -- UNIT: dual by type -> *_MONAD = quote raw (wei) (prize_mon * 1e18, raffle_service.rs get_prize_whale/general); *_HYPE = points (int) (RAFFLE_HYPE_POINT_REWARD = 200).
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    CONSTRAINT fk_raffle_winner_round FOREIGN KEY (round) REFERENCES raffle_round(round),
    CONSTRAINT fk_raffle_winner_raffle FOREIGN KEY (raffle_id) REFERENCES raffle(id)
);

CREATE INDEX IF NOT EXISTS idx_raffle_winner_round ON raffle_winner (round);
CREATE INDEX IF NOT EXISTS idx_raffle_winner_account ON raffle_winner (account_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_raffle_winner_round_type_rank ON raffle_winner (round, type, rank);





-- =====================================================
-- 테스트 쿼리문
-- =====================================================
/*
-- 1. raffle_round 데이터 생성 (현재시간 기준)
DO $$
DECLARE
    now_ts BIGINT := EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT;
BEGIN
    -- Round 1: 30일 전 ~ 1일 전 (완료)
    INSERT INTO raffle_round (round, start_at, end_at, status) VALUES
    (1, now_ts - (30 * 24 * 60 * 60), now_ts - (1 * 24 * 60 * 60), 'COMPLETED')
    ON CONFLICT (round) DO NOTHING;

    -- Round 2: 1일 전 ~ 29일 후 (현재 진행중)
    INSERT INTO raffle_round (round, start_at, end_at, status) VALUES
    (2, now_ts - (1 * 24 * 60 * 60), now_ts + (29 * 24 * 60 * 60), 'ACTIVE')
    ON CONFLICT (round) DO NOTHING;

    -- Round 3: 30일 후 ~ 60일 후 (대기중)
    INSERT INTO raffle_round (round, start_at, end_at, status) VALUES
    (3, now_ts + (30 * 24 * 60 * 60), now_ts + (60 * 24 * 60 * 60), 'READY')
    ON CONFLICT (round) DO NOTHING;
END $$;

-- 2. 테스트용 account 생성
INSERT INTO account (account_id) VALUES
('0x1111111111111111111111111111111111111111'),
('0x2222222222222222222222222222222222222222'),
('0x3333333333333333333333333333333333333333')
ON CONFLICT (account_id) DO NOTHING;

-- 3. monad_airdrop에 일부 계정만 추가
-- 0x1111... : monad_airdrop O -> raffle 생성됨
-- 0x2222... : monad_airdrop O -> raffle 생성됨
-- 0x3333... : monad_airdrop X -> raffle 생성 안됨
INSERT INTO monad_airdrop (account_id) VALUES
('0x1111111111111111111111111111111111111111'),
('0x2222222222222222222222222222222222222222')
ON CONFLICT (account_id) DO NOTHING;

-- 4. point 테스트 케이스

-- Case 1: 0x1111 (monad_airdrop O) - 0 -> 50 round_point (raffle 2개 생성)
INSERT INTO point (account_id, round_point) VALUES
('0x1111111111111111111111111111111111111111', 50)
ON CONFLICT (account_id) DO UPDATE SET round_point = 50, raffle_count = 0;

-- Case 2: 0x1111 (monad_airdrop O) - 50 -> 100 round_point (raffle 3개 추가: 5-2=3)
UPDATE point SET round_point = 100
WHERE account_id = '0x1111111111111111111111111111111111111111';

-- Case 3: 0x1111 (monad_airdrop O) - 100 -> 150 round_point (raffle 2개 추가: 7-5=2)
UPDATE point SET round_point = 150
WHERE account_id = '0x1111111111111111111111111111111111111111';

-- Case 4: 0x2222 (monad_airdrop O) - 0 -> 80 round_point (raffle 4개 생성)
INSERT INTO point (account_id, round_point) VALUES
('0x2222222222222222222222222222222222222222', 80)
ON CONFLICT (account_id) DO UPDATE SET round_point = 80, raffle_count = 0;

-- Case 5: 0x3333 (monad_airdrop X) - 0 -> 100 round_point (raffle 0개, 생성 안됨!)
INSERT INTO point (account_id, round_point) VALUES
('0x3333333333333333333333333333333333333333', 100)
ON CONFLICT (account_id) DO UPDATE SET round_point = 100, raffle_count = 0;

-- Case 6: 0x3333 (monad_airdrop X) - 100 -> 200 round_point (여전히 raffle 0개)
UPDATE point SET round_point = 200
WHERE account_id = '0x3333333333333333333333333333333333333333';

-- 5. 결과 확인

-- raffle_round 상태 확인
SELECT
    round,
    status,
    TO_TIMESTAMP(start_at) as start_time,
    TO_TIMESTAMP(end_at) as end_time,
    CASE
        WHEN start_at <= EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT
         AND end_at >= EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT
        THEN 'CURRENT'
        WHEN start_at > EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT
        THEN 'FUTURE'
        ELSE 'PAST'
    END as time_status
FROM raffle_round
ORDER BY round;

-- monad_airdrop 확인
SELECT
    ma.account_id,
    CASE WHEN ma.account_id IS NOT NULL THEN 'O' ELSE 'X' END as in_airdrop
FROM account a
LEFT JOIN monad_airdrop ma ON a.account_id = ma.account_id
WHERE a.account_id IN (
    '0x1111111111111111111111111111111111111111',
    '0x2222222222222222222222222222222222222222',
    '0x3333333333333333333333333333333333333333'
)
ORDER BY a.account_id;

-- point 확인 (monad_airdrop 여부와 함께)
SELECT
    p.account_id,
    CASE WHEN ma.account_id IS NOT NULL THEN 'O' ELSE 'X' END as in_airdrop,
    p.round_point,
    p.raffle_count,
    p.round_point / 20 as expected_raffle_count
FROM point p
LEFT JOIN monad_airdrop ma ON p.account_id = ma.account_id
WHERE p.account_id IN (
    '0x1111111111111111111111111111111111111111',
    '0x2222222222222222222222222222222222222222',
    '0x3333333333333333333333333333333333333333'
)
ORDER BY p.account_id;

-- raffle 개수 확인
SELECT
    r.account_id,
    COUNT(*) as actual_raffle_count,
    r.round
FROM raffle r
WHERE r.account_id IN (
    '0x1111111111111111111111111111111111111111',
    '0x2222222222222222222222222222222222222222',
    '0x3333333333333333333333333333333333333333'
)
GROUP BY r.account_id, r.round
ORDER BY r.account_id, r.round;

-- 전체 raffle 상세
SELECT
    id,
    round,
    account_id,
    TO_TIMESTAMP(created_at) as created_time
FROM raffle
WHERE account_id IN (
    '0x1111111111111111111111111111111111111111',
    '0x2222222222222222222222222222222222222222',
    '0x3333333333333333333333333333333333333333'
)
ORDER BY account_id, created_at;

-- 6. 예상 결과:
-- account 0x1111... (monad_airdrop O): raffle 7개 (2+3+2), round_point=150, round=2
-- account 0x2222... (monad_airdrop O): raffle 4개, round_point=80, round=2
-- account 0x3333... (monad_airdrop X): raffle 0개, round_point=200, raffle_count=0 ⭐

-- 7. 정리 (테스트 후)
DELETE FROM raffle WHERE account_id IN (
    '0x1111111111111111111111111111111111111111',
    '0x2222222222222222222222222222222222222222',
    '0x3333333333333333333333333333333333333333'
);
DELETE FROM point WHERE account_id IN (
    '0x1111111111111111111111111111111111111111',
    '0x2222222222222222222222222222222222222222',
    '0x3333333333333333333333333333333333333333'
);
DELETE FROM monad_airdrop WHERE account_id IN (
    '0x1111111111111111111111111111111111111111',
    '0x2222222222222222222222222222222222222222'
);
DELETE FROM raffle_round WHERE round IN (1, 2, 3);
*/

CREATE TABLE IF NOT EXISTS monad_airdrop(
   account_id VARCHAR(42) PRIMARY KEY
);


CREATE TABLE IF NOT EXISTS prize(
    round BIGINT NOT NULL,
    account_id VARCHAR(42) NOT NULL,
    amount BIGINT NOT NULL,
    PRIMARY KEY (round, account_id)
);

CREATE INDEX IF NOT EXISTS idx_round ON prize (round);

-- ============================================================================
-- >>> 0011_trend.sql
-- ============================================================================

CREATE TABLE IF NOT EXISTS trend(
    token_id VARCHAR(42) NOT NULL,
    display_order INT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (token_id)
);


CREATE TABLE IF NOT EXISTS admin(
    account_id VARCHAR(42) NOT NULL,
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (account_id)
);

-- ============================================================================
-- >>> 0012_fee.sql
-- ============================================================================

CREATE TABLE IF NOT EXISTS set_fee_history(
    pool_id VARCHAR(42) NOT NULL,
    block_number BIGINT NOT NULL,
    transaction_hash VARCHAR(66) NOT NULL,
    tx_index INT NOT NULL,
    log_index INT NOT NULL,
    fee_protocol0_old SMALLINT NOT NULL,
    fee_protocol1_old SMALLINT NOT NULL,
    fee_protocol0_new SMALLINT NOT NULL,
    fee_protocol1_new SMALLINT NOT NULL,
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (pool_id, block_number, transaction_hash, tx_index, log_index)
);

CREATE INDEX IF NOT EXISTS idx_set_fee_history_pool ON set_fee_history (pool_id);


-- ============================================================================
-- >>> 0013_position.sql
-- ============================================================================

-- Position V2: Transfer 기반 PnL 추적 (현금 흐름 기반)
-- 모든 케이스 커버: Buy, Sell, LP Mint, LP Burn, Transfer, Airdrop

-- 1. 기존 트리거 및 함수 삭제
DROP TRIGGER IF EXISTS trg_position_on_swap ON swap;
DROP FUNCTION IF EXISTS update_position_on_swap();

-- 2. 기존 position 테이블 삭제
DROP TABLE IF EXISTS position CASCADE;

-- 3. position_history 테이블 생성 (분석된 position 변화 기록)
CREATE TABLE IF NOT EXISTS position_history (
    account_id VARCHAR(42) NOT NULL,
    token_id VARCHAR(42) NOT NULL,

    -- Quote 흐름 (이 TX에서의 변화량)
    quote_in NUMERIC NOT NULL DEFAULT 0,   -- UNIT: quote raw (wei)
    quote_out NUMERIC NOT NULL DEFAULT 0,  -- UNIT: quote raw (wei)

    -- USD 흐름
    usd_in NUMERIC NOT NULL DEFAULT 0,   -- UNIT: USD (human)
    usd_out NUMERIC NOT NULL DEFAULT 0,  -- UNIT: USD (human)

    -- Token 흐름
    token_in NUMERIC NOT NULL DEFAULT 0,   -- UNIT: token raw (wei)
    token_out NUMERIC NOT NULL DEFAULT 0,  -- UNIT: token raw (wei)

    -- Transfer 메타데이터
    -- transfer_type: 'buy', 'sell', 'transfer_out', 'transfer_in', NULL(LP 등)
    transfer_type VARCHAR(20),
    sender_address VARCHAR(42),  -- transfer_in 시 sender 주소

    -- TX 정보
    transaction_hash VARCHAR(66) NOT NULL,
    block_number BIGINT NOT NULL,
    tx_index INT NOT NULL,
    log_index INT NOT NULL,
    created_at BIGINT NOT NULL,

    PRIMARY KEY (account_id, token_id, transaction_hash, tx_index, log_index)
);

CREATE INDEX IF NOT EXISTS idx_position_history_account ON position_history(account_id);
CREATE INDEX IF NOT EXISTS idx_position_history_token ON position_history(token_id);
CREATE INDEX IF NOT EXISTS idx_position_history_tx ON position_history(transaction_hash);
CREATE INDEX IF NOT EXISTS idx_position_history_block ON position_history(block_number, tx_index, log_index);
CREATE INDEX IF NOT EXISTS idx_position_history_transfer_type ON position_history(transfer_type);
CREATE INDEX IF NOT EXISTS idx_position_history_sender_address ON position_history(sender_address);

-- 4. position 테이블 생성 (누적 position)
CREATE TABLE IF NOT EXISTS position (
    account_id VARCHAR(42) NOT NULL,
    token_id VARCHAR(42) NOT NULL,

    -- Quote 흐름 (누적)
    quote_in NUMERIC NOT NULL DEFAULT 0,       -- 수입 (매도, LP 제거 시 받음) | UNIT: quote raw (wei)
    quote_out NUMERIC NOT NULL DEFAULT 0,      -- 지출 (매수, LP 추가 시 지불) | UNIT: quote raw (wei)

    -- USD 흐름 (누적)
    usd_in NUMERIC NOT NULL DEFAULT 0,         -- 수입 (USD) | UNIT: USD (human)
    usd_out NUMERIC NOT NULL DEFAULT 0,        -- 지출 (USD) | UNIT: USD (human)

    -- Token 흐름 (누적)
    token_in NUMERIC NOT NULL DEFAULT 0,       -- 획득 (매수, LP 제거, Transfer 받음) | UNIT: token raw (wei)
    token_out NUMERIC NOT NULL DEFAULT 0,      -- 지출 (매도, LP 추가, Transfer 보냄) | UNIT: token raw (wei)

    -- 메타데이터
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,

    PRIMARY KEY (account_id, token_id)
);

CREATE INDEX IF NOT EXISTS idx_position_account ON position(account_id);
CREATE INDEX IF NOT EXISTS idx_position_token ON position(token_id);

-- 5. position_history INSERT 시 position 자동 업데이트 트리거 (cost basis 이전 포함)
CREATE OR REPLACE FUNCTION update_position_on_history()
RETURNS TRIGGER AS $$
DECLARE
    sender_position RECORD;
    avg_cost_quote NUMERIC;
    avg_cost_usd NUMERIC;
    transfer_cost_quote NUMERIC;
    transfer_cost_usd NUMERIC;
    current_balance NUMERIC;
BEGIN
    -- transfer_out인 경우: sender의 cost basis 계산하여 quote_in에 기록
    IF NEW.transfer_type = 'transfer_out' THEN
        SELECT quote_out, usd_out, token_in, token_out
        INTO sender_position
        FROM position
        WHERE account_id = NEW.account_id AND token_id = NEW.token_id;

        IF FOUND AND sender_position.token_in > 0 THEN
            current_balance := sender_position.token_in - sender_position.token_out;

            IF current_balance > 0 THEN
                avg_cost_quote := sender_position.quote_out / sender_position.token_in;
                avg_cost_usd := sender_position.usd_out / sender_position.token_in;

                transfer_cost_quote := avg_cost_quote * NEW.token_out;
                transfer_cost_usd := avg_cost_usd * NEW.token_out;

                NEW.quote_in := transfer_cost_quote;
                NEW.usd_in := transfer_cost_usd;
            END IF;
        END IF;
    END IF;

    -- transfer_in인 경우: sender_address의 cost basis 가져와서 quote_out에 기록
    IF NEW.transfer_type = 'transfer_in' AND NEW.sender_address IS NOT NULL THEN
        SELECT quote_out, usd_out, token_in, token_out
        INTO sender_position
        FROM position
        WHERE account_id = NEW.sender_address AND token_id = NEW.token_id;

        IF FOUND AND sender_position.token_in > 0 THEN
            current_balance := sender_position.token_in - sender_position.token_out;

            IF current_balance > 0 THEN
                avg_cost_quote := sender_position.quote_out / sender_position.token_in;
                avg_cost_usd := sender_position.usd_out / sender_position.token_in;

                transfer_cost_quote := avg_cost_quote * NEW.token_in;
                transfer_cost_usd := avg_cost_usd * NEW.token_in;

                NEW.quote_out := transfer_cost_quote;
                NEW.usd_out := transfer_cost_usd;
            END IF;
        END IF;
    END IF;

    -- position 테이블 업데이트
    INSERT INTO position (
        account_id, token_id,
        quote_in, quote_out,
        usd_in, usd_out,
        token_in, token_out,
        created_at, updated_at
    )
    VALUES (
        NEW.account_id, NEW.token_id,
        NEW.quote_in, NEW.quote_out,
        NEW.usd_in, NEW.usd_out,
        NEW.token_in, NEW.token_out,
        NEW.created_at, NEW.created_at
    )
    ON CONFLICT (account_id, token_id) DO UPDATE SET
        quote_in = position.quote_in + EXCLUDED.quote_in,
        quote_out = position.quote_out + EXCLUDED.quote_out,
        usd_in = position.usd_in + EXCLUDED.usd_in,
        usd_out = position.usd_out + EXCLUDED.usd_out,
        token_in = position.token_in + EXCLUDED.token_in,
        token_out = position.token_out + EXCLUDED.token_out,
        updated_at = EXCLUDED.updated_at;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- BEFORE INSERT trigger (NEW 값 수정 가능)
CREATE TRIGGER trg_position_on_history
BEFORE INSERT ON position_history
FOR EACH ROW
EXECUTE FUNCTION update_position_on_history();



-- Fee History: Buy 이벤트에서 발생한 fee 추적
-- Curve, DEX Swap, DexRouter Buy 이벤트에서 fee 계산 및 누적
-- PnL 조회 시 position과 JOIN해서 사용

-- 1. fee_history 테이블 생성 (개별 fee 이벤트)
CREATE TABLE IF NOT EXISTS fee_history (
    transaction_hash VARCHAR(66) NOT NULL,
    tx_index INT NOT NULL DEFAULT 0,
    log_index INT NOT NULL,
    account_id VARCHAR(42) NOT NULL,
    token_id VARCHAR(42) NOT NULL,
    quote_amount NUMERIC NOT NULL,      -- Quote token 기준 fee | UNIT: quote raw (wei)
    usd_amount NUMERIC NOT NULL,         -- USD 기준 fee | UNIT: USD (human)
    fee_type VARCHAR(20) NOT NULL,       -- 'create', 'curve_buy', 'swap_buy', 'dex_router_buy'
    block_number BIGINT NOT NULL,
    created_at BIGINT NOT NULL,

    PRIMARY KEY (transaction_hash, tx_index, log_index)
);

CREATE INDEX IF NOT EXISTS idx_fee_history_tx ON fee_history(transaction_hash);
CREATE INDEX IF NOT EXISTS idx_fee_history_account_token ON fee_history(account_id, token_id);
CREATE INDEX IF NOT EXISTS idx_fee_history_block ON fee_history(block_number);

-- 2. fee 테이블 생성 (account, token별 누적)
CREATE TABLE IF NOT EXISTS fee (
    account_id VARCHAR(42) NOT NULL,
    token_id VARCHAR(42) NOT NULL,
    quote_amount NUMERIC NOT NULL DEFAULT 0,  -- 누적 fee (Quote) | UNIT: quote raw (wei)
    usd_amount NUMERIC NOT NULL DEFAULT 0,     -- 누적 fee (USD) | UNIT: USD (human)
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,

    PRIMARY KEY (account_id, token_id)
);

CREATE INDEX IF NOT EXISTS idx_fee_account ON fee(account_id);
CREATE INDEX IF NOT EXISTS idx_fee_token ON fee(token_id);

-- 3. fee_history INSERT 시 fee 자동 업데이트 트리거
CREATE OR REPLACE FUNCTION update_fee_on_history()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO fee (
        account_id, token_id,
        quote_amount, usd_amount,
        created_at, updated_at
    )
    VALUES (
        NEW.account_id, NEW.token_id,
        NEW.quote_amount, NEW.usd_amount,
        NEW.created_at, NEW.created_at
    )
    ON CONFLICT (account_id, token_id) DO UPDATE SET
        quote_amount = fee.quote_amount + EXCLUDED.quote_amount,
        usd_amount = fee.usd_amount + EXCLUDED.usd_amount,
        updated_at = EXCLUDED.updated_at;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_fee_on_history
AFTER INSERT ON fee_history
FOR EACH ROW
EXECUTE FUNCTION update_fee_on_history();


-- ============================================================================
-- >>> 0014_dex.sql
-- ============================================================================

-- V2 DEX infrastructure: pool (pairs), dex_token (external tokens),
-- fee_config, raw event tables (dex_swap / dex_sync / dex_mint / dex_burn),
-- and the statement-level update_pool_volume() trigger.
--
-- Consolidated from prior incremental migrations (0022_pool_volume,
-- 0023_dex_event_tables, 0024_pool_volume_trigger, 0025_dex_event_value_tvl,
-- 0026_dex_event_per_side_usd) into one file representing the final V2 DEX
-- schema. Existing prod DBs are upgraded by the idempotent
-- migrations/v2_upgrade_new_tables.sql; this file is for fresh DBs.

-- ---------------------------------------------------------------------------
-- 1. DEX Token (external tokens discovered via PairCreated)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dex_token (
    token_id   VARCHAR(42) PRIMARY KEY,
    name       VARCHAR     NOT NULL DEFAULT '',
    symbol     VARCHAR     NOT NULL DEFAULT '',
    decimals   INT         NOT NULL DEFAULT 18,
    image_uri  VARCHAR     NOT NULL DEFAULT '',
    created_at BIGINT      NOT NULL
);

-- GIN trigram indexes for /dex/search ILIKE substring acceleration.
-- Requires the pg_trgm extension (already enabled in production per the
-- existing idx_token_*_gin declarations in 0002_token.sql).
-- Folded in from the former standalone 0029_dex_search_indexes.sql now that
-- the indexes are applied on prod/dev — keeps the canonical dex_token DDL
-- and its indexes in one file for fresh-DB loads.
CREATE INDEX IF NOT EXISTS idx_dex_token_symbol_gin
    ON dex_token USING GIN (symbol gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_dex_token_name_gin
    ON dex_token USING GIN (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_dex_token_token_id_gin
    ON dex_token USING GIN (token_id gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- 2. Pool (DEX pairs — both graduated launchpad and pure DEX)
--
-- volume = lifetime trade volume in USD (accumulated by update_pool_volume()
--          trigger below from dex_swap inserts).
-- value  = current TVL snapshot in USD (updated alongside reserves by the
--          indexer when prices are known).
-- token0_price_usd / token1_price_usd = per-token USD unit price
--          (WMON-implied price x Pyth WMON/USD), set by the indexer's RawSync
--          inference. NULL when the token has no WMON-reachable price (orphan)
--          or before the first priced sync.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pool (
    pool_id         VARCHAR(42) PRIMARY KEY,
    token0          VARCHAR(42) NOT NULL,
    token1          VARCHAR(42) NOT NULL,
    reserve0        NUMERIC     NOT NULL DEFAULT 0, -- token raw (wei) of token0
    reserve1        NUMERIC     NOT NULL DEFAULT 0, -- token raw (wei) of token1
    price           NUMERIC     NOT NULL DEFAULT 0, -- quote per token (native_reserve/token_reserve; 0 for pure-DEX RawSync arm)
    volume          NUMERIC     NOT NULL DEFAULT 0, -- USD (human); lifetime SUM(dex_swap.value)
    value           NUMERIC     NOT NULL DEFAULT 0, -- USD (human); current TVL snapshot
    token0_price_usd NUMERIC    NULL, -- USD per token (token0)
    token1_price_usd NUMERIC    NULL, -- USD per token (token1)
    latest_trade_at BIGINT      NOT NULL DEFAULT 0,
    created_at      BIGINT      NOT NULL,
    block_number    BIGINT      NOT NULL,
    tx_hash         VARCHAR     NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pool_token0 ON pool (token0);
CREATE INDEX IF NOT EXISTS idx_pool_token1 ON pool (token1);

-- Idempotent ALTERs cover DBs created before volume/value joined the
-- canonical CREATE TABLE definition. Safe no-op on fresh DBs.
ALTER TABLE pool
    ADD COLUMN IF NOT EXISTS volume NUMERIC NOT NULL DEFAULT 0, -- USD (human); lifetime SUM(dex_swap.value)
    ADD COLUMN IF NOT EXISTS value  NUMERIC NOT NULL DEFAULT 0, -- USD (human); current TVL snapshot
    -- Per-token USD unit price (observer feat/v2-dex-pool-price-usd). Nullable:
    -- NULL = orphan token (no WMON-implied price) or not yet synced.
    ADD COLUMN IF NOT EXISTS token0_price_usd NUMERIC, -- USD per token (token0)
    ADD COLUMN IF NOT EXISTS token1_price_usd NUMERIC; -- USD per token (token1)

-- ---------------------------------------------------------------------------
-- 3. Fee Config (per-pair fee rates from FeeCollector.Setup)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fee_config (
    pair_id                 VARCHAR(42) PRIMARY KEY,
    token_id                VARCHAR(42) NOT NULL,
    creator_fee_rate        SMALLINT    NOT NULL,
    curve_protocol_fee_rate SMALLINT    NOT NULL,
    dex_protocol_fee_rate   SMALLINT    NOT NULL,
    created_at              BIGINT      NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_fee_config_token ON fee_config (token_id);

-- ---------------------------------------------------------------------------
-- 4. Raw V2 DEX event tables (dex_swap / dex_sync / dex_mint / dex_burn)
--
-- value      = total USD value of the event (token0_usd + token1_usd).
-- token0_usd = USD value of the token0 side at this event.
-- token1_usd = USD value of the token1 side at this event.
--
-- Per-side preservation lets partial-orphan cases (one side priced, the
-- other unknown) keep the known side's USD rather than collapsing the
-- whole row to value=0.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dex_swap (
    pool_id          VARCHAR(42) NOT NULL,
    sender           VARCHAR(42) NOT NULL,
    amount0_in       NUMERIC     NOT NULL, -- token raw (wei) of token0 in
    amount1_in       NUMERIC     NOT NULL, -- token raw (wei) of token1 in
    amount0_out      NUMERIC     NOT NULL, -- token raw (wei) of token0 out
    amount1_out      NUMERIC     NOT NULL, -- token raw (wei) of token1 out
    value            NUMERIC     NOT NULL DEFAULT 0, -- USD (human); priced-side flow x token USD price (0 = orphan/Pyth miss)
    created_at       BIGINT      NOT NULL, -- unix seconds (block timestamp)
    block_number     BIGINT      NOT NULL,
    transaction_hash VARCHAR     NOT NULL,
    log_index        INTEGER     NOT NULL,
    tx_index         INTEGER     NOT NULL,
    PRIMARY KEY (pool_id, transaction_hash, tx_index, log_index)
);
CREATE INDEX IF NOT EXISTS idx_dex_swap_block_desc
    ON dex_swap (block_number DESC, tx_index DESC, log_index DESC);
CREATE INDEX IF NOT EXISTS idx_dex_swap_pool_block
    ON dex_swap (pool_id, block_number DESC);

CREATE TABLE IF NOT EXISTS dex_sync (
    pool_id          VARCHAR(42) NOT NULL,
    reserve0         NUMERIC     NOT NULL, -- token raw (wei) of token0
    reserve1         NUMERIC     NOT NULL, -- token raw (wei) of token1
    value            NUMERIC     NOT NULL DEFAULT 0, -- USD (human); token0_usd + token1_usd (TVL at this sync)
    token0_usd       NUMERIC     NOT NULL DEFAULT 0, -- USD (human); USD value of the token0 reserve side
    token1_usd       NUMERIC     NOT NULL DEFAULT 0, -- USD (human); USD value of the token1 reserve side
    created_at       BIGINT      NOT NULL, -- unix seconds (block timestamp)
    block_number     BIGINT      NOT NULL,
    transaction_hash VARCHAR     NOT NULL,
    log_index        INTEGER     NOT NULL,
    tx_index         INTEGER     NOT NULL,
    PRIMARY KEY (pool_id, transaction_hash, tx_index, log_index)
);
CREATE INDEX IF NOT EXISTS idx_dex_sync_pool_block
    ON dex_sync (pool_id, block_number DESC);

CREATE TABLE IF NOT EXISTS dex_mint (
    pool_id          VARCHAR(42) NOT NULL,
    sender           VARCHAR(42) NOT NULL,
    amount0          NUMERIC     NOT NULL, -- token raw (wei) of token0 added
    amount1          NUMERIC     NOT NULL, -- token raw (wei) of token1 added
    value            NUMERIC     NOT NULL DEFAULT 0, -- USD (human); token0_usd + token1_usd
    token0_usd       NUMERIC     NOT NULL DEFAULT 0, -- USD (human); USD value of the token0 side
    token1_usd       NUMERIC     NOT NULL DEFAULT 0, -- USD (human); USD value of the token1 side
    created_at       BIGINT      NOT NULL, -- unix seconds (block timestamp)
    block_number     BIGINT      NOT NULL,
    transaction_hash VARCHAR     NOT NULL,
    log_index        INTEGER     NOT NULL,
    tx_index         INTEGER     NOT NULL,
    PRIMARY KEY (pool_id, transaction_hash, tx_index, log_index)
);
CREATE INDEX IF NOT EXISTS idx_dex_mint_pool_block
    ON dex_mint (pool_id, block_number DESC);

CREATE TABLE IF NOT EXISTS dex_burn (
    pool_id          VARCHAR(42) NOT NULL,
    sender           VARCHAR(42) NOT NULL,
    to_address       VARCHAR(42) NOT NULL,
    amount0          NUMERIC     NOT NULL, -- token raw (wei) of token0 removed
    amount1          NUMERIC     NOT NULL, -- token raw (wei) of token1 removed
    value            NUMERIC     NOT NULL DEFAULT 0, -- USD (human); token0_usd + token1_usd
    token0_usd       NUMERIC     NOT NULL DEFAULT 0, -- USD (human); USD value of the token0 side
    token1_usd       NUMERIC     NOT NULL DEFAULT 0, -- USD (human); USD value of the token1 side
    created_at       BIGINT      NOT NULL, -- unix seconds (block timestamp)
    block_number     BIGINT      NOT NULL,
    transaction_hash VARCHAR     NOT NULL,
    log_index        INTEGER     NOT NULL,
    tx_index         INTEGER     NOT NULL,
    PRIMARY KEY (pool_id, transaction_hash, tx_index, log_index)
);
CREATE INDEX IF NOT EXISTS idx_dex_burn_pool_block
    ON dex_burn (pool_id, block_number DESC);

-- Idempotent ALTERs cover DBs that ran an older revision of this file
-- where value / token0_usd / token1_usd were added in a follow-up.
ALTER TABLE dex_sync
    ADD COLUMN IF NOT EXISTS value      NUMERIC NOT NULL DEFAULT 0, -- USD (human); token0_usd + token1_usd (TVL)
    ADD COLUMN IF NOT EXISTS token0_usd NUMERIC NOT NULL DEFAULT 0, -- USD (human); token0 side
    ADD COLUMN IF NOT EXISTS token1_usd NUMERIC NOT NULL DEFAULT 0; -- USD (human); token1 side
ALTER TABLE dex_mint
    ADD COLUMN IF NOT EXISTS value      NUMERIC NOT NULL DEFAULT 0, -- USD (human); token0_usd + token1_usd
    ADD COLUMN IF NOT EXISTS token0_usd NUMERIC NOT NULL DEFAULT 0, -- USD (human); token0 side
    ADD COLUMN IF NOT EXISTS token1_usd NUMERIC NOT NULL DEFAULT 0; -- USD (human); token1 side
ALTER TABLE dex_burn
    ADD COLUMN IF NOT EXISTS value      NUMERIC NOT NULL DEFAULT 0, -- USD (human); token0_usd + token1_usd
    ADD COLUMN IF NOT EXISTS token0_usd NUMERIC NOT NULL DEFAULT 0, -- USD (human); token0 side
    ADD COLUMN IF NOT EXISTS token1_usd NUMERIC NOT NULL DEFAULT 0; -- USD (human); token1 side

-- ---------------------------------------------------------------------------
-- 5. pool.volume accumulator trigger
--
-- Statement-level: a single batch INSERT fires the trigger once with the
-- full new-rows view, so we GROUP BY pool_id and emit one UPDATE per pool
-- instead of one plpgsql call per row.
--
-- Idempotency: when a dex_swap INSERT uses ON CONFLICT DO NOTHING and the
-- row is skipped, the conflicted row is NOT included in the AFTER INSERT
-- transition table (PostgreSQL semantics). The trigger therefore only sums
-- the values of rows that were actually inserted — safe under replay.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_pool_volume()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE pool p
       SET volume = p.volume + d.swap_volume
      FROM (
          SELECT pool_id, SUM(value) AS swap_volume
            FROM new_dex_swaps
           GROUP BY pool_id
      ) d
     WHERE p.pool_id = d.pool_id;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_update_pool_volume ON dex_swap;
CREATE TRIGGER trg_update_pool_volume
    AFTER INSERT ON dex_swap
    REFERENCING NEW TABLE AS new_dex_swaps
    FOR EACH STATEMENT
    EXECUTE FUNCTION update_pool_volume();


-- ============================================================================
-- >>> 0015_v2_events.sql (pruned: v2_sniping_history only)
-- ============================================================================

-- Populated from BondingCurve.SnipingFeeCollected by the Curve handler.
-- (The other 0015 tables — v2 fee/lp-allocate histories — are not indexed
-- by the GIWA runtime and are omitted from this consolidated migration.)

-- 1. V2 Sniping Penalties (BondingCurve.SnipingFeeCollected)
CREATE TABLE IF NOT EXISTS v2_sniping_history (
    token_id VARCHAR(42) NOT NULL,
    buyer VARCHAR(42) NOT NULL,
    sniping_fee NUMERIC NOT NULL, -- quote raw (wei): BondingCurve.SnipingPenalty.snipingFee uint256
    penalty_bps NUMERIC NOT NULL, -- bps: BondingCurve.SnipingPenalty.penaltyBps uint256
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL,
    created_at BIGINT NOT NULL, -- unix seconds (block timestamp)
    log_index INT NOT NULL,
    tx_index INT NOT NULL,
    PRIMARY KEY (transaction_hash, tx_index, log_index)
);
CREATE INDEX IF NOT EXISTS idx_v2_sniping_history_token ON v2_sniping_history (token_id);


-- ============================================================================
-- >>> 0016_pnl_aggregator.sql
-- ============================================================================

-- PnL Aggregator: account별 실현 + 미실현 손익 집계
-- Scheduler에서 5분마다 갱신
-- API에서 SELECT만 하면 되므로 빠름

CREATE TABLE IF NOT EXISTS pnl_aggregator (
    account_id VARCHAR(42) PRIMARY KEY,
    total_invested_native NUMERIC NOT NULL DEFAULT 0,  -- UNIT: quote raw (wei)
    total_invested_usd NUMERIC NOT NULL DEFAULT 0,     -- UNIT: USD (human)
    realized_native NUMERIC NOT NULL DEFAULT 0,        -- UNIT: quote raw (wei)
    realized_usd NUMERIC NOT NULL DEFAULT 0,           -- UNIT: USD (human)
    unrealized_native NUMERIC NOT NULL DEFAULT 0,      -- UNIT: quote raw (wei)
    unrealized_usd NUMERIC NOT NULL DEFAULT 0,         -- UNIT: USD (human)
    updated_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_pnl_aggregator_total ON pnl_aggregator((realized_native + unrealized_native) DESC);


-- ============================================================================
-- >>> 0017_chester_round.sql
-- ============================================================================

CREATE TABLE IF NOT EXISTS chester_reward_token(
    token_id VARCHAR(42) PRIMARY KEY,
    name VARCHAR NOT NULL,
    symbol VARCHAR NOT NULL,
    image_uri VARCHAR NOT NULL
);

-- Seed from existing chester_reward + token
-- INSERT INTO chester_reward_token (token_id, name, symbol, image_uri)
-- SELECT DISTINCT rw.token_id, t.name, t.symbol, t.image_uri
-- FROM chester_reward rw
-- INNER JOIN token t ON t.token_id = rw.token_id
-- ON CONFLICT (token_id) DO NOTHING;



-- Chester Round configuration (raffle_round 패턴)
CREATE TABLE IF NOT EXISTS chester_round(
    round BIGINT NOT NULL,
    start_at BIGINT NOT NULL,
    end_at BIGINT NOT NULL,
    status VARCHAR NOT NULL CHECK (status IN ('ACTIVE', 'COMPLETED', 'READY')),
    merkle_root VARCHAR,
    created_at BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (round)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_chester_round_single_active
    ON chester_round ((1)) WHERE status = 'ACTIVE';

-- Chester Reward (라운드별 보상 토큰)
CREATE TABLE IF NOT EXISTS chester_reward(
    round BIGINT NOT NULL REFERENCES chester_round(round),
    token_id VARCHAR(42) NOT NULL,
    amount NUMERIC NOT NULL,  -- UNIT: token raw (wei) — reward pool size per token; box rewards scaled by 1e18 are validated against this (mock seed 1e21 = 1000 tokens)
    PRIMARY KEY (round, token_id)
);

-- -- Mock data: Round 1 (2026-02-06 ~ 2026-02-13 23:59 KST)
-- INSERT INTO chester_round (round, start_at, end_at, status)
-- VALUES (1, 1770392544, 1770994740, 'ACTIVE')
-- ON CONFLICT (round) DO NOTHING;

-- INSERT INTO chester_reward (round, token_id, amount)
-- VALUES (1, '0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A', 1e21)
-- ON CONFLICT (round, token_id) DO NOTHING;

-- Volume/Fee는 별도 테이블 없이 실시간 쿼리로 계산:
-- total_usd_volume = SUM(swap.value) WHERE created_at BETWEEN start_at AND end_at
-- total_fee_usd = SUM(point_history.value) WHERE created_at BETWEEN start_at AND end_at
--
-- Reward usd_value 계산:
-- WMON: reward.amount * price.price (최신 block의 MON/USD)
-- 기타: reward.amount * market.price * price.price (토큰→MON→USD)


-- 상자별 보상 결과 (외부 정산 프로세스에서 INSERT)
CREATE TABLE IF NOT EXISTS chester_box_reward (
    round           BIGINT NOT NULL REFERENCES chester_round(round),
    level           INT NOT NULL,              -- 상자 레벨 1~4
    token_id        VARCHAR(42) NOT NULL,
    account_id      VARCHAR(42) NOT NULL,
    amount          NUMERIC NOT NULL,          -- 토큰 수량 | UNIT: token raw (wei) — (expected_qty * multiplier).floor() * 1e18 (chester_settlement_service.rs:171-175)
    status          VARCHAR NOT NULL CHECK (status IN ('AWAITING', 'CLAIMED')),
    proof           TEXT[] NOT NULL,            -- 머클 프루프
    transaction_hash VARCHAR NULL,             -- Claim 시 기록
    claimed_at      BIGINT NULL,
    created_at      BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (round, level, token_id, account_id)
);

CREATE INDEX IF NOT EXISTS idx_chester_box_reward_account
    ON chester_box_reward (account_id);
CREATE INDEX IF NOT EXISTS idx_chester_box_reward_round_account
    ON chester_box_reward (round, account_id);

-- AddReward 이벤트 이력 테이블
CREATE TABLE IF NOT EXISTS chester_add_reward_history (
    round           BIGINT NOT NULL,
    token_id        VARCHAR(42) NOT NULL,
    account_id      VARCHAR(42) NOT NULL,
    amount          NUMERIC NOT NULL,  -- UNIT: token raw (wei) — on-chain AddReward event amount (U256); mirrors chester_box_reward.amount scale (no INSERT writer in observer/scheduler src)
    transaction_hash VARCHAR NOT NULL,
    log_index       BIGINT NOT NULL,
    block_number    BIGINT NOT NULL,
    block_timestamp BIGINT NOT NULL,
    created_at      BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (round, account_id, token_id, transaction_hash, log_index)
);

-- BoxRewardClaimed 이벤트 이력 테이블 (중복 인덱싱 방지)
CREATE TABLE IF NOT EXISTS chester_box_reward_claim_history (
    round           BIGINT NOT NULL,
    level           BIGINT NOT NULL,
    token_id        VARCHAR(42) NOT NULL,
    account_id      VARCHAR(42) NOT NULL,
    amount          NUMERIC NOT NULL,  -- UNIT: token raw (wei) — on-chain BoxRewardClaimed event amount (U256); equals the claimed chester_box_reward.amount (no INSERT writer in observer/scheduler src)
    transaction_hash VARCHAR NOT NULL,
    log_index       BIGINT NOT NULL,
    block_number    BIGINT NOT NULL,
    block_timestamp BIGINT NOT NULL,
    created_at      BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,
    PRIMARY KEY (round, level, token_id, account_id, transaction_hash, log_index)
);

-- point_distribution에 'CHEST' activity_type 추가
ALTER TABLE point_distribution DROP CONSTRAINT IF EXISTS point_distribution_activity_type_check;
ALTER TABLE point_distribution ADD CONSTRAINT point_distribution_activity_type_check
    CHECK (activity_type IN ('CREATE','CURVE','GRADUATE','DEX','HYPEBOARD','RAFFLE','CHEST'));

-- 트리거 함수 업데이트: CHEST도 hype_point로 처리
CREATE OR REPLACE FUNCTION update_point_on_distribution_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.activity_type IN ('RAFFLE', 'CHEST') THEN
        -- RAFFLE, CHEST updates hype_point
        INSERT INTO point (account_id, hype_point)
        VALUES (NEW.account_id, NEW.amount)
        ON CONFLICT (account_id)
        DO UPDATE SET hype_point = point.hype_point + NEW.amount;
    ELSE
        -- Other activities update round_point
        INSERT INTO point (account_id, round_point)
        VALUES (NEW.account_id, NEW.amount)
        ON CONFLICT (account_id)
        DO UPDATE SET round_point = point.round_point + NEW.amount;
    END IF;

    RETURN NEW;
END;
$$;


-- ============================================================================
-- >>> 0019_quote_token.sql
-- ============================================================================

-- Quote token metadata for multi-quote support
-- Stores name, symbol, decimals, pyth feed, and image for each quote asset (WETH, USDC, etc.)
-- Referenced by market.quote_id via LEFT JOIN in api-server queries
-- Observer reads pyth_feed_id + decimals at startup to build its quote price config
-- (replaces the old QUOTE_CONFIGS env var)

CREATE TABLE IF NOT EXISTS quote_token (
    quote_id VARCHAR(42) PRIMARY KEY,
    name VARCHAR NOT NULL,
    symbol VARCHAR NOT NULL,
    decimals INT NOT NULL DEFAULT 18,
    pyth_feed_id VARCHAR NOT NULL,
    image_uri VARCHAR NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

INSERT INTO quote_token (quote_id, name, symbol, decimals, pyth_feed_id, image_uri)
VALUES (
    '0x4200000000000000000000000000000000000006',
    'Wrapped Ether',
    'WETH',
    18,
    '0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace',
    'https://storage.nadapp.net/quote/weth.webp'
) ON CONFLICT (quote_id) DO NOTHING;


-- ============================================================================
-- >>> 0020_gift_tweet.sql
-- ============================================================================

-- =====================================================
-- gift_tweet: producer(트윗 스트림)와 consumer(on-chain setReceiver)
-- 사이의 크래시 안전 버퍼. 추가로 consumer가 setReceiver 성공 직후
-- nad.fun 프로필 링크로 답글을 다는 reply 워크플로 상태도 같이 보관.
--
-- 설계 문서: gift-bot/docs/plans/2026-04-24-split-architecture-design.md
--
-- Reply 상태머신 (reply_status):
--   none      — reply 기능 비활성/이 row는 reply 대상 아님
--   pending   — setReceiver 성공, reply 워커가 처리 대기
--   sent      — POST /2/tweets 성공, reply_tweet_id에 답글 id 저장
--   failed    — 최대 재시도 횟수 초과 / 비재시도 오류 (operator 액션 필요)
-- =====================================================

CREATE TABLE IF NOT EXISTS gift_tweet (
    tweet_id         VARCHAR(32)  PRIMARY KEY,                 -- X snowflake id
    token_id         VARCHAR(42)  NOT NULL,                    -- 0x... token contract
    receiver_id      VARCHAR(42)  NOT NULL,                    -- 0x... resolved EVM receiver
    handle           VARCHAR(16)  NOT NULL,                    -- tweet 작성자 X handle (@ 제외)

    status           VARCHAR(16)  NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','submitted','completed','rejected')),
    reject_reason    VARCHAR(32),                              -- ValidationReject variant name
    tx_hash          VARCHAR(66),                              -- submitted → completed 전이 시 기록
    last_error       TEXT,                                     -- transient 실패 최근 원인

    -- Reply-on-success 워크플로 (consumer가 setReceiver 성공 후 X에 답글)
    reply_status     VARCHAR(16)  NOT NULL DEFAULT 'none'
                     CHECK (reply_status IN ('none','pending','sent','failed')),
    reply_tweet_id   VARCHAR(32),                              -- X가 반환한 답글의 snowflake id
    reply_attempts   INT          NOT NULL DEFAULT 0,          -- 재시도 카운터
    reply_last_error TEXT,                                     -- 최근 reply 실패 사유
    reply_sent_at    TIMESTAMPTZ,                              -- 답글 성공 timestamp

    received_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- pending 큐 폴링 최적화 (보통의 work queue)
CREATE INDEX IF NOT EXISTS idx_gift_tweet_pending
    ON gift_tweet (received_at)
    WHERE status = 'pending';

-- submitted 스윕 최적화 (재시작 시 on-chain reconciliation)
CREATE INDEX IF NOT EXISTS idx_gift_tweet_submitted
    ON gift_tweet (received_at)
    WHERE status = 'submitted';

-- Reply 워커 폴링 최적화: 'pending'만 인덱싱 (partial index라
-- sent/failed/none이 누적돼도 인덱스가 부풀지 않음)
CREATE INDEX IF NOT EXISTS idx_gift_tweet_reply_pending
    ON gift_tweet (updated_at)
    WHERE reply_status = 'pending';

-- INSERT 시 consumer에게 신호 (트랜잭션 커밋 후 발송됨)
CREATE OR REPLACE FUNCTION notify_gift_tweet_new() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('gift_tweet_new', NEW.tweet_id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS gift_tweet_notify ON gift_tweet;
CREATE TRIGGER gift_tweet_notify
    AFTER INSERT ON gift_tweet
    FOR EACH ROW
    EXECUTE FUNCTION notify_gift_tweet_new();


-- ============================================================================
-- >>> 0021_lp_position.sql
-- ============================================================================

-- LP position tracking for V2 NadFunPair (position pattern)
-- Mirrors migrations/0013_position.sql conventions
-- Spec: docs/superpowers/specs/2026-05-14-v2-lp-position-design.md
--
-- Consolidated from 0021 (tables + triggers) and the former 0029
-- (lp_position_cost_basis view + one-time backfill) into one canonical
-- file. The view appears at the tail of this file because it joins against
-- dex_mint / dex_burn (created in 0014_dex.sql) — fresh-DB load order
-- 0014 → 0021 guarantees those tables exist by view-creation time.
--
-- ⚠️ If you edit the fill_lp_cost_basis() / apply_lp_position() /
-- refresh_lp_position_cost_basis() function bodies OR the view body,
-- mirror the change in migrations/v2_upgrade_lp_position.sql.
--
-- Schema includes USD value columns (cost-basis, frozen at deposit/transfer
-- time). USD is filled by `fill_lp_cost_basis` from dex_mint/dex_burn (mint,
-- burn events) or pro-rated from the sender's running lp_position (transfer).
-- Current market value is the API layer's job
-- (balance × pool.value / pool.total_supply).
--
-- Note: `lp_event_type` is the first project-level ENUM. `position_history.transfer_type`
-- in 0013 stayed VARCHAR(20) — no precedent. We choose ENUM here for type safety
-- and storage efficiency on a high-volume event log.

-- Event type enum for lp_position_history
CREATE TYPE lp_event_type AS ENUM ('mint', 'burn', 'transfer_in', 'transfer_out');

CREATE TABLE IF NOT EXISTS lp_position_history (
    account_id       VARCHAR(42) NOT NULL,
    pool_id          VARCHAR(42) NOT NULL,

    lp_in            NUMERIC NOT NULL DEFAULT 0, -- LP shares (raw); chain Transfer.value on LP token
    lp_out           NUMERIC NOT NULL DEFAULT 0, -- LP shares (raw); chain Transfer.value on LP token
    token0_in        NUMERIC NOT NULL DEFAULT 0, -- token0 raw (wei); share-weighted from dex_mint.amount0
    token0_out       NUMERIC NOT NULL DEFAULT 0, -- token0 raw (wei); from dex_burn.amount0
    token1_in        NUMERIC NOT NULL DEFAULT 0, -- token1 raw (wei); share-weighted from dex_mint.amount1
    token1_out       NUMERIC NOT NULL DEFAULT 0, -- token1 raw (wei); from dex_burn.amount1

    -- Cost-basis USD value, frozen at the event's block time.
    lp_in_usd        NUMERIC NOT NULL DEFAULT 0, -- USD (human); share-weighted from dex_mint.value
    lp_out_usd       NUMERIC NOT NULL DEFAULT 0, -- USD (human); from dex_burn.value
    token0_in_usd    NUMERIC NOT NULL DEFAULT 0, -- USD (human); share-weighted from dex_mint.token0_usd
    token0_out_usd   NUMERIC NOT NULL DEFAULT 0, -- USD (human); from dex_burn.token0_usd
    token1_in_usd    NUMERIC NOT NULL DEFAULT 0, -- USD (human); share-weighted from dex_mint.token1_usd
    token1_out_usd   NUMERIC NOT NULL DEFAULT 0, -- USD (human); from dex_burn.token1_usd

    event_type       lp_event_type NOT NULL,
    counterparty     VARCHAR(42),

    transaction_hash VARCHAR(66) NOT NULL,
    block_number     BIGINT NOT NULL,
    tx_index         INT NOT NULL,
    log_index        INT NOT NULL,
    created_at       BIGINT NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT,

    PRIMARY KEY (account_id, pool_id, transaction_hash, tx_index, log_index)
);

-- Idempotent USD-column adds for any DB that ran an older rev of this file
-- (pre-USD shape). Safe no-op on fresh DBs.
ALTER TABLE lp_position_history
    ADD COLUMN IF NOT EXISTS lp_in_usd      NUMERIC NOT NULL DEFAULT 0, -- USD (human)
    ADD COLUMN IF NOT EXISTS lp_out_usd     NUMERIC NOT NULL DEFAULT 0, -- USD (human)
    ADD COLUMN IF NOT EXISTS token0_in_usd  NUMERIC NOT NULL DEFAULT 0, -- USD (human)
    ADD COLUMN IF NOT EXISTS token0_out_usd NUMERIC NOT NULL DEFAULT 0, -- USD (human)
    ADD COLUMN IF NOT EXISTS token1_in_usd  NUMERIC NOT NULL DEFAULT 0, -- USD (human)
    ADD COLUMN IF NOT EXISTS token1_out_usd NUMERIC NOT NULL DEFAULT 0; -- USD (human)

CREATE INDEX IF NOT EXISTS idx_lp_position_history_account ON lp_position_history(account_id);
CREATE INDEX IF NOT EXISTS idx_lp_position_history_pool    ON lp_position_history(pool_id);
CREATE INDEX IF NOT EXISTS idx_lp_position_history_tx      ON lp_position_history(transaction_hash);
CREATE INDEX IF NOT EXISTS idx_lp_position_history_block   ON lp_position_history(block_number, tx_index, log_index);
CREATE INDEX IF NOT EXISTS idx_lp_position_history_event   ON lp_position_history(event_type);

CREATE TABLE IF NOT EXISTS lp_position (
    account_id     VARCHAR(42) NOT NULL,
    pool_id        VARCHAR(42) NOT NULL,
    lp_in          NUMERIC NOT NULL DEFAULT 0, -- LP shares (raw); SUM of mint/transfer-in Transfer.value
    lp_out         NUMERIC NOT NULL DEFAULT 0, -- LP shares (raw); SUM of burn/transfer-out Transfer.value
    -- Running open balance for this (account, pool) epoch. Maintained
    -- automatically by PostgreSQL; no trigger logic touches it. Consumers
    -- can `SELECT balance` directly instead of computing lp_in - lp_out and
    -- can index/sort by it.
    balance        NUMERIC GENERATED ALWAYS AS (lp_in - lp_out) STORED, -- LP shares (raw); open balance = lp_in - lp_out
    token0_in      NUMERIC NOT NULL DEFAULT 0, -- token0 raw (wei); epoch SUM from history
    token0_out     NUMERIC NOT NULL DEFAULT 0, -- token0 raw (wei); epoch SUM from history
    token1_in      NUMERIC NOT NULL DEFAULT 0, -- token1 raw (wei); epoch SUM from history
    token1_out     NUMERIC NOT NULL DEFAULT 0, -- token1 raw (wei); epoch SUM from history
    lp_in_usd      NUMERIC NOT NULL DEFAULT 0, -- USD (human); epoch SUM from history
    lp_out_usd     NUMERIC NOT NULL DEFAULT 0, -- USD (human); epoch SUM from history
    token0_in_usd  NUMERIC NOT NULL DEFAULT 0, -- USD (human); epoch SUM from history
    token0_out_usd NUMERIC NOT NULL DEFAULT 0, -- USD (human); epoch SUM from history
    token1_in_usd  NUMERIC NOT NULL DEFAULT 0, -- USD (human); epoch SUM from history
    token1_out_usd NUMERIC NOT NULL DEFAULT 0, -- USD (human); epoch SUM from history
    created_at     BIGINT NOT NULL,
    updated_at     BIGINT NOT NULL,
    PRIMARY KEY (account_id, pool_id)
);

ALTER TABLE lp_position
    ADD COLUMN IF NOT EXISTS lp_in_usd            NUMERIC NOT NULL DEFAULT 0, -- USD (human)
    ADD COLUMN IF NOT EXISTS lp_out_usd           NUMERIC NOT NULL DEFAULT 0, -- USD (human)
    ADD COLUMN IF NOT EXISTS token0_in_usd        NUMERIC NOT NULL DEFAULT 0, -- USD (human)
    ADD COLUMN IF NOT EXISTS token0_out_usd       NUMERIC NOT NULL DEFAULT 0, -- USD (human)
    ADD COLUMN IF NOT EXISTS token1_in_usd        NUMERIC NOT NULL DEFAULT 0, -- USD (human)
    ADD COLUMN IF NOT EXISTS token1_out_usd       NUMERIC NOT NULL DEFAULT 0, -- USD (human)
    -- Epoch boundary: lp_position rows are deleted on full exit and re-INSERTed
    -- on re-entry, so each row represents one continuous open epoch. Track the
    -- (block, tx_index, log_index) of the row's first event so the materialize
    -- trigger's SUM-from-history sums only THIS epoch and doesn't resurrect
    -- cost basis from closed past epochs.
    ADD COLUMN IF NOT EXISTS epoch_start_block     BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS epoch_start_tx_index  INT    NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS epoch_start_log_index INT    NOT NULL DEFAULT 0,
    -- Generated stored open-balance column. Auto-recomputed by PG on every
    -- UPDATE of lp_in/lp_out via apply_lp_position(); no trigger maintenance.
    ADD COLUMN IF NOT EXISTS balance               NUMERIC GENERATED ALWAYS AS (lp_in - lp_out) STORED; -- LP shares (raw); open balance = lp_in - lp_out

CREATE INDEX IF NOT EXISTS idx_lp_position_account ON lp_position(account_id);
CREATE INDEX IF NOT EXISTS idx_lp_position_pool    ON lp_position(pool_id);

ALTER TABLE pool ADD COLUMN IF NOT EXISTS total_supply NUMERIC(78,0) NOT NULL DEFAULT 0; -- LP shares (raw); running pool LP supply (Σ mint lp_in − Σ burn lp_out)

-- BEFORE INSERT: balance bookkeeping only. Cost basis lives in the
-- lp_position_cost_basis view defined below.
--
-- Responsibilities preserved from the previous revision:
--   * burn rows: re-attribute account_id to dex_burn.to_address (the Transfer
--     log's from-field is the pair contract, not the user).
--   * transfer rows where counterparty=pool: drop (Pair.burn() emits a
--     pool↔user Transfer leg that should be folded into the matching burn).
--
-- Removed responsibilities (now derived in lp_position_cost_basis view):
--   * Filling token0_in/token1_in/USD on mint (share-weighted in the view).
--   * Filling token0_out/token1_out/USD on burn (single-recipient in the view).
--   * Pro-rating transfer cost basis from the sender's running lp_position
--     (out of scope; defer until a consumer needs running per-holder cost
--     basis after transfers).
CREATE OR REPLACE FUNCTION fill_lp_cost_basis()
RETURNS TRIGGER AS $$
DECLARE
    burn_row RECORD;
BEGIN
    IF NEW.event_type = 'burn' THEN
        SELECT * INTO burn_row
          FROM dex_burn
         WHERE pool_id = NEW.pool_id
           AND transaction_hash = NEW.transaction_hash
           AND log_index > NEW.log_index
         ORDER BY log_index ASC LIMIT 1;
        IF FOUND THEN
            NEW.account_id := burn_row.to_address;
        ELSE
            RAISE WARNING 'LP burn without matching dex_burn: pool=% tx=% (attributed to %)',
                NEW.pool_id, NEW.transaction_hash, NEW.account_id;
        END IF;

    ELSIF NEW.event_type = 'transfer_out' THEN
        -- Drop the user→pair leg of burn(); the burn row that follows in the
        -- same tx (re-attributed above) carries the user's lp_out.
        IF NEW.counterparty = NEW.pool_id THEN
            RETURN NULL;
        END IF;

    ELSIF NEW.event_type = 'transfer_in' THEN
        -- Drop the pair-receives-LP phantom row (first leg of burn).
        IF NEW.account_id = NEW.pool_id THEN
            RETURN NULL;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- AFTER INSERT: aggregate lp balance + pool.total_supply only. Token/USD
-- accumulation removed — those columns stay at 0 on lp_position and consumers
-- read cost basis from the lp_position_cost_basis view.
-- Does NOT fire when ON CONFLICT DO NOTHING skips.
CREATE OR REPLACE FUNCTION apply_lp_position()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.event_type = 'mint' THEN
        UPDATE pool SET total_supply = total_supply + NEW.lp_in WHERE pool_id = NEW.pool_id;
    ELSIF NEW.event_type = 'burn' THEN
        UPDATE pool SET total_supply = total_supply - NEW.lp_out WHERE pool_id = NEW.pool_id;
    END IF;

    INSERT INTO lp_position (account_id, pool_id, lp_in, lp_out, created_at, updated_at,
                             epoch_start_block, epoch_start_tx_index, epoch_start_log_index)
    VALUES (NEW.account_id, NEW.pool_id, NEW.lp_in, NEW.lp_out, NEW.created_at, NEW.created_at,
            NEW.block_number, NEW.tx_index, NEW.log_index)
    ON CONFLICT (account_id, pool_id) DO UPDATE SET
        lp_in      = lp_position.lp_in  + EXCLUDED.lp_in,
        lp_out     = lp_position.lp_out + EXCLUDED.lp_out,
        updated_at = EXCLUDED.updated_at;
    -- epoch_start_* are intentionally NOT in the SET list — they're set
    -- only on fresh INSERT (= start of a new epoch) and preserved across
    -- subsequent UPSERTs until the row is DELETEd by full-exit below.

    DELETE FROM lp_position
     WHERE account_id = NEW.account_id
       AND pool_id    = NEW.pool_id
       AND lp_in      = lp_out;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- AFTER STATEMENT: materialize the lp_position_cost_basis view definition into
-- both lp_position_history (per-row token/USD cols) and lp_position (aggregate
-- token/USD cols) for the (pool_id, transaction_hash) tuples touched in this
-- INSERT batch. Fires once per INSERT statement (sees the whole batch via the
-- NEW transition table), so share-weighted attribution is correct regardless of
-- batch row order.
--
-- Ordering invariant: V2 DEX stream completes before Token stream, so dex_mint
-- and dex_burn rows are already in the DB when this fires. If a row's matching
-- dex_mint/dex_burn is missing (= invariant broken), RAISE WARNING and leave
-- token cols at 0 — never silently mis-attribute.
CREATE OR REPLACE FUNCTION refresh_lp_position_cost_basis()
RETURNS TRIGGER AS $$
DECLARE
    feeto CONSTANT TEXT := '0x715103eeeac12fb84f5d3b35c3268dd767fa8b8a';
BEGIN
    -- (1) MINT side: re-fill lp_position_history.token cols for every mint row
    -- in (pool_id, transaction_hash) tuples touched by this batch.
    -- Uses the same share-weighted math as the lp_position_cost_basis view.
    WITH affected_mint_txs AS (
        SELECT DISTINCT pool_id, transaction_hash
          FROM new_rows
         WHERE event_type = 'mint'
    ),
    mint_with_dm AS (
        SELECT
            ph.account_id, ph.pool_id, ph.transaction_hash, ph.tx_index, ph.log_index,
            ph.lp_in,
            dm.amount0    AS dm_amount0,
            dm.amount1    AS dm_amount1,
            dm.value      AS dm_value,
            dm.token0_usd AS dm_token0_usd,
            dm.token1_usd AS dm_token1_usd,
            dm.log_index  AS dm_log_index
          FROM lp_position_history ph
          JOIN affected_mint_txs a
            ON a.pool_id = ph.pool_id AND a.transaction_hash = ph.transaction_hash
          JOIN LATERAL (
              SELECT *
                FROM dex_mint
               WHERE pool_id = ph.pool_id
                 AND transaction_hash = ph.transaction_hash
                 AND log_index > ph.log_index
               ORDER BY log_index ASC LIMIT 1
          ) dm ON true
         WHERE ph.event_type = 'mint'
    ),
    mint_truncs AS (
        SELECT
            ph.account_id, ph.pool_id, ph.transaction_hash, ph.tx_index, ph.log_index,
            ph.lp_in, ph.dm_amount0, ph.dm_amount1, ph.dm_value,
            ph.dm_token0_usd, ph.dm_token1_usd, ph.dm_log_index, r.real_lp,
            CASE WHEN LOWER(ph.account_id) = feeto THEN 0
                 ELSE TRUNC(ph.lp_in * ph.dm_amount0 / NULLIF(r.real_lp, 0))
            END AS t0_trunc,
            CASE WHEN LOWER(ph.account_id) = feeto THEN 0
                 ELSE TRUNC(ph.lp_in * ph.dm_amount1 / NULLIF(r.real_lp, 0))
            END AS t1_trunc,
            ROW_NUMBER() OVER (
                PARTITION BY ph.pool_id, ph.transaction_hash, ph.dm_log_index
                ORDER BY
                    CASE WHEN LOWER(ph.account_id) = feeto THEN 1 ELSE 0 END,
                    ph.lp_in DESC,
                    ph.log_index ASC
            ) AS anchor_rn
          FROM mint_with_dm ph
          JOIN LATERAL (
              SELECT COALESCE(SUM(sib.lp_in), 0) AS real_lp
                FROM mint_with_dm sib
               WHERE sib.pool_id = ph.pool_id
                 AND sib.transaction_hash = ph.transaction_hash
                 AND sib.dm_log_index = ph.dm_log_index
                 AND LOWER(sib.account_id) <> feeto
          ) r ON true
    ),
    mint_costs AS (
        SELECT
            mt.account_id, mt.pool_id, mt.transaction_hash, mt.tx_index, mt.log_index,
            -- Residual sum partition MUST match the anchor partition (per
            -- dex_mint, not per tx). A router-aggregated tx with multiple
            -- dex_mints carries independent residuals.
            CASE WHEN LOWER(mt.account_id) = feeto THEN 0
                 WHEN mt.anchor_rn = 1
                     THEN mt.t0_trunc + (mt.dm_amount0 - SUM(mt.t0_trunc) OVER (
                            PARTITION BY mt.pool_id, mt.transaction_hash, mt.dm_log_index))
                 ELSE mt.t0_trunc
            END AS token0_in,
            CASE WHEN LOWER(mt.account_id) = feeto THEN 0
                 WHEN mt.anchor_rn = 1
                     THEN mt.t1_trunc + (mt.dm_amount1 - SUM(mt.t1_trunc) OVER (
                            PARTITION BY mt.pool_id, mt.transaction_hash, mt.dm_log_index))
                 ELSE mt.t1_trunc
            END AS token1_in,
            CASE WHEN LOWER(mt.account_id) = feeto THEN 0
                 ELSE ROUND(mt.lp_in * COALESCE(mt.dm_token0_usd, 0) / NULLIF(mt.real_lp, 0), 10)
            END AS token0_in_usd,
            CASE WHEN LOWER(mt.account_id) = feeto THEN 0
                 ELSE ROUND(mt.lp_in * COALESCE(mt.dm_token1_usd, 0) / NULLIF(mt.real_lp, 0), 10)
            END AS token1_in_usd,
            CASE WHEN LOWER(mt.account_id) = feeto THEN 0
                 ELSE ROUND(mt.lp_in * COALESCE(mt.dm_value, 0) / NULLIF(mt.real_lp, 0), 10)
            END AS lp_in_usd
          FROM mint_truncs mt
    )
    UPDATE lp_position_history h
       SET token0_in     = c.token0_in,
           token1_in     = c.token1_in,
           token0_in_usd = c.token0_in_usd,
           token1_in_usd = c.token1_in_usd,
           lp_in_usd     = c.lp_in_usd
      FROM mint_costs c
     WHERE h.account_id       = c.account_id
       AND h.pool_id          = c.pool_id
       AND h.transaction_hash = c.transaction_hash
       AND h.tx_index         = c.tx_index
       AND h.log_index        = c.log_index;

    -- (2) BURN side: re-fill lp_position_history.token cols for burn rows
    -- in (pool_id, transaction_hash) tuples touched by this batch.
    WITH affected_burn_txs AS (
        SELECT DISTINCT pool_id, transaction_hash
          FROM new_rows
         WHERE event_type = 'burn'
    ),
    burn_costs AS (
        SELECT
            ph.account_id, ph.pool_id, ph.transaction_hash, ph.tx_index, ph.log_index,
            db.amount0    AS token0_out,
            db.amount1    AS token1_out,
            ROUND(COALESCE(db.token0_usd, 0), 10) AS token0_out_usd,
            ROUND(COALESCE(db.token1_usd, 0), 10) AS token1_out_usd,
            ROUND(COALESCE(db.value,      0), 10) AS lp_out_usd
          FROM lp_position_history ph
          JOIN affected_burn_txs a
            ON a.pool_id = ph.pool_id AND a.transaction_hash = ph.transaction_hash
          JOIN LATERAL (
              SELECT *
                FROM dex_burn
               WHERE pool_id = ph.pool_id
                 AND transaction_hash = ph.transaction_hash
                 AND log_index > ph.log_index
               ORDER BY log_index ASC LIMIT 1
          ) db ON true
         WHERE ph.event_type = 'burn'
    )
    UPDATE lp_position_history h
       SET token0_out     = c.token0_out,
           token1_out     = c.token1_out,
           token0_out_usd = c.token0_out_usd,
           token1_out_usd = c.token1_out_usd,
           lp_out_usd     = c.lp_out_usd
      FROM burn_costs c
     WHERE h.account_id       = c.account_id
       AND h.pool_id          = c.pool_id
       AND h.transaction_hash = c.transaction_hash
       AND h.tx_index         = c.tx_index
       AND h.log_index        = c.log_index;

    -- (3) WARNING for rows that landed without a matching dex_mint or dex_burn
    -- (= ordering invariant broken: V2 DEX should have finished first).
    -- Aggregate the offending (pool, tx) pairs into the message (capped to 5
    -- for bounded log line length) so operators can correlate immediately.
    DECLARE
        missing_pairs TEXT;
    BEGIN
        SELECT string_agg(
                   format('pool=%s tx=%s', n.pool_id, n.transaction_hash),
                   ', '
                   ORDER BY n.pool_id, n.transaction_hash
               )
          INTO missing_pairs
          FROM (
              SELECT DISTINCT n.pool_id, n.transaction_hash
                FROM new_rows n
               WHERE n.event_type = 'mint'
                 AND NOT EXISTS (SELECT 1 FROM dex_mint dm
                                  WHERE dm.pool_id = n.pool_id
                                    AND dm.transaction_hash = n.transaction_hash
                                    AND dm.log_index > n.log_index)
               LIMIT 5
          ) n;
        IF missing_pairs IS NOT NULL THEN
            RAISE WARNING 'LP mint without matching dex_mint — ordering invariant broken; offending pairs (first 5): %', missing_pairs;
        END IF;

        SELECT string_agg(
                   format('pool=%s tx=%s', n.pool_id, n.transaction_hash),
                   ', '
                   ORDER BY n.pool_id, n.transaction_hash
               )
          INTO missing_pairs
          FROM (
              SELECT DISTINCT n.pool_id, n.transaction_hash
                FROM new_rows n
               WHERE n.event_type = 'burn'
                 AND NOT EXISTS (SELECT 1 FROM dex_burn db
                                  WHERE db.pool_id = n.pool_id
                                    AND db.transaction_hash = n.transaction_hash
                                    AND db.log_index > n.log_index)
               LIMIT 5
          ) n;
        IF missing_pairs IS NOT NULL THEN
            RAISE WARNING 'LP burn without matching dex_burn — ordering invariant broken; offending pairs (first 5): %', missing_pairs;
        END IF;
    END;

    -- (4) Aggregate rebuild: for each (account_id, pool_id) touched by this
    -- batch, recompute lp_position.token* / *_usd absolutely from history.
    -- lp_in / lp_out are NOT touched here — they're maintained by the existing
    -- apply_lp_position() per-row UPSERT. This trigger only owns cost basis.
    WITH affected_pairs AS (
        SELECT DISTINCT account_id, pool_id FROM new_rows
        UNION
        -- The UNION is load-bearing for SHARE-WEIGHTING RECOMPUTATION across
        -- statements: when a later batch inserts a new mint row into a tx
        -- that already had stored mint rows, the prior rows' share denominator
        -- changes (= they need re-attribution). Their (account_id, pool_id)
        -- pairs are NOT in `new_rows` for this batch, so we pull them in via
        -- the stored history for any affected (pool, tx). Burn re-attribution
        -- (BEFORE-trigger rewriting account_id from pool → to_address) is
        -- already reflected in `new_rows` per PG semantics — the NEW
        -- transition table holds post-BEFORE-trigger values.
        SELECT DISTINCT h.account_id, h.pool_id
          FROM lp_position_history h
          JOIN (SELECT DISTINCT pool_id, transaction_hash FROM new_rows) t
            ON t.pool_id = h.pool_id AND t.transaction_hash = h.transaction_hash
    ),
    aggregates AS (
        SELECT h.account_id, h.pool_id,
               SUM(h.token0_in)      AS token0_in,
               SUM(h.token0_out)     AS token0_out,
               SUM(h.token1_in)      AS token1_in,
               SUM(h.token1_out)     AS token1_out,
               SUM(h.token0_in_usd)  AS token0_in_usd,
               SUM(h.token0_out_usd) AS token0_out_usd,
               SUM(h.token1_in_usd)  AS token1_in_usd,
               SUM(h.token1_out_usd) AS token1_out_usd,
               SUM(h.lp_in_usd)      AS lp_in_usd,
               SUM(h.lp_out_usd)     AS lp_out_usd
          FROM lp_position_history h
          JOIN affected_pairs ap
            ON ap.account_id = h.account_id AND ap.pool_id = h.pool_id
          JOIN lp_position lp
            ON lp.account_id = h.account_id AND lp.pool_id = h.pool_id
         -- Restrict SUM to the CURRENT open epoch only. Re-entry after a
         -- full exit creates a new lp_position row with fresh epoch_start_*
         -- coordinates; history rows from prior (closed) epochs must NOT
         -- contribute to the current row's cost basis.
         WHERE (h.block_number, h.tx_index, h.log_index)
             >= (lp.epoch_start_block, lp.epoch_start_tx_index, lp.epoch_start_log_index)
         GROUP BY h.account_id, h.pool_id
    )
    UPDATE lp_position lp
       SET token0_in      = a.token0_in,
           token0_out     = a.token0_out,
           token1_in      = a.token1_in,
           token1_out     = a.token1_out,
           token0_in_usd  = a.token0_in_usd,
           token0_out_usd = a.token0_out_usd,
           token1_in_usd  = a.token1_in_usd,
           token1_out_usd = a.token1_out_usd,
           lp_in_usd      = a.lp_in_usd,
           lp_out_usd     = a.lp_out_usd
      FROM aggregates a
     WHERE lp.account_id = a.account_id
       AND lp.pool_id    = a.pool_id;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_lp_position_on_history ON lp_position_history;  -- old single trigger
DROP TRIGGER IF EXISTS trg_fill_lp_cost_basis     ON lp_position_history;
DROP TRIGGER IF EXISTS trg_apply_lp_position      ON lp_position_history;
DROP TRIGGER IF EXISTS trg_refresh_lp_position_cost_basis ON lp_position_history;

CREATE TRIGGER trg_fill_lp_cost_basis
    BEFORE INSERT ON lp_position_history
    FOR EACH ROW EXECUTE FUNCTION fill_lp_cost_basis();

CREATE TRIGGER trg_apply_lp_position
    AFTER INSERT ON lp_position_history
    FOR EACH ROW EXECUTE FUNCTION apply_lp_position();

CREATE TRIGGER trg_refresh_lp_position_cost_basis
    AFTER INSERT ON lp_position_history
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION refresh_lp_position_cost_basis();

-- ---------------------------------------------------------------------------
-- View: lp_position_cost_basis
--
-- Per-row derived cost basis for mint and burn events. The materialize
-- trigger above writes the same math into lp_position_history's token/USD
-- columns; this view stays as the canonical SQL definition of the math
-- (used by the one-time backfill below and by ad-hoc analytics).
--
-- Mint cost basis:
--   * Each lp_position_history mint row is matched to the dex_mint with the
--     smallest log_index greater than the row's own log_index (router-
--     aggregated multi-mint within a single tx works).
--   * feeTo rows (_mintFee() carve-out from k growth, NOT a deposit) get 0.
--   * Other rows: anchor-residual share-weighted attribution against non-
--     feeTo siblings of the same dex_mint. The LARGEST non-feeTo recipient
--     (by lp_in DESC, tie-break log_index ASC) absorbs the leftover wei so
--     Σ token0_in / token1_in over recipients = dex_mint.amount EXACTLY.
--
-- Burn cost basis:
--   * Full attribution to the single dex_burn row (matched by smallest
--     log_index > row.log_index, same rule as mint).
--
-- USD columns stay with ROUND(..., 10): naturally fractional, no wei-
-- integer conservation needed.
--
-- feeTo = factory(0x59c51c66...).feeTo() on testnet. Hardcoded SQL constant
-- for v1; move to a protocol_config table if the factory ever rotates feeTo.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS lp_position_cost_basis;
CREATE VIEW lp_position_cost_basis AS
WITH mint_with_dm AS (
    SELECT
        ph.account_id,
        ph.pool_id,
        ph.transaction_hash,
        ph.tx_index,
        ph.log_index,
        ph.event_type,
        ph.lp_in,
        dm.amount0    AS dm_amount0,
        dm.amount1    AS dm_amount1,
        dm.value      AS dm_value,
        dm.token0_usd AS dm_token0_usd,
        dm.token1_usd AS dm_token1_usd,
        dm.log_index  AS dm_log_index
      FROM lp_position_history ph
      JOIN LATERAL (
          SELECT *
            FROM dex_mint
           WHERE pool_id = ph.pool_id
             AND transaction_hash = ph.transaction_hash
             AND log_index > ph.log_index
           ORDER BY log_index ASC LIMIT 1
      ) dm ON true
     WHERE ph.event_type = 'mint'
),
mint_truncs AS (
    SELECT
        ph.account_id,
        ph.pool_id,
        ph.transaction_hash,
        ph.tx_index,
        ph.log_index,
        ph.event_type,
        ph.lp_in,
        ph.dm_amount0,
        ph.dm_amount1,
        ph.dm_value,
        ph.dm_token0_usd,
        ph.dm_token1_usd,
        ph.dm_log_index,
        r.real_lp,
        -- TRUNC of share-weighted amount: each non-feeTo recipient's wei-integer floor.
        -- feeTo rows zeroed (consistent with existing carve-out semantics).
        CASE WHEN LOWER(ph.account_id) = '0x715103eeeac12fb84f5d3b35c3268dd767fa8b8a' THEN 0
             ELSE TRUNC(ph.lp_in * ph.dm_amount0 / NULLIF(r.real_lp, 0))
        END AS t0_trunc,
        CASE WHEN LOWER(ph.account_id) = '0x715103eeeac12fb84f5d3b35c3268dd767fa8b8a' THEN 0
             ELSE TRUNC(ph.lp_in * ph.dm_amount1 / NULLIF(r.real_lp, 0))
        END AS t1_trunc,
        -- Anchor row selection: the LARGEST non-feeTo recipient in this
        -- (pool, tx, dex_mint) group. Tie-break by log_index ASC. feeTo
        -- rows pushed to the end (rn never == 1 for them, so they never
        -- receive the residual).
        ROW_NUMBER() OVER (
            PARTITION BY ph.pool_id, ph.transaction_hash, ph.dm_log_index
            ORDER BY
                CASE WHEN LOWER(ph.account_id) = '0x715103eeeac12fb84f5d3b35c3268dd767fa8b8a' THEN 1 ELSE 0 END,
                ph.lp_in DESC,
                ph.log_index ASC
        ) AS anchor_rn
      FROM mint_with_dm ph
      JOIN LATERAL (
          SELECT COALESCE(SUM(sib.lp_in), 0) AS real_lp
            FROM mint_with_dm sib
           WHERE sib.pool_id = ph.pool_id
             AND sib.transaction_hash = ph.transaction_hash
             AND sib.dm_log_index = ph.dm_log_index
             AND LOWER(sib.account_id) <> '0x715103eeeac12fb84f5d3b35c3268dd767fa8b8a'
      ) r ON true
),
mint_costs AS (
    SELECT
        mt.account_id,
        mt.pool_id,
        mt.transaction_hash,
        mt.tx_index,
        mt.log_index,
        mt.event_type,
        -- Anchor-residual: the largest non-feeTo recipient (anchor_rn=1)
        -- absorbs the leftover wei so Σ over recipients = full amount.
        -- feeTo rows stay at 0 (already zeroed in t0_trunc/t1_trunc).
        -- Residual sum window MUST match the anchor partition: one residual per
        -- dex_mint event, not per tx. A router-aggregated tx can hold multiple
        -- dex_mints, each with its own dm_amount0 and its own anchor — they
        -- must NOT share a residual pool.
        CASE WHEN LOWER(mt.account_id) = '0x715103eeeac12fb84f5d3b35c3268dd767fa8b8a' THEN 0
             WHEN mt.anchor_rn = 1
                 THEN mt.t0_trunc + (mt.dm_amount0 - SUM(mt.t0_trunc) OVER (
                        PARTITION BY mt.pool_id, mt.transaction_hash, mt.dm_log_index))
             ELSE mt.t0_trunc
        END AS token0_in,
        CASE WHEN LOWER(mt.account_id) = '0x715103eeeac12fb84f5d3b35c3268dd767fa8b8a' THEN 0
             WHEN mt.anchor_rn = 1
                 THEN mt.t1_trunc + (mt.dm_amount1 - SUM(mt.t1_trunc) OVER (
                        PARTITION BY mt.pool_id, mt.transaction_hash, mt.dm_log_index))
             ELSE mt.t1_trunc
        END AS token1_in,
        -- USD columns keep ROUND(..., 10): naturally fractional, no need for
        -- wei-integer conservation (USD is cents/sub-cents, not raw wei).
        CASE WHEN LOWER(mt.account_id) = '0x715103eeeac12fb84f5d3b35c3268dd767fa8b8a' THEN 0
             ELSE ROUND(mt.lp_in * COALESCE(mt.dm_token0_usd, 0) / NULLIF(mt.real_lp, 0), 10)
        END AS token0_in_usd,
        CASE WHEN LOWER(mt.account_id) = '0x715103eeeac12fb84f5d3b35c3268dd767fa8b8a' THEN 0
             ELSE ROUND(mt.lp_in * COALESCE(mt.dm_token1_usd, 0) / NULLIF(mt.real_lp, 0), 10)
        END AS token1_in_usd,
        CASE WHEN LOWER(mt.account_id) = '0x715103eeeac12fb84f5d3b35c3268dd767fa8b8a' THEN 0
             ELSE ROUND(mt.lp_in * COALESCE(mt.dm_value, 0) / NULLIF(mt.real_lp, 0), 10)
        END AS lp_in_usd,
        0::NUMERIC AS token0_out,
        0::NUMERIC AS token1_out,
        0::NUMERIC AS token0_out_usd,
        0::NUMERIC AS token1_out_usd,
        0::NUMERIC AS lp_out_usd
      FROM mint_truncs mt
),
burn_costs AS (
    SELECT
        ph.account_id,
        ph.pool_id,
        ph.transaction_hash,
        ph.tx_index,
        ph.log_index,
        ph.event_type,
        0::NUMERIC AS token0_in,
        0::NUMERIC AS token1_in,
        0::NUMERIC AS token0_in_usd,
        0::NUMERIC AS token1_in_usd,
        0::NUMERIC AS lp_in_usd,
        db.amount0 AS token0_out,
        db.amount1 AS token1_out,
        ROUND(COALESCE(db.token0_usd, 0), 10) AS token0_out_usd,
        ROUND(COALESCE(db.token1_usd, 0), 10) AS token1_out_usd,
        ROUND(COALESCE(db.value,      0), 10) AS lp_out_usd
      FROM lp_position_history ph
      JOIN LATERAL (
          SELECT *
            FROM dex_burn
           WHERE pool_id = ph.pool_id
             AND transaction_hash = ph.transaction_hash
             AND log_index > ph.log_index
           ORDER BY log_index ASC LIMIT 1
      ) db ON true
     WHERE ph.event_type = 'burn'
)
SELECT * FROM mint_costs
UNION ALL
SELECT * FROM burn_costs;

-- ---------------------------------------------------------------------------
-- One-time backfill: rebuild token/USD columns on lp_position_history
-- (per-row, via the same share-weighted view math) and on lp_position
-- (aggregate, via SUM-from-history). Idempotent — re-running on
-- already-correct data is a no-op.
-- ---------------------------------------------------------------------------

-- Defensive zero-reset before the selective view-based UPDATEs below.
-- Older revisions of this file (or older trigger logic) may have left stale
-- values on non-mint or non-burn rows (e.g. token0_out on a 'mint' row from
-- a pre-PR-#216 trigger). The selective backfill that follows only touches
-- mint-side cols on mint rows and burn-side cols on burn rows; without this
-- reset, the aggregate SUM-from-history would re-materialize the stale
-- values into lp_position. No-op on fresh DBs and on already-correct rows.
UPDATE lp_position_history SET
    token0_in      = 0, token0_out      = 0,
    token1_in      = 0, token1_out      = 0,
    token0_in_usd  = 0, token0_out_usd  = 0,
    token1_in_usd  = 0, token1_out_usd  = 0,
    lp_in_usd      = 0, lp_out_usd      = 0;

-- Backfill lp_position_history.token cols for ALL mint rows using the view
-- definition (which already encodes share-weighted feeTo-zero math).
UPDATE lp_position_history h
   SET token0_in     = v.token0_in,
       token1_in     = v.token1_in,
       token0_in_usd = v.token0_in_usd,
       token1_in_usd = v.token1_in_usd,
       lp_in_usd     = v.lp_in_usd
  FROM lp_position_cost_basis v
 WHERE h.event_type       = 'mint'
   AND h.account_id       = v.account_id
   AND h.pool_id          = v.pool_id
   AND h.transaction_hash = v.transaction_hash
   AND h.tx_index         = v.tx_index
   AND h.log_index        = v.log_index;

UPDATE lp_position_history h
   SET token0_out     = v.token0_out,
       token1_out     = v.token1_out,
       token0_out_usd = v.token0_out_usd,
       token1_out_usd = v.token1_out_usd,
       lp_out_usd     = v.lp_out_usd
  FROM lp_position_cost_basis v
 WHERE h.event_type       = 'burn'
   AND h.account_id       = v.account_id
   AND h.pool_id          = v.pool_id
   AND h.transaction_hash = v.transaction_hash
   AND h.tx_index         = v.tx_index
   AND h.log_index        = v.log_index;

-- Backfill epoch_start_* on every existing lp_position row to the start of
-- its CURRENT OPEN epoch. Without this, existing rows would have
-- epoch_start_* = 0 (column default) and the aggregate below would sum
-- across closed past epochs. The current-open-epoch start is the most
-- recent history row where running balance transitioned from 0 to >0.
WITH running_after AS (
    SELECT account_id, pool_id, block_number, tx_index, log_index,
           SUM(lp_in - lp_out) OVER (
               PARTITION BY account_id, pool_id
               ORDER BY block_number, tx_index, log_index
           ) AS bal_after
      FROM lp_position_history
),
running_pair AS (
    SELECT account_id, pool_id, block_number, tx_index, log_index, bal_after,
           COALESCE(LAG(bal_after) OVER (
               PARTITION BY account_id, pool_id
               ORDER BY block_number, tx_index, log_index
           ), 0) AS bal_before
      FROM running_after
),
epoch_starts AS (
    SELECT DISTINCT ON (account_id, pool_id)
           account_id, pool_id, block_number, tx_index, log_index
      FROM running_pair
     WHERE bal_before = 0 AND bal_after > 0
     ORDER BY account_id, pool_id, block_number DESC, tx_index DESC, log_index DESC
)
UPDATE lp_position lp
   SET epoch_start_block     = es.block_number,
       epoch_start_tx_index  = es.tx_index,
       epoch_start_log_index = es.log_index
  FROM epoch_starts es
 WHERE lp.account_id = es.account_id
   AND lp.pool_id    = es.pool_id;

-- Backfill lp_position aggregate from history (now epoch-bounded).
UPDATE lp_position lp
   SET token0_in      = agg.token0_in,
       token0_out     = agg.token0_out,
       token1_in      = agg.token1_in,
       token1_out     = agg.token1_out,
       token0_in_usd  = agg.token0_in_usd,
       token0_out_usd = agg.token0_out_usd,
       token1_in_usd  = agg.token1_in_usd,
       token1_out_usd = agg.token1_out_usd,
       lp_in_usd      = agg.lp_in_usd,
       lp_out_usd     = agg.lp_out_usd
  FROM (
      SELECT h.account_id, h.pool_id,
             SUM(h.token0_in)      AS token0_in,
             SUM(h.token0_out)     AS token0_out,
             SUM(h.token1_in)      AS token1_in,
             SUM(h.token1_out)     AS token1_out,
             SUM(h.token0_in_usd)  AS token0_in_usd,
             SUM(h.token0_out_usd) AS token0_out_usd,
             SUM(h.token1_in_usd)  AS token1_in_usd,
             SUM(h.token1_out_usd) AS token1_out_usd,
             SUM(h.lp_in_usd)      AS lp_in_usd,
             SUM(h.lp_out_usd)     AS lp_out_usd
        FROM lp_position_history h
        JOIN lp_position lp2
          ON lp2.account_id = h.account_id AND lp2.pool_id = h.pool_id
       WHERE (h.block_number, h.tx_index, h.log_index)
           >= (lp2.epoch_start_block, lp2.epoch_start_tx_index, lp2.epoch_start_log_index)
       GROUP BY h.account_id, h.pool_id
  ) agg
 WHERE lp.account_id = agg.account_id
   AND lp.pool_id    = agg.pool_id;


-- ============================================================================
-- >>> 0027_pool_fee_hourly.sql
-- ============================================================================

-- 0027_pool_fee_hourly.sql
--
-- V2 LP fee accrual & APR tracking. See:
--   docs/superpowers/specs/2026-05-20-v2-lp-fee-apr-tracking-design.md
--
-- (1) pool: baseline columns
ALTER TABLE pool ADD COLUMN IF NOT EXISTS last_sqrt_k         NUMERIC NOT NULL DEFAULT 0; -- ratio (raw); sqrt(reserve0*reserve1), geometric mean of token-raw (wei) reserves — fee-accrual baseline
ALTER TABLE pool ADD COLUMN IF NOT EXISTS last_sync_at        BIGINT  NOT NULL DEFAULT 0; -- unix seconds (last sync block timestamp)
ALTER TABLE pool ADD COLUMN IF NOT EXISTS last_sync_block     BIGINT  NOT NULL DEFAULT 0;
ALTER TABLE pool ADD COLUMN IF NOT EXISTS last_sync_tx_index  INT     NOT NULL DEFAULT 0;
ALTER TABLE pool ADD COLUMN IF NOT EXISTS last_sync_log_index INT     NOT NULL DEFAULT 0;

-- (2) hourly bucket
CREATE TABLE IF NOT EXISTS pool_fee_hourly (
    pool_id        VARCHAR(42) NOT NULL,
    bucket_hour    BIGINT      NOT NULL, -- unix-hours (created_at / 3600)
    fee_token0     NUMERIC     NOT NULL DEFAULT 0, -- token raw (wei) of token0; share_growth * reserve0
    fee_token1     NUMERIC     NOT NULL DEFAULT 0, -- token raw (wei) of token1; share_growth * reserve1
    fee_usd        NUMERIC     NOT NULL DEFAULT 0, -- USD (human); share_growth * (token0_usd + token1_usd)
    tvl_usd_sum    NUMERIC     NOT NULL DEFAULT 0, -- USD (human); sum of per-sync TVL (token0_usd+token1_usd), avg via /sample_count
    sample_count   INT         NOT NULL DEFAULT 0,
    updated_at     BIGINT      NOT NULL DEFAULT EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT, -- unix seconds (last write)
    PRIMARY KEY (pool_id, bucket_hour)
);
CREATE INDEX IF NOT EXISTS idx_pool_fee_hourly_pool_hour
    ON pool_fee_hourly (pool_id, bucket_hour DESC);
CREATE INDEX IF NOT EXISTS idx_pool_fee_hourly_hour
    ON pool_fee_hourly (bucket_hour DESC);

-- (3) trigger function: sqrt(k) ratio fee accrual.
--
-- Algorithm:
--   share_growth = sqrt(k_new) / sqrt(k_old) - 1
--   fee_usd      = share_growth * (token0_usd + token1_usd)
--   fee_token0/1 = share_growth * reserve0/1  (share-growth equivalent)
--
-- Three correctness guards (codex P1+P2 fixes):
--   (a) Application-level serialization: process_raw_dex_events awaits
--       dex_mint/dex_burn inserts BEFORE dex_sync, so the LEFT JOIN below
--       is race-free in production.
--   (b) LAG runs over ALL syncs (mint/burn-blocked included). The
--       blocked predicate filters fee_rows only — blocked syncs still
--       advance the intra-batch baseline for the next swap.
--   (c) Baseline UPDATE and pool.last_sqrt_k fallback are guarded by an
--       on-chain freshness tuple (block_number, tx_index, log_index) so
--       out-of-order/reconnect-overlap inserts can't rewind the baseline
--       or accrue fee against a stale starting point.
CREATE OR REPLACE FUNCTION update_pool_fee_accrual()
RETURNS TRIGGER AS $$
BEGIN
    WITH
    -- 1) For each sync mark whether it's mint/burn-blocked (LEFT JOIN match).
    annotated AS (
        SELECT
            s.pool_id, s.reserve0, s.reserve1, s.created_at,
            s.block_number, s.tx_index, s.log_index,
            s.token0_usd, s.token1_usd,
            (m.pool_id IS NOT NULL OR b.pool_id IS NOT NULL) AS is_blocked
        FROM new_dex_syncs s
        LEFT JOIN dex_mint m
            ON m.pool_id = s.pool_id
           AND m.transaction_hash = s.transaction_hash
        LEFT JOIN dex_burn b
            ON b.pool_id = s.pool_id
           AND b.transaction_hash = s.transaction_hash
    ),
    -- 2) Order ALL syncs (blocked + not) and compute LAG so a blocked
    --    sync's post-mint/burn reserves still serve as baseline for the
    --    next swap in the same batch.
    ordered AS (
        SELECT
            a.*,
            sqrt(a.reserve0 * a.reserve1) AS sqrt_k_new,
            LAG(sqrt(a.reserve0 * a.reserve1)) OVER w AS sqrt_k_old_intra,
            (SELECT p.last_sqrt_k FROM pool p WHERE p.pool_id = a.pool_id) AS sqrt_k_pool,
            (SELECT (p.last_sync_block, p.last_sync_tx_index, p.last_sync_log_index)
               FROM pool p WHERE p.pool_id = a.pool_id) AS pool_freshness
        FROM annotated a
        WINDOW w AS (
            PARTITION BY a.pool_id
            ORDER BY a.block_number, a.tx_index, a.log_index
        )
    ),
    -- 3) fee_rows: non-blocked syncs that are fresher than pool baseline
    --    AND whose sqrt_k strictly increased. The intra-batch LAG is
    --    preferred; cross-batch fallback uses pool.last_sqrt_k but only
    --    when this sync is fresher than the stored baseline.
    fee_rows AS (
        SELECT
            pool_id,
            (created_at / 3600)::BIGINT                      AS bucket_hour,
            (sqrt_k_new / sqrt_k_old - 1) * reserve0         AS fee_token0,
            (sqrt_k_new / sqrt_k_old - 1) * reserve1         AS fee_token1,
            (sqrt_k_new / sqrt_k_old - 1) * (token0_usd + token1_usd) AS fee_usd,
            (token0_usd + token1_usd)                        AS tvl_usd_at_evt
        FROM (
            SELECT
                pool_id, reserve0, reserve1, created_at, token0_usd, token1_usd, sqrt_k_new,
                COALESCE(
                    sqrt_k_old_intra,
                    CASE WHEN (block_number, tx_index, log_index) > pool_freshness
                         THEN sqrt_k_pool
                    END
                ) AS sqrt_k_old,
                is_blocked
            FROM ordered
        ) x
        WHERE NOT is_blocked
          AND sqrt_k_old IS NOT NULL
          AND sqrt_k_old > 0
          AND sqrt_k_new > sqrt_k_old
    )
    INSERT INTO pool_fee_hourly (
        pool_id, bucket_hour, fee_token0, fee_token1, fee_usd, tvl_usd_sum, sample_count, updated_at
    )
    SELECT
        pool_id, bucket_hour,
        SUM(fee_token0), SUM(fee_token1), SUM(fee_usd),
        SUM(tvl_usd_at_evt), COUNT(*)::INT,
        EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)::BIGINT
    FROM fee_rows
    GROUP BY pool_id, bucket_hour
    ON CONFLICT (pool_id, bucket_hour) DO UPDATE SET
        fee_token0   = pool_fee_hourly.fee_token0   + EXCLUDED.fee_token0,
        fee_token1   = pool_fee_hourly.fee_token1   + EXCLUDED.fee_token1,
        fee_usd      = pool_fee_hourly.fee_usd      + EXCLUDED.fee_usd,
        tvl_usd_sum  = pool_fee_hourly.tvl_usd_sum  + EXCLUDED.tvl_usd_sum,
        sample_count = pool_fee_hourly.sample_count + EXCLUDED.sample_count,
        updated_at   = EXCLUDED.updated_at;

    -- 4) Baseline 갱신 — freshness guard prevents reconnect/overlap from
    --    rewinding pool.last_* to an older sync. Blocked syncs (mint/burn)
    --    still advance the baseline so the next swap measures correctly.
    UPDATE pool p
       SET last_sqrt_k         = d.sqrt_k_new,
           last_sync_at        = d.created_at,
           last_sync_block     = d.block_number,
           last_sync_tx_index  = d.tx_index,
           last_sync_log_index = d.log_index
      FROM (
          SELECT DISTINCT ON (pool_id)
                 pool_id, sqrt(reserve0 * reserve1) AS sqrt_k_new,
                 created_at, block_number, tx_index, log_index
            FROM new_dex_syncs
           ORDER BY pool_id, block_number DESC, tx_index DESC, log_index DESC
      ) d
     WHERE p.pool_id = d.pool_id
       AND (d.block_number, d.tx_index, d.log_index)
           > (p.last_sync_block, p.last_sync_tx_index, p.last_sync_log_index);

    -- 5) WARNING for sqrt_k decrease without a mint/burn — likely a missed
    --    LP-supply-change indexing or chain reorg.
    PERFORM 1
      FROM new_dex_syncs s
      JOIN pool p ON p.pool_id = s.pool_id
     WHERE p.last_sqrt_k > 0
       AND sqrt(s.reserve0 * s.reserve1) < p.last_sqrt_k
       AND NOT EXISTS (
           SELECT 1 FROM dex_mint m
            WHERE m.pool_id = s.pool_id AND m.transaction_hash = s.transaction_hash
       )
       AND NOT EXISTS (
           SELECT 1 FROM dex_burn b
            WHERE b.pool_id = s.pool_id AND b.transaction_hash = s.transaction_hash
       );
    IF FOUND THEN
        RAISE WARNING 'pool_fee_accrual: sqrt_k decreased without mint/burn (mint/burn missing?)';
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- 트리거 이름은 알파벳상 reserve trigger 보다 먼저 실행되도록 'a_' prefix.
DROP TRIGGER IF EXISTS a_trg_update_pool_fee_accrual ON dex_sync;
CREATE TRIGGER a_trg_update_pool_fee_accrual
    AFTER INSERT ON dex_sync
    REFERENCING NEW TABLE AS new_dex_syncs
    FOR EACH STATEMENT
    EXECUTE FUNCTION update_pool_fee_accrual();

-- (4) pool_apr view
--
-- Two fee scales exposed:
--   * fee_*_usd  / fee_*_token{0,1}  = gross pool-level fee retained in
--     reserves (every basis point of LP_FEE_RATE = 25 BPS = 0.25%).
--   * lp_fee_*   = LP-holder net share = gross × LP_SHARE_FACTOR (0.8).
--
-- Why 0.8: NadFunPair._mintFee uses `rootK * 4 + rootKLast` as the
-- carve-out denominator (vs Uniswap V2 standard `rootK * 5 + rootKLast`).
-- When factory.feeTo() != address(0) — the active configuration on this
-- deployment — that mints (√k_new - √k_last) / (5 × √k_new) of total LP
-- to the protocol at the next mint/burn, capturing 1/5 = 20% of accrued
-- fees and leaving LP holders with 80%. If feeTo is ever rotated to
-- address(0) this overstates protocol cut by 20% (LP would see full
-- gross); revisit then.
CREATE OR REPLACE VIEW pool_apr AS
WITH now_h AS (SELECT (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) / 3600)::BIGINT AS h),
     params AS (SELECT 0.8::numeric AS lp_share_factor)
SELECT
    f.pool_id,
    SUM(f.fee_usd) FILTER (WHERE f.bucket_hour >= now_h.h - 24)        AS fee_24h_usd,
    SUM(f.fee_usd) FILTER (WHERE f.bucket_hour >= now_h.h - 24*7)      AS fee_7d_usd,
    SUM(f.fee_usd) FILTER (WHERE f.bucket_hour >= now_h.h - 24*30)     AS fee_30d_usd,
    SUM(f.fee_token0) FILTER (WHERE f.bucket_hour >= now_h.h - 24)     AS fee_24h_token0,
    SUM(f.fee_token1) FILTER (WHERE f.bucket_hour >= now_h.h - 24)     AS fee_24h_token1,
    SUM(f.fee_token0) FILTER (WHERE f.bucket_hour >= now_h.h - 24*7)   AS fee_7d_token0,
    SUM(f.fee_token1) FILTER (WHERE f.bucket_hour >= now_h.h - 24*7)   AS fee_7d_token1,
    SUM(f.fee_token0) FILTER (WHERE f.bucket_hour >= now_h.h - 24*30)  AS fee_30d_token0,
    SUM(f.fee_token1) FILTER (WHERE f.bucket_hour >= now_h.h - 24*30)  AS fee_30d_token1,
    -- LP-net (after _mintFee 20% protocol carve-out)
    params.lp_share_factor * SUM(f.fee_usd) FILTER (WHERE f.bucket_hour >= now_h.h - 24)
        AS lp_fee_24h_usd,
    params.lp_share_factor * SUM(f.fee_usd) FILTER (WHERE f.bucket_hour >= now_h.h - 24*7)
        AS lp_fee_7d_usd,
    params.lp_share_factor * SUM(f.fee_usd) FILTER (WHERE f.bucket_hour >= now_h.h - 24*30)
        AS lp_fee_30d_usd,
    params.lp_share_factor AS lp_share_factor,
    SUM(f.tvl_usd_sum) FILTER (WHERE f.bucket_hour >= now_h.h - 24)
        / NULLIF(SUM(f.sample_count) FILTER (WHERE f.bucket_hour >= now_h.h - 24), 0)
        AS tvl_24h_usd_avg,
    SUM(f.tvl_usd_sum) FILTER (WHERE f.bucket_hour >= now_h.h - 24*7)
        / NULLIF(SUM(f.sample_count) FILTER (WHERE f.bucket_hour >= now_h.h - 24*7), 0)
        AS tvl_7d_usd_avg,
    SUM(f.tvl_usd_sum) FILTER (WHERE f.bucket_hour >= now_h.h - 24*30)
        / NULLIF(SUM(f.sample_count) FILTER (WHERE f.bucket_hour >= now_h.h - 24*30), 0)
        AS tvl_30d_usd_avg
FROM pool_fee_hourly f
CROSS JOIN now_h
CROSS JOIN params
WHERE f.bucket_hour >= now_h.h - 24*30
GROUP BY f.pool_id, now_h.h, params.lp_share_factor;


-- ============================================================================
-- >>> 0028_quote_token_is_native.sql
-- ============================================================================

-- 0028_quote_token_is_native.sql
--
-- Add an `is_native` flag to `quote_token` so the indexer can treat WETH and
-- 1:1 native-pegged wrappers as the same "native" token
-- when propagating chain-implied prices into `token_price_cache`.
--
-- Currently the cache propagation logic hardcodes a single `WNATIVE_ADDRESS`
-- env var: only pools where one side IS that address seed prices, so any pool
-- paired with LVMON (also MON-pegged, also seeded as a quote_token) stays
-- orphan and `dex_swap.value` / `pool.value` end up at 0. With this column
-- the indexer reads "every quote_token where is_native = true" at startup
-- and treats all of them as native-equivalent.
--
-- DEFAULT TRUE: current quote_token only holds the native-pegged WETH row,
-- so backfilling existing data to TRUE is the desired state and avoids a
-- separate UPDATE. Future non-native quotes (USDC, USDT, ...) must INSERT with
-- an explicit `is_native = FALSE`.
--
-- Idempotent: ALTER ... IF NOT EXISTS. Safe to re-run.

ALTER TABLE quote_token
    ADD COLUMN IF NOT EXISTS is_native BOOLEAN NOT NULL DEFAULT TRUE;


-- ============================================================================
-- >>> 0031_whitelist_token.sql
-- ============================================================================

CREATE TABLE IF NOT EXISTS whitelist_token (
    token_id   VARCHAR(42) PRIMARY KEY,
    sort_order INT NOT NULL,
    enabled    BOOLEAN NOT NULL DEFAULT TRUE
);

-- 고정순서: WETH(1), USDC(2), USDT(3), ...
-- NOTE: USDC/USDT GIWA 온체인 주소 미확정 → WETH만 seed, 나머지는 주소 확정 후 후속 커밋.
INSERT INTO whitelist_token (token_id, sort_order) VALUES
    ('0x4200000000000000000000000000000000000006', 1)   -- WETH (quote_token 시드 주소)
ON CONFLICT (token_id) DO NOTHING;


-- ============================================================================
-- >>> 0032_whitelist_token_columns.sql
-- ============================================================================

-- whitelist_token: CMS 큐레이션 컬럼 추가 (0031 CREATE 이후 append-only).
--   price_feed_id : Pyth Hermes feed id. NULL이면 가격 미조회 → balance_usd null.
--   name/symbol/image_uri/decimals : 표시·계산 메타. 값이 있으면 우선,
--                                    NULL이면 token/dex_token/quote_token에서 fallback.
-- 기존 DB는 0032만 새로 적용(0031 체크섬 불변). 모두 IF NOT EXISTS라 idempotent.
ALTER TABLE whitelist_token
    ADD COLUMN IF NOT EXISTS price_feed_id VARCHAR,
    ADD COLUMN IF NOT EXISTS name          VARCHAR,
    ADD COLUMN IF NOT EXISTS symbol        VARCHAR,
    ADD COLUMN IF NOT EXISTS image_uri     VARCHAR,
    ADD COLUMN IF NOT EXISTS decimals      INT;


-- ============================================================================
-- >>> 0033_dex_token_price.sql
-- ============================================================================

-- 0033_dex_token_price.sql
--
-- dex_token_price: per-token USD unit price, taken from the deepest-TVL pool
-- the token trades in. Read-time aggregation over pool.token0_price_usd /
-- pool.token1_price_usd (set by the observer's RawSync inference; columns added
-- in 0014_dex.sql). pool is the single source, so no denormalized column and no
-- trigger/indexer write is needed — the view is always consistent with the
-- latest synced prices.
--
-- Selection: DISTINCT ON (token_id) ORDER BY value DESC picks the token's price
-- from the pool where it holds the largest USD TVL (most liquid = canonical
-- market price, manipulation-resistant). Ties are broken by latest_trade_at
-- then pool_id so output is deterministic (no flapping between equal-TVL pools).
--
-- Coverage: a token appears only when at least one of its pools has a non-NULL
-- side price. The NULL side of a half-priced pool drops out of the UNION, and
-- orphan tokens (no WMON-reachable price) have no row at all — callers read
-- "no row" as price unknown (NULL).
--
-- Consumers: api-server /dex/tokens resolves price_usd as
--   COALESCE(dex_token_price.price_usd, market.price * quote->USD)
-- i.e. this pool-view first, legacy market path as fallback.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW dex_token_price AS
SELECT DISTINCT ON (token_id)
       token_id,
       price_usd,
       pool_id,            -- source pool (debug / trace)
       value AS pool_value
FROM (
    SELECT token0 AS token_id, token0_price_usd AS price_usd,
           pool_id, value, latest_trade_at
    FROM pool
    WHERE token0_price_usd IS NOT NULL
    UNION ALL
    SELECT token1 AS token_id, token1_price_usd AS price_usd,
           pool_id, value, latest_trade_at
    FROM pool
    WHERE token1_price_usd IS NOT NULL
) t
ORDER BY token_id, value DESC NULLS LAST, latest_trade_at DESC, pool_id;


-- ============================================================================
-- >>> 0034_price_usd.sql
-- ============================================================================

-- 0034_price_usd.sql
--
-- price_usd: per-(whitelist token, block) USD unit price sourced from the
-- DefiLlama coins API (free tier). SEPARATE from `price` (Pyth, quote_token,
-- indexing path) — price_usd feeds downstream `balance_usd` display only and is
-- NOT read by get_quote_usd_price / forward-propagation.
--
-- Block-keyed dense (mirrors `price`, 0007_price.sql): the observer price_usd
-- refresher writes one row per block for each enabled whitelist_token, applying
-- the latest DefiLlama price (fetched at most once / 60s) to every block in the
-- elapsed range, so there are no gap blocks. `created_at` = block_timestamp
-- (same meaning as in `price`). `confidence` = DefiLlama 0..1 quality score
-- (NULL permitted).
--
-- Read contract (downstream balance_usd):
--   latest   : ORDER BY block_number DESC LIMIT 1
--   as-of(b) : WHERE block_number <= b ORDER BY block_number DESC LIMIT 1
--              (carry-forward — never a future price).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS price_usd (
    token_id     VARCHAR(42) NOT NULL,
    block_number BIGINT      NOT NULL,
    price        NUMERIC     NOT NULL,   -- USD unit price (DefiLlama)
    confidence   NUMERIC,                -- DefiLlama confidence (0..1), NULL allowed
    created_at   BIGINT      NOT NULL,   -- block_timestamp
    PRIMARY KEY (token_id, block_number)
);

CREATE INDEX IF NOT EXISTS idx_price_usd_token_block ON price_usd (token_id, block_number DESC);


-- ============================================================================
-- >>> 0035_whitelist_price_source_id.sql
-- ============================================================================

-- 0035_whitelist_price_source_id.sql
--
-- Add `price_source_id` to whitelist_token: the address used to QUERY DefiLlama
-- for this token's USD price, decoupled from `token_id` (the on-chain address
-- that is the price_usd storage / join key for this deployment).
--
-- DefiLlama only knows major-chain MAINNET addresses (ethereum for GIWA tokens). On testnet, pools and balances
-- reference mock token addresses DefiLlama cannot price, so `token_id` holds the
-- testnet mock address and `price_source_id` holds the mainnet equivalent. On
-- mainnet, `price_source_id` stays NULL and the indexer falls back to token_id.
--
-- Indexer rule (src/event/common/price_usd):
--   DefiLlama coin ref = COALESCE(NULLIF(price_source_id, ''), token_id)
--   price_usd rows are stored under token_id.
-- Multiple tokens may share one price_source_id (multiple native-pegged tokens
-- may price via one mainnet address), so a single fetched price fans out to several tokens.
--
-- NULL default: mainnet rows need no value. Per-environment data seeding
-- (testnet token_id remap + price_source_id) is applied separately, not here.
-- Idempotent: ADD COLUMN IF NOT EXISTS. Safe to re-run.

ALTER TABLE whitelist_token
    ADD COLUMN IF NOT EXISTS price_source_id VARCHAR(42);


-- ============================================================================
-- >>> 0036_token_chain.sql
-- ============================================================================

BEGIN;

ALTER TABLE token
    ADD COLUMN IF NOT EXISTS chain VARCHAR;

UPDATE token
SET chain = 'MON'
WHERE chain IS NULL;

ALTER TABLE token
    ALTER COLUMN chain SET DEFAULT 'MON';

ALTER TABLE token
    ALTER COLUMN chain SET NOT NULL;

COMMIT;

