-- GIWA Observer fresh-database schema.

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

-- Retained CMS analytics source, maintained by the swap trigger below.
CREATE TABLE IF NOT EXISTS account_activity (
    account_id VARCHAR(42) PRIMARY KEY,
    first_swap_at BIGINT NOT NULL,
    last_swap_at BIGINT NOT NULL,
    total_swap_count BIGINT NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_account_activity_first_swap
    ON account_activity (first_swap_at);
CREATE INDEX IF NOT EXISTS idx_account_activity_last_swap
    ON account_activity (last_swap_at);

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

-- API Search 모듈 최적화: Twitter 핸들 검색 시 account 테이블과의 JOIN 성능을 위한 인덱스


-- Search 모듈 최적화: Twitter 핸들 gin_trgm_ops 조회하는 쿼리용 인덱스



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

    token_holder_count BIGINT NOT NULL DEFAULT 0
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
    market_type VARCHAR NOT NULL CHECK (market_type IN ('CURVE', 'DEX')),
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
    market_type VARCHAR NOT NULL CHECK (market_type IN ('CURVE', 'DEX')),
    is_buy BOOLEAN NOT NULL,
    quote_amount NUMERIC NOT NULL,   -- UNIT: quote raw (wei); buy amount_in or sell amount_out
    token_amount NUMERIC NOT NULL,   -- UNIT: token raw (wei); buy amount_out or sell amount_in
    reserve_quote NUMERIC NULL,   -- UNIT: quote raw (wei); curve/pool quote reserve snapshot
    reserve_token NUMERIC NULL,   -- UNIT: token raw (wei); curve/pool token reserve snapshot
    value NUMERIC NOT NULL DEFAULT 0,   -- UNIT: USD (human); quote_amount / 10^decimals * USD-per-quote price
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

-- Maintain first/last swap timestamps for retained CMS analytics.
CREATE OR REPLACE FUNCTION update_account_activity_on_swap()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO account_activity (account_id, first_swap_at, last_swap_at, total_swap_count)
    VALUES (NEW.account_id, NEW.created_at, NEW.created_at, 1)
    ON CONFLICT (account_id) DO UPDATE SET
        last_swap_at = GREATEST(account_activity.last_swap_at, EXCLUDED.last_swap_at),
        first_swap_at = LEAST(account_activity.first_swap_at, EXCLUDED.first_swap_at),
        total_swap_count = account_activity.total_swap_count + 1;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_account_activity_on_swap ON swap;
CREATE TRIGGER trg_account_activity_on_swap
    AFTER INSERT ON swap
    FOR EACH ROW
    EXECUTE FUNCTION update_account_activity_on_swap();



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
    quote_amount NUMERIC NOT NULL,   -- UNIT: quote raw (wei); decoded log amount
    token_amount NUMERIC NOT NULL,   -- UNIT: token raw (wei); decoded log amount
    reserve_quote NUMERIC NOT NULL,   -- UNIT: quote raw (wei); pool reserve snapshot
    reserve_token NUMERIC NOT NULL,   -- UNIT: token raw (wei); pool reserve snapshot
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
    quote_amount NUMERIC NOT NULL,   -- UNIT: quote raw (wei); decoded log amount
    token_amount NUMERIC NOT NULL,   -- UNIT: token raw (wei); decoded log amount
    reserve_quote NUMERIC NOT NULL,   -- UNIT: quote raw (wei); pool reserve snapshot
    reserve_token NUMERIC NOT NULL,   -- UNIT: token raw (wei); pool reserve snapshot
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

-- DISTINCT ON (account_id, token_id) ordered by canonical log coordinates is
-- the "latest balance per (account, token)" query. Without this index the sort spills
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


CREATE OR REPLACE FUNCTION update_token_holder_count()
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
EXECUTE FUNCTION update_token_holder_count();


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


-- ============================================================================
-- >>> 0007_price.sql
-- ============================================================================

-- Price table: multi-quote aware.
-- Supports multiple quote tokens (WMON, USDC, etc.) via a composite
-- primary key (quote_id, block_number). The default quote_id is the
-- GIWA WETH predeploy address used as the default quote token.
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
-- >>> 0013_position.sql
-- ============================================================================

-- Transfer-based position and cash-flow tracking.
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

-- DEX infrastructure: pool pairs, external tokens,
-- fee_config, raw event tables (dex_swap / dex_sync),
-- and the statement-level update_pool_volume() trigger.

-- GIN trigram indexes for /dex/search ILIKE substring acceleration.
-- Requires the pg_trgm extension (already enabled in production per the
-- existing idx_token_*_gin declarations in 0002_token.sql).
-- Keep the canonical dex_token DDL and search indexes together.

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


-- ============================================================================
-- >>> 0015_contract_events.sql
-- ============================================================================

-- Contract event history tables populated from the active on-chain
-- events: BondingCurve, LPManager, FeeCollector, CreatorFeeProcessor,
-- BurnVault, GiftVault, LPVault, CreatorFeeVault.
--
-- All quote_id DEFAULTs are the GIWA WETH predeploy (chain-agnostic
-- OP Stack address, valid on testnet and mainnet).

-- 1. Sniping Penalties (BondingCurve.SnipingFeeCollected)
CREATE TABLE IF NOT EXISTS sniping_history (
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
CREATE INDEX IF NOT EXISTS idx_sniping_history_token ON sniping_history (token_id);

-- 3. Fee Collect History (FeeCollector.Collect)
CREATE TABLE IF NOT EXISTS fee_collect_history (
    token VARCHAR(42) NOT NULL,
    pair VARCHAR(42) NOT NULL,
    quote_id VARCHAR(42) NOT NULL DEFAULT '0x4200000000000000000000000000000000000006',
    amount NUMERIC NOT NULL, -- quote raw (wei): FeeCollector.Collect.amount uint256 (fees denominated in quote_id)
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL,
    created_at BIGINT NOT NULL, -- unix seconds (block timestamp)
    log_index INT NOT NULL,
    tx_index INT NOT NULL,
    PRIMARY KEY (transaction_hash, tx_index, log_index)
);
CREATE INDEX IF NOT EXISTS idx_fee_collect_token ON fee_collect_history (token);
CREATE INDEX IF NOT EXISTS idx_fee_collect_pair ON fee_collect_history (pair);

-- 4. Fee Settle History (FeeCollector.Settle)
CREATE TABLE IF NOT EXISTS fee_settle_history (
    token VARCHAR(42) NOT NULL,
    pair VARCHAR(42) NOT NULL,
    quote_id VARCHAR(42) NOT NULL DEFAULT '0x4200000000000000000000000000000000000006',
    total_fee NUMERIC NOT NULL, -- quote raw (wei): FeeCollector.Settle.totalFee uint256 (fees denominated in quote_id)
    creator_fee NUMERIC NOT NULL, -- quote raw (wei): FeeCollector.Settle.creatorFee uint256 (fees denominated in quote_id)
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL,
    created_at BIGINT NOT NULL, -- unix seconds (block timestamp)
    log_index INT NOT NULL,
    tx_index INT NOT NULL,
    PRIMARY KEY (transaction_hash, tx_index, log_index)
);
CREATE INDEX IF NOT EXISTS idx_fee_settle_token ON fee_settle_history (token);
CREATE INDEX IF NOT EXISTS idx_fee_settle_pair ON fee_settle_history (pair);

-- 5. Creator Fee Distribution (CreatorFeeProcessor.Distribute / CallbackFail)
CREATE TABLE IF NOT EXISTS creator_fee_distribution (
    event_type VARCHAR NOT NULL,
    token VARCHAR(42),
    quote_id VARCHAR(42) NOT NULL DEFAULT '0x4200000000000000000000000000000000000006',
    vault VARCHAR(42),
    amount NUMERIC NOT NULL, -- quote raw (wei): CreatorFeeProcessor.Distribute.amount uint256 (denominated in quote_id; usd_enrich.rs divides by quote decimals)
    usd_value NUMERIC NOT NULL DEFAULT 0, -- USD (human): amount/10^quote_decimals * quote USD price (usd_enrich.rs)
    reason BYTEA,
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL,
    created_at BIGINT NOT NULL, -- unix seconds (block timestamp)
    log_index INT NOT NULL,
    tx_index INT NOT NULL,
    PRIMARY KEY (transaction_hash, tx_index, log_index)
);
CREATE INDEX IF NOT EXISTS idx_creator_fee_dist_token ON creator_fee_distribution (token);


-- Vault event logs, registry, metadata, aggregates, and triggers are defined
-- together in the vault section below.

-- 6. FeeTo Claim History (FeeTo.Claimed)
-- Each row = one successful claim() call on FeeTo. quoteIn fixed at ~1 MON
-- by txbot; quoteOut = excess routed to feeReceiver.
CREATE TABLE IF NOT EXISTS fee_to_claim_history (
    token VARCHAR(42) NOT NULL,
    pair VARCHAR(42) NOT NULL,
    quote_id VARCHAR(42) NOT NULL DEFAULT '0x4200000000000000000000000000000000000006',
    quote_in NUMERIC NOT NULL, -- quote raw (wei): FeeTo.Claimed.quoteIn uint256
    quote_out NUMERIC NOT NULL, -- quote raw (wei): FeeTo.Claimed.quoteOut uint256 (excess routed to feeReceiver)
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL,
    created_at BIGINT NOT NULL, -- unix seconds (block timestamp)
    log_index INT NOT NULL,
    tx_index INT NOT NULL,
    PRIMARY KEY (transaction_hash, tx_index, log_index)
);
CREATE INDEX IF NOT EXISTS idx_fee_to_claim_token ON fee_to_claim_history (token);
CREATE INDEX IF NOT EXISTS idx_fee_to_claim_pair_created ON fee_to_claim_history (pair, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_fee_to_claim_created ON fee_to_claim_history (created_at DESC);

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

ALTER TABLE quote_token
    ADD COLUMN IF NOT EXISTS price_usd_source_id VARCHAR(42);

UPDATE quote_token
SET price_usd_source_id = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'
WHERE LOWER(quote_id) = LOWER('0x4200000000000000000000000000000000000006')
  AND price_usd_source_id IS NULL;

CREATE TABLE IF NOT EXISTS price_usd (
    token_id VARCHAR(42) NOT NULL,
    block_number BIGINT NOT NULL,
    price NUMERIC NOT NULL,
    confidence NUMERIC,
    created_at BIGINT NOT NULL,
    PRIMARY KEY (token_id, block_number)
);

CREATE INDEX IF NOT EXISTS idx_price_usd_token_block
    ON price_usd (token_id, block_number DESC);


-- ============================================================================
-- >>> 0020_gift_tweet.sql
-- ============================================================================

-- =====================================================
-- gift_tweet: producer(트윗 스트림)와 consumer(on-chain setReceiver)
-- 사이의 크래시 안전 버퍼. 추가로 consumer가 setReceiver 성공 직후
-- 프로필 링크로 답글을 다는 reply 워크플로 상태도 같이 보관.
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
-- >>> 0018_api_keys.sql (GIWA identity variant)
-- ============================================================================

-- The retained /api-key API needs this table on fresh databases. GIWA does
-- not install pgactive, so IDs use PostgreSQL's built-in identity generator.
CREATE TABLE IF NOT EXISTS api_keys (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    key_hash VARCHAR(64) NOT NULL UNIQUE,
    key_prefix VARCHAR(12) NOT NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    owner_address VARCHAR(42),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ,
    last_used_at TIMESTAMPTZ,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    request_count BIGINT NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_api_keys_key_hash ON api_keys (key_hash);
CREATE INDEX IF NOT EXISTS idx_api_keys_active
    ON api_keys (is_active)
    WHERE is_active = TRUE;


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
-- DEFAULT TRUE marks the seeded native-pegged WETH row. Future non-native
-- quotes (USDC, USDT, ...) must INSERT with an explicit `is_native = FALSE`.

ALTER TABLE quote_token
    ADD COLUMN IF NOT EXISTS is_native BOOLEAN NOT NULL DEFAULT TRUE;


-- ============================================================================
-- >>> dividend.sql
-- ============================================================================

-- ============================================================================
-- DividendVault indexing schema
--
-- Contract: singleton UUPS DividendVault (one address, all source tokens).
-- Indexed events (5):
--   DividendSetup(sourceToken idx, dividendTokens[], ratios[], minBalance)
--   Deposit(sourceToken idx, dividendTokens[], slices[], pending[])
--   Converted(sourceTokens[], dividendTokens[], consumedQuote[], received[])
--   SetMerkleRoot(merkleRoot idx)
--   Claim(holder idx, sourceTokens[], dividendTokens[], amounts[])
--
-- Contract facts the schema relies on (verified in DividendVault.sol):
--   * setup() is one-time immutable per sourceToken (reverts AlreadyConfigured,
--     DividendVault.sol:93) -> dividend_setups doubles as config lookup.
--   * Deposit fires ONCE per afterDeposit with ALL ratio slices (parallel
--     arrays). For each entry i: slices[i] is the quote-denominated slice and
--     pending[i] = (dividendToken != quoteToken). pending=false -> credited
--     immediately to dividendBalance; pending=true -> accrued to pendingSwap
--     and later consumed by Converted. There is NO balance snapshot field.
--   * Converted does NOT carry the resulting balance -> stats use arithmetic.
--   * claim() does NOT decrement on-chain dividendBalance -> dividend_balance
--     in stats is CUMULATIVE (deposited + converted received), mirroring chain.
--   * Claim amounts[i] == 0 means the item was skipped on-chain (ineligible /
--     already claimed / insufficient vault balance). Zero entries are NOT
--     inserted: this table is PAID claim history, not attempt history.
--
-- Pattern: history INSERT (ON CONFLICT DO NOTHING) -> AFTER INSERT trigger
--          upserts dividend_vault_stats in the same transaction. Trigger
--          fires only on rows actually inserted: insert success -> update.
--          This is REPLAY-idempotent (re-processing the same logs is safe).
--          It is NOT reorg-rollback: orphaned rows are not removed (observer
--          has no rollback machinery anywhere; same property as all tables).
--
-- Insert ordering requirement (controller): within a receive batch,
--   dividend_merkle_roots MUST be inserted BEFORE dividend_claims so the
--   claims' merkle_root insert-time lookup sees roots from the same batch.
--
-- LOCAL-DEV reset note: earlier commits on this branch created the dividend_*
--   tables with the OLD deposit shape (dividend_balance column, 3-col PK). Because
--   the tables use CREATE TABLE IF NOT EXISTS, a dev who ran an earlier branch
--   commit must DROP the dividend_* tables locally before re-running this file
--   — otherwise deposit inserts fail on the missing pending / entry_index columns.
--   Prod has no dividend tables yet, so prod is unaffected (no ALTER needed here).
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1) History: DividendSetup (exploded: one row per dividend token entry)
--    setup() is once-per-source immutable -> also serves as config lookup.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dividend_setups (
    source_token     VARCHAR(42) NOT NULL,
    dividend_token   VARCHAR(42) NOT NULL,
    ratio            INT NOT NULL,            -- BPS (uint16, sums to 10000 per source)
    min_balance      NUMERIC NOT NULL,        -- min sourceToken holding to claim
    entry_index      INT NOT NULL,            -- position in dividendTokens[]
    transaction_hash VARCHAR NOT NULL,
    block_number     BIGINT NOT NULL,
    created_at       BIGINT NOT NULL,         -- block timestamp
    log_index        INT NOT NULL,
    tx_index         INT NOT NULL,
    PRIMARY KEY (transaction_hash, tx_index, log_index, entry_index)
);
-- contract enforces ZeroRatio / BPS total
ALTER TABLE dividend_setups
    DROP CONSTRAINT IF EXISTS chk_dividend_setups_ratio;
ALTER TABLE dividend_setups
    ADD CONSTRAINT chk_dividend_setups_ratio
    CHECK (ratio > 0 AND ratio <= 10000);
CREATE INDEX IF NOT EXISTS idx_dividend_setups_source
    ON dividend_setups (source_token);

-- ----------------------------------------------------------------------------
-- 2) History: Deposit (exploded: one row per ratio slice)
--    Emitted ONCE per afterDeposit with ALL slices. amount is the per-slice
--    quote-denominated value; pending distinguishes immediate credit
--    (pending=false, dividend_token == quote) from swap-pending accrual
--    (pending=true, dividend_token != quote, later consumed by Converted).
--    No on-chain balance snapshot exists in the new event shape.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dividend_deposits (
    source_token     VARCHAR(42) NOT NULL,
    dividend_token   VARCHAR(42) NOT NULL,    -- target dividend token for this slice
    amount           NUMERIC NOT NULL,        -- per-slice value (quote units)
    pending          BOOLEAN NOT NULL,        -- true = swap-pending; false = immediate credit
    entry_index      INT NOT NULL,            -- position in dividendTokens[]/slices[]
    transaction_hash VARCHAR NOT NULL,
    block_number     BIGINT NOT NULL,
    created_at       BIGINT NOT NULL,
    log_index        INT NOT NULL,
    tx_index         INT NOT NULL,
    quote_id         VARCHAR(42),             -- quote token used for USD pricing
    usd_value        NUMERIC NOT NULL DEFAULT 0,  -- USD of amount (quote-priced)
    PRIMARY KEY (transaction_hash, tx_index, log_index, entry_index)
);
CREATE INDEX IF NOT EXISTS idx_dividend_deposits_pair
    ON dividend_deposits (source_token, dividend_token);

-- ----------------------------------------------------------------------------
-- 3) History: Converted (exploded: one row per conversion order)
--    USD semantics: usd_value prices consumed_quote (quote units are reliably
--    priceable via quote->WMON->Pyth). received is raw dividendToken units;
--    its USD value is intentionally NOT stored (arbitrary ERC20, often
--    unpriceable — avoid silently-bogus numbers).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dividend_conversions (
    source_token     VARCHAR(42) NOT NULL,
    dividend_token   VARCHAR(42) NOT NULL,
    consumed_quote   NUMERIC NOT NULL,        -- quote consumed from pendingSwap
    received         NUMERIC NOT NULL,        -- dividendToken credited (balance delta)
    entry_index      INT NOT NULL,            -- order index within the batch event
    transaction_hash VARCHAR NOT NULL,
    block_number     BIGINT NOT NULL,
    created_at       BIGINT NOT NULL,
    log_index        INT NOT NULL,
    tx_index         INT NOT NULL,
    quote_id         VARCHAR(42),             -- quote token used for USD pricing
    usd_value        NUMERIC NOT NULL DEFAULT 0,  -- USD of consumed_quote
    PRIMARY KEY (transaction_hash, tx_index, log_index, entry_index)
);
CREATE INDEX IF NOT EXISTS idx_dividend_conversions_pair
    ON dividend_conversions (source_token, dividend_token);

-- ----------------------------------------------------------------------------
-- 4) History: SetMerkleRoot (distribution period markers)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dividend_merkle_roots (
    merkle_root      VARCHAR(66) NOT NULL,    -- 0x + 64 hex
    transaction_hash VARCHAR NOT NULL,
    block_number     BIGINT NOT NULL,
    created_at       BIGINT NOT NULL,
    log_index        INT NOT NULL,
    tx_index         INT NOT NULL,
    PRIMARY KEY (transaction_hash, tx_index, log_index)
);
-- Latest-root lookup (claims enrichment + "current root" queries).
CREATE INDEX IF NOT EXISTS idx_dividend_merkle_roots_coords
    ON dividend_merkle_roots (block_number DESC, tx_index DESC, log_index DESC);

