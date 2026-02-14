-- =============================================================
-- API Usage Tracking
-- =============================================================
SET search_path = public, ag_catalog, "$user";

-- Tracks every LLM and embedding API call for cost analysis.
-- Inspired by OpenClaw's provider-usage system, but stored in
-- Postgres (our brain) rather than JSONL transcript files.

-- -------------------------------------------------------------
-- Table
-- -------------------------------------------------------------

CREATE TABLE api_usage (
    id              BIGSERIAL PRIMARY KEY,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    provider        TEXT NOT NULL,            -- e.g. 'anthropic', 'openai', 'gemini', 'ollama'
    model           TEXT NOT NULL,            -- e.g. 'claude-opus-4-6', 'gpt-4o'
    operation       TEXT NOT NULL DEFAULT 'chat',  -- 'chat', 'embed', 'image', 'stream'
    input_tokens    INT NOT NULL DEFAULT 0,
    output_tokens   INT NOT NULL DEFAULT 0,
    cache_read_tokens  INT NOT NULL DEFAULT 0,
    cache_write_tokens INT NOT NULL DEFAULT 0,
    total_tokens    INT GENERATED ALWAYS AS (
        input_tokens + output_tokens + cache_read_tokens + cache_write_tokens
    ) STORED,
    cost_usd        NUMERIC(12, 6),          -- NULL if unknown
    session_key     TEXT,                     -- correlate to chat/heartbeat session
    source          TEXT NOT NULL DEFAULT 'chat',  -- 'chat', 'heartbeat', 'cron', 'sub_agent', 'maintenance'
    metadata        JSONB NOT NULL DEFAULT '{}'
);

-- -------------------------------------------------------------
-- Indexes
-- -------------------------------------------------------------

CREATE INDEX idx_api_usage_created
    ON api_usage (created_at DESC);

CREATE INDEX idx_api_usage_provider
    ON api_usage (provider, created_at DESC);

CREATE INDEX idx_api_usage_source
    ON api_usage (source, created_at DESC);

CREATE INDEX idx_api_usage_session
    ON api_usage (session_key, created_at DESC)
    WHERE session_key IS NOT NULL;

-- -------------------------------------------------------------
-- Functions
-- -------------------------------------------------------------

-- Record a single API usage entry
CREATE FUNCTION record_api_usage(
    p_provider TEXT,
    p_model TEXT,
    p_operation TEXT DEFAULT 'chat',
    p_input_tokens INT DEFAULT 0,
    p_output_tokens INT DEFAULT 0,
    p_cache_read_tokens INT DEFAULT 0,
    p_cache_write_tokens INT DEFAULT 0,
    p_cost_usd NUMERIC DEFAULT NULL,
    p_session_key TEXT DEFAULT NULL,
    p_source TEXT DEFAULT 'chat',
    p_metadata JSONB DEFAULT '{}'
) RETURNS BIGINT AS $$
    INSERT INTO api_usage (
        provider, model, operation,
        input_tokens, output_tokens,
        cache_read_tokens, cache_write_tokens,
        cost_usd, session_key, source, metadata
    ) VALUES (
        p_provider, p_model, p_operation,
        p_input_tokens, p_output_tokens,
        p_cache_read_tokens, p_cache_write_tokens,
        p_cost_usd, p_session_key, p_source, p_metadata
    )
    RETURNING id;
$$ LANGUAGE sql;


-- Summarize usage for a time range, grouped by provider + model
CREATE FUNCTION usage_summary(
    p_since INTERVAL DEFAULT '30 days',
    p_source TEXT DEFAULT NULL
) RETURNS TABLE (
    provider TEXT,
    model TEXT,
    operation TEXT,
    call_count BIGINT,
    total_input_tokens BIGINT,
    total_output_tokens BIGINT,
    total_cache_read BIGINT,
    total_cache_write BIGINT,
    total_tokens BIGINT,
    total_cost NUMERIC
) AS $$
    SELECT
        u.provider,
        u.model,
        u.operation,
        count(*) AS call_count,
        sum(u.input_tokens)::bigint AS total_input_tokens,
        sum(u.output_tokens)::bigint AS total_output_tokens,
        sum(u.cache_read_tokens)::bigint AS total_cache_read,
        sum(u.cache_write_tokens)::bigint AS total_cache_write,
        sum(u.total_tokens)::bigint AS total_tokens,
        sum(u.cost_usd) AS total_cost
    FROM api_usage u
    WHERE u.created_at >= now() - p_since
      AND (p_source IS NULL OR u.source = p_source)
    GROUP BY u.provider, u.model, u.operation
    ORDER BY total_cost DESC NULLS LAST, total_tokens DESC;
$$ LANGUAGE sql STABLE;


-- Daily cost breakdown for a time range
CREATE FUNCTION usage_daily(
    p_since INTERVAL DEFAULT '30 days',
    p_source TEXT DEFAULT NULL
) RETURNS TABLE (
    day DATE,
    provider TEXT,
    model TEXT,
    call_count BIGINT,
    total_tokens BIGINT,
    total_cost NUMERIC
) AS $$
    SELECT
        date_trunc('day', u.created_at)::date AS day,
        u.provider,
        u.model,
        count(*) AS call_count,
        sum(u.total_tokens)::bigint AS total_tokens,
        sum(u.cost_usd) AS total_cost
    FROM api_usage u
    WHERE u.created_at >= now() - p_since
      AND (p_source IS NULL OR u.source = p_source)
    GROUP BY day, u.provider, u.model
    ORDER BY day DESC, total_cost DESC NULLS LAST;
$$ LANGUAGE sql STABLE;


-- Cleanup old usage records (default: keep 90 days)
CREATE FUNCTION usage_cleanup(p_older_than INTERVAL DEFAULT '90 days')
RETURNS INTEGER AS $$
    WITH deleted AS (
        DELETE FROM api_usage
        WHERE created_at < now() - p_older_than
        RETURNING 1
    )
    SELECT count(*)::integer FROM deleted;
$$ LANGUAGE sql;