-- ----------------------------------------------------------------------------
-- 5) History: Claim — PAID entries only (exploded; zero/skipped NOT inserted)
--    merkle_root = period the claim was paid under, resolved at insert time as
--    the latest SetMerkleRoot at or before the claim's (block, tx, log) coords.
--    NULL only if no root event was ever indexed before the claim (shouldn't
--    happen: claim() reverts when merkleRoot is unset).
--    usd_value prices amount via the dividend token's cached USD price;
--    0 when the token is not WMON-reachable (pricing misses are logged).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dividend_claims (
    holder           VARCHAR(42) NOT NULL,
    source_token     VARCHAR(42) NOT NULL,
    dividend_token   VARCHAR(42) NOT NULL,
    amount           NUMERIC NOT NULL,        -- paid amount (dividendToken units)
    merkle_root      VARCHAR(66),             -- distribution period (resolved at insert)
    entry_index      INT NOT NULL,            -- position in the claim arrays
    transaction_hash VARCHAR NOT NULL,
    block_number     BIGINT NOT NULL,
    created_at       BIGINT NOT NULL,
    log_index        INT NOT NULL,
    tx_index         INT NOT NULL,
    usd_value        NUMERIC NOT NULL DEFAULT 0,  -- USD of amount (0 if unpriceable)
    PRIMARY KEY (transaction_hash, tx_index, log_index, entry_index)
);
-- paid-only table; zero entries rejected
ALTER TABLE dividend_claims
    DROP CONSTRAINT IF EXISTS chk_dividend_claims_amount;
ALTER TABLE dividend_claims
    ADD CONSTRAINT chk_dividend_claims_amount
    CHECK (amount > 0);
CREATE INDEX IF NOT EXISTS idx_dividend_claims_holder
    ON dividend_claims (holder);
CREATE INDEX IF NOT EXISTS idx_dividend_claims_pair
    ON dividend_claims (source_token, dividend_token);
CREATE INDEX IF NOT EXISTS idx_dividend_claims_root
    ON dividend_claims (merkle_root);

-- ----------------------------------------------------------------------------
-- 6) Aggregate: per (source_token, dividend_token) pair
--    All NUMERIC columns are denominated in that row's dividend_token units
--    (deposits qualify: their dividend_token IS the quote token).
--    claim_count counts PAID ENTRIES, not claim transactions or unique holders.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dividend_vault_stats (
    source_token             VARCHAR(42) NOT NULL,
    dividend_token           VARCHAR(42) NOT NULL,
    total_deposited          NUMERIC NOT NULL DEFAULT 0,  -- immediate slices (quote units)
    total_deposited_usd      NUMERIC NOT NULL DEFAULT 0,
    total_pending_deposited  NUMERIC NOT NULL DEFAULT 0,  -- swap-pending slices (quote units)
    total_pending_deposited_usd NUMERIC NOT NULL DEFAULT 0,
    total_consumed_quote     NUMERIC NOT NULL DEFAULT 0,  -- quote spent in conversions
    total_converted_received NUMERIC NOT NULL DEFAULT 0,  -- dividendToken from conversions
    -- quote awaiting conversion = pending deposited − consumed by Converted.
    -- A transient OR persisted NEGATIVE value is an ordering / replay-gap signal
    -- (a Converted row landing before its matching pending Deposit — within a
    -- batch the deposit/conversion inserts run concurrently, or across batches),
    -- NOT silent corruption. On-chain the contract never lets pendingSwap go
    -- negative, so a persisted negative means that (source_token, dividend_token)
    -- range must be re-indexed. Readers treating this as a displayable balance
    -- should GREATEST(pending_swap_balance, 0).
    pending_swap_balance     NUMERIC GENERATED ALWAYS AS
                                 (total_pending_deposited - total_consumed_quote) STORED,
    dividend_balance         NUMERIC NOT NULL DEFAULT 0,  -- cumulative mirror:
                                                          -- total_deposited + total_converted_received
    total_claimed            NUMERIC NOT NULL DEFAULT 0,  -- dividendToken paid to holders
    total_claimed_usd        NUMERIC NOT NULL DEFAULT 0,
    claim_count              INT NOT NULL DEFAULT 0,      -- paid entries
    last_block               BIGINT NOT NULL DEFAULT 0,
    updated_at               BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (source_token, dividend_token)
);

-- ----------------------------------------------------------------------------
-- Triggers: history insert success -> stats update (same transaction)
-- ----------------------------------------------------------------------------

-- Setup: seed the stats row so every configured pair exists with zeros
-- (setup is once-per-source immutable; DO NOTHING is reorg-replay-safe).
CREATE OR REPLACE FUNCTION update_dividend_stats_on_setup()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO dividend_vault_stats (source_token, dividend_token, last_block, updated_at)
    VALUES (NEW.source_token, NEW.dividend_token, NEW.block_number, NEW.created_at)
    ON CONFLICT (source_token, dividend_token) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_dividend_stats_on_setup ON dividend_setups;
CREATE TRIGGER trg_dividend_stats_on_setup
AFTER INSERT ON dividend_setups
FOR EACH ROW EXECUTE FUNCTION update_dividend_stats_on_setup();

-- Deposit: branch on pending.
--   pending=false -> immediate credit: total_deposited / _usd / dividend_balance.
--   pending=true  -> swap-pending accrual: total_pending_deposited / _usd only
--                    (dividend_balance is NOT touched; conversion credits it later).
CREATE OR REPLACE FUNCTION update_dividend_stats_on_deposit()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.pending THEN
        INSERT INTO dividend_vault_stats
            (source_token, dividend_token, total_pending_deposited,
             total_pending_deposited_usd, last_block, updated_at)
        VALUES
            (NEW.source_token, NEW.dividend_token, NEW.amount, NEW.usd_value,
             NEW.block_number, NEW.created_at)
        ON CONFLICT (source_token, dividend_token) DO UPDATE SET
            total_pending_deposited     = dividend_vault_stats.total_pending_deposited     + EXCLUDED.total_pending_deposited,
            total_pending_deposited_usd = dividend_vault_stats.total_pending_deposited_usd + EXCLUDED.total_pending_deposited_usd,
            last_block                  = GREATEST(dividend_vault_stats.last_block, EXCLUDED.last_block),
            updated_at                  = GREATEST(dividend_vault_stats.updated_at, EXCLUDED.updated_at);
    ELSE
        INSERT INTO dividend_vault_stats
            (source_token, dividend_token, total_deposited, total_deposited_usd,
             dividend_balance, last_block, updated_at)
        VALUES
            (NEW.source_token, NEW.dividend_token, NEW.amount, NEW.usd_value,
             NEW.amount, NEW.block_number, NEW.created_at)
        ON CONFLICT (source_token, dividend_token) DO UPDATE SET
            total_deposited     = dividend_vault_stats.total_deposited     + EXCLUDED.total_deposited,
            total_deposited_usd = dividend_vault_stats.total_deposited_usd + EXCLUDED.total_deposited_usd,
            dividend_balance    = dividend_vault_stats.dividend_balance    + EXCLUDED.dividend_balance,
            last_block          = GREATEST(dividend_vault_stats.last_block, EXCLUDED.last_block),
            updated_at          = GREATEST(dividend_vault_stats.updated_at, EXCLUDED.updated_at);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_dividend_stats_on_deposit ON dividend_deposits;
CREATE TRIGGER trg_dividend_stats_on_deposit
AFTER INSERT ON dividend_deposits
FOR EACH ROW EXECUTE FUNCTION update_dividend_stats_on_deposit();

-- Conversion: pendingSwap -> dividendBalance.
CREATE OR REPLACE FUNCTION update_dividend_stats_on_conversion()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO dividend_vault_stats
        (source_token, dividend_token, total_consumed_quote, total_converted_received,
         dividend_balance, last_block, updated_at)
    VALUES
        (NEW.source_token, NEW.dividend_token, NEW.consumed_quote, NEW.received,
         NEW.received, NEW.block_number, NEW.created_at)
    ON CONFLICT (source_token, dividend_token) DO UPDATE SET
        total_consumed_quote     = dividend_vault_stats.total_consumed_quote     + EXCLUDED.total_consumed_quote,
        total_converted_received = dividend_vault_stats.total_converted_received + EXCLUDED.total_converted_received,
        dividend_balance         = dividend_vault_stats.dividend_balance         + EXCLUDED.dividend_balance,
        last_block               = GREATEST(dividend_vault_stats.last_block, EXCLUDED.last_block),
        updated_at               = GREATEST(dividend_vault_stats.updated_at, EXCLUDED.updated_at);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_dividend_stats_on_conversion ON dividend_conversions;
CREATE TRIGGER trg_dividend_stats_on_conversion
AFTER INSERT ON dividend_conversions
FOR EACH ROW EXECUTE FUNCTION update_dividend_stats_on_conversion();

-- Claim: paid out to holder (does NOT reduce dividend_balance — chain doesn't).
CREATE OR REPLACE FUNCTION update_dividend_stats_on_claim()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO dividend_vault_stats
        (source_token, dividend_token, total_claimed, total_claimed_usd,
         claim_count, last_block, updated_at)
    VALUES
        (NEW.source_token, NEW.dividend_token, NEW.amount, NEW.usd_value,
         1, NEW.block_number, NEW.created_at)
    ON CONFLICT (source_token, dividend_token) DO UPDATE SET
        total_claimed     = dividend_vault_stats.total_claimed     + EXCLUDED.total_claimed,
        total_claimed_usd = dividend_vault_stats.total_claimed_usd + EXCLUDED.total_claimed_usd,
        claim_count       = dividend_vault_stats.claim_count       + 1,
        last_block        = GREATEST(dividend_vault_stats.last_block, EXCLUDED.last_block),
        updated_at        = GREATEST(dividend_vault_stats.updated_at, EXCLUDED.updated_at);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_dividend_stats_on_claim ON dividend_claims;
CREATE TRIGGER trg_dividend_stats_on_claim
AFTER INSERT ON dividend_claims
FOR EACH ROW EXECUTE FUNCTION update_dividend_stats_on_claim();

-- ----------------------------------------------------------------------------
-- Backfill: rebuild stats from history in ONE statement set, same transaction.
-- Safe to run on fresh installs (empty history -> no-op). On live systems run
-- inside this migration transaction only — single full-aggregate rebuild, no
-- cross-statement additive accumulation (partial runs cannot corrupt totals).
-- ----------------------------------------------------------------------------
TRUNCATE dividend_vault_stats;

-- pending_swap_balance is a GENERATED column — Postgres computes it; it is
-- intentionally EXCLUDED from the INSERT column list.
INSERT INTO dividend_vault_stats
    (source_token, dividend_token,
     total_deposited, total_deposited_usd,
     total_pending_deposited, total_pending_deposited_usd,
     total_consumed_quote, total_converted_received,
     dividend_balance,
     total_claimed, total_claimed_usd, claim_count,
     last_block, updated_at)
SELECT
    pair.source_token,
    pair.dividend_token,
    COALESCE(d.total_deposited, 0),
    COALESCE(d.total_deposited_usd, 0),
    COALESCE(d.total_pending_deposited, 0),
    COALESCE(d.total_pending_deposited_usd, 0),
    COALESCE(c.total_consumed_quote, 0),
    COALESCE(c.total_converted_received, 0),
    COALESCE(d.total_deposited, 0) + COALESCE(c.total_converted_received, 0),
    COALESCE(cl.total_claimed, 0),
    COALESCE(cl.total_claimed_usd, 0),
    COALESCE(cl.claim_count, 0),
    GREATEST(COALESCE(s.last_block, 0), COALESCE(d.last_block, 0),
             COALESCE(c.last_block, 0), COALESCE(cl.last_block, 0)),
    GREATEST(COALESCE(s.updated_at, 0), COALESCE(d.updated_at, 0),
             COALESCE(c.updated_at, 0), COALESCE(cl.updated_at, 0))
FROM (
    SELECT source_token, dividend_token FROM dividend_setups
    UNION
    SELECT source_token, dividend_token FROM dividend_deposits
    UNION
    SELECT source_token, dividend_token FROM dividend_conversions
    UNION
    SELECT source_token, dividend_token FROM dividend_claims
) AS pair
LEFT JOIN (
    SELECT source_token, dividend_token,
           MAX(block_number) AS last_block, MAX(created_at) AS updated_at
    FROM dividend_setups GROUP BY 1, 2
) s USING (source_token, dividend_token)
LEFT JOIN (
    -- Split deposits by pending: immediate (pending=false) feeds total_deposited
    -- and the dividend_balance sum; pending=true feeds total_pending_deposited.
    SELECT source_token, dividend_token,
           SUM(amount) FILTER (WHERE NOT pending) AS total_deposited,
           SUM(usd_value) FILTER (WHERE NOT pending) AS total_deposited_usd,
           SUM(amount) FILTER (WHERE pending) AS total_pending_deposited,
           SUM(usd_value) FILTER (WHERE pending) AS total_pending_deposited_usd,
           MAX(block_number) AS last_block, MAX(created_at) AS updated_at
    FROM dividend_deposits GROUP BY 1, 2
) d USING (source_token, dividend_token)
LEFT JOIN (
    SELECT source_token, dividend_token,
           SUM(consumed_quote) AS total_consumed_quote, SUM(received) AS total_converted_received,
           MAX(block_number) AS last_block, MAX(created_at) AS updated_at
    FROM dividend_conversions GROUP BY 1, 2
) c USING (source_token, dividend_token)
LEFT JOIN (
    SELECT source_token, dividend_token,
           SUM(amount) AS total_claimed, SUM(usd_value) AS total_claimed_usd,
           COUNT(*) AS claim_count,
           MAX(block_number) AS last_block, MAX(created_at) AS updated_at
    FROM dividend_claims GROUP BY 1, 2
) cl USING (source_token, dividend_token);


-- ============================================================================
-- Scheduler distribution and accrual schema.
-- history INSERT -> trigger -> aggregate; leaf amount = cumulative accrued.
-- ============================================================================

CREATE TABLE IF NOT EXISTS dividend_accrual_history (
    source_token     VARCHAR(42) NOT NULL,
    dividend_token   VARCHAR(42) NOT NULL,
    holder           VARCHAR(42) NOT NULL,
    accrued          NUMERIC(78,0) NOT NULL CHECK (accrued >= 0),
    snapshot_balance NUMERIC(78,0) NOT NULL CHECK (snapshot_balance >= 0),
    balance_to       NUMERIC(78,0) NOT NULL CHECK (balance_to >= 0),
    snapshot_block   BIGINT  NOT NULL,
    created_at       BIGINT  NOT NULL,
    PRIMARY KEY (source_token, dividend_token, holder, balance_to)
);
CREATE INDEX IF NOT EXISTS idx_dividend_accrual_history_pair ON dividend_accrual_history (source_token, dividend_token);

CREATE TABLE IF NOT EXISTS dividend_accrual (
    source_token   VARCHAR(42) NOT NULL,
    holder         VARCHAR(42) NOT NULL,
    dividend_token VARCHAR(42) NOT NULL,
    accrued        NUMERIC(78,0) NOT NULL DEFAULT 0 CHECK (accrued >= 0),
    updated_at     BIGINT  NOT NULL DEFAULT 0,
    PRIMARY KEY (source_token, holder, dividend_token)
);
CREATE INDEX IF NOT EXISTS idx_dividend_accrual_holder ON dividend_accrual (holder);

CREATE TABLE IF NOT EXISTS dividend_pair_state (
    source_token           VARCHAR(42) NOT NULL,
    dividend_token         VARCHAR(42) NOT NULL,
    last_allocated_balance NUMERIC(78,0) NOT NULL DEFAULT 0 CHECK (last_allocated_balance >= 0),
    last_snapshot_block    BIGINT  NOT NULL DEFAULT 0,
    updated_at             BIGINT  NOT NULL DEFAULT 0,
    PRIMARY KEY (source_token, dividend_token)
);

CREATE OR REPLACE FUNCTION update_dividend_accrual_on_history()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO dividend_accrual (source_token, holder, dividend_token, accrued, updated_at)
    VALUES (NEW.source_token, NEW.holder, NEW.dividend_token, NEW.accrued, NEW.created_at)
    ON CONFLICT (source_token, holder, dividend_token) DO UPDATE SET
        accrued    = dividend_accrual.accrued + EXCLUDED.accrued,
        updated_at = GREATEST(dividend_accrual.updated_at, EXCLUDED.updated_at);

    INSERT INTO dividend_pair_state (source_token, dividend_token, last_allocated_balance, last_snapshot_block, updated_at)
    VALUES (NEW.source_token, NEW.dividend_token, NEW.balance_to, NEW.snapshot_block, NEW.created_at)
    ON CONFLICT (source_token, dividend_token) DO UPDATE SET
        last_allocated_balance = GREATEST(dividend_pair_state.last_allocated_balance, EXCLUDED.last_allocated_balance),
        last_snapshot_block    = GREATEST(dividend_pair_state.last_snapshot_block, EXCLUDED.last_snapshot_block),
        updated_at             = GREATEST(dividend_pair_state.updated_at, EXCLUDED.updated_at);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_dividend_accrual_on_history ON dividend_accrual_history;
CREATE TRIGGER trg_dividend_accrual_on_history
AFTER INSERT ON dividend_accrual_history
FOR EACH ROW EXECUTE FUNCTION update_dividend_accrual_on_history();

CREATE TABLE IF NOT EXISTS dividend_merkle_root (
    merkle_root      VARCHAR(66) PRIMARY KEY,
    transaction_hash VARCHAR NOT NULL,
    leaf_count       INT NOT NULL,
    created_at       BIGINT NOT NULL
);

-- Latest-only claim snapshot (one row per (source, holder, dividend); rebuilt each run via upsert).
-- status set at build time from dividend_claims (CLAIMED = claimed >= amount). Cumulative model:
-- a new root grows amount, flipping status back to AWAITING. No per-root history kept.
CREATE TABLE IF NOT EXISTS dividend_distribution (
    source_token   VARCHAR(42) NOT NULL,
    holder         VARCHAR(42) NOT NULL,
    dividend_token VARCHAR(42) NOT NULL,
    merkle_root    VARCHAR(66) NOT NULL,                          -- current published root
    amount         NUMERIC(78,0) NOT NULL CHECK (amount >= 0),    -- leaf = cumulative accrued
    proof          TEXT[]  NOT NULL,
    status         VARCHAR NOT NULL CHECK (status IN ('AWAITING', 'CLAIMED')),
    created_at     BIGINT  NOT NULL,
    PRIMARY KEY (source_token, holder, dividend_token)
);
CREATE INDEX IF NOT EXISTS idx_dividend_distribution_holder ON dividend_distribution (holder);

-- BACKFILL (rebuild aggregates from history). pair_state must come from ONE row per pair
-- (the max-balance_to row) so its (balance, snapshot_block) stay paired (Codex L10).
TRUNCATE dividend_accrual;
INSERT INTO dividend_accrual (source_token, holder, dividend_token, accrued, updated_at)
SELECT source_token, holder, dividend_token, SUM(accrued), MAX(created_at)
FROM dividend_accrual_history GROUP BY source_token, holder, dividend_token;

TRUNCATE dividend_pair_state;
INSERT INTO dividend_pair_state (source_token, dividend_token, last_allocated_balance, last_snapshot_block, updated_at)
SELECT DISTINCT ON (source_token, dividend_token)
       source_token, dividend_token, balance_to, snapshot_block, created_at
FROM dividend_accrual_history
ORDER BY source_token, dividend_token, balance_to DESC, snapshot_block DESC, created_at DESC;

COMMIT;

-- ============================================================================
-- >>> vault.sql
-- ============================================================================

-- ======================================================================
-- Vault schema — single source of truth for all vault-related data.
-- ----------------------------------------------------------------------
-- Covers BurnVault, LPVault, CreatorFeeVault, GiftVault and the
-- VaultRegistry that catalogues them.
--
-- Contents
--
--   1. Event log tables
--      - vault_burns
--      - vault_lp_injections
--      - creator_fee_claims
--      - gifts
--      - creator_updates
--      - gift_expiry_updates
--      - vault_registry
--      - vault_metadata
--   2. Pre-aggregated stat tables (per token)
--      - burn_vault_stats
--      - lp_vault_stats
--      - creator_fee_vault_stats  (with current_balance)
--      - gift_vault_stats         (with current_state, current_balance)
--   3. AFTER INSERT triggers that maintain the stat tables
--   4. Initial aggregate materialization from event rows
--
-- creator_fee_distribution lives in the contract-event section (it's a
-- CreatorFeeProcessor event, not a vault event).
-- ======================================================================

BEGIN;

-- ======================================================================
-- 1. Event log tables
-- ======================================================================

-- 1.1 vault_burns — BurnVault.Burn / GiftVault.Burn
CREATE TABLE IF NOT EXISTS vault_burns (
    vault_type VARCHAR NOT NULL,
    token_id VARCHAR(42) NOT NULL,
    quote_in NUMERIC NOT NULL,       -- UNIT: quote raw (wei) — BurnVault.Burn.quoteIn
    token_burned NUMERIC NOT NULL,   -- UNIT: token raw (wei) — BurnVault.Burn.tokenBurned
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL,
    created_at BIGINT NOT NULL,
    log_index INT NOT NULL,
    tx_index INT NOT NULL,
    quote_id VARCHAR(42),
    usd_value NUMERIC NOT NULL DEFAULT 0,  -- UNIT: USD (human) — quote_in / 10^quote_decimals * quote_price
    PRIMARY KEY (transaction_hash, tx_index, log_index)
);
CREATE INDEX IF NOT EXISTS idx_vault_burns_token
    ON vault_burns (token_id);

-- 1.2 vault_lp_injections — LPVault.AddLiquidity
CREATE TABLE IF NOT EXISTS vault_lp_injections (
    token_id VARCHAR(42) NOT NULL,
    quote_used NUMERIC NOT NULL,     -- UNIT: quote raw (wei) — LPVault.AddLiquidity.quoteUsed
    token_used NUMERIC NOT NULL,     -- UNIT: token raw (wei) — LPVault.AddLiquidity.tokenUsed
    lp_burned NUMERIC NOT NULL,      -- UNIT: token raw (wei) — LP-token amount, AddLiquidity.lpBurned
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL,
    created_at BIGINT NOT NULL,
    log_index INT NOT NULL,
    tx_index INT NOT NULL,
    quote_id VARCHAR(42),
    usd_value NUMERIC NOT NULL DEFAULT 0,  -- UNIT: USD (human) — quote_used / 10^quote_decimals * quote_price
    PRIMARY KEY (transaction_hash, tx_index, log_index)
);
CREATE INDEX IF NOT EXISTS idx_vault_lp_inject_token
    ON vault_lp_injections (token_id);

-- 1.3 creator_fee_claims — CreatorFeeVault.Deposit / Claim
CREATE TABLE IF NOT EXISTS creator_fee_claims (
    event_type VARCHAR NOT NULL,
    token_id VARCHAR(42) NOT NULL,
    creator VARCHAR(42),
    amount NUMERIC NOT NULL,         -- UNIT: quote raw (wei) — CreatorFeeVault Deposit/Claim.amount
    new_balance NUMERIC,             -- UNIT: quote raw (wei) — CreatorFeeVault.Deposit.newBalance (NULL on CLAIM)
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL,
    created_at BIGINT NOT NULL,
    log_index INT NOT NULL,
    tx_index INT NOT NULL,
    quote_id VARCHAR(42),
    usd_value NUMERIC NOT NULL DEFAULT 0,  -- UNIT: USD (human) — amount / 10^quote_decimals * quote_price
    PRIMARY KEY (transaction_hash, tx_index, log_index)
);
CREATE INDEX IF NOT EXISTS idx_creator_fee_claims_token
    ON creator_fee_claims (token_id);
ALTER TABLE creator_fee_claims
    DROP CONSTRAINT IF EXISTS creator_fee_claims_event_type_check;
ALTER TABLE creator_fee_claims
    ADD CONSTRAINT creator_fee_claims_event_type_check
    CHECK (event_type IN ('DEPOSIT', 'CLAIM'));

-- 1.4 gifts — GiftVault.Setup / Deposit / Claim / Expire / ReceiverSet
--   Setup identifies the target by platform and platform_id; Claim and
--   ReceiverSet identify the receiving account through receiver.
CREATE TABLE IF NOT EXISTS gifts (
    event_type VARCHAR NOT NULL,
    token_id VARCHAR(42) NOT NULL,
    platform VARCHAR,
    platform_id VARCHAR,
    receiver VARCHAR(42),
    amount NUMERIC,                  -- UNIT: quote raw (wei) — GiftVault Deposit/Claim/Expire.amount (NULL on SETUP/RECEIVER_SET)
    new_balance NUMERIC,             -- UNIT: quote raw (wei) — GiftVault.Deposit.newBalance (NULL on non-DEPOSIT)
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL,
    created_at BIGINT NOT NULL,
    log_index INT NOT NULL,
    tx_index INT NOT NULL,
    quote_id VARCHAR(42),
    usd_value NUMERIC NOT NULL DEFAULT 0,  -- UNIT: USD (human) — amount / 10^quote_decimals * quote_price
    -- Gift expiry epoch (unix seconds). Meaningful on SETUP rows
    -- (= block_timestamp + GIFT_EXPIRY_DURATION) and on RECEIVER_SET
    -- rows (= 0, expiry cleared). Other event types record 0 as a
    -- placeholder; consumers read gift_vault_stats.expires_at for
    -- the live value.
    expires_at BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (transaction_hash, tx_index, log_index)
);

ALTER TABLE gifts DROP CONSTRAINT IF EXISTS gifts_platform_check;
ALTER TABLE gifts ADD CONSTRAINT gifts_platform_check
    CHECK (platform IS NULL OR platform IN ('GITHUB', 'X'));

ALTER TABLE gifts DROP CONSTRAINT IF EXISTS gifts_event_type_check;
ALTER TABLE gifts ADD CONSTRAINT gifts_event_type_check
    CHECK (event_type IN ('SETUP', 'DEPOSIT', 'CLAIM', 'EXPIRE', 'RECEIVER_SET'));

CREATE INDEX IF NOT EXISTS idx_gifts_token
    ON gifts (token_id);
CREATE INDEX IF NOT EXISTS idx_gifts_setup
    ON gifts (platform, platform_id) WHERE event_type = 'SETUP';

-- 1.5 creator_updates — CreatorFeeVault.VaultSetup / CreatorUpdate
--   event_type='SETUP'  -> initial creator bind (old_creator NULL)
--   event_type='UPDATE' -> subsequent creator change
CREATE TABLE IF NOT EXISTS creator_updates (
    event_type VARCHAR NOT NULL,
    token_id VARCHAR(42) NOT NULL,
    old_creator VARCHAR(42),
    new_creator VARCHAR(42) NOT NULL,
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL,
    created_at BIGINT NOT NULL,
    log_index INT NOT NULL,
    tx_index INT NOT NULL,
    PRIMARY KEY (transaction_hash, tx_index, log_index)
);
ALTER TABLE creator_updates
    DROP CONSTRAINT IF EXISTS creator_updates_event_type_check;
ALTER TABLE creator_updates
    ADD CONSTRAINT creator_updates_event_type_check
    CHECK (event_type IN ('SETUP', 'UPDATE'));
CREATE INDEX IF NOT EXISTS idx_creator_updates_token
    ON creator_updates (token_id);
CREATE INDEX IF NOT EXISTS idx_creator_updates_new_creator
    ON creator_updates (new_creator);

-- 1.6 gift_expiry_updates — GiftVault.ExpiryUpdate (governance config)
CREATE TABLE IF NOT EXISTS gift_expiry_updates (
    old_duration NUMERIC NOT NULL,   -- UNIT: seconds — GiftVault.ExpiryUpdate.oldDuration (gift expiry window)
    new_duration NUMERIC NOT NULL,   -- UNIT: seconds — GiftVault.ExpiryUpdate.newDuration (gift expiry window)
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL,
    created_at BIGINT NOT NULL,
    log_index INT NOT NULL,
    tx_index INT NOT NULL,
    PRIMARY KEY (transaction_hash, tx_index, log_index)
);

-- 1.7 vault_registry — VaultRegistry.Register (append-only log)
CREATE TABLE IF NOT EXISTS vault_registry (
    vault_id VARCHAR(42) NOT NULL,
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL,
    created_at BIGINT NOT NULL,
    log_index INT NOT NULL,
    tx_index INT NOT NULL,
    PRIMARY KEY (transaction_hash, tx_index, log_index)
);
CREATE INDEX IF NOT EXISTS idx_vault_registry_vault
    ON vault_registry (vault_id);

-- 1.8 vault_metadata — denormalized per-vault catalog. One row per
--     registered vault. Upserted on Register (name / creator / vault_type
--     + fetched metadata JSON), `active` toggled by Deactivate.
--     metadata / metadata_uri may be NULL if off-chain fetch failed.
CREATE TABLE IF NOT EXISTS vault_metadata (
    vault_id VARCHAR(42) PRIMARY KEY,
    name VARCHAR NOT NULL,
    creator VARCHAR(42) NOT NULL,
    vault_type VARCHAR NOT NULL
        CONSTRAINT vault_metadata_type_check
        CHECK (vault_type IN ('CUSTOM','BURN','LP','CREATOR_FEE','GIFT','DIVIDEND')),
    active BOOLEAN NOT NULL DEFAULT TRUE,
    metadata_uri VARCHAR,
    metadata JSONB,
    metadata_fetched_at BIGINT,
    registered_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_vault_metadata_type
    ON vault_metadata (vault_type);
CREATE INDEX IF NOT EXISTS idx_vault_metadata_active
    ON vault_metadata (active) WHERE active;

-- 1.9 creator_fee_allocation — per-token vault distribution percentages
--   from CreatorFeeProcessor.Setup(token, vaults[(vault, bps)]).
--   PK = (token_id, vault_id). Re-Setup of the same token UPSERTs
--   each row's bps. Drives UI fee-distribution % displays.
CREATE TABLE IF NOT EXISTS creator_fee_allocation (
    token_id VARCHAR(42) NOT NULL,
    vault_id VARCHAR(42) NOT NULL,
    bps INT NOT NULL,
    transaction_hash VARCHAR NOT NULL,
    block_number BIGINT NOT NULL,
    created_at BIGINT NOT NULL,
    log_index INT NOT NULL,
    tx_index INT NOT NULL,
    PRIMARY KEY (token_id, vault_id)
);
ALTER TABLE creator_fee_allocation
    DROP CONSTRAINT IF EXISTS creator_fee_allocation_bps_check;
ALTER TABLE creator_fee_allocation
    ADD CONSTRAINT creator_fee_allocation_bps_check
    CHECK (bps >= 0 AND bps <= 10000);
CREATE INDEX IF NOT EXISTS idx_creator_fee_allocation_vault
    ON creator_fee_allocation (vault_id);

-- ======================================================================
-- 2. Pre-aggregated stat tables (one row per token)
-- ----------------------------------------------------------------------
-- Each vault aggregates from its own event tables — no cross-vault JOIN,
-- no VaultRegistry dependency. creator_fee_distribution stays a pure
-- event log and is NOT an aggregation source (BurnVault / LPVault never
-- emit a "deposit" event of their own).
--
-- current_balance on creator_fee / gift mirrors on-chain `_balances` /
-- `gift.balance` exactly:
--   DEPOSIT → set to Deposit.newBalance (from the event row)
--   CLAIM   → 0
--   EXPIRE  → 0     (gift only — sweep + buyback zeros gift.balance)
-- ======================================================================

-- 2.1 BurnVault — buyback+burn totals. No "received" metric (BurnVault
--     never emits a Deposit event).
CREATE TABLE IF NOT EXISTS burn_vault_stats (
    token_id VARCHAR(42) PRIMARY KEY,
    quote_spent NUMERIC NOT NULL DEFAULT 0,      -- UNIT: quote raw (wei) — SUM(vault_burns.quote_in)
    quote_spent_usd NUMERIC NOT NULL DEFAULT 0,  -- UNIT: USD (human) — SUM(vault_burns.usd_value)
    tokens_burned NUMERIC NOT NULL DEFAULT 0,    -- UNIT: token raw (wei) — SUM(vault_burns.token_burned)
    burn_count INT NOT NULL DEFAULT 0,
    last_block BIGINT NOT NULL DEFAULT 0,
    updated_at BIGINT NOT NULL DEFAULT 0
);

-- 2.2 LPVault — LP injection totals.
CREATE TABLE IF NOT EXISTS lp_vault_stats (
    token_id VARCHAR(42) PRIMARY KEY,
    quote_injected NUMERIC NOT NULL DEFAULT 0,      -- UNIT: quote raw (wei) — SUM(vault_lp_injections.quote_used)
    quote_injected_usd NUMERIC NOT NULL DEFAULT 0,  -- UNIT: USD (human) — SUM(vault_lp_injections.usd_value)
    token_injected NUMERIC NOT NULL DEFAULT 0,      -- UNIT: token raw (wei) — SUM(vault_lp_injections.token_used)
    lp_burned NUMERIC NOT NULL DEFAULT 0,           -- UNIT: token raw (wei) — LP-token, SUM(vault_lp_injections.lp_burned)
    inject_count INT NOT NULL DEFAULT 0,
    last_block BIGINT NOT NULL DEFAULT 0,
    updated_at BIGINT NOT NULL DEFAULT 0
);

-- 2.3 CreatorFeeVault — deposit / claim totals + live balance mirror.
CREATE TABLE IF NOT EXISTS creator_fee_vault_stats (
    token_id VARCHAR(42) PRIMARY KEY,
    current_balance NUMERIC NOT NULL DEFAULT 0,      -- UNIT: quote raw (wei) — mirrors Deposit.newBalance, 0 after CLAIM
    total_deposited NUMERIC NOT NULL DEFAULT 0,      -- UNIT: quote raw (wei) — SUM(DEPOSIT amount)
    total_deposited_usd NUMERIC NOT NULL DEFAULT 0,  -- UNIT: USD (human) — SUM(DEPOSIT usd_value)
    total_claimed NUMERIC NOT NULL DEFAULT 0,        -- UNIT: quote raw (wei) — SUM(CLAIM amount)
    total_claimed_usd NUMERIC NOT NULL DEFAULT 0,    -- UNIT: USD (human) — SUM(CLAIM usd_value)
    deposit_count INT NOT NULL DEFAULT 0,
    claim_count INT NOT NULL DEFAULT 0,
    last_block BIGINT NOT NULL DEFAULT 0,
    updated_at BIGINT NOT NULL DEFAULT 0
);

-- 2.4 GiftVault — full lifecycle + current_state + live balance mirror.
--   platform / platform_id captured from the SETUP event (X handle,
--   GitHub login, ...). receiver captured from the RECEIVER_SET event
--   so consumers (gift-bot, UI) can read current bind state without
--   joining gifts.
CREATE TABLE IF NOT EXISTS gift_vault_stats (
    token_id VARCHAR(42) PRIMARY KEY,
    current_state VARCHAR NOT NULL DEFAULT 'Accumulating',
    current_balance NUMERIC NOT NULL DEFAULT 0,          -- UNIT: quote raw (wei) — mirrors Deposit.newBalance, 0 after CLAIM/EXPIRE
    platform VARCHAR,
    platform_id VARCHAR,
    receiver VARCHAR(42),
    total_deposited NUMERIC NOT NULL DEFAULT 0,          -- UNIT: quote raw (wei) — SUM(DEPOSIT amount)
    total_deposited_usd NUMERIC NOT NULL DEFAULT 0,      -- UNIT: USD (human) — SUM(DEPOSIT usd_value)
    total_claimed NUMERIC NOT NULL DEFAULT 0,            -- UNIT: quote raw (wei) — SUM(CLAIM amount)
    total_claimed_usd NUMERIC NOT NULL DEFAULT 0,        -- UNIT: USD (human) — SUM(CLAIM usd_value)
    total_expired NUMERIC NOT NULL DEFAULT 0,            -- UNIT: quote raw (wei) — SUM(EXPIRE amount)
    total_expired_usd NUMERIC NOT NULL DEFAULT 0,        -- UNIT: USD (human) — SUM(EXPIRE usd_value)
    buyback_quote_spent NUMERIC NOT NULL DEFAULT 0,      -- UNIT: quote raw (wei) — SUM(vault_burns.quote_in WHERE vault_type='GIFT')
    buyback_quote_spent_usd NUMERIC NOT NULL DEFAULT 0,  -- UNIT: USD (human) — SUM(GIFT-burn usd_value)
    buyback_tokens NUMERIC NOT NULL DEFAULT 0,           -- UNIT: token raw (wei) — SUM(vault_burns.token_burned WHERE vault_type='GIFT')
    -- Current expiry epoch for the gift. Set from the SETUP event's
    -- expires_at (= setup block_timestamp + GIFT_EXPIRY_DURATION) and
    -- cleared to 0 when a RECEIVER_SET event lands (gift is claimed by
    -- a bound receiver, no longer expires).
    expires_at BIGINT NOT NULL DEFAULT 0,
    -- block_timestamp of the RECEIVER_SET event that bound this gift
    -- to its receiver. 0 while the gift is still 'Accumulating'.
    receiver_set_at BIGINT NOT NULL DEFAULT 0,
    last_block BIGINT NOT NULL DEFAULT 0,
    updated_at BIGINT NOT NULL DEFAULT 0
);

-- 2.5 CreatorFeeDistribution — per-(token, vault) fee distribution totals.
--     Sourced from CreatorFeeProcessor.Distribute events
--     (event_type = 'DISTRIBUTE') in creator_fee_distribution. Unlike
--     vault-side stats, this captures the *outgoing* fee a token routed to
--     each vault. CALLBACKFAIL rows are ignored (failed distribution
--     attempts; on-chain side handles refunds separately).
CREATE TABLE IF NOT EXISTS creator_fee_distribution_stats (
    token_id              VARCHAR(42) NOT NULL,
    vault_id              VARCHAR(42) NOT NULL,
    quote_id              VARCHAR(42) NOT NULL,
    distributed_quote     NUMERIC     NOT NULL DEFAULT 0,  -- UNIT: quote raw (wei) — SUM(creator_fee_distribution.amount WHERE event_type='DISTRIBUTE')
    distributed_quote_usd NUMERIC     NOT NULL DEFAULT 0,  -- UNIT: USD (human) — SUM(DISTRIBUTE usd_value)
    distribute_count      INT         NOT NULL DEFAULT 0,
    last_block            BIGINT      NOT NULL DEFAULT 0,
    updated_at            BIGINT      NOT NULL DEFAULT 0,
    PRIMARY KEY (token_id, vault_id)
);

ALTER TABLE gift_vault_stats
    DROP CONSTRAINT IF EXISTS gift_vault_stats_platform_check;
ALTER TABLE gift_vault_stats
    ADD CONSTRAINT gift_vault_stats_platform_check
    CHECK (platform IS NULL OR platform IN ('GITHUB', 'X'));

ALTER TABLE gift_vault_stats
    DROP CONSTRAINT IF EXISTS gift_vault_stats_state_check;
ALTER TABLE gift_vault_stats
    ADD CONSTRAINT gift_vault_stats_state_check
    CHECK (current_state IN ('Accumulating','Active','Burned'));

-- Supporting indexes for event queries and aggregate maintenance.
CREATE INDEX IF NOT EXISTS idx_vault_burns_type_token
    ON vault_burns (vault_type, token_id);
CREATE INDEX IF NOT EXISTS idx_creator_fee_claims_event_token
    ON creator_fee_claims (event_type, token_id);
CREATE INDEX IF NOT EXISTS idx_gifts_event_token
    ON gifts (event_type, token_id);
CREATE INDEX IF NOT EXISTS idx_creator_fee_dist_vault_event
    ON creator_fee_distribution (vault, event_type);

-- Profile gift-fee endpoint (`GET /profile/gift-fee/{account_id}`) filters by
-- receiver and orders by claimable balance (current_balance DESC). Partial
-- index on (receiver, current_balance DESC) WHERE receiver IS NOT NULL covers
-- both WHERE and ORDER BY in a single index-only scan, and excludes the
-- "Accumulating" rows that have NULL receiver to keep the index small.
CREATE INDEX IF NOT EXISTS idx_gift_vault_stats_receiver_balance
    ON gift_vault_stats (receiver, current_balance DESC)
    WHERE receiver IS NOT NULL;

-- ======================================================================
-- 3. Trigger functions + triggers
-- ----------------------------------------------------------------------
-- Idempotency: every * event table uses
--   INSERT ... ON CONFLICT (transaction_hash, tx_index, log_index) DO NOTHING
-- Postgres skips AFTER INSERT triggers when no row is actually inserted,
-- so reorg / restart replays cannot double-count aggregates.
-- ======================================================================

-- 3.1 vault_burns → burn_stats (vault_type='BURN')
--                   → gift_stats (vault_type='GIFT', buyback columns)
CREATE OR REPLACE FUNCTION update_vault_burn_stats()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.vault_type = 'BURN' THEN
        INSERT INTO burn_vault_stats
            (token_id, quote_spent, quote_spent_usd, tokens_burned,
             burn_count, last_block, updated_at)
        VALUES
            (NEW.token_id, NEW.quote_in, NEW.usd_value, NEW.token_burned, 1,
             NEW.block_number, NEW.created_at)
        ON CONFLICT (token_id) DO UPDATE SET
            quote_spent     = burn_vault_stats.quote_spent     + EXCLUDED.quote_spent,
            quote_spent_usd = burn_vault_stats.quote_spent_usd + EXCLUDED.quote_spent_usd,
            tokens_burned   = burn_vault_stats.tokens_burned   + EXCLUDED.tokens_burned,
            burn_count      = burn_vault_stats.burn_count      + 1,
            last_block      = GREATEST(burn_vault_stats.last_block, EXCLUDED.last_block),
            updated_at      = GREATEST(burn_vault_stats.updated_at, EXCLUDED.updated_at);
    ELSIF NEW.vault_type = 'GIFT' THEN
        INSERT INTO gift_vault_stats
            (token_id, buyback_quote_spent, buyback_quote_spent_usd, buyback_tokens,
             last_block, updated_at)
        VALUES
            (NEW.token_id, NEW.quote_in, NEW.usd_value, NEW.token_burned,
             NEW.block_number, NEW.created_at)
        ON CONFLICT (token_id) DO UPDATE SET
            buyback_quote_spent     = gift_vault_stats.buyback_quote_spent     + EXCLUDED.buyback_quote_spent,
            buyback_quote_spent_usd = gift_vault_stats.buyback_quote_spent_usd + EXCLUDED.buyback_quote_spent_usd,
            buyback_tokens          = gift_vault_stats.buyback_tokens          + EXCLUDED.buyback_tokens,
            last_block              = GREATEST(gift_vault_stats.last_block, EXCLUDED.last_block),
            updated_at              = GREATEST(gift_vault_stats.updated_at, EXCLUDED.updated_at);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_update_vault_burn_stats ON vault_burns;
CREATE TRIGGER trg_update_vault_burn_stats
AFTER INSERT ON vault_burns
FOR EACH ROW EXECUTE FUNCTION update_vault_burn_stats();

-- 3.2 vault_lp_injections → lp_stats
CREATE OR REPLACE FUNCTION update_vault_lp_stats()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO lp_vault_stats
        (token_id, quote_injected, quote_injected_usd, token_injected, lp_burned,
         inject_count, last_block, updated_at)
    VALUES
        (NEW.token_id, NEW.quote_used, NEW.usd_value, NEW.token_used, NEW.lp_burned, 1,
         NEW.block_number, NEW.created_at)
    ON CONFLICT (token_id) DO UPDATE SET
        quote_injected     = lp_vault_stats.quote_injected     + EXCLUDED.quote_injected,
        quote_injected_usd = lp_vault_stats.quote_injected_usd + EXCLUDED.quote_injected_usd,
        token_injected     = lp_vault_stats.token_injected     + EXCLUDED.token_injected,
        lp_burned          = lp_vault_stats.lp_burned          + EXCLUDED.lp_burned,
        inject_count       = lp_vault_stats.inject_count       + 1,
        last_block         = GREATEST(lp_vault_stats.last_block, EXCLUDED.last_block),
        updated_at         = GREATEST(lp_vault_stats.updated_at, EXCLUDED.updated_at);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_update_vault_lp_stats ON vault_lp_injections;
CREATE TRIGGER trg_update_vault_lp_stats
AFTER INSERT ON vault_lp_injections
FOR EACH ROW EXECUTE FUNCTION update_vault_lp_stats();

-- 3.3 creator_fee_claims → creator_fee_stats
--   DEPOSIT: current_balance = NEW.new_balance, total_deposited += amount
--   CLAIM:   current_balance = 0,              total_claimed   += amount
CREATE OR REPLACE FUNCTION update_creator_fee_vault_stats()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.event_type = 'DEPOSIT' THEN
        INSERT INTO creator_fee_vault_stats
            (token_id, current_balance, total_deposited, total_deposited_usd,
             deposit_count, last_block, updated_at)
        VALUES
            (NEW.token_id, COALESCE(NEW.new_balance, 0), NEW.amount, NEW.usd_value, 1,
             NEW.block_number, NEW.created_at)
        ON CONFLICT (token_id) DO UPDATE SET
            current_balance     = COALESCE(EXCLUDED.current_balance, creator_fee_vault_stats.current_balance),
            total_deposited     = creator_fee_vault_stats.total_deposited     + EXCLUDED.total_deposited,
            total_deposited_usd = creator_fee_vault_stats.total_deposited_usd + EXCLUDED.total_deposited_usd,
            deposit_count       = creator_fee_vault_stats.deposit_count       + 1,
            last_block          = GREATEST(creator_fee_vault_stats.last_block, EXCLUDED.last_block),
            updated_at          = GREATEST(creator_fee_vault_stats.updated_at, EXCLUDED.updated_at);
    ELSIF NEW.event_type = 'CLAIM' THEN
        INSERT INTO creator_fee_vault_stats
            (token_id, current_balance, total_claimed, total_claimed_usd,
             claim_count, last_block, updated_at)
        VALUES
            (NEW.token_id, 0, NEW.amount, NEW.usd_value, 1,
             NEW.block_number, NEW.created_at)
        ON CONFLICT (token_id) DO UPDATE SET
            current_balance   = 0,
            total_claimed     = creator_fee_vault_stats.total_claimed     + EXCLUDED.total_claimed,
            total_claimed_usd = creator_fee_vault_stats.total_claimed_usd + EXCLUDED.total_claimed_usd,
            claim_count       = creator_fee_vault_stats.claim_count       + 1,
            last_block        = GREATEST(creator_fee_vault_stats.last_block, EXCLUDED.last_block),
            updated_at        = GREATEST(creator_fee_vault_stats.updated_at, EXCLUDED.updated_at);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_update_creator_fee_vault_stats ON creator_fee_claims;
CREATE TRIGGER trg_update_creator_fee_vault_stats
AFTER INSERT ON creator_fee_claims
FOR EACH ROW EXECUTE FUNCTION update_creator_fee_vault_stats();

-- 3.4 gifts → gift_stats
--   SETUP:        init row ('Accumulating')
--   DEPOSIT:      current_balance = NEW.new_balance, total_deposited += amount
--   CLAIM:        current_balance = 0,              total_claimed   += amount
--   EXPIRE:       current_balance = 0, total_expired += amount, state = 'Burned'
--   RECEIVER_SET: state = 'Active' (stays Burned if already Burned)
CREATE OR REPLACE FUNCTION update_gift_vault_stats()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.event_type = 'SETUP' THEN
        INSERT INTO gift_vault_stats
            (token_id, current_state, platform, platform_id, expires_at,
             last_block, updated_at)
        VALUES
            (NEW.token_id, 'Accumulating', NEW.platform, NEW.platform_id, NEW.expires_at,
             NEW.block_number, NEW.created_at)
        ON CONFLICT (token_id) DO UPDATE SET
            platform    = COALESCE(EXCLUDED.platform, gift_vault_stats.platform),
            platform_id = COALESCE(EXCLUDED.platform_id, gift_vault_stats.platform_id),
            expires_at  = EXCLUDED.expires_at,
            last_block  = GREATEST(gift_vault_stats.last_block, EXCLUDED.last_block),
            updated_at  = GREATEST(gift_vault_stats.updated_at, EXCLUDED.updated_at);
    ELSIF NEW.event_type = 'DEPOSIT' THEN
        INSERT INTO gift_vault_stats
            (token_id, current_balance, total_deposited, total_deposited_usd,
             last_block, updated_at)
        VALUES
            (NEW.token_id, COALESCE(NEW.new_balance, 0), NEW.amount, NEW.usd_value,
             NEW.block_number, NEW.created_at)
        ON CONFLICT (token_id) DO UPDATE SET
            current_balance     = COALESCE(EXCLUDED.current_balance, gift_vault_stats.current_balance),
            total_deposited     = gift_vault_stats.total_deposited     + EXCLUDED.total_deposited,
            total_deposited_usd = gift_vault_stats.total_deposited_usd + EXCLUDED.total_deposited_usd,
            last_block          = GREATEST(gift_vault_stats.last_block, EXCLUDED.last_block),
            updated_at          = GREATEST(gift_vault_stats.updated_at, EXCLUDED.updated_at);
    ELSIF NEW.event_type = 'CLAIM' THEN
        INSERT INTO gift_vault_stats
            (token_id, current_balance, total_claimed, total_claimed_usd,
             last_block, updated_at)
        VALUES
            (NEW.token_id, 0, NEW.amount, NEW.usd_value,
             NEW.block_number, NEW.created_at)
        ON CONFLICT (token_id) DO UPDATE SET
            current_balance   = 0,
            total_claimed     = gift_vault_stats.total_claimed     + EXCLUDED.total_claimed,
            total_claimed_usd = gift_vault_stats.total_claimed_usd + EXCLUDED.total_claimed_usd,
            last_block        = GREATEST(gift_vault_stats.last_block, EXCLUDED.last_block),
            updated_at        = GREATEST(gift_vault_stats.updated_at, EXCLUDED.updated_at);
    ELSIF NEW.event_type = 'EXPIRE' THEN
        INSERT INTO gift_vault_stats
            (token_id, current_state, current_balance, total_expired, total_expired_usd,
             last_block, updated_at)
        VALUES
            (NEW.token_id, 'Burned', 0, NEW.amount, NEW.usd_value,
             NEW.block_number, NEW.created_at)
        ON CONFLICT (token_id) DO UPDATE SET
            current_state     = 'Burned',
            current_balance   = 0,
            total_expired     = gift_vault_stats.total_expired     + EXCLUDED.total_expired,
            total_expired_usd = gift_vault_stats.total_expired_usd + EXCLUDED.total_expired_usd,
            last_block        = GREATEST(gift_vault_stats.last_block, EXCLUDED.last_block),
            updated_at        = GREATEST(gift_vault_stats.updated_at, EXCLUDED.updated_at);
    ELSIF NEW.event_type = 'RECEIVER_SET' THEN
        INSERT INTO gift_vault_stats
            (token_id, current_state, receiver, expires_at, receiver_set_at,
             last_block, updated_at)
        VALUES
            (NEW.token_id, 'Active', NEW.receiver, 0, NEW.created_at,
             NEW.block_number, NEW.created_at)
        ON CONFLICT (token_id) DO UPDATE SET
            current_state   = CASE gift_vault_stats.current_state
                WHEN 'Burned' THEN 'Burned'  -- terminal
                ELSE 'Active'
            END,
            receiver        = COALESCE(EXCLUDED.receiver, gift_vault_stats.receiver),
            -- receiver bound → gift no longer expires
            expires_at      = 0,
            receiver_set_at = EXCLUDED.receiver_set_at,
            last_block      = GREATEST(gift_vault_stats.last_block, EXCLUDED.last_block),
            updated_at      = GREATEST(gift_vault_stats.updated_at, EXCLUDED.updated_at);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_update_gift_vault_stats ON gifts;
CREATE TRIGGER trg_update_gift_vault_stats
AFTER INSERT ON gifts
FOR EACH ROW EXECUTE FUNCTION update_gift_vault_stats();

-- 3.5 creator_updates → token.creator
--   CreatorFeeVault.VaultSetup (initial bind) and CreatorUpdate
--   (subsequent change) are the on-chain source of truth for a token's
--   creator after graduation. Mirror new_creator into the canonical
--   `token` row so consumers can keep reading token.creator without
--   joining creator_updates.
CREATE OR REPLACE FUNCTION sync_token_creator_from_updates()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE token
       SET creator = NEW.new_creator
     WHERE token_id = NEW.token_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_token_creator_from_updates
    ON creator_updates;
CREATE TRIGGER trg_sync_token_creator_from_updates
AFTER INSERT ON creator_updates
FOR EACH ROW EXECUTE FUNCTION sync_token_creator_from_updates();

-- 3.6 creator_fee_distribution → distribution_stats
--     Aggregates 'DISTRIBUTE' rows into per-(token, vault) totals. Other
--     event_type values (e.g. 'CALLBACKFAIL') are skipped — failed
--     callbacks aren't successful fee transfers.
CREATE OR REPLACE FUNCTION update_creator_fee_distribution_stats()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.event_type <> 'DISTRIBUTE'
       OR NEW.token IS NULL
       OR NEW.vault IS NULL THEN
        RETURN NEW;
    END IF;

    INSERT INTO creator_fee_distribution_stats
        (token_id, vault_id, quote_id,
         distributed_quote, distributed_quote_usd,
         distribute_count, last_block, updated_at)
    VALUES
        (NEW.token, NEW.vault, NEW.quote_id,
         NEW.amount, NEW.usd_value,
         1, NEW.block_number, NEW.created_at)
    ON CONFLICT (token_id, vault_id) DO UPDATE SET
        distributed_quote     = creator_fee_distribution_stats.distributed_quote
                              + EXCLUDED.distributed_quote,
        distributed_quote_usd = creator_fee_distribution_stats.distributed_quote_usd
                              + EXCLUDED.distributed_quote_usd,
        distribute_count      = creator_fee_distribution_stats.distribute_count + 1,
        last_block            = GREATEST(creator_fee_distribution_stats.last_block,
                                         EXCLUDED.last_block),
        updated_at            = GREATEST(creator_fee_distribution_stats.updated_at,
                                         EXCLUDED.updated_at);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_update_creator_fee_distribution_stats
    ON creator_fee_distribution;
CREATE TRIGGER trg_update_creator_fee_distribution_stats
AFTER INSERT ON creator_fee_distribution
FOR EACH ROW EXECUTE FUNCTION update_creator_fee_distribution_stats();

-- ======================================================================
-- 4. One-time backfill from existing event data.
--    ON CONFLICT DO NOTHING makes this safe to re-run: rows the trigger
--    already maintains stay untouched.
-- ======================================================================

-- 4.1 BurnVault
INSERT INTO burn_vault_stats
    (token_id, quote_spent, tokens_burned, burn_count, last_block, updated_at)
SELECT token_id,
       SUM(quote_in),
       SUM(token_burned),
       COUNT(*),
       MAX(block_number),
       MAX(created_at)
FROM vault_burns
WHERE vault_type = 'BURN'
GROUP BY token_id
ON CONFLICT (token_id) DO NOTHING;

-- 4.2 LPVault
INSERT INTO lp_vault_stats
    (token_id, quote_injected, token_injected, lp_burned, inject_count,
     last_block, updated_at)
SELECT token_id,
       SUM(quote_used),
       SUM(token_used),
       SUM(lp_burned),
       COUNT(*),
       MAX(block_number),
       MAX(created_at)
FROM vault_lp_injections
GROUP BY token_id
ON CONFLICT (token_id) DO NOTHING;

-- 4.3 CreatorFeeVault — current_balance from latest event per token.
WITH latest AS (
    SELECT DISTINCT ON (token_id) token_id, event_type, new_balance
    FROM creator_fee_claims
    ORDER BY token_id, block_number DESC, log_index DESC
),
totals AS (
    SELECT token_id,
           COALESCE(SUM(amount) FILTER (WHERE event_type = 'DEPOSIT'), 0) AS total_deposited,
           COALESCE(SUM(amount) FILTER (WHERE event_type = 'CLAIM'),   0) AS total_claimed,
           COUNT(*) FILTER (WHERE event_type = 'DEPOSIT') AS deposit_count,
           COUNT(*) FILTER (WHERE event_type = 'CLAIM')   AS claim_count,
           MAX(block_number) AS last_block,
           MAX(created_at)   AS updated_at
    FROM creator_fee_claims
    GROUP BY token_id
)
INSERT INTO creator_fee_vault_stats
    (token_id, current_balance, total_deposited, total_claimed,
     deposit_count, claim_count, last_block, updated_at)
SELECT t.token_id,
       CASE l.event_type
           WHEN 'DEPOSIT' THEN COALESCE(l.new_balance, 0)
           ELSE 0
       END,
       t.total_deposited,
       t.total_claimed,
       t.deposit_count,
       t.claim_count,
       t.last_block,
       t.updated_at
FROM totals t
LEFT JOIN latest l USING (token_id)
ON CONFLICT (token_id) DO NOTHING;

-- 4.4 GiftVault — current_state from event presence; current_balance
--                 from latest balance-affecting event.
WITH latest_bal AS (
    SELECT DISTINCT ON (token_id) token_id, event_type, new_balance
    FROM gifts
    WHERE event_type IN ('DEPOSIT','CLAIM','EXPIRE')
    ORDER BY token_id, block_number DESC, log_index DESC
),
latest_setup AS (
    SELECT DISTINCT ON (token_id) token_id, platform, platform_id
    FROM gifts
    WHERE event_type = 'SETUP'
    ORDER BY token_id, block_number DESC, log_index DESC
),
latest_receiver AS (
    SELECT DISTINCT ON (token_id) token_id, receiver
    FROM gifts
    WHERE event_type = 'RECEIVER_SET'
    ORDER BY token_id, block_number DESC, log_index DESC
),
totals AS (
    SELECT token_id,
           CASE
               WHEN bool_or(event_type = 'EXPIRE') THEN 'Burned'
               WHEN bool_or(event_type = 'RECEIVER_SET') THEN 'Active'
               ELSE 'Accumulating'
           END AS current_state,
           COALESCE(SUM(amount) FILTER (WHERE event_type = 'DEPOSIT'), 0) AS total_deposited,
           COALESCE(SUM(amount) FILTER (WHERE event_type = 'CLAIM'),   0) AS total_claimed,
           COALESCE(SUM(amount) FILTER (WHERE event_type = 'EXPIRE'),  0) AS total_expired,
           MAX(block_number) AS last_block,
           MAX(created_at)   AS updated_at
    FROM gifts
    GROUP BY token_id
),
burns AS (
    SELECT token_id,
           SUM(quote_in)     AS buyback_quote_spent,
           SUM(token_burned) AS buyback_tokens,
           MAX(block_number) AS last_block,
           MAX(created_at)   AS updated_at
    FROM vault_burns
    WHERE vault_type = 'GIFT'
    GROUP BY token_id
)
INSERT INTO gift_vault_stats
    (token_id, current_state, current_balance,
     platform, platform_id, receiver,
     total_deposited, total_claimed, total_expired,
     buyback_quote_spent, buyback_tokens,
     last_block, updated_at)
SELECT t.token_id,
       t.current_state,
       CASE l.event_type
           WHEN 'DEPOSIT' THEN COALESCE(l.new_balance, 0)
           ELSE 0
       END,
       s.platform,
       s.platform_id,
       r.receiver,
       t.total_deposited,
       t.total_claimed,
       t.total_expired,
       COALESCE(b.buyback_quote_spent, 0),
       COALESCE(b.buyback_tokens, 0),
       GREATEST(t.last_block, COALESCE(b.last_block, 0)),
       GREATEST(t.updated_at, COALESCE(b.updated_at, 0))
FROM totals t
LEFT JOIN latest_bal l USING (token_id)
LEFT JOIN latest_setup s USING (token_id)
LEFT JOIN latest_receiver r USING (token_id)
LEFT JOIN burns b USING (token_id)
ON CONFLICT (token_id) DO NOTHING;

-- Pick up Burn-only rows (tokens that went Burned via afterDeposit
-- without a prior gifts row for them).
INSERT INTO gift_vault_stats
    (token_id, current_state, buyback_quote_spent, buyback_tokens,
     last_block, updated_at)
SELECT token_id, 'Burned', SUM(quote_in), SUM(token_burned),
       MAX(block_number), MAX(created_at)
FROM vault_burns
WHERE vault_type = 'GIFT'
GROUP BY token_id
ON CONFLICT (token_id) DO NOTHING;

-- 4.5 Materialize token.creator from the latest creator_updates row.
WITH latest_creator AS (
    SELECT DISTINCT ON (token_id) token_id, new_creator
    FROM creator_updates
    ORDER BY token_id, block_number DESC, log_index DESC
)
UPDATE token t
   SET creator = lc.new_creator
  FROM latest_creator lc
 WHERE t.token_id = lc.token_id
   AND t.creator IS DISTINCT FROM lc.new_creator;

-- 4.6 CreatorFeeDistribution — per-(token, vault) totals from event log.
INSERT INTO creator_fee_distribution_stats
    (token_id, vault_id, quote_id,
     distributed_quote, distribute_count, last_block, updated_at)
SELECT
    token,
    vault,
    MIN(quote_id),
    SUM(amount),
    COUNT(*),
    MAX(block_number),
    MAX(created_at)
FROM creator_fee_distribution
WHERE event_type = 'DISTRIBUTE'
  AND token IS NOT NULL
  AND vault IS NOT NULL
GROUP BY token, vault
ON CONFLICT (token_id, vault_id) DO NOTHING;

-- ======================================================================
-- 5. USD value materialization
-- ----------------------------------------------------------------------
-- Step A: populate quote_id + usd_value on event rows without enrichment.
-- Idempotent via the `WHERE usd_value = 0` guard.
-- Live trigger inserts will land with the correct usd_value already set,
-- so the WHERE clause skips them harmlessly.
-- ======================================================================

UPDATE vault_burns vb
   SET quote_id  = m.quote_id,
       usd_value = COALESCE(
           (vb.quote_in / POWER(10, qt.decimals)::numeric) * (
               SELECT price FROM price
                WHERE quote_id = m.quote_id
                  AND block_number <= vb.block_number
                ORDER BY block_number DESC
                LIMIT 1
           ),
           0
       )
  FROM market m
  JOIN quote_token qt ON qt.quote_id = m.quote_id
 WHERE vb.token_id = m.token_id
   AND vb.usd_value = 0;

UPDATE vault_lp_injections vli
   SET quote_id  = m.quote_id,
       usd_value = COALESCE(
           (vli.quote_used / POWER(10, qt.decimals)::numeric) * (
               SELECT price FROM price
                WHERE quote_id = m.quote_id
                  AND block_number <= vli.block_number
                ORDER BY block_number DESC
                LIMIT 1
           ),
           0
       )
  FROM market m
  JOIN quote_token qt ON qt.quote_id = m.quote_id
 WHERE vli.token_id = m.token_id
   AND vli.usd_value = 0;

UPDATE creator_fee_claims cfc
   SET quote_id  = m.quote_id,
       usd_value = COALESCE(
           (cfc.amount / POWER(10, qt.decimals)::numeric) * (
               SELECT price FROM price
                WHERE quote_id = m.quote_id
                  AND block_number <= cfc.block_number
                ORDER BY block_number DESC
                LIMIT 1
           ),
           0
       )
  FROM market m
  JOIN quote_token qt ON qt.quote_id = m.quote_id
 WHERE cfc.token_id = m.token_id
   AND cfc.usd_value = 0;

-- gifts: only DEPOSIT/CLAIM/EXPIRE rows have a real amount.
-- SETUP/RECEIVER_SET have amount NULL; leave their usd_value at default 0.
UPDATE gifts g
   SET quote_id  = m.quote_id,
       usd_value = COALESCE(
           (g.amount / POWER(10, qt.decimals)::numeric) * (
               SELECT price FROM price
                WHERE quote_id = m.quote_id
                  AND block_number <= g.block_number
                ORDER BY block_number DESC
                LIMIT 1
           ),
           0
       )
  FROM market m
  JOIN quote_token qt ON qt.quote_id = m.quote_id
 WHERE g.token_id = m.token_id
   AND g.amount IS NOT NULL
   AND g.usd_value = 0;

-- creator_fee_distribution: quote_id already on row, no market JOIN.
UPDATE creator_fee_distribution cfd
   SET usd_value = COALESCE(
           (cfd.amount / POWER(10, qt.decimals)::numeric) * (
               SELECT price FROM price
                WHERE quote_id = cfd.quote_id
                  AND block_number <= cfd.block_number
                ORDER BY block_number DESC
                LIMIT 1
           ),
           0
       )
  FROM quote_token qt
 WHERE cfd.quote_id = qt.quote_id
   AND cfd.event_type = 'DISTRIBUTE'
   AND cfd.usd_value = 0;

-- ----------------------------------------------------------------------
-- Step B: backfill cumulative USD into stats tables. Sum-aggregates
-- per token from the now-populated event rows. Guarded by `WHERE = 0`
-- so re-runs and live trigger inserts don't double-count.
-- ----------------------------------------------------------------------

WITH s AS (
    SELECT token_id, SUM(usd_value) AS quote_spent_usd
      FROM vault_burns
     WHERE vault_type = 'BURN'
     GROUP BY token_id
)
UPDATE burn_vault_stats v
   SET quote_spent_usd = s.quote_spent_usd
  FROM s
 WHERE v.token_id = s.token_id
   AND v.quote_spent_usd = 0;

WITH s AS (
    SELECT token_id, SUM(usd_value) AS quote_injected_usd
      FROM vault_lp_injections
     GROUP BY token_id
)
UPDATE lp_vault_stats v
   SET quote_injected_usd = s.quote_injected_usd
  FROM s
 WHERE v.token_id = s.token_id
   AND v.quote_injected_usd = 0;

WITH s AS (
    SELECT token_id,
           SUM(usd_value) FILTER (WHERE event_type = 'DEPOSIT') AS dep_usd,
           SUM(usd_value) FILTER (WHERE event_type = 'CLAIM')   AS clm_usd
      FROM creator_fee_claims
     GROUP BY token_id
)
UPDATE creator_fee_vault_stats v
   SET total_deposited_usd = COALESCE(s.dep_usd, 0),
       total_claimed_usd   = COALESCE(s.clm_usd, 0)
  FROM s
 WHERE v.token_id = s.token_id
   AND (v.total_deposited_usd = 0 AND v.total_claimed_usd = 0);

WITH s AS (
    SELECT token_id,
           SUM(usd_value) FILTER (WHERE event_type = 'DEPOSIT') AS dep_usd,
           SUM(usd_value) FILTER (WHERE event_type = 'CLAIM')   AS clm_usd,
           SUM(usd_value) FILTER (WHERE event_type = 'EXPIRE')  AS exp_usd
      FROM gifts
     WHERE amount IS NOT NULL
     GROUP BY token_id
),
b AS (
    SELECT token_id, SUM(usd_value) AS bb_usd
      FROM vault_burns
     WHERE vault_type = 'GIFT'
     GROUP BY token_id
)
UPDATE gift_vault_stats v
   SET total_deposited_usd     = COALESCE(s.dep_usd, 0),
       total_claimed_usd       = COALESCE(s.clm_usd, 0),
       total_expired_usd       = COALESCE(s.exp_usd, 0),
       buyback_quote_spent_usd = COALESCE(b.bb_usd, 0)
  FROM s
  LEFT JOIN b USING (token_id)
 WHERE v.token_id = s.token_id
   AND v.total_deposited_usd = 0
   AND v.total_claimed_usd = 0
   AND v.total_expired_usd = 0
   AND v.buyback_quote_spent_usd = 0;

WITH s AS (
    SELECT token AS token_id, vault AS vault_id,
           SUM(usd_value) AS distributed_quote_usd
      FROM creator_fee_distribution
     WHERE event_type = 'DISTRIBUTE'
       AND token IS NOT NULL
       AND vault IS NOT NULL
     GROUP BY token, vault
)
UPDATE creator_fee_distribution_stats v
   SET distributed_quote_usd = s.distributed_quote_usd
  FROM s
 WHERE v.token_id = s.token_id
   AND v.vault_id = s.vault_id
   AND v.distributed_quote_usd = 0;

COMMIT;

-- ============================================================================
-- >>> 0036_token_x_verification.sql
-- ============================================================================

-- 0036_token_x_verification.sql
--
-- X (Twitter) hidden-creator verification signals, scoped to a single coin:
-- pre-deploy reservation, creator self-verification, and public follower
-- attestations (including X's official "blue badge" status on each
-- attestation). See: docs/plans/2026-07-03-x-hidden-creator-verification-design.md
-- (§3-bis, §4, §7.1-B).
--
-- No FK to `token` anywhere in this file: at reserve/finalize time the token
-- row does not exist yet (the Observer indexer creates it later from the
-- on-chain event).

-- Creator self-verification result (follower count + own X handle). x_user_id
-- and x_handle are internal (operational/admin) — never exposed by the API.
CREATE TABLE IF NOT EXISTS token_x_verification (
    token_id VARCHAR(42) PRIMARY KEY,
    account_id VARCHAR(42) NOT NULL,
    x_user_id VARCHAR(32) NOT NULL,
    x_handle VARCHAR(16),
    followers_count BIGINT NOT NULL,
    verified_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_token_x_verification_account_id
    ON token_x_verification (account_id);

-- Third-party handles that provably follow the creator (max 3, public).
-- Handles that do NOT follow are never stored. is_x_verified carries X's
-- official "blue badge" status for the handle — a trust signal about the
-- PUBLIC third-party handle, not the hidden creator.
CREATE TABLE IF NOT EXISTS token_x_followed_by (
    token_id VARCHAR(42) NOT NULL
        REFERENCES token_x_verification(token_id) ON DELETE CASCADE,
    x_handle VARCHAR(16) NOT NULL,
    x_image_uri VARCHAR NOT NULL,
    x_followers_count BIGINT NOT NULL,
    is_x_verified BOOLEAN NOT NULL DEFAULT FALSE,
    checked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (token_id, x_handle)
);

-- Pre-deploy reservation binding a CREATE2 token_id to a session account while
-- the salt is still secret (before on-chain deployment). finalize checks only
-- that this reservation belongs to the session (design §3-bis, §7.1-B).
--
-- No FK to `token` or `token_x_verification`: the reservation is created BEFORE
-- either row exists. token_id is stored EIP-55 checksummed (never LOWER()).
-- The row is immutable once created (account_id never changes) — this is what
-- makes the reserve INSERT a sound first-writer-wins record.
CREATE TABLE IF NOT EXISTS token_x_reservation (
    token_id VARCHAR(42) PRIMARY KEY,
    account_id VARCHAR(42) NOT NULL,
    reserved_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_token_x_reservation_account_id
    ON token_x_reservation (account_id);

-- ============================================================================
-- >>> 0037_dev_post.sql
-- ============================================================================

-- Dev Post feature: coin-creator posts with images, polls, likes, votes.
-- Design: docs/plans/2026-07-07-dev-post-api-design.md
-- The GIWA deployment uses a plain PostgreSQL sequence for post ids.
CREATE SEQUENCE IF NOT EXISTS dev_post_snowflake_seq;

CREATE TABLE IF NOT EXISTS dev_post (
    id          BIGINT PRIMARY KEY DEFAULT nextval('dev_post_snowflake_seq'),
    token_id    VARCHAR(42) NOT NULL,
    author      VARCHAR(42) NOT NULL,
    title       TEXT        NOT NULL DEFAULT '',
    body        TEXT        NOT NULL DEFAULT '',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    posted_on   DATE GENERATED ALWAYS AS ((created_at AT TIME ZONE 'UTC')::date) STORED,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    edited_at   TIMESTAMPTZ,
    deleted_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_dev_post_token_created ON dev_post (token_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_dev_post_created       ON dev_post (created_at DESC)            WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_dev_post_author        ON dev_post (author)                     WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS dev_post_image (
    post_id   BIGINT   NOT NULL REFERENCES dev_post(id) ON DELETE CASCADE,
    position  SMALLINT NOT NULL,
    image_uri TEXT     NOT NULL,
    PRIMARY KEY (post_id, position)
);

CREATE TABLE IF NOT EXISTS dev_post_poll (
    post_id   BIGINT      PRIMARY KEY REFERENCES dev_post(id) ON DELETE CASCADE,
    closes_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS dev_post_poll_option (
    post_id   BIGINT   NOT NULL REFERENCES dev_post_poll(post_id) ON DELETE CASCADE,
    position  SMALLINT NOT NULL,
    label     TEXT     NOT NULL,
    image_uri TEXT,
    PRIMARY KEY (post_id, position)
);

CREATE TABLE IF NOT EXISTS dev_post_like (
    post_id    BIGINT      NOT NULL REFERENCES dev_post(id) ON DELETE CASCADE,
    account_id VARCHAR(42) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (post_id, account_id)
);
CREATE INDEX IF NOT EXISTS idx_dev_post_like_created ON dev_post_like (created_at, post_id);

CREATE TABLE IF NOT EXISTS dev_post_poll_vote (
    post_id         BIGINT      NOT NULL REFERENCES dev_post_poll(post_id) ON DELETE CASCADE,
    account_id      VARCHAR(42) NOT NULL,
    option_position SMALLINT    NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (post_id, account_id),
    FOREIGN KEY (post_id, option_position) REFERENCES dev_post_poll_option(post_id, position)
);

-- ============================================================================
-- >>> 0039_dev_post_pin.sql
-- ============================================================================

CREATE TABLE IF NOT EXISTS dev_post_pin (
    token_id VARCHAR(42) PRIMARY KEY
        REFERENCES token(token_id) ON DELETE CASCADE,
    post_id BIGINT NOT NULL UNIQUE
        REFERENCES dev_post(id) ON DELETE CASCADE,
    pinned_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- >>> 0040_dev_post_moderation_log.sql
-- ============================================================================

CREATE TABLE IF NOT EXISTS dev_post_moderation_log (
    id               UUID        PRIMARY KEY,
    post_id          BIGINT      NOT NULL CHECK (post_id > 0),
    token_id         VARCHAR(42) NOT NULL,
    admin_account_id VARCHAR(42) NOT NULL,
    action           VARCHAR(8)  NOT NULL
        CHECK (action IN ('DELETE', 'RESTORE')),
    changed          BOOLEAN     NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS idx_dev_post_moderation_log_post_created
    ON dev_post_moderation_log (post_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_dev_post_moderation_log_admin_created
    ON dev_post_moderation_log (admin_account_id, created_at DESC);

-- ============================================================================
-- >>> 0042_dev_post_daily_limit.sql
-- ============================================================================

-- Daily dev-post limit support: up to N posts (currently 3, app-enforced)
-- per token per UTC calendar day.
--
-- posted_on is a stored generated column so the app's count gate
-- (`WHERE token_id = $1 AND posted_on = <today UTC>`) is a cheap indexed
-- lookup. Enforcement lives in create_post's CTE — a unique index can cap at
-- exactly one row but cannot express "at most 3", so a burst of concurrent
-- creates can momentarily exceed the cap; acceptable for spam limiting.
--
-- Deleted posts still count toward the day's quota (the app counts without a
-- deleted_at filter): deleting does not free a slot, edits exist for
-- corrections.

CREATE INDEX IF NOT EXISTS idx_dev_post_token_daily
    ON dev_post (token_id, posted_on);
