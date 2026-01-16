-- ============================================================================
-- HEXIS MEMORY SYSTEM - FINAL SCHEMA
-- ============================================================================
-- Architecture:
--   - Relational: Core storage, clusters, acceleration, identity
--   - Graph (AGE): Reasoning layer (memories + concepts only)
--   - Vector (pgvector): Semantic similarity search
-- ============================================================================

-- ============================================================================
-- EXTENSIONS
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS age;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS http;
-- Required for gen_random_uuid() + sha256()
CREATE EXTENSION IF NOT EXISTS pgcrypto;

LOAD 'age';
SET search_path = ag_catalog, "$user", public;

-- ============================================================================
-- GRAPH INITIALIZATION
-- ============================================================================

SELECT create_graph('memory_graph');
SELECT create_vlabel('memory_graph', 'MemoryNode');
SELECT create_vlabel('memory_graph', 'ConceptNode');
SELECT create_vlabel('memory_graph', 'SelfNode');
SELECT create_vlabel('memory_graph', 'LifeChapterNode');
SELECT create_vlabel('memory_graph', 'TurningPointNode');
SELECT create_vlabel('memory_graph', 'NarrativeThreadNode');
SELECT create_vlabel('memory_graph', 'RelationshipNode');
SELECT create_vlabel('memory_graph', 'ValueConflictNode');
-- Phase 6 (ReduceScopeCreep): GoalNode for graph-based goal relationships
-- GoalsRoot is an anchor node for O(1) goal retrieval
SELECT create_vlabel('memory_graph', 'GoalNode');
SELECT create_vlabel('memory_graph', 'GoalsRoot');
-- Phase 3 (ReduceScopeCreep): ClusterNode for graph-based cluster relationships
SELECT create_vlabel('memory_graph', 'ClusterNode');
-- Phase 4 (ReduceScopeCreep): EpisodeNode for graph-based episode relationships
SELECT create_vlabel('memory_graph', 'EpisodeNode');

SET search_path = public, ag_catalog, "$user";

-- ============================================================================
-- ENUMS
-- ============================================================================

-- Phase 5 (ReduceScopeCreep): Added 'worldview' type for beliefs that filter perception
-- Worldview memories store beliefs, values, boundaries, and other core identity elements
-- metadata schema: {category, confidence, stability, origin, trigger_patterns, response_type, etc.}
-- Phase 6 (ReduceScopeCreep): Added 'goal' type for goals/intentions stored as memories
-- Goal metadata schema: {title, description, priority, source, due_at, progress, blocked_by, emotional_valence, last_touched, parent_goal_id}
CREATE TYPE memory_type AS ENUM ('episodic', 'semantic', 'procedural', 'strategic', 'worldview', 'goal');
CREATE TYPE memory_status AS ENUM ('active', 'archived', 'invalidated');
CREATE TYPE cluster_type AS ENUM ('theme', 'emotion', 'temporal', 'person', 'pattern', 'mixed');
CREATE TYPE graph_edge_type AS ENUM (
    'TEMPORAL_NEXT',
    'CAUSES',
    'DERIVED_FROM',
    'CONTRADICTS',
    'SUPPORTS',
    'INSTANCE_OF',
    'PARENT_OF',
    'ASSOCIATED',
    -- Phase 6 (ReduceScopeCreep): Goal relationship edges
    'ORIGINATED_FROM',  -- Goal originated from a memory
    'BLOCKS',           -- Memory/goal blocks another goal
    'EVIDENCE_FOR',     -- Memory provides evidence for goal progress
    'SUBGOAL_OF',       -- Goal is a subgoal of parent goal
    -- Phase 3 (ReduceScopeCreep): Cluster relationship edges
    'CLUSTER_RELATES',  -- General cluster relationship
    'CLUSTER_OVERLAPS', -- Clusters share significant members
    'CLUSTER_SIMILAR',  -- Clusters have similar centroids
    -- Phase 4 (ReduceScopeCreep): Episode relationship edges
    'IN_EPISODE',       -- Memory is part of an episode
    'EPISODE_FOLLOWS'   -- Episode temporal sequence
);

-- ============================================================================
-- CORE STORAGE
-- ============================================================================

-- Base memory table (unified with JSONB metadata for type-specific fields)
-- Metadata schema by type:
--   episodic: {action_taken, context, result, emotional_valence, verification_status, event_time}
--   semantic: {confidence, last_validated, source_references, contradictions, category, related_concepts}
--   procedural: {steps, prerequisites, success_count, total_attempts, average_duration_seconds, failure_points}
--   strategic: {pattern_description, supporting_evidence, confidence_score, success_metrics, adaptation_history, context_applicability}
CREATE TABLE memories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    type memory_type NOT NULL,
    status memory_status DEFAULT 'active',
    content TEXT NOT NULL,
    embedding vector(768) NOT NULL,
    importance FLOAT DEFAULT 0.5,
    -- Provenance + epistemic trust
    source_attribution JSONB NOT NULL DEFAULT '{}'::jsonb,
    trust_level FLOAT NOT NULL DEFAULT 0.5 CHECK (trust_level >= 0 AND trust_level <= 1),
    trust_updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    access_count INTEGER DEFAULT 0,
    last_accessed TIMESTAMPTZ,
    decay_rate FLOAT DEFAULT 0.01,
    -- Type-specific metadata (replaces episodic_memories, semantic_memories, procedural_memories, strategic_memories tables)
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

-- Working memory (transient, short-term)
-- Phase 9 (ReduceScopeCreep): UNLOGGED for faster transient storage (no WAL overhead)
-- Working memory is ephemeral by design - safe to lose on crash
CREATE UNLOGGED TABLE working_memory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    content TEXT NOT NULL,
    embedding vector(768) NOT NULL,
    importance FLOAT DEFAULT 0.3,
    source_attribution JSONB NOT NULL DEFAULT '{}'::jsonb,
    trust_level FLOAT NOT NULL DEFAULT 0.5 CHECK (trust_level >= 0 AND trust_level <= 1),
    access_count INTEGER DEFAULT 0,
    last_accessed TIMESTAMPTZ,
    promote_to_long_term BOOLEAN NOT NULL DEFAULT FALSE,
    expiry TIMESTAMPTZ
);

-- Phase 10 (ReduceScopeCreep): ingestion_receipts table removed.
-- Idempotency now uses memories.source_attribution->>'content_hash' instead.

CREATE INDEX IF NOT EXISTS idx_memories_source_content_hash
    ON memories ((source_attribution->>'content_hash'))
    WHERE source_attribution->>'content_hash' IS NOT NULL;

-- ============================================================================
-- CLUSTERING (Relational Only)
-- ============================================================================

CREATE TABLE clusters (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    cluster_type cluster_type NOT NULL,
    name TEXT NOT NULL,
    centroid_embedding vector(768)
);

-- Phase 3 (ReduceScopeCreep): memory_cluster_members table removed - use graph edges instead
-- Cluster membership is now stored in graph using MEMBER_OF edges from MemoryNode to ClusterNode
-- See: link_memory_to_cluster_graph(), get_cluster_members_graph()

-- Phase 3 (ReduceScopeCreep): cluster_relationships table removed - use graph edges instead
-- Cluster-to-cluster relationships are now stored in graph using CLUSTER_RELATES, CLUSTER_OVERLAPS, CLUSTER_SIMILAR edges

-- ============================================================================
-- ACCELERATION LAYER
-- ============================================================================

-- Episodes: Temporal segmentation for narrative coherence
CREATE TABLE episodes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    summary TEXT,
    summary_embedding vector(768),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    time_range TSTZRANGE GENERATED ALWAYS AS (
        tstzrange(started_at, COALESCE(ended_at, 'infinity'::timestamptz))
    ) STORED
);

-- Phase 4 (ReduceScopeCreep): episode_memories table removed - use graph edges instead
-- Episode membership is now stored in graph using IN_EPISODE edges from MemoryNode to EpisodeNode
-- See: link_memory_to_episode_graph(), find_episode_memories_graph()

-- Phase 4 (ReduceScopeCreep): Link memory to episode via graph edge
CREATE OR REPLACE FUNCTION link_memory_to_episode_graph(
    p_memory_id UUID,
    p_episode_id UUID,
    p_sequence_order INT DEFAULT 0
)
RETURNS BOOLEAN AS $$
BEGIN
    -- Ensure episode node exists
    PERFORM sync_episode_node(p_episode_id);
    -- Ensure memory node exists (trigger fires before create_memory adds node)
    PERFORM sync_memory_node(p_memory_id);

    EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MATCH (m:MemoryNode {memory_id: %L})
        MATCH (e:EpisodeNode {episode_id: %L})
        CREATE (m)-[:IN_EPISODE {sequence_order: %s}]->(e)
        RETURN m
    $q$) as (result agtype)', p_memory_id, p_episode_id, p_sequence_order);

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Phase 4 (ReduceScopeCreep): Find memories in episode via graph
CREATE OR REPLACE FUNCTION find_episode_memories_graph(p_episode_id UUID)
RETURNS TABLE (
    memory_id UUID,
    sequence_order INT
) AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MATCH (m:MemoryNode)-[e:IN_EPISODE]->(ep:EpisodeNode {episode_id: %L})
        RETURN m.memory_id, e.sequence_order
        ORDER BY e.sequence_order
    $q$) as (memory_id agtype, seq agtype)', p_episode_id)
    LOOP
        -- Strip quotes from agtype values before casting
        memory_id := replace(rec.memory_id::text, '"', '')::uuid;
        sequence_order := COALESCE(replace(rec.seq::text, '"', '')::int, 0);
        RETURN NEXT;
    END LOOP;
EXCEPTION WHEN OTHERS THEN
    RETURN;
END;
$$ LANGUAGE plpgsql;

-- Precomputed neighborhoods (replaces live spreading activation)
CREATE TABLE memory_neighborhoods (
    memory_id UUID PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
    neighbors JSONB NOT NULL DEFAULT '{}',  -- {uuid: weight}
    computed_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    is_stale BOOLEAN DEFAULT TRUE
);

-- Fetch memory neighborhoods for given ids (application-facing).
CREATE OR REPLACE FUNCTION get_memory_neighborhoods(p_ids UUID[])
RETURNS TABLE (
    memory_id UUID,
    neighbors JSONB
) AS $$
BEGIN
    IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT mn.memory_id, mn.neighbors
    FROM memory_neighborhoods mn
    WHERE mn.memory_id = ANY(p_ids);
END;
$$ LANGUAGE plpgsql STABLE;

-- Transient activation cache (fast writes, lost on crash)
CREATE UNLOGGED TABLE activation_cache (
    session_id UUID,
    memory_id UUID,
    activation_level FLOAT,
    computed_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (session_id, memory_id)
);

-- ============================================================================
-- CONCEPT LAYER
-- ============================================================================

-- concepts and memory_concepts tables removed in Phase 2 (ReduceScopeCreep)
-- Concepts are now stored entirely in the graph as ConceptNode vertices.
-- Memory-to-concept links are INSTANCE_OF edges: MemoryNode --[INSTANCE_OF {strength}]--> ConceptNode
-- Use link_memory_to_concept() to create links, find_memories_by_concept() to query.

-- ============================================================================
-- IDENTITY & WORLDVIEW
-- ============================================================================
-- Phase 5 (ReduceScopeCreep): worldview_primitives, worldview_memory_influences,
-- identity_aspects, identity_memory_resonance tables removed.
--
-- Worldview elements (beliefs, values, boundaries) are now memories with type='worldview'
-- and metadata containing: category, confidence, stability, origin, trigger_patterns, etc.
-- Use create_worldview_memory() to create new worldview memories.
--
-- Identity aspects are now graph edges from SelfNode:
--   SelfNode --[HAS_BELIEF]--> MemoryNode(worldview)
--   SelfNode --[CAPABLE_OF]--> ConceptNode
--   SelfNode --[VALUES]--> ConceptNode
-- Use upsert_self_concept_edge() to manage identity edges.

-- ============================================================================
-- AUDIT & CACHE
-- ============================================================================

-- memory_changes table removed in Phase 8 (ReduceScopeCreep) - audit data can be
-- reconstructed from heartbeat_log if needed.

CREATE TABLE embedding_cache (
    content_hash TEXT PRIMARY KEY,
    embedding vector(768) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- UNIFIED CONFIG TABLE (must be defined early for embedding functions)
-- ============================================================================

CREATE TABLE IF NOT EXISTS config (
    key TEXT PRIMARY KEY,
    value JSONB NOT NULL,
    description TEXT,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Initial embedding config entries (will be expanded later)
INSERT INTO config (key, value, description) VALUES
    ('embedding.service_url', '"http://embeddings:80/embed"'::jsonb, 'URL of the embedding service'),
    ('embedding.dimension', to_jsonb(COALESCE(NULLIF(current_setting('app.embedding_dimension', true), ''), '768')::int), 'Embedding vector dimension'),
    ('embedding.retry_seconds', '30'::jsonb, 'Total seconds to retry embedding requests'),
    ('embedding.retry_interval_seconds', '1.0'::jsonb, 'Seconds between retry attempts')
ON CONFLICT (key) DO NOTHING;

-- Phase 7 (ReduceScopeCreep): embedding_config table removed - use unified config table only

-- Return the configured embedding dimension (from config, or postgres setting fallback).
-- Note: Cannot use get_config_int helper here since this function is called during schema init
-- before the helper functions are defined.
CREATE OR REPLACE FUNCTION embedding_dimension()
RETURNS INT
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT (value #>> '{}')::int FROM config WHERE key = 'embedding.dimension'),
        NULLIF(current_setting('app.embedding_dimension', true), '')::int,
        768
    );
$$;

-- Keep embedding dimension synchronized with the docker-compose postgres setting (if present).
CREATE OR REPLACE FUNCTION sync_embedding_dimension_config()
RETURNS INT AS $$
DECLARE
    configured TEXT;
BEGIN
    configured := NULLIF(current_setting('app.embedding_dimension', true), '');
    IF configured IS NULL THEN
        RETURN embedding_dimension();
    END IF;

    -- Update unified config table
    INSERT INTO config (key, value, description, updated_at)
    VALUES ('embedding.dimension', to_jsonb(configured::int), 'Embedding vector dimension', CURRENT_TIMESTAMP)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at;

    RETURN configured::int;
END;
$$ LANGUAGE plpgsql;

-- Align vector column dimensions to the configured embedding dimension (required for HNSW indexes).
DO $$
DECLARE
    dim INT;
BEGIN
    dim := sync_embedding_dimension_config();

    EXECUTE format(
        'ALTER TABLE memories ALTER COLUMN embedding TYPE vector(%s) USING embedding::vector(%s)',
        dim,
        dim
    );
    EXECUTE format(
        'ALTER TABLE working_memory ALTER COLUMN embedding TYPE vector(%s) USING embedding::vector(%s)',
        dim,
        dim
    );
    EXECUTE format(
        'ALTER TABLE embedding_cache ALTER COLUMN embedding TYPE vector(%s) USING embedding::vector(%s)',
        dim,
        dim
    );
    EXECUTE format(
        'ALTER TABLE clusters ALTER COLUMN centroid_embedding TYPE vector(%s) USING centroid_embedding::vector(%s)',
        dim,
        dim
    );
    EXECUTE format(
        'ALTER TABLE episodes ALTER COLUMN summary_embedding TYPE vector(%s) USING summary_embedding::vector(%s)',
        dim,
        dim
    );
END;
$$;

-- ============================================================================
-- INDEXES
-- ============================================================================

-- Memory indexes
CREATE INDEX idx_memories_embedding ON memories USING hnsw (embedding vector_cosine_ops);
CREATE INDEX idx_memories_status ON memories (status);
CREATE INDEX idx_memories_type ON memories (type);
CREATE INDEX idx_memories_content ON memories USING GIN (content gin_trgm_ops);
CREATE INDEX idx_memories_importance ON memories (importance DESC) WHERE status = 'active';
CREATE INDEX idx_memories_created ON memories (created_at DESC);
CREATE INDEX idx_memories_last_accessed ON memories (last_accessed DESC NULLS LAST);
-- Metadata indexes (for type-specific queries)
CREATE INDEX idx_memories_metadata ON memories USING GIN (metadata);
CREATE INDEX idx_memories_emotional_valence ON memories ((metadata->>'emotional_valence')) WHERE type = 'episodic';
CREATE INDEX idx_memories_confidence ON memories ((metadata->>'confidence')) WHERE type = 'semantic';

-- Working memory
CREATE INDEX idx_working_memory_expiry ON working_memory (expiry);
CREATE INDEX idx_working_memory_embedding ON working_memory USING hnsw (embedding vector_cosine_ops);

-- Cluster indexes
CREATE INDEX idx_clusters_centroid ON clusters USING hnsw (centroid_embedding vector_cosine_ops);
CREATE INDEX idx_clusters_type ON clusters (cluster_type);
-- Phase 3 (ReduceScopeCreep): memory_cluster_members indexes removed - table replaced by graph edges
-- Phase 3 (ReduceScopeCreep): cluster_relationships indexes removed - table replaced by graph edges

-- Episode indexes
CREATE INDEX idx_episodes_time_range ON episodes USING GIST (time_range);
CREATE INDEX idx_episodes_summary_embedding ON episodes USING hnsw (summary_embedding vector_cosine_ops);
CREATE INDEX idx_episodes_started ON episodes (started_at DESC);
-- Phase 4 (ReduceScopeCreep): episode_memories indexes removed - table replaced by graph edges

-- Neighborhood indexes
CREATE INDEX idx_neighborhoods_stale ON memory_neighborhoods (is_stale) WHERE is_stale = TRUE;
CREATE INDEX idx_neighborhoods_neighbors ON memory_neighborhoods USING GIN (neighbors);

-- Concept indexes removed in Phase 2 (concepts table removed)

-- Identity/worldview indexes removed in Phase 5 (tables removed)
-- Worldview data is now in memories table with type='worldview'
CREATE INDEX idx_memories_worldview_category ON memories ((metadata->>'category'))
    WHERE type = 'worldview';

-- Phase 6 (ReduceScopeCreep): Goal memory indexes
-- Note: Using text-based indexes because timestamptz casts aren't IMMUTABLE
CREATE INDEX idx_memories_goal_priority ON memories ((metadata->>'priority'))
    WHERE type = 'goal';

-- Cache indexes
CREATE INDEX idx_embedding_cache_created ON embedding_cache (created_at);

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Calculate age in days (used for decay)
CREATE OR REPLACE FUNCTION age_in_days(ts TIMESTAMPTZ) 
RETURNS FLOAT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT EXTRACT(EPOCH FROM (NOW() - ts)) / 86400.0;
$$;

-- Calculate relevance score dynamically
CREATE OR REPLACE FUNCTION calculate_relevance(
    p_importance FLOAT,
    p_decay_rate FLOAT,
    p_created_at TIMESTAMPTZ,
    p_last_accessed TIMESTAMPTZ
) RETURNS FLOAT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT p_importance * EXP(
        -p_decay_rate * LEAST(
            age_in_days(p_created_at),
            COALESCE(age_in_days(p_last_accessed), age_in_days(p_created_at)) * 0.5
        )
    );
$$;

-- Get embedding from service (with caching)
CREATE OR REPLACE FUNCTION get_embedding(text_content TEXT)
RETURNS vector AS $$
	DECLARE
	    service_url TEXT;
	    response http_response;
	    request_body TEXT;
	    embedding_array FLOAT[];
	    embedding_json JSONB;
	    v_content_hash TEXT;
	    cached_embedding vector;
	    expected_dim INT;
	    start_ts TIMESTAMPTZ;
	    retry_seconds INT;
	    retry_interval_seconds FLOAT;
	    last_error TEXT;
	BEGIN
	    PERFORM sync_embedding_dimension_config();
	    expected_dim := embedding_dimension();

	    -- Generate hash for caching
	    v_content_hash := encode(sha256(text_content::bytea), 'hex');

    -- Check cache first
    SELECT ec.embedding INTO cached_embedding
    FROM embedding_cache ec
    WHERE ec.content_hash = v_content_hash;

    IF FOUND THEN
        RETURN cached_embedding;
    END IF;

    -- Get service URL from unified config
    -- Note: Cannot use helper functions here as they're defined later in schema
	    service_url := (SELECT CASE WHEN jsonb_typeof(value) = 'string' THEN value #>> '{}' ELSE value::text END FROM config WHERE key = 'embedding.service_url');

	    -- Prepare request body
	    request_body := json_build_object('inputs', text_content)::TEXT;

	    -- Make HTTP request (with retries to tolerate a slow-starting embedding service).
	    retry_seconds := COALESCE(
	        (SELECT (value #>> '{}')::int FROM config WHERE key = 'embedding.retry_seconds'),
	        30
	    );
	    retry_interval_seconds := COALESCE(
	        (SELECT (value #>> '{}')::float FROM config WHERE key = 'embedding.retry_interval_seconds'),
	        1.0
	    );
	    start_ts := clock_timestamp();

	    LOOP
	        BEGIN
	            SELECT * INTO response FROM http_post(
	                service_url,
	                request_body,
	                'application/json'
	            );

	            IF response.status = 200 THEN
	                EXIT;
	            END IF;

	            -- Non-retriable statuses (bad request, auth, etc).
	            IF response.status IN (400, 401, 403, 404, 422) THEN
	                RAISE EXCEPTION 'Embedding service error: % - %', response.status, response.content;
	            END IF;

	            last_error := format('status %s: %s', response.status, left(COALESCE(response.content, ''), 500));
	        EXCEPTION
	            WHEN OTHERS THEN
	                last_error := SQLERRM;
	        END;

	        IF retry_seconds <= 0 OR clock_timestamp() - start_ts >= (retry_seconds || ' seconds')::interval THEN
	            RAISE EXCEPTION 'Embedding service not available after % seconds: %', retry_seconds, COALESCE(last_error, '<unknown>');
	        END IF;

	        PERFORM pg_sleep(GREATEST(0.0, retry_interval_seconds));
	    END LOOP;

	    -- Parse response
	    embedding_json := response.content::JSONB;

    -- Extract embedding array (handle different response formats)
    IF embedding_json ? 'embeddings' THEN
        -- Format: {"embeddings": [[...]]}
        embedding_array := ARRAY(
            SELECT jsonb_array_elements_text((embedding_json->'embeddings')->0)::FLOAT
        );
    ELSIF embedding_json ? 'embedding' THEN
        -- Format: {"embedding": [...]}
        embedding_array := ARRAY(
            SELECT jsonb_array_elements_text(embedding_json->'embedding')::FLOAT
        );
    ELSIF embedding_json ? 'data' THEN
        -- OpenAI format: {"data": [{"embedding": [...]}]}
        embedding_array := ARRAY(
            SELECT jsonb_array_elements_text((embedding_json->'data')->0->'embedding')::FLOAT
        );
    ELSIF jsonb_typeof(embedding_json->0) = 'array' THEN
        -- HuggingFace TEI format: [[...]] (array of arrays)
        embedding_array := ARRAY(
            SELECT jsonb_array_elements_text(embedding_json->0)::FLOAT
        );
    ELSE
        -- Flat array format: [...]
        embedding_array := ARRAY(
            SELECT jsonb_array_elements_text(embedding_json)::FLOAT
        );
	    END IF;
	
	    -- Validate embedding size
	    IF array_length(embedding_array, 1) IS NULL OR array_length(embedding_array, 1) != expected_dim THEN
	        RAISE EXCEPTION 'Invalid embedding dimension: expected %, got %', expected_dim, array_length(embedding_array, 1);
	    END IF;
	
	    -- Cache the result
	    INSERT INTO embedding_cache (content_hash, embedding)
	    VALUES (v_content_hash, embedding_array::vector)
	    ON CONFLICT DO NOTHING;
	
	    RETURN embedding_array::vector;
	EXCEPTION
	    WHEN OTHERS THEN
	        RAISE EXCEPTION 'Failed to get embedding: %', SQLERRM;
	END;
$$ LANGUAGE plpgsql;

-- Check embedding service health
CREATE OR REPLACE FUNCTION check_embedding_service_health()
RETURNS BOOLEAN AS $$
DECLARE
    service_url TEXT;
    health_url TEXT;
    response http_response;
BEGIN
    -- Get service URL from unified config
    -- Note: Cannot use helper functions here as they're defined later in schema
    service_url := (SELECT CASE WHEN jsonb_typeof(value) = 'string' THEN value #>> '{}' ELSE value::text END FROM config WHERE key = 'embedding.service_url');

    -- Extract base URL (scheme + host + port) using regexp, then append /health
    -- e.g., http://embeddings:80/embed -> http://embeddings:80/health
    health_url := regexp_replace(service_url, '^(https?://[^/]+).*$', '\1/health');

    SELECT * INTO response FROM http_get(health_url);

    RETURN response.status = 200;
EXCEPTION
    WHEN OTHERS THEN
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Update memory timestamp on modification
CREATE OR REPLACE FUNCTION update_memory_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_memory_timestamp
    BEFORE UPDATE ON memories
    FOR EACH ROW
    EXECUTE FUNCTION update_memory_timestamp();

-- Update importance based on access
CREATE OR REPLACE FUNCTION update_memory_importance()
RETURNS TRIGGER AS $$
BEGIN
    NEW.importance = NEW.importance * (1.0 + (LN(NEW.access_count + 1) * 0.1));
    NEW.last_accessed = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_importance_on_access
    BEFORE UPDATE ON memories
    FOR EACH ROW
    WHEN (NEW.access_count != OLD.access_count)
    EXECUTE FUNCTION update_memory_importance();

-- Mark neighborhoods stale when memories change significantly
CREATE OR REPLACE FUNCTION mark_neighborhoods_stale()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE memory_neighborhoods 
    SET is_stale = TRUE 
    WHERE memory_id = NEW.id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_neighborhood_staleness
    AFTER UPDATE OF importance, status ON memories
    FOR EACH ROW
    EXECUTE FUNCTION mark_neighborhoods_stale();

-- Auto-assign memories to episodes
-- Phase 4 (ReduceScopeCreep): Uses graph edges (IN_EPISODE) instead of episode_memories table
CREATE OR REPLACE FUNCTION assign_to_episode()
RETURNS TRIGGER AS $$
DECLARE
    current_episode_id UUID;
    last_memory_time TIMESTAMPTZ;
    new_seq INT;
BEGIN
    -- Prevent concurrent episode creation
    PERFORM pg_advisory_xact_lock(hashtext('episode_manager'));

    -- Find most recent open episode
    SELECT e.id INTO current_episode_id
    FROM episodes e
    WHERE e.ended_at IS NULL
    ORDER BY e.started_at DESC
    LIMIT 1;

    -- Get last memory time and max sequence from graph if episode exists
    IF current_episode_id IS NOT NULL THEN
        SELECT MAX(m.created_at), COALESCE(MAX(fem.sequence_order), 0)
        INTO last_memory_time, new_seq
        FROM find_episode_memories_graph(current_episode_id) fem
        JOIN memories m ON fem.memory_id = m.id;

        new_seq := COALESCE(new_seq, 0) + 1;
    END IF;

    -- If gap > 30 min or no episodes, start new episode
    IF current_episode_id IS NULL OR
       (last_memory_time IS NOT NULL AND NEW.created_at - last_memory_time > INTERVAL '30 minutes')
    THEN
        -- Close previous episode
        IF current_episode_id IS NOT NULL THEN
            UPDATE episodes
            SET ended_at = last_memory_time
            WHERE id = current_episode_id;
        END IF;

        -- Create new episode
        INSERT INTO episodes (started_at, metadata)
        VALUES (NEW.created_at, jsonb_build_object('episode_type', 'autonomous'))
        RETURNING id INTO current_episode_id;

        new_seq := 1;
    END IF;

    -- Link memory to episode via graph
    PERFORM link_memory_to_episode_graph(NEW.id, current_episode_id, new_seq);

    -- Initialize neighborhood record
    INSERT INTO memory_neighborhoods (memory_id, is_stale)
    VALUES (NEW.id, TRUE)
    ON CONFLICT DO NOTHING;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_auto_episode_assignment
    AFTER INSERT ON memories
    FOR EACH ROW
    EXECUTE FUNCTION assign_to_episode();

-- ============================================================================
-- CORE FUNCTIONS
-- ============================================================================

-- Fast recall: Primary retrieval function (Hot Path)
CREATE OR REPLACE FUNCTION fast_recall(
    p_query_text TEXT,
    p_limit INT DEFAULT 10
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    memory_type memory_type,
    score FLOAT,
    source TEXT
) AS $$
	DECLARE
	    query_embedding vector;
	    zero_vec vector;
	    current_valence FLOAT;
	    current_arousal FLOAT;
	    current_primary TEXT;
        min_trust FLOAT;
	BEGIN
	    query_embedding := get_embedding(p_query_text);
	    zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;
	    BEGIN
	        current_valence := NULLIF(get_current_affective_state()->>'valence', '')::float;
	    EXCEPTION
	        WHEN OTHERS THEN
	            current_valence := NULL;
	    END;
	    BEGIN
	        current_arousal := NULLIF(get_current_affective_state()->>'arousal', '')::float;
	    EXCEPTION
	        WHEN OTHERS THEN
	            current_arousal := NULL;
	    END;
	    BEGIN
	        current_primary := NULLIF(get_current_affective_state()->>'primary_emotion', '');
	    EXCEPTION
	        WHEN OTHERS THEN
	            current_primary := NULL;
	    END;
	    current_valence := COALESCE(current_valence, 0.0);
	    current_arousal := COALESCE(current_arousal, 0.5);
	    current_primary := COALESCE(current_primary, 'neutral');
        min_trust := COALESCE(get_config_float('memory.recall_min_trust_level'), 0.0);
	    
	    RETURN QUERY
	    WITH 
    -- Vector seeds (semantic similarity)
	    seeds AS (
	        SELECT 
	            m.id, 
	            m.content, 
	            m.type,
            m.importance,
            m.decay_rate,
            m.created_at,
            m.last_accessed,
            1 - (m.embedding <=> query_embedding) as sim
        FROM memories m
	        WHERE m.status = 'active'
	          AND m.embedding IS NOT NULL
	          AND m.embedding <> zero_vec
	        ORDER BY m.embedding <=> query_embedding
	        LIMIT GREATEST(p_limit, 5)
	    ),
    -- Expand via precomputed neighborhoods
    associations AS (
        SELECT 
            (key)::UUID as mem_id,
            MAX((value::float) * s.sim) as assoc_score
        FROM seeds s
        JOIN memory_neighborhoods mn ON s.id = mn.memory_id,
        jsonb_each_text(mn.neighbors)
        WHERE NOT mn.is_stale
        GROUP BY key
    ),
    -- Temporal context from episodes (Phase 4: uses graph via find_episode_memories_graph)
    -- For simplicity, find recent episode memories as temporal context
    -- Note: This is a simplified version - a full graph traversal would be more complex
    temporal AS (
        SELECT DISTINCT
            fem.memory_id as mem_id,
            0.15 as temp_score
        FROM episodes e
        CROSS JOIN LATERAL find_episode_memories_graph(e.id) fem
        WHERE e.ended_at IS NULL  -- current episode
          OR e.ended_at > CURRENT_TIMESTAMP - INTERVAL '1 hour'  -- recent episodes
        LIMIT 20
    ),
    -- Combine all candidates
    candidates AS (
        SELECT id as mem_id, sim as vector_score, NULL::float as assoc_score, NULL::float as temp_score
        FROM seeds
        UNION
        SELECT mem_id, NULL, assoc_score, NULL FROM associations
        UNION
        SELECT mem_id, NULL, NULL, temp_score FROM temporal
    ),
    -- Aggregate scores per memory
    scored AS (
        SELECT 
            c.mem_id,
            MAX(c.vector_score) as vector_score,
            MAX(c.assoc_score) as assoc_score,
            MAX(c.temp_score) as temp_score
        FROM candidates c
        GROUP BY c.mem_id
    )
	    SELECT
	        m.id,
	        m.content,
	        m.type,
	        GREATEST(
	            COALESCE(sc.vector_score, 0) * 0.5 +
	            COALESCE(sc.assoc_score, 0) * 0.2 +
	            COALESCE(sc.temp_score, 0) * 0.15 +
	            calculate_relevance(m.importance, m.decay_rate, m.created_at, m.last_accessed) * 0.05 +
                COALESCE(m.trust_level, 0.5) * 0.1 +
	            -- Mood-congruent recall bias (small): prefer memories whose emotional context matches current affect.
	            (CASE
	                WHEN m.metadata ? 'emotional_context' THEN
	                    (
	                        COALESCE(
	                            CASE
	                                WHEN (m.metadata->'emotional_context'->>'valence') IS NULL THEN NULL
	                                ELSE 1.0 - (ABS((m.metadata->'emotional_context'->>'valence')::float - current_valence) / 2.0)
	                            END,
	                            0.5
	                        ) * 0.6
	                        +
	                        COALESCE(
	                            CASE
	                                WHEN (m.metadata->'emotional_context'->>'arousal') IS NULL THEN NULL
	                                ELSE 1.0 - ABS((m.metadata->'emotional_context'->>'arousal')::float - current_arousal)
	                            END,
	                            0.5
	                        ) * 0.3
	                        +
	                        (CASE
	                            WHEN (m.metadata->'emotional_context'->>'primary_emotion') IS NULL THEN 0.5
	                            WHEN (m.metadata->'emotional_context'->>'primary_emotion') = current_primary THEN 1.0
	                            ELSE 0.7
	                        END) * 0.1
	                    )
	                ELSE
	                    CASE
	                        WHEN (m.metadata->>'emotional_valence') IS NULL THEN 0.5
	                        ELSE 1.0 - (ABS((m.metadata->>'emotional_valence')::float - current_valence) / 2.0)
	                    END
	            END) * 0.05,
	            0.001
	        ) as final_score,
	        CASE
	            WHEN sc.vector_score IS NOT NULL THEN 'vector'
	            WHEN sc.assoc_score IS NOT NULL THEN 'association'
	            WHEN sc.temp_score IS NOT NULL THEN 'temporal'
	            ELSE 'fallback'
	        END as source
	    FROM scored sc
	    JOIN memories m ON sc.mem_id = m.id
	    WHERE m.status = 'active'
          AND m.trust_level >= min_trust
	    ORDER BY final_score DESC
	    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- PROVENANCE & TRUST (Normalization Layer)
-- ============================================================================

-- Normalize a source reference object into a consistent shape.
-- Intended fields: kind, ref, label, author, observed_at, trust, content_hash.
CREATE OR REPLACE FUNCTION normalize_source_reference(p_source JSONB)
RETURNS JSONB AS $$
DECLARE
    kind TEXT;
    ref TEXT;
    label TEXT;
    author TEXT;
    observed_at TIMESTAMPTZ;
    trust FLOAT;
    content_hash TEXT;
BEGIN
    IF p_source IS NULL OR jsonb_typeof(p_source) <> 'object' THEN
        RETURN '{}'::jsonb;
    END IF;

    kind := NULLIF(p_source->>'kind', '');
    ref := COALESCE(NULLIF(p_source->>'ref', ''), NULLIF(p_source->>'uri', ''));
    label := NULLIF(p_source->>'label', '');
    author := NULLIF(p_source->>'author', '');
    -- Phase 10: Preserve content_hash for ingestion receipt lookups
    content_hash := NULLIF(p_source->>'content_hash', '');

    BEGIN
        observed_at := (p_source->>'observed_at')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
        observed_at := CURRENT_TIMESTAMP;
    END;
    IF observed_at IS NULL THEN
        observed_at := CURRENT_TIMESTAMP;
    END IF;

    trust := COALESCE(NULLIF(p_source->>'trust', '')::float, 0.5);
    trust := LEAST(1.0, GREATEST(0.0, trust));

    RETURN jsonb_strip_nulls(
        jsonb_build_object(
            'kind', kind,
            'ref', ref,
            'label', label,
            'author', author,
            'observed_at', observed_at,
            'trust', trust,
            'content_hash', content_hash
        )
    );
    END;
$$ LANGUAGE plpgsql STABLE;

-- Recall memories with filters (application-facing convenience).
CREATE OR REPLACE FUNCTION recall_memories_filtered(
    p_query_text TEXT,
    p_limit INT DEFAULT 10,
    p_memory_types memory_type[] DEFAULT NULL,
    p_min_importance FLOAT DEFAULT 0.0
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    memory_type memory_type,
    score FLOAT,
    source TEXT,
    importance FLOAT,
    trust_level FLOAT,
    source_attribution JSONB,
    created_at TIMESTAMPTZ,
    emotional_valence FLOAT
) AS $$
BEGIN
    RETURN QUERY
    WITH hits AS (
        SELECT * FROM fast_recall(p_query_text, p_limit * 2)
    )
    SELECT
        h.memory_id,
        h.content,
        h.memory_type,
        h.score,
        h.source,
        m.importance,
        m.trust_level,
        m.source_attribution,
        m.created_at,
        (m.metadata->>'emotional_valence')::float AS emotional_valence
    FROM hits h
    JOIN memories m ON m.id = h.memory_id
    WHERE (p_memory_types IS NULL OR h.memory_type = ANY(p_memory_types))
      AND m.importance >= COALESCE(p_min_importance, 0.0)
    ORDER BY h.score DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- Touch memories to increment access_count/last_accessed (application-facing).
CREATE OR REPLACE FUNCTION touch_memories(p_ids UUID[])
RETURNS INT AS $$
DECLARE
    updated_count INT;
BEGIN
    IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
        RETURN 0;
    END IF;
    UPDATE memories
    SET access_count = access_count + 1,
        last_accessed = CURRENT_TIMESTAMP
    WHERE id = ANY(p_ids);
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN COALESCE(updated_count, 0);
END;
$$ LANGUAGE plpgsql;

-- Get a memory by id (application-facing).
CREATE OR REPLACE FUNCTION get_memory_by_id(p_memory_id UUID)
RETURNS TABLE (
    id UUID,
    type memory_type,
    content TEXT,
    importance FLOAT,
    trust_level FLOAT,
    source_attribution JSONB,
    created_at TIMESTAMPTZ,
    emotional_valence FLOAT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.id,
        m.type,
        m.content,
        m.importance,
        m.trust_level,
        m.source_attribution,
        m.created_at,
        (m.metadata->>'emotional_valence')::float
    FROM memories m
    WHERE m.id = p_memory_id;
END;
$$ LANGUAGE plpgsql STABLE;

-- Get a lightweight summary for a set of memories (application-facing).
CREATE OR REPLACE FUNCTION get_memories_summary(p_ids UUID[])
RETURNS TABLE (
    id UUID,
    type memory_type,
    content TEXT,
    importance FLOAT
) AS $$
BEGIN
    IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT
        m.id,
        m.type,
        m.content,
        m.importance
    FROM memories m
    WHERE m.id = ANY(p_ids);
END;
$$ LANGUAGE plpgsql STABLE;

-- List recent memories (application-facing).
CREATE OR REPLACE FUNCTION list_recent_memories(
    p_limit INT DEFAULT 10,
    p_memory_types memory_type[] DEFAULT NULL,
    p_by_access BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    memory_type memory_type,
    importance FLOAT,
    created_at TIMESTAMPTZ,
    last_accessed TIMESTAMPTZ,
    trust_level FLOAT,
    source_attribution JSONB,
    emotional_valence FLOAT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.id,
        m.content,
        m.type,
        m.importance,
        m.created_at,
        m.last_accessed,
        m.trust_level,
        m.source_attribution,
        (m.metadata->>'emotional_valence')::float
    FROM memories m
    WHERE m.status = 'active'
      AND (p_memory_types IS NULL OR m.type = ANY(p_memory_types))
    ORDER BY
        CASE WHEN p_by_access THEN m.last_accessed ELSE m.created_at END DESC NULLS LAST
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- Episode helpers (application-facing).
CREATE OR REPLACE FUNCTION get_episode_details(p_episode_id UUID)
RETURNS TABLE (
    id UUID,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    episode_type TEXT,
    summary TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        e.id,
        e.started_at,
        e.ended_at,
        e.metadata->>'episode_type' as episode_type,
        e.summary
    FROM episodes e
    WHERE e.id = p_episode_id;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_episode_memories(p_episode_id UUID)
RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    memory_type memory_type,
    importance FLOAT,
    trust_level FLOAT,
    source_attribution JSONB,
    created_at TIMESTAMPTZ,
    emotional_valence FLOAT,
    sequence_order INT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.id,
        m.content,
        m.type,
        m.importance,
        m.trust_level,
        m.source_attribution,
        m.created_at,
        (m.metadata->>'emotional_valence')::float,
        fem.sequence_order
    FROM find_episode_memories_graph(p_episode_id) fem
    JOIN memories m ON fem.memory_id = m.id
    ORDER BY fem.sequence_order ASC;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION list_recent_episodes(p_limit INT DEFAULT 5)
RETURNS TABLE (
    id UUID,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    episode_type TEXT,
    summary TEXT,
    memory_count INT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        e.id,
        e.started_at,
        e.ended_at,
        e.metadata->>'episode_type' as episode_type,
        e.summary,
        (SELECT COUNT(*)::int FROM find_episode_memories_graph(e.id)) as memory_count
    FROM episodes e
    ORDER BY e.started_at DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- Cluster search helpers (application-facing).
CREATE OR REPLACE FUNCTION search_clusters_by_query(
    p_query TEXT,
    p_limit INT DEFAULT 3
) RETURNS TABLE (
    id UUID,
    name TEXT,
    cluster_type cluster_type,
    similarity FLOAT
) AS $$
BEGIN
    RETURN QUERY
    WITH query_embedding AS (
        SELECT get_embedding(p_query) as emb
    )
    SELECT
        c.id,
        c.name,
        c.cluster_type,
        1 - (c.centroid_embedding <=> (SELECT emb FROM query_embedding)) as similarity
    FROM clusters c
    WHERE c.centroid_embedding IS NOT NULL
    ORDER BY c.centroid_embedding <=> (SELECT emb FROM query_embedding)
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_cluster_sample_memories(
    p_cluster_id UUID,
    p_limit INT DEFAULT 3
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    memory_type memory_type,
    membership_strength FLOAT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.id,
        m.content,
        m.type,
        gcm.membership_strength
    FROM get_cluster_members_graph(p_cluster_id) gcm
    JOIN memories m ON gcm.memory_id = m.id
    WHERE m.status = 'active'
    ORDER BY gcm.membership_strength DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- Concept helpers (application-facing).
CREATE OR REPLACE FUNCTION find_related_concepts_for_memories(
    p_memory_ids UUID[],
    p_exclude TEXT DEFAULT '',
    p_limit INT DEFAULT 10
) RETURNS TABLE (
    name TEXT,
    shared_memories INT
) AS $$
DECLARE
    ids_sql TEXT;
    sql TEXT;
BEGIN
    IF p_memory_ids IS NULL OR array_length(p_memory_ids, 1) IS NULL THEN
        RETURN;
    END IF;

    SELECT array_to_string(ARRAY(
        SELECT quote_literal(mid::text)
        FROM unnest(p_memory_ids) as mid
    ), ',') INTO ids_sql;

    IF ids_sql IS NULL OR btrim(ids_sql) = '' THEN
        RETURN;
    END IF;

    sql := format($sql$
        SELECT
            replace(name_raw::text, '"', '') as name,
            (shared_raw::text)::int as shared_memories
        FROM cypher('memory_graph', $q$
            MATCH (m:MemoryNode)-[:INSTANCE_OF]->(c:ConceptNode)
            WHERE m.memory_id IN [%s] AND c.name <> %L
            RETURN c.name, COUNT(m) as shared
            ORDER BY shared DESC
            LIMIT %s
        $q$) as (name_raw agtype, shared_raw agtype)
    $sql$, ids_sql, COALESCE(p_exclude, ''), p_limit);

    RETURN QUERY EXECUTE sql;
END;
$$ LANGUAGE plpgsql STABLE;

-- Procedural search helper (application-facing).
CREATE OR REPLACE FUNCTION search_procedural_memories(
    p_task TEXT,
    p_limit INT DEFAULT 3
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    steps JSONB,
    prerequisites JSONB,
    success_rate FLOAT,
    average_duration FLOAT,
    similarity FLOAT
) AS $$
BEGIN
    RETURN QUERY
    WITH query_embedding AS (
        SELECT get_embedding(p_task) as emb
    )
    SELECT
        m.id,
        m.content,
        m.metadata->'steps' as steps,
        m.metadata->'prerequisites' as prerequisites,
        CASE
            WHEN COALESCE((m.metadata->>'total_attempts')::int, 0) > 0 THEN
                (m.metadata->>'success_count')::float / NULLIF((m.metadata->>'total_attempts')::float, 0)
            ELSE NULL
        END as success_rate,
        (m.metadata->>'average_duration_seconds')::float as average_duration,
        1 - (m.embedding <=> (SELECT emb FROM query_embedding)) as similarity
    FROM memories m
    WHERE m.status = 'active'
      AND m.type = 'procedural'
    ORDER BY m.embedding <=> (SELECT emb FROM query_embedding)
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- Strategic search helper (application-facing).
CREATE OR REPLACE FUNCTION search_strategic_memories(
    p_situation TEXT,
    p_limit INT DEFAULT 3
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    pattern_description TEXT,
    confidence_score FLOAT,
    context_applicability JSONB,
    success_metrics JSONB,
    similarity FLOAT
) AS $$
BEGIN
    RETURN QUERY
    WITH query_embedding AS (
        SELECT get_embedding(p_situation) as emb
    )
    SELECT
        m.id,
        m.content,
        COALESCE(m.metadata->>'pattern_description', m.content) as pattern_description,
        (m.metadata->>'confidence_score')::float as confidence_score,
        m.metadata->'context_applicability' as context_applicability,
        m.metadata->'success_metrics' as success_metrics,
        1 - (m.embedding <=> (SELECT emb FROM query_embedding)) as similarity
    FROM memories m
    WHERE m.status = 'active'
      AND m.type = 'strategic'
    ORDER BY m.embedding <=> (SELECT emb FROM query_embedding)
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- Normalize source references into an array of normalized source objects.
CREATE OR REPLACE FUNCTION normalize_source_references(p_sources JSONB)
RETURNS JSONB AS $$
DECLARE
    elem JSONB;
    out_arr JSONB := '[]'::jsonb;
BEGIN
    IF p_sources IS NULL THEN
        RETURN '[]'::jsonb;
    END IF;

    IF jsonb_typeof(p_sources) = 'array' THEN
        FOR elem IN SELECT * FROM jsonb_array_elements(p_sources)
        LOOP
            out_arr := out_arr || jsonb_build_array(normalize_source_reference(elem));
        END LOOP;
    ELSIF jsonb_typeof(p_sources) = 'object' THEN
        out_arr := jsonb_build_array(normalize_source_reference(p_sources));
    ELSE
        RETURN '[]'::jsonb;
    END IF;

    RETURN COALESCE(
        (SELECT jsonb_agg(e) FROM jsonb_array_elements(out_arr) e WHERE e <> '{}'::jsonb),
        '[]'::jsonb
    );
END;
$$ LANGUAGE plpgsql STABLE;

-- Dedupe normalized sources by a canonical key (ref/label fallback), keeping the most recent observed_at.
CREATE OR REPLACE FUNCTION dedupe_source_references(p_sources JSONB)
RETURNS JSONB AS $$
BEGIN
    RETURN COALESCE((
        SELECT jsonb_agg(d.elem)
        FROM (
            SELECT DISTINCT ON (d.key) d.elem
            FROM (
                SELECT
                    COALESCE(NULLIF(e->>'ref', ''), NULLIF(e->>'label', ''), md5(e::text)) AS key,
                    e AS elem,
                    COALESCE(e->>'observed_at', '') AS observed_at
                FROM jsonb_array_elements(normalize_source_references(p_sources)) e
            ) d
            ORDER BY d.key, d.observed_at DESC
        ) d
    ), '[]'::jsonb);
END;
$$ LANGUAGE plpgsql STABLE;

-- Convert sources into a reinforcement score [0..1] that grows with unique source count and average trust.
CREATE OR REPLACE FUNCTION source_reinforcement_score(p_source_references JSONB)
RETURNS FLOAT AS $$
DECLARE
    unique_sources INT;
    avg_trust FLOAT;
BEGIN
    WITH elems AS (
        SELECT
            COALESCE(NULLIF(e->>'ref', ''), NULLIF(e->>'label', ''), md5(e::text)) AS key,
            COALESCE((e->>'trust')::float, 0.5) AS trust
        FROM jsonb_array_elements(dedupe_source_references(p_source_references)) e
    )
    SELECT COUNT(DISTINCT key), AVG(trust) INTO unique_sources, avg_trust
    FROM elems;

    IF unique_sources IS NULL OR unique_sources = 0 THEN
        RETURN 0.0;
    END IF;

    avg_trust := COALESCE(avg_trust, 0.5);
    RETURN 1.0 - exp(-0.8 * unique_sources * avg_trust);
END;
$$ LANGUAGE plpgsql STABLE;

-- Worldview alignment score in [-1..1], based on graph edges (SUPPORTS/CONTRADICTS) to worldview memories.
-- Phase 5 (ReduceScopeCreep): Updated to use graph instead of relational tables.
CREATE OR REPLACE FUNCTION compute_worldview_alignment(p_memory_id UUID)
RETURNS FLOAT AS $$
DECLARE
    supports_score FLOAT := 0;
    contradicts_score FLOAT := 0;
    alignment FLOAT;
    sql TEXT;
BEGIN
    -- Query graph for SUPPORTS edges from this memory to worldview memories
    BEGIN
        sql := format($sql$
            SELECT COALESCE(SUM((strength::text)::float), 0)
            FROM cypher('memory_graph', $q$
                MATCH (m:MemoryNode {memory_id: %L})-[r:SUPPORTS]->(w:MemoryNode)
                WHERE w.type = 'worldview'
                RETURN r.strength
            $q$) as (strength agtype)
        $sql$, p_memory_id);
        EXECUTE sql INTO supports_score;
    EXCEPTION WHEN OTHERS THEN supports_score := 0; END;

    -- Query graph for CONTRADICTS edges from this memory to worldview memories
    BEGIN
        sql := format($sql$
            SELECT COALESCE(SUM((strength::text)::float), 0)
            FROM cypher('memory_graph', $q$
                MATCH (m:MemoryNode {memory_id: %L})-[r:CONTRADICTS]->(w:MemoryNode)
                WHERE w.type = 'worldview'
                RETURN r.strength
            $q$) as (strength agtype)
        $sql$, p_memory_id);
        EXECUTE sql INTO contradicts_score;
    EXCEPTION WHEN OTHERS THEN contradicts_score := 0; END;

    -- Net alignment: supports positive, contradicts negative
    supports_score := COALESCE(supports_score, 0);
    contradicts_score := COALESCE(contradicts_score, 0);

    IF (supports_score + contradicts_score) = 0 THEN
        RETURN 0.0;
    END IF;

    alignment := (supports_score - contradicts_score) / (supports_score + contradicts_score);
    RETURN LEAST(1.0, GREATEST(-1.0, alignment));
END;
$$ LANGUAGE plpgsql STABLE;

-- Compute an effective trust level for semantic memories, capped by multi-source reinforcement and worldview alignment.
CREATE OR REPLACE FUNCTION compute_semantic_trust(
    p_confidence FLOAT,
    p_source_references JSONB,
    p_worldview_alignment FLOAT DEFAULT 0.0
)
RETURNS FLOAT AS $$
DECLARE
    base_confidence FLOAT;
    reinforcement FLOAT;
    cap FLOAT;
    effective FLOAT;
    alignment FLOAT;
BEGIN
    base_confidence := LEAST(1.0, GREATEST(0.0, COALESCE(p_confidence, 0.5)));
    reinforcement := source_reinforcement_score(p_source_references);

    -- With no sources, cap stays low; more independent sources raises the ceiling.
    cap := 0.15 + 0.85 * reinforcement;
    effective := LEAST(base_confidence, cap);

    alignment := LEAST(1.0, GREATEST(-1.0, COALESCE(p_worldview_alignment, 0.0)));
    IF alignment < 0 THEN
        -- Strong misalignment can drive trust toward 0.
        effective := effective * (1.0 + alignment);
    ELSE
        -- Mild bonus for alignment.
        effective := LEAST(1.0, effective + 0.10 * alignment);
    END IF;

    RETURN LEAST(1.0, GREATEST(0.0, effective));
END;
$$ LANGUAGE plpgsql STABLE;

-- Sync `memories.trust_level` based on semantic confidence/sources + worldview influences.
CREATE OR REPLACE FUNCTION sync_memory_trust(p_memory_id UUID)
RETURNS VOID AS $$
DECLARE
    mtype memory_type;
    conf FLOAT;
    sources JSONB;
    alignment FLOAT;
    computed FLOAT;
    mem_metadata JSONB;
BEGIN
    SELECT type, metadata INTO mtype, mem_metadata FROM memories WHERE id = p_memory_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF mtype <> 'semantic' THEN
        RETURN;
    END IF;

    -- Read confidence and source_references from metadata
    conf := COALESCE((mem_metadata->>'confidence')::float, 0.5);
    sources := mem_metadata->'source_references';

    sources := dedupe_source_references(sources);
    alignment := compute_worldview_alignment(p_memory_id);
    computed := compute_semantic_trust(conf, sources, alignment);

    UPDATE memories
    SET trust_level = computed,
        trust_updated_at = CURRENT_TIMESTAMP,
        source_attribution = CASE
            WHEN (source_attribution = '{}'::jsonb OR source_attribution IS NULL)
                 AND jsonb_typeof(sources) = 'array'
                 AND jsonb_array_length(sources) > 0
            THEN normalize_source_reference(sources->0)
            ELSE source_attribution
        END
    WHERE id = p_memory_id;
END;
$$ LANGUAGE plpgsql;

-- Add a new source reference to a semantic memory and recompute trust.
CREATE OR REPLACE FUNCTION add_semantic_source_reference(
    p_memory_id UUID,
    p_source JSONB
)
RETURNS VOID AS $$
DECLARE
    normalized JSONB;
BEGIN
    normalized := normalize_source_reference(p_source);
    IF normalized = '{}'::jsonb THEN
        RETURN;
    END IF;

    -- Update source_references in metadata
    UPDATE memories
    SET metadata = jsonb_set(
            jsonb_set(
                metadata,
                '{source_references}',
                dedupe_source_references(
                    COALESCE(metadata->'source_references', '[]'::jsonb) || jsonb_build_array(normalized)
                )
            ),
            '{last_validated}',
            to_jsonb(CURRENT_TIMESTAMP)
        )
    WHERE id = p_memory_id AND type = 'semantic';

    PERFORM sync_memory_trust(p_memory_id);
END;
$$ LANGUAGE plpgsql;

-- Provide a compact truth/provenance profile for downstream consumers (prompts, APIs).
CREATE OR REPLACE FUNCTION get_memory_truth_profile(p_memory_id UUID)
RETURNS JSONB AS $$
DECLARE
    mtype memory_type;
    base_conf FLOAT;
    sources JSONB;
    reinforcement FLOAT;
    alignment FLOAT;
    trust FLOAT;
    source_count INT;
    mem_metadata JSONB;
BEGIN
    SELECT type, trust_level, metadata INTO mtype, trust, mem_metadata
    FROM memories
    WHERE id = p_memory_id;

    IF NOT FOUND THEN
        RETURN '{}'::jsonb;
    END IF;

    IF mtype = 'semantic' THEN
        -- Read confidence and source_references from metadata
        base_conf := COALESCE((mem_metadata->>'confidence')::float, 0.5);
        sources := mem_metadata->'source_references';

        sources := dedupe_source_references(sources);
        reinforcement := source_reinforcement_score(sources);
        alignment := compute_worldview_alignment(p_memory_id);
        source_count := COALESCE(jsonb_array_length(sources), 0);

        RETURN jsonb_build_object(
            'type', 'semantic',
            'base_confidence', COALESCE(base_conf, 0.5),
            'trust_level', trust,
            'source_count', source_count,
            'source_reinforcement', reinforcement,
            'worldview_alignment', alignment,
            'sources', sources
        );
    END IF;

    RETURN jsonb_build_object(
        'type', mtype::text,
        'trust_level', trust
    );
END;
$$ LANGUAGE plpgsql STABLE;

-- Phase 5 (ReduceScopeCreep): update_worldview_confidence_from_influences and
-- trg_worldview_influence_trust_sync removed (worldview_memory_influences table removed).
-- Worldview beliefs are now stored as memories with type='worldview'.
-- Confidence updates happen via update on memories.metadata->>'confidence' directly.

-- Update a worldview memory's confidence based on supporting evidence in graph.
-- This is kept for compatibility but simplified for the new schema.
CREATE OR REPLACE FUNCTION update_worldview_confidence_from_influences(
    p_worldview_memory_id UUID,
    p_window INTERVAL DEFAULT INTERVAL '30 days',
    p_learning_rate FLOAT DEFAULT 0.05
)
RETURNS VOID AS $$
DECLARE
    delta FLOAT := 0;
    base_conf FLOAT;
    mem_meta JSONB;
BEGIN
    IF p_worldview_memory_id IS NULL THEN
        RETURN;
    END IF;

    -- Get current confidence from memory metadata
    SELECT metadata INTO mem_meta FROM memories WHERE id = p_worldview_memory_id AND type = 'worldview';
    IF NOT FOUND THEN RETURN; END IF;

    base_conf := COALESCE((mem_meta->>'confidence')::float, 0.5);

    -- Query graph for SUPPORTS edges TO this worldview memory
    BEGIN
        EXECUTE format($sql$
            SELECT COALESCE(AVG((strength::text)::float * 0.5), 0)
            FROM cypher('memory_graph', $q$
                MATCH (m:MemoryNode)-[r:SUPPORTS]->(w:MemoryNode {memory_id: %L})
                RETURN r.strength
            $q$) as (strength agtype)
        $sql$, p_worldview_memory_id) INTO delta;
    EXCEPTION WHEN OTHERS THEN delta := 0; END;

    -- Update confidence in metadata
    UPDATE memories
    SET metadata = jsonb_set(
            metadata,
            '{confidence}',
            to_jsonb(LEAST(1.0, GREATEST(0.0, base_conf + COALESCE(p_learning_rate, 0.05) * COALESCE(delta, 0))))
        ),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_worldview_memory_id;
END;
$$ LANGUAGE plpgsql;

-- Create memory (base function) - generates embedding automatically
CREATE OR REPLACE FUNCTION create_memory(
    p_type memory_type,
    p_content TEXT,
    p_importance FLOAT DEFAULT 0.5,
    p_source_attribution JSONB DEFAULT NULL,
    p_trust_level FLOAT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    embedding_vec vector;
    normalized_source JSONB;
    effective_trust FLOAT;
BEGIN
    normalized_source := normalize_source_reference(p_source_attribution);
    IF normalized_source = '{}'::jsonb THEN
        normalized_source := jsonb_build_object(
            'kind',
            CASE
                WHEN p_type = 'semantic' THEN 'unattributed'
                ELSE 'internal'
            END,
            'observed_at', CURRENT_TIMESTAMP
        );
    END IF;

    effective_trust := p_trust_level;
    IF effective_trust IS NULL THEN
        effective_trust := CASE
            WHEN p_type = 'episodic' THEN 0.95
            WHEN p_type = 'semantic' THEN 0.20
            WHEN p_type = 'procedural' THEN 0.70
            WHEN p_type = 'strategic' THEN 0.70
            ELSE 0.50
        END;
    END IF;
    effective_trust := LEAST(1.0, GREATEST(0.0, effective_trust));

    -- Generate embedding
    embedding_vec := get_embedding(p_content);

    INSERT INTO memories (type, content, embedding, importance, source_attribution, trust_level, trust_updated_at, metadata)
    VALUES (p_type, p_content, embedding_vec, p_importance, normalized_source, effective_trust, CURRENT_TIMESTAMP, COALESCE(p_metadata, '{}'::jsonb))
    RETURNING id INTO new_memory_id;

    -- Create graph node (MERGE to avoid duplicates if trigger already synced)
    EXECUTE format(
        'SELECT * FROM cypher(''memory_graph'', $q$
            MERGE (n:MemoryNode {memory_id: %L})
            SET n.type = %L, n.created_at = %L
            RETURN n
        $q$) as (result agtype)',
        new_memory_id,
        p_type,
        CURRENT_TIMESTAMP
    );

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;

-- Create episodic memory
CREATE OR REPLACE FUNCTION create_episodic_memory(
    p_content TEXT,
    p_action_taken JSONB DEFAULT NULL,
    p_context JSONB DEFAULT NULL,
    p_result JSONB DEFAULT NULL,
    p_emotional_valence FLOAT DEFAULT 0.0,
    p_event_time TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    p_importance FLOAT DEFAULT 0.5,
    p_source_attribution JSONB DEFAULT NULL,
    p_trust_level FLOAT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    normalized_source JSONB;
    effective_trust FLOAT;
    meta JSONB;
BEGIN
    normalized_source := normalize_source_reference(p_source_attribution);
    IF normalized_source = '{}'::jsonb THEN
        normalized_source := jsonb_build_object('kind', 'internal', 'observed_at', CURRENT_TIMESTAMP);
    END IF;
    effective_trust := COALESCE(p_trust_level, 0.95);

    -- Build metadata for episodic memory
    meta := jsonb_build_object(
        'action_taken', p_action_taken,
        'context', p_context,
        'result', p_result,
        'emotional_valence', LEAST(1.0, GREATEST(-1.0, COALESCE(p_emotional_valence, 0.0))),
        'event_time', COALESCE(p_event_time, CURRENT_TIMESTAMP),
        'verification_status', NULL
    );

    new_memory_id := create_memory('episodic', p_content, p_importance, normalized_source, effective_trust, meta);

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;

-- Create semantic memory
CREATE OR REPLACE FUNCTION create_semantic_memory(
    p_content TEXT,
    p_confidence FLOAT,
    p_category TEXT[] DEFAULT NULL,
    p_related_concepts TEXT[] DEFAULT NULL,
    p_source_references JSONB DEFAULT NULL,
    p_importance FLOAT DEFAULT 0.5,
    p_source_attribution JSONB DEFAULT NULL,
    p_trust_level FLOAT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    normalized_sources JSONB;
    primary_source JSONB;
    base_confidence FLOAT;
    effective_trust FLOAT;
    meta JSONB;
BEGIN
    normalized_sources := dedupe_source_references(p_source_references);
    base_confidence := LEAST(1.0, GREATEST(0.0, COALESCE(p_confidence, 0.5)));

    primary_source := normalize_source_reference(p_source_attribution);
    IF primary_source = '{}'::jsonb AND jsonb_typeof(normalized_sources) = 'array' AND jsonb_array_length(normalized_sources) > 0 THEN
        primary_source := normalize_source_reference(normalized_sources->0);
    END IF;
    IF primary_source = '{}'::jsonb THEN
        primary_source := jsonb_build_object('kind', 'unattributed', 'observed_at', CURRENT_TIMESTAMP);
    END IF;

    effective_trust := COALESCE(p_trust_level, compute_semantic_trust(base_confidence, normalized_sources, 0.0));

    -- Build metadata for semantic memory
    meta := jsonb_build_object(
        'confidence', base_confidence,
        'last_validated', CURRENT_TIMESTAMP,
        'source_references', normalized_sources,
        'contradictions', NULL,
        'category', to_jsonb(p_category),
        'related_concepts', to_jsonb(p_related_concepts)
    );

    new_memory_id := create_memory('semantic', p_content, p_importance, primary_source, effective_trust, meta);

    PERFORM sync_memory_trust(new_memory_id);

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;

-- Create procedural memory
CREATE OR REPLACE FUNCTION create_procedural_memory(
    p_content TEXT,
    p_steps JSONB,
    p_prerequisites JSONB DEFAULT NULL,
    p_importance FLOAT DEFAULT 0.5,
    p_source_attribution JSONB DEFAULT NULL,
    p_trust_level FLOAT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    normalized_source JSONB;
    effective_trust FLOAT;
    meta JSONB;
BEGIN
    normalized_source := normalize_source_reference(p_source_attribution);
    IF normalized_source = '{}'::jsonb THEN
        normalized_source := jsonb_build_object('kind', 'internal', 'observed_at', CURRENT_TIMESTAMP);
    END IF;
    effective_trust := COALESCE(p_trust_level, 0.70);

    -- Build metadata for procedural memory
    meta := jsonb_build_object(
        'steps', p_steps,
        'prerequisites', p_prerequisites,
        'success_count', 0,
        'total_attempts', 0,
        'average_duration_seconds', NULL,
        'failure_points', NULL
    );

    new_memory_id := create_memory('procedural', p_content, p_importance, normalized_source, effective_trust, meta);

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;

-- Create strategic memory
CREATE OR REPLACE FUNCTION create_strategic_memory(
    p_content TEXT,
    p_pattern_description TEXT,
    p_confidence_score FLOAT,
    p_supporting_evidence JSONB DEFAULT NULL,
    p_context_applicability JSONB DEFAULT NULL,
    p_importance FLOAT DEFAULT 0.5,
    p_source_attribution JSONB DEFAULT NULL,
    p_trust_level FLOAT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    normalized_source JSONB;
    effective_trust FLOAT;
    meta JSONB;
BEGIN
    normalized_source := normalize_source_reference(p_source_attribution);
    IF normalized_source = '{}'::jsonb THEN
        normalized_source := jsonb_build_object('kind', 'internal', 'observed_at', CURRENT_TIMESTAMP);
    END IF;
    effective_trust := COALESCE(p_trust_level, 0.70);

    -- Build metadata for strategic memory
    meta := jsonb_build_object(
        'pattern_description', p_pattern_description,
        'confidence_score', LEAST(1.0, GREATEST(0.0, COALESCE(p_confidence_score, 0.5))),
        'supporting_evidence', p_supporting_evidence,
        'success_metrics', NULL,
        'adaptation_history', NULL,
        'context_applicability', p_context_applicability
    );

    new_memory_id := create_memory('strategic', p_content, p_importance, normalized_source, effective_trust, meta);

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;

-- Create worldview memory (Phase 5: replaces worldview_primitives, boundaries tables)
-- Worldview memories represent beliefs, values, and boundaries that filter perception.
-- Categories: 'belief', 'value', 'ethic', 'boundary', 'preference', 'self', 'world', 'other'
CREATE OR REPLACE FUNCTION create_worldview_memory(
    p_content TEXT,                              -- The belief/value/boundary statement
    p_category TEXT DEFAULT 'belief',            -- Category of worldview element
    p_confidence FLOAT DEFAULT 0.8,              -- How certain (0-1)
    p_stability FLOAT DEFAULT 0.7,               -- How resistant to change (0-1)
    p_importance FLOAT DEFAULT 0.8,              -- Importance score
    p_origin TEXT DEFAULT 'discovered',          -- foundational | discovered | taught | reasoned | experienced
    p_trigger_patterns JSONB DEFAULT NULL,       -- For boundaries: keyword triggers
    p_response_type TEXT DEFAULT NULL,           -- For boundaries: refuse | negotiate | flag
    p_response_template TEXT DEFAULT NULL,       -- For boundaries: response text
    p_emotional_valence FLOAT DEFAULT 0.0        -- Emotional charge (-1 to 1)
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    normalized_source JSONB;
    effective_trust FLOAT;
    meta JSONB;
BEGIN
    normalized_source := jsonb_build_object('kind', 'internal', 'observed_at', CURRENT_TIMESTAMP);
    effective_trust := LEAST(1.0, GREATEST(0.0, COALESCE(p_stability, 0.7)));

    -- Build metadata for worldview memory
    meta := jsonb_build_object(
        'category', p_category,
        'confidence', LEAST(1.0, GREATEST(0.0, COALESCE(p_confidence, 0.8))),
        'stability', LEAST(1.0, GREATEST(0.0, COALESCE(p_stability, 0.7))),
        'origin', COALESCE(p_origin, 'discovered'),
        'emotional_valence', LEAST(1.0, GREATEST(-1.0, COALESCE(p_emotional_valence, 0.0))),
        'evidence_threshold', 0.9,  -- High threshold for updating worldview
        -- Boundary-specific fields (only used when category='boundary')
        'trigger_patterns', p_trigger_patterns,
        'response_type', p_response_type,
        'response_template', p_response_template
    );

    new_memory_id := create_memory('worldview', p_content, p_importance, normalized_source, effective_trust, meta);

    -- Create SelfNode edge for worldview beliefs
    BEGIN
        EXECUTE format(
            'SELECT * FROM cypher(''memory_graph'', $q$
                MATCH (s:SelfNode)
                MATCH (m:MemoryNode {memory_id: %L})
                CREATE (s)-[:HAS_BELIEF {category: %L, stability: %s}]->(m)
                RETURN m
            $q$) as (result agtype)',
            new_memory_id,
            p_category,
            p_stability
        );
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;

-- Backward-compatible wrapper (Phase 5: worldview beliefs are memories)
CREATE OR REPLACE FUNCTION create_worldview_belief(
    p_content TEXT,
    p_category TEXT DEFAULT 'belief',
    p_confidence FLOAT DEFAULT 0.8,
    p_stability FLOAT DEFAULT 0.7,
    p_importance FLOAT DEFAULT 0.8,
    p_origin TEXT DEFAULT 'discovered',
    p_evidence_threshold FLOAT DEFAULT 0.7,
    p_emotional_valence FLOAT DEFAULT 0.0,
    p_trigger_patterns TEXT[] DEFAULT NULL,
    p_response_type TEXT DEFAULT NULL,
    p_source_references JSONB DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    normalized_sources JSONB;
    trigger_json JSONB;
    meta_patch JSONB := '{}'::jsonb;
BEGIN
    trigger_json := CASE
        WHEN p_trigger_patterns IS NULL THEN NULL
        ELSE to_jsonb(p_trigger_patterns)
    END;

    new_memory_id := create_worldview_memory(
        p_content,
        p_category,
        p_confidence,
        p_stability,
        p_importance,
        p_origin,
        trigger_json,
        p_response_type,
        NULL,
        p_emotional_valence
    );

    IF p_evidence_threshold IS NOT NULL THEN
        meta_patch := meta_patch || jsonb_build_object(
            'evidence_threshold',
            LEAST(1.0, GREATEST(0.0, p_evidence_threshold))
        );
    END IF;

    IF p_source_references IS NOT NULL THEN
        normalized_sources := dedupe_source_references(p_source_references);
        meta_patch := meta_patch || jsonb_build_object('source_references', normalized_sources);
    END IF;

    IF meta_patch <> '{}'::jsonb THEN
        UPDATE memories
        SET metadata = metadata || meta_patch,
            source_attribution = CASE
                WHEN normalized_sources IS NOT NULL
                     AND jsonb_typeof(normalized_sources) = 'array'
                     AND jsonb_array_length(normalized_sources) > 0
                     AND (source_attribution IS NULL OR source_attribution = '{}'::jsonb)
                THEN normalize_source_reference(normalized_sources->0)
                ELSE source_attribution
            END,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = new_memory_id;
    END IF;

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;

-- Update a self-related worldview belief with stability enforcement.
CREATE OR REPLACE FUNCTION update_identity_belief(
    p_worldview_id UUID,
    p_new_content TEXT,
    p_evidence_memory_id UUID,
    p_force BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN AS $$
DECLARE
    current_stability FLOAT;
    stable_threshold FLOAT := 0.8;
BEGIN
    SELECT COALESCE((metadata->>'stability')::float, 0.7)
    INTO current_stability
    FROM memories
    WHERE id = p_worldview_id
      AND type = 'worldview'
      AND metadata->>'category' = 'self';

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- High stability requires explicit force or strong evidence.
    IF current_stability > stable_threshold AND NOT COALESCE(p_force, FALSE) THEN
        PERFORM create_strategic_memory(
            'Identity belief challenged but stable',
            'Identity stability check',
            0.7,
            jsonb_build_object(
                'worldview_id', p_worldview_id,
                'evidence_memory_id', p_evidence_memory_id
            )
        );
        RETURN FALSE;
    END IF;

    UPDATE memories
    SET content = p_new_content,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_worldview_id AND type = 'worldview';

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- Batch create memories from JSONB items.
-- Each item must include: {"type": "semantic|episodic|procedural|strategic", "content": "..."}
-- Optional keys: importance, emotional_valence, context, action_taken, result, event_time,
--                confidence, category, related_concepts, source_references, steps, prerequisites,
--                pattern_description, supporting_evidence, context_applicability,
--                source_attribution, trust_level.
CREATE OR REPLACE FUNCTION batch_create_memories(p_items JSONB)
RETURNS UUID[] AS $$
DECLARE
    ids UUID[] := ARRAY[]::UUID[];
    item JSONB;
    mtype memory_type;
    content TEXT;
    importance FLOAT;
    new_id UUID;
    idx INT := 0;
BEGIN
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
        RETURN ids;
    END IF;

    FOR item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        idx := idx + 1;
        mtype := NULLIF(item->>'type', '')::memory_type;
        content := NULLIF(item->>'content', '');
        IF content IS NULL OR mtype IS NULL THEN
            RAISE EXCEPTION 'batch_create_memories: item % missing required fields', idx;
        END IF;
        importance := COALESCE(NULLIF(item->>'importance', '')::float, 0.5);

        IF mtype = 'episodic' THEN
            new_id := create_episodic_memory(
                content,
                item->'action_taken',
                item->'context',
                item->'result',
                COALESCE(NULLIF(item->>'emotional_valence', '')::float, 0.0),
                COALESCE(NULLIF(item->>'event_time', '')::timestamptz, CURRENT_TIMESTAMP),
                importance,
                item->'source_attribution',
                NULLIF(item->>'trust_level', '')::float
            );
        ELSIF mtype = 'semantic' THEN
            new_id := create_semantic_memory(
                content,
                COALESCE(NULLIF(item->>'confidence', '')::float, 0.8),
                CASE WHEN item ? 'category' THEN ARRAY(SELECT jsonb_array_elements_text(item->'category')) ELSE NULL END,
                CASE WHEN item ? 'related_concepts' THEN ARRAY(SELECT jsonb_array_elements_text(item->'related_concepts')) ELSE NULL END,
                item->'source_references',
                importance,
                item->'source_attribution',
                NULLIF(item->>'trust_level', '')::float
            );
        ELSIF mtype = 'procedural' THEN
            new_id := create_procedural_memory(
                content,
                COALESCE(item->'steps', jsonb_build_object('steps', '[]'::jsonb)),
                item->'prerequisites',
                importance,
                item->'source_attribution',
                NULLIF(item->>'trust_level', '')::float
            );
        ELSIF mtype = 'strategic' THEN
            new_id := create_strategic_memory(
                content,
                COALESCE(NULLIF(item->>'pattern_description', ''), content),
                COALESCE(NULLIF(item->>'confidence_score', '')::float, 0.8),
                item->'supporting_evidence',
                item->'context_applicability',
                importance,
                item->'source_attribution',
                NULLIF(item->>'trust_level', '')::float
            );
        ELSE
            RAISE EXCEPTION 'batch_create_memories: item % invalid type %', idx, mtype::text;
        END IF;

        IF new_id IS NULL THEN
            RAISE EXCEPTION 'batch_create_memories: item % failed to create memory', idx;
        END IF;
        ids := array_append(ids, new_id);
    END LOOP;

    RETURN ids;
END;
$$ LANGUAGE plpgsql;

-- Create memory with a precomputed embedding (used for batched/externally-generated embeddings).
CREATE OR REPLACE FUNCTION create_memory_with_embedding(
    p_type memory_type,
    p_content TEXT,
    p_embedding vector,
    p_importance FLOAT DEFAULT 0.5,
    p_source_attribution JSONB DEFAULT NULL,
    p_trust_level FLOAT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    normalized_source JSONB;
    effective_trust FLOAT;
BEGIN
    IF p_embedding IS NULL THEN
        RAISE EXCEPTION 'embedding must not be NULL';
    END IF;

    normalized_source := normalize_source_reference(p_source_attribution);
    IF normalized_source = '{}'::jsonb THEN
        normalized_source := jsonb_build_object(
            'kind',
            CASE
                WHEN p_type = 'semantic' THEN 'unattributed'
                ELSE 'internal'
            END,
            'observed_at', CURRENT_TIMESTAMP
        );
    END IF;

    effective_trust := p_trust_level;
    IF effective_trust IS NULL THEN
        effective_trust := CASE
            WHEN p_type = 'episodic' THEN 0.95
            WHEN p_type = 'semantic' THEN 0.20
            WHEN p_type = 'procedural' THEN 0.70
            WHEN p_type = 'strategic' THEN 0.70
            ELSE 0.50
        END;
    END IF;
    effective_trust := LEAST(1.0, GREATEST(0.0, effective_trust));

    INSERT INTO memories (type, content, embedding, importance, source_attribution, trust_level, trust_updated_at, metadata)
    VALUES (p_type, p_content, p_embedding, p_importance, normalized_source, effective_trust, CURRENT_TIMESTAMP, COALESCE(p_metadata, '{}'::jsonb))
    RETURNING id INTO new_memory_id;

    EXECUTE format(
        'SELECT * FROM cypher(''memory_graph'', $q$
            CREATE (n:MemoryNode {memory_id: %L, type: %L, created_at: %L})
            RETURN n
        $q$) as (result agtype)',
        new_memory_id,
        p_type,
        CURRENT_TIMESTAMP
    );

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;

-- Batch create memories with precomputed embeddings (single type, no per-item metadata).
-- Inserts the base row with default metadata, creates the MemoryNode.
CREATE OR REPLACE FUNCTION batch_create_memories_with_embeddings(
    p_type memory_type,
    p_contents TEXT[],
    p_embeddings JSONB,
    p_importance FLOAT DEFAULT 0.5
)
RETURNS UUID[] AS $$
DECLARE
    ids UUID[] := ARRAY[]::UUID[];
    n INT;
    i INT;
    expected_dim INT;
    emb_vec vector;
    emb_json JSONB;
    emb_arr FLOAT4[];
    new_id UUID;
    default_meta JSONB;
BEGIN
    n := COALESCE(array_length(p_contents, 1), 0);
    IF n = 0 THEN
        RETURN ids;
    END IF;

    IF p_embeddings IS NULL OR jsonb_typeof(p_embeddings) <> 'array' THEN
        RAISE EXCEPTION 'embeddings must be a JSON array';
    END IF;
    IF jsonb_array_length(p_embeddings) <> n THEN
        RAISE EXCEPTION 'contents and embeddings length mismatch';
    END IF;

    expected_dim := embedding_dimension();

    FOR i IN 1..n LOOP
        IF p_contents[i] IS NULL OR p_contents[i] = '' THEN
            CONTINUE;
        END IF;

        emb_json := p_embeddings->(i - 1);
        IF emb_json IS NULL OR jsonb_typeof(emb_json) <> 'array' THEN
            RAISE EXCEPTION 'embedding % must be a JSON array', i;
        END IF;

        SELECT ARRAY_AGG(value::float4) INTO emb_arr
        FROM jsonb_array_elements_text(emb_json) value;

        IF COALESCE(array_length(emb_arr, 1), 0) <> expected_dim THEN
            RAISE EXCEPTION 'embedding dimension mismatch: expected %, got %', expected_dim, COALESCE(array_length(emb_arr, 1), 0);
        END IF;

        emb_vec := (emb_arr::float4[])::vector;

        -- Build default metadata based on type
        IF p_type = 'episodic' THEN
            default_meta := jsonb_build_object(
                'action_taken', NULL,
                'context', jsonb_build_object('type', 'raw_batch'),
                'result', NULL,
                'emotional_valence', 0.0,
                'verification_status', NULL,
                'event_time', CURRENT_TIMESTAMP
            );
        ELSIF p_type = 'semantic' THEN
            default_meta := jsonb_build_object(
                'confidence', 0.8,
                'last_validated', CURRENT_TIMESTAMP,
                'source_references', '[]'::jsonb,
                'contradictions', NULL,
                'category', NULL,
                'related_concepts', NULL
            );
        ELSIF p_type = 'procedural' THEN
            default_meta := jsonb_build_object(
                'steps', '[]'::jsonb,
                'prerequisites', NULL,
                'success_count', 0,
                'total_attempts', 0,
                'average_duration_seconds', NULL,
                'failure_points', NULL
            );
        ELSIF p_type = 'strategic' THEN
            default_meta := jsonb_build_object(
                'pattern_description', p_contents[i],
                'supporting_evidence', NULL,
                'confidence_score', 0.8,
                'success_metrics', NULL,
                'adaptation_history', NULL,
                'context_applicability', NULL
            );
        ELSE
            default_meta := '{}'::jsonb;
        END IF;

        new_id := create_memory_with_embedding(p_type, p_contents[i], emb_vec, p_importance, NULL, NULL, default_meta);

        IF p_type = 'semantic' THEN
            PERFORM sync_memory_trust(new_id);
        END IF;

        ids := array_append(ids, new_id);
    END LOOP;

    RETURN ids;
END;
$$ LANGUAGE plpgsql;

-- Search similar memories
CREATE OR REPLACE FUNCTION search_similar_memories(
    p_query_text TEXT,
    p_limit INT DEFAULT 10,
    p_memory_types memory_type[] DEFAULT NULL,
    p_min_importance FLOAT DEFAULT 0.0
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    type memory_type,
    similarity FLOAT,
    importance FLOAT
) AS $$
DECLARE
    query_embedding vector;
    zero_vec vector;
BEGIN
    query_embedding := get_embedding(p_query_text);
    zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;
    
    RETURN QUERY
    WITH candidates AS MATERIALIZED (
        SELECT m.id, m.content, m.type, m.embedding, m.importance
        FROM memories m
        WHERE m.status = 'active'
          AND m.embedding IS NOT NULL
          AND m.embedding <> zero_vec
          AND (p_memory_types IS NULL OR m.type = ANY(p_memory_types))
          AND m.importance >= p_min_importance
    )
    SELECT
        c.id,
        c.content,
        c.type,
        1 - (c.embedding <=> query_embedding) as similarity,
        c.importance
    FROM candidates c
    ORDER BY c.embedding <=> query_embedding
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- Assign memory to clusters based on similarity
-- Phase 3 (ReduceScopeCreep): Uses graph edges (MEMBER_OF) instead of memory_cluster_members table
CREATE OR REPLACE FUNCTION assign_memory_to_clusters(
    p_memory_id UUID,
    p_max_clusters INT DEFAULT 3
) RETURNS VOID AS $$
DECLARE
    memory_embedding vector;
    cluster_record RECORD;
    similarity_threshold FLOAT := 0.7;
    assigned_count INT := 0;
    zero_vec vector := array_fill(0, ARRAY[embedding_dimension()])::vector;
BEGIN
    SELECT embedding INTO memory_embedding
    FROM memories WHERE id = p_memory_id;

    -- Avoid NaNs from cosine distance when any side is the zero vector.
    IF memory_embedding IS NULL OR memory_embedding = zero_vec THEN
        RETURN;
    END IF;

    FOR cluster_record IN
        SELECT id, 1 - (centroid_embedding <=> memory_embedding) as similarity
        FROM clusters
        WHERE centroid_embedding IS NOT NULL
          AND centroid_embedding <> zero_vec
        ORDER BY centroid_embedding <=> memory_embedding
        LIMIT 50
    LOOP
        IF cluster_record.similarity >= similarity_threshold AND assigned_count < p_max_clusters THEN
            -- Phase 3: Use graph edge instead of relational table
            PERFORM link_memory_to_cluster_graph(p_memory_id, cluster_record.id, cluster_record.similarity);
            assigned_count := assigned_count + 1;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Recalculate cluster centroid
-- Phase 3 (ReduceScopeCreep): Uses graph edges (MEMBER_OF) instead of memory_cluster_members table
CREATE OR REPLACE FUNCTION recalculate_cluster_centroid(p_cluster_id UUID)
RETURNS VOID AS $$
DECLARE
    new_centroid vector;
BEGIN
    -- Phase 3: Query graph for cluster members
    SELECT AVG(m.embedding)::vector
    INTO new_centroid
    FROM memories m
    JOIN get_cluster_members_graph(p_cluster_id) gcm ON m.id = gcm.memory_id
    WHERE m.status = 'active'
    AND gcm.membership_strength > 0.3;

    UPDATE clusters
    SET centroid_embedding = new_centroid,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_cluster_id;
END;
$$ LANGUAGE plpgsql;

-- Create graph relationship between memories
CREATE OR REPLACE FUNCTION create_memory_relationship(
    p_from_id UUID,
    p_to_id UUID,
    p_relationship_type graph_edge_type,
    p_properties JSONB DEFAULT '{}'
) RETURNS VOID AS $$
BEGIN
    EXECUTE format(
        'SELECT * FROM cypher(''memory_graph'', $q$
            MATCH (a:MemoryNode {memory_id: %L}), (b:MemoryNode {memory_id: %L})
            CREATE (a)-[r:%s %s]->(b)
            RETURN r
        $q$) as (result agtype)',
        p_from_id,
        p_to_id,
        p_relationship_type,
        CASE WHEN p_properties = '{}'::jsonb 
             THEN '' 
             ELSE format('{%s}', 
                  (SELECT string_agg(format('%I: %s', key, value), ', ')
                   FROM jsonb_each(p_properties)))
        END
    );
END;
$$ LANGUAGE plpgsql;

-- Auto-check worldview alignment for new semantic memories.
CREATE OR REPLACE FUNCTION auto_check_worldview_alignment()
RETURNS TRIGGER AS $$
DECLARE
    min_support FLOAT;
    min_contradict FLOAT;
    sim FLOAT;
    w RECORD;
    zero_vec vector;
BEGIN
    IF NEW.type <> 'semantic' THEN
        RETURN NEW;
    END IF;
    IF NEW.embedding IS NULL THEN
        RETURN NEW;
    END IF;

    zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;
    IF NEW.embedding = zero_vec THEN
        RETURN NEW;
    END IF;

    min_support := COALESCE(get_config_float('memory.worldview_support_threshold'), 0.8);
    min_contradict := COALESCE(get_config_float('memory.worldview_contradict_threshold'), -0.5);

    BEGIN
        FOR w IN
            SELECT id, embedding
            FROM memories
            WHERE type = 'worldview'
              AND status = 'active'
              AND embedding IS NOT NULL
              AND embedding <> zero_vec
            ORDER BY embedding <=> NEW.embedding
            LIMIT 10
        LOOP
            sim := 1 - (w.embedding <=> NEW.embedding);
            IF sim >= min_support THEN
                PERFORM create_memory_relationship(
                    NEW.id,
                    w.id,
                    'SUPPORTS',
                    jsonb_build_object('strength', sim, 'source', 'auto_alignment')
                );
            ELSIF sim <= min_contradict THEN
                PERFORM create_memory_relationship(
                    NEW.id,
                    w.id,
                    'CONTRADICTS',
                    jsonb_build_object('strength', ABS(sim), 'source', 'auto_alignment')
                );
            END IF;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_auto_worldview_alignment ON memories;
CREATE TRIGGER trg_auto_worldview_alignment
    AFTER INSERT ON memories
    FOR EACH ROW
    EXECUTE FUNCTION auto_check_worldview_alignment();

-- Link memory to concept
-- Link a memory to a concept in the graph layer.
-- Phase 2 (ReduceScopeCreep): Concepts are now graph-only.
-- Returns TRUE on success.
CREATE OR REPLACE FUNCTION link_memory_to_concept(
    p_memory_id UUID,
    p_concept_name TEXT,
    p_strength FLOAT DEFAULT 1.0
) RETURNS BOOLEAN AS $$
BEGIN
    -- Create ConceptNode if not exists
    EXECUTE format(
        'SELECT * FROM cypher(''memory_graph'', $q$
            MERGE (c:ConceptNode {name: %L})
            RETURN c
        $q$) as (result agtype)',
        p_concept_name
    );

    -- Create INSTANCE_OF edge from memory to concept
    EXECUTE format(
        'SELECT * FROM cypher(''memory_graph'', $q$
            MATCH (m:MemoryNode {memory_id: %L})
            MATCH (c:ConceptNode {name: %L})
            CREATE (m)-[:INSTANCE_OF {strength: %s}]->(c)
            RETURN m
        $q$) as (result agtype)',
        p_memory_id,
        p_concept_name,
        p_strength
    );
    RETURN TRUE;
EXCEPTION
    WHEN OTHERS THEN
        -- Log error but return false (edge may already exist)
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Create a concept node in the graph (ConceptNode {name, description, depth}).
CREATE OR REPLACE FUNCTION create_concept(
    p_name TEXT,
    p_description TEXT DEFAULT NULL,
    p_depth INT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
    desc_literal TEXT;
    depth_literal TEXT;
BEGIN
    IF p_name IS NULL OR btrim(p_name) = '' THEN
        RETURN FALSE;
    END IF;

    desc_literal := CASE WHEN p_description IS NULL THEN 'NULL' ELSE quote_literal(p_description) END;
    depth_literal := CASE WHEN p_depth IS NULL THEN 'NULL' ELSE p_depth::text END;

    EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MERGE (c:ConceptNode {name: %L})
        SET c.description = COALESCE(%s, c.description),
            c.depth = COALESCE(%s, c.depth)
        RETURN c
    $q$) as (result agtype)', p_name, desc_literal, depth_literal);

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Link a concept to its parent in the graph (ConceptNode)-[:PARENT_OF]->(ConceptNode).
CREATE OR REPLACE FUNCTION link_concept_parent(
    p_child_name TEXT,
    p_parent_name TEXT
)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_child_name IS NULL OR btrim(p_child_name) = ''
       OR p_parent_name IS NULL OR btrim(p_parent_name) = '' THEN
        RETURN FALSE;
    END IF;

    PERFORM create_concept(p_child_name);
    PERFORM create_concept(p_parent_name);

    EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MATCH (child:ConceptNode {name: %L})
        MATCH (parent:ConceptNode {name: %L})
        MERGE (parent)-[:PARENT_OF]->(child)
        RETURN parent
    $q$) as (result agtype)', p_child_name, p_parent_name);

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Touch working memory rows (access tracking for consolidation heuristics)
CREATE OR REPLACE FUNCTION touch_working_memory(p_ids UUID[])
RETURNS VOID AS $$
BEGIN
    IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
        RETURN;
    END IF;

    UPDATE working_memory
    SET access_count = access_count + 1,
        last_accessed = CURRENT_TIMESTAMP
    WHERE id = ANY(p_ids);
END;
$$ LANGUAGE plpgsql;

-- Promote a working-memory item into long-term episodic memory (preserving the existing embedding).
CREATE OR REPLACE FUNCTION promote_working_memory_to_episodic(
    p_working_memory_id UUID,
    p_importance FLOAT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    wm RECORD;
    new_id UUID;
    affect JSONB;
    v_valence FLOAT;
    meta JSONB;
BEGIN
    SELECT * INTO wm FROM working_memory WHERE id = p_working_memory_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    affect := get_current_affective_state();
    BEGIN
        v_valence := NULLIF(affect->>'valence', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            v_valence := 0.0;
    END;
    v_valence := LEAST(1.0, GREATEST(-1.0, COALESCE(v_valence, 0.0)));

    -- Build episodic metadata
    meta := jsonb_build_object(
        'action_taken', NULL,
        'context', jsonb_build_object(
            'from_working_memory_id', wm.id,
            'promoted_at', CURRENT_TIMESTAMP,
            'working_memory_created_at', wm.created_at,
            'working_memory_expiry', wm.expiry,
            'source_attribution', wm.source_attribution
        ),
        'result', NULL,
        'emotional_valence', v_valence,
        'verification_status', NULL,
        'event_time', wm.created_at
    );

    new_id := create_memory_with_embedding(
        'episodic'::memory_type,
        wm.content,
        wm.embedding,
        COALESCE(p_importance, wm.importance, 0.4),
        wm.source_attribution,
        wm.trust_level,
        meta
    );

    RETURN new_id;
END;
$$ LANGUAGE plpgsql;

-- Clean expired working memory (with optional consolidation before delete).
CREATE OR REPLACE FUNCTION cleanup_working_memory(
    p_min_importance_to_promote FLOAT DEFAULT 0.75,
    p_min_accesses_to_promote INT DEFAULT 3
)
RETURNS JSONB AS $$
DECLARE
    promoted UUID[] := ARRAY[]::uuid[];
    rec RECORD;
    deleted_count INT := 0;
BEGIN
    FOR rec IN
        SELECT id, importance, access_count, promote_to_long_term
        FROM working_memory
        WHERE expiry < CURRENT_TIMESTAMP
    LOOP
        IF COALESCE(rec.promote_to_long_term, false)
           OR COALESCE(rec.importance, 0) >= COALESCE(p_min_importance_to_promote, 0.75)
           OR COALESCE(rec.access_count, 0) >= COALESCE(p_min_accesses_to_promote, 3)
        THEN
            promoted := array_append(promoted, promote_working_memory_to_episodic(rec.id, rec.importance));
        END IF;
    END LOOP;

    WITH deleted AS (
        DELETE FROM working_memory
        WHERE expiry < CURRENT_TIMESTAMP
        RETURNING 1
    )
    SELECT COUNT(*) INTO deleted_count FROM deleted;

    RETURN jsonb_build_object(
        'deleted_count', COALESCE(deleted_count, 0),
        'promoted_count', COALESCE(array_length(promoted, 1), 0),
        'promoted_ids', COALESCE(to_jsonb(promoted), '[]'::jsonb)
    );
END;
$$ LANGUAGE plpgsql;

-- Add to working memory with auto-embedding
CREATE OR REPLACE FUNCTION add_to_working_memory(
    p_content TEXT,
    p_expiry INTERVAL DEFAULT INTERVAL '1 hour',
    p_importance FLOAT DEFAULT 0.3,
    p_source_attribution JSONB DEFAULT NULL,
    p_trust_level FLOAT DEFAULT NULL,
    p_promote_to_long_term BOOLEAN DEFAULT FALSE
) RETURNS UUID AS $$
	DECLARE
	    new_id UUID;
	    embedding_vec vector;
	    normalized_source JSONB;
	    effective_trust FLOAT;
	BEGIN
	    embedding_vec := get_embedding(p_content);

	    normalized_source := normalize_source_reference(p_source_attribution);
	    IF normalized_source = '{}'::jsonb THEN
	        normalized_source := jsonb_build_object('kind', 'internal', 'observed_at', CURRENT_TIMESTAMP);
	    END IF;
	    effective_trust := p_trust_level;
	    IF effective_trust IS NULL THEN
	        effective_trust := 0.8;
	    END IF;
	    effective_trust := LEAST(1.0, GREATEST(0.0, effective_trust));

	    INSERT INTO working_memory (content, embedding, importance, source_attribution, trust_level, promote_to_long_term, expiry)
	    VALUES (
	        p_content,
	        embedding_vec,
	        LEAST(1.0, GREATEST(0.0, COALESCE(p_importance, 0.3))),
	        normalized_source,
	        effective_trust,
	        COALESCE(p_promote_to_long_term, false),
	        CURRENT_TIMESTAMP + p_expiry
	    )
	    RETURNING id INTO new_id;
	    
	    RETURN new_id;
	END;
	$$ LANGUAGE plpgsql;

-- Search working memory
CREATE OR REPLACE FUNCTION search_working_memory(
    p_query_text TEXT,
    p_limit INT DEFAULT 5
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    similarity FLOAT,
    created_at TIMESTAMPTZ
) AS $$
	DECLARE
	    query_embedding vector;
	    zero_vec vector;
	BEGIN
	    query_embedding := get_embedding(p_query_text);
	    zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;
	    
	    -- Clean expired first
	    PERFORM cleanup_working_memory();
	    
	    RETURN QUERY
	    WITH ranked AS (
	        SELECT
	            wm.id,
	            wm.content AS content_text,
	            1 - (wm.embedding <=> query_embedding) as similarity,
	            wm.created_at,
	            (wm.embedding <=> query_embedding) as dist
	        FROM working_memory wm
	        WHERE wm.embedding IS NOT NULL
	          AND wm.embedding <> zero_vec
	        ORDER BY wm.embedding <=> query_embedding
	        LIMIT p_limit
	    ),
	    touched AS (
	        UPDATE working_memory wm
	        SET access_count = access_count + 1,
	            last_accessed = CURRENT_TIMESTAMP
	        WHERE wm.id IN (SELECT id FROM ranked)
	        RETURNING wm.id
	    )
	    SELECT ranked.id AS memory_id, ranked.content_text AS content, ranked.similarity, ranked.created_at
	    FROM ranked
	    ORDER BY ranked.dist;
	END;
	$$ LANGUAGE plpgsql;

-- Clean old embedding cache
CREATE OR REPLACE FUNCTION cleanup_embedding_cache(
    p_older_than INTERVAL DEFAULT INTERVAL '7 days'
) RETURNS INT AS $$
DECLARE
    deleted_count INT;
BEGIN
    WITH deleted AS (
        DELETE FROM embedding_cache
        WHERE created_at < CURRENT_TIMESTAMP - p_older_than
        RETURNING 1
    )
    SELECT COUNT(*) INTO deleted_count FROM deleted;
    
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- GRAPH HELPER FUNCTIONS (needed by views)
-- ============================================================================

-- Phase 3 (ReduceScopeCreep): Get cluster members from graph
-- Must be defined before cluster_insights view
CREATE OR REPLACE FUNCTION get_cluster_members_graph(p_cluster_id UUID)
RETURNS TABLE (
    memory_id UUID,
    membership_strength FLOAT
) AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MATCH (m:MemoryNode)-[r:MEMBER_OF]->(c:ClusterNode {cluster_id: %L})
        RETURN m.memory_id, r.strength
    $q$) as (mid agtype, str agtype)', p_cluster_id)
    LOOP
        -- Strip quotes from agtype values before casting to UUID
        memory_id := replace(rec.mid::text, '"', '')::uuid;
        membership_strength := COALESCE(replace(rec.str::text, '"', '')::float, 1.0);
        RETURN NEXT;
    END LOOP;
EXCEPTION WHEN OTHERS THEN
    RETURN;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- VIEWS
-- ============================================================================

CREATE VIEW memory_health AS
SELECT 
    type,
    COUNT(*) as total_memories,
    AVG(importance) as avg_importance,
    AVG(access_count) as avg_access_count,
    COUNT(*) FILTER (WHERE last_accessed > CURRENT_TIMESTAMP - INTERVAL '1 day') as accessed_last_day,
    AVG(calculate_relevance(importance, decay_rate, created_at, last_accessed)) as avg_relevance
FROM memories
WHERE status = 'active'
GROUP BY type;

-- Phase 3 (ReduceScopeCreep): Uses graph edges (MEMBER_OF) instead of memory_cluster_members table
CREATE VIEW cluster_insights AS
SELECT
    mc.id,
    mc.name,
    mc.cluster_type,
    (SELECT COUNT(*) FROM get_cluster_members_graph(mc.id)) as memory_count
FROM clusters mc
ORDER BY memory_count DESC, mc.name ASC;

-- Phase 4 (ReduceScopeCreep): Uses graph edges (IN_EPISODE) instead of episode_memories table
CREATE VIEW episode_summary AS
SELECT
    e.id,
    e.started_at,
    e.ended_at,
    e.metadata->>'episode_type' as episode_type,
    e.summary,
    (SELECT COUNT(*) FROM find_episode_memories_graph(e.id)) as memory_count,
    (SELECT MIN(m.created_at) FROM find_episode_memories_graph(e.id) fem JOIN memories m ON fem.memory_id = m.id) as first_memory_at,
    (SELECT MAX(m.created_at) FROM find_episode_memories_graph(e.id) fem JOIN memories m ON fem.memory_id = m.id) as last_memory_at
FROM episodes e
ORDER BY e.started_at DESC;

CREATE VIEW stale_neighborhoods AS
SELECT 
    mn.memory_id,
    m.content,
    m.type,
    mn.computed_at,
    AGE(CURRENT_TIMESTAMP, mn.computed_at) as staleness
FROM memory_neighborhoods mn
JOIN memories m ON mn.memory_id = m.id
WHERE mn.is_stale = TRUE
ORDER BY mn.computed_at ASC;

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON FUNCTION fast_recall IS 'Primary retrieval function combining vector similarity, precomputed associations, and temporal context. Hot path - optimized for speed.';

COMMENT ON FUNCTION create_memory IS 'Creates a base memory record and corresponding graph node. Embedding must be pre-computed by application.';

COMMENT ON FUNCTION create_memory_relationship IS 'Creates a typed edge between two memories in the graph. Used for causal chains, contradictions, etc.';

COMMENT ON FUNCTION link_memory_to_concept IS 'Links a memory to an abstract concept, creating the concept if needed. Updates both relational and graph layers.';

COMMENT ON TABLE memory_neighborhoods IS 'Precomputed associative neighborhoods for each memory. Replaces live spreading activation for performance. Updated by background worker.';

COMMENT ON TABLE episodes IS 'Temporal segmentation of memories into coherent episodes. Auto-populated by trigger on memory insert.';

COMMENT ON TABLE activation_cache IS 'UNLOGGED table for transient activation state during reasoning. Lost on crash, which is acceptable.';

COMMENT ON VIEW stale_neighborhoods IS 'Shows memories whose neighborhood cache needs recomputation. Used by background worker.';

-- ============================================================================
-- HEARTBEAT SYSTEM - AUTONOMOUS COGNITIVE LOOP
-- ============================================================================
-- Adds goal management, energy budgeting, and autonomous decision-making
-- ============================================================================

-- ============================================================================
-- HEARTBEAT ENUMS
-- ============================================================================

CREATE TYPE goal_priority AS ENUM (
    'active',      -- Currently working on (1-3 max)
    'queued',      -- Next up when capacity opens (5-10)
    'backburner',  -- Someday, not now (unlimited)
    'completed',   -- Done, archived
    'abandoned'    -- Gave up, with reason
);

CREATE TYPE goal_source AS ENUM (
    'curiosity',     -- Self-generated interest
    'user_request',  -- User explicitly asked
    'identity',      -- Aligned with self-concept
    'derived',       -- Sub-goal of another goal
    'external'       -- Triggered by external event
);

CREATE TYPE heartbeat_action AS ENUM (
    'observe',           -- Perceive environment (free)
    'review_goals',      -- Check goal backlog (free)
    'remember',          -- Store as episodic memory (free)
    'recall',            -- Query memory system
    'connect',           -- Create graph relationships
    'reprioritize',      -- Move goals between priorities
    'reflect',           -- Notice patterns, update self-model
    'maintain',          -- Update beliefs, revise, prune
    'mark_turning_point',      -- Consciously mark a significant moment
    'begin_chapter',           -- Start a new life chapter
    'close_chapter',           -- Close a life chapter with a summary
    'acknowledge_relationship',-- Explicitly recognize a relationship
    'update_trust',            -- Adjust trust in a relationship
    'reflect_on_relationship', -- Focused reflection on a relationship
    'resolve_contradiction',   -- Resolve a detected contradiction
    'accept_tension',          -- Acknowledge contradiction without resolving
    'brainstorm_goals',  -- Generate new potential goals
    'inquire_shallow',   -- Light web research
    'synthesize',        -- Generate artifact, form conclusion
    'reach_out_user',    -- Message the user
    'inquire_deep',      -- Deep web research
    'reach_out_public',  -- Social media, GitHub, etc.
    'terminate',         -- Permanently end the agent (wipe state; leave last will)
    'rest'               -- Bank remaining energy
);

CREATE TYPE external_call_type AS ENUM (
    'embed',   -- Generate embedding
    'think'    -- LLM reasoning/decision
);

CREATE TYPE external_call_status AS ENUM (
    'pending',
    'processing',
    'complete',
    'failed'
);

-- ============================================================================
-- GOALS SYSTEM
-- ============================================================================
-- Phase 6 (ReduceScopeCreep): goals table removed.
-- Goals are now memories with type='goal' and metadata containing:
-- {title, description, priority, source, due_at, progress, blocked_by,
--  emotional_valence, last_touched, parent_goal_id, completed_at, abandoned_at, abandonment_reason}
-- See goal functions: create_goal(), touch_goal(), add_goal_progress(), change_goal_priority()

-- ============================================================================
-- DRIVES (Intrinsic Motivation)
-- ============================================================================

CREATE TABLE drives (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT UNIQUE NOT NULL,
    description TEXT,
    current_level FLOAT DEFAULT 0.5 CHECK (current_level >= 0 AND current_level <= 1),
    baseline FLOAT DEFAULT 0.5 CHECK (baseline >= 0 AND baseline <= 1),
    accumulation_rate FLOAT DEFAULT 0.01 CHECK (accumulation_rate >= 0),
    decay_rate FLOAT DEFAULT 0.05 CHECK (decay_rate >= 0),
    satisfaction_cooldown INTERVAL DEFAULT '1 hour',
    last_satisfied TIMESTAMPTZ,
    urgency_threshold FLOAT DEFAULT 0.8 CHECK (urgency_threshold > 0 AND urgency_threshold <= 1),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO drives (name, description, baseline, current_level, accumulation_rate, decay_rate, satisfaction_cooldown, urgency_threshold)
VALUES
    ('curiosity',  'Builds fast; satisfied by research/learning',               0.50, 0.50, 0.02, 0.05, INTERVAL '30 minutes', 0.80),
    ('coherence',  'Builds when contradictions exist; satisfied by reflection', 0.50, 0.50, 0.01, 0.05, INTERVAL '2 hours',    0.80),
    ('connection', 'Builds slowly; satisfied by quality interaction',          0.50, 0.50, 0.005,0.05, INTERVAL '1 day',      0.80),
    ('competence', 'Builds when goals stall; satisfied by completion',         0.50, 0.50, 0.01, 0.05, INTERVAL '4 hours',    0.80),
    ('rest',       'Builds fastest; satisfied by resting',                     0.50, 0.50, 0.03, 0.05, INTERVAL '2 hours',    0.80)
ON CONFLICT (name) DO NOTHING;

CREATE OR REPLACE FUNCTION update_drives()
RETURNS VOID AS $$
BEGIN
    UPDATE drives d
    SET current_level = CASE
        WHEN d.last_satisfied IS NULL
          OR d.last_satisfied < CURRENT_TIMESTAMP - d.satisfaction_cooldown
        THEN LEAST(1.0, d.current_level + d.accumulation_rate)
        ELSE
            CASE
                WHEN d.current_level > d.baseline THEN GREATEST(d.baseline, d.current_level - d.decay_rate)
                WHEN d.current_level < d.baseline THEN LEAST(d.baseline, d.current_level + d.decay_rate)
                ELSE d.current_level
            END
    END
    WHERE TRUE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION satisfy_drive(p_drive_name TEXT, p_amount FLOAT DEFAULT 0.3)
RETURNS VOID AS $$
BEGIN
    UPDATE drives
    SET current_level = GREATEST(baseline, LEAST(1.0, current_level - GREATEST(0.0, COALESCE(p_amount, 0.3)))),
        last_satisfied = CURRENT_TIMESTAMP
    WHERE name = p_drive_name;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW drive_status AS
SELECT
    name,
    current_level,
    baseline,
    urgency_threshold,
    (current_level >= urgency_threshold) as is_urgent,
    ROUND((current_level / NULLIF(urgency_threshold, 0) * 100)::numeric, 1) as urgency_percent,
    last_satisfied,
    EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - last_satisfied)) / 3600 as hours_since_satisfied
FROM drives
ORDER BY current_level DESC;

-- Phase 6 (ReduceScopeCreep): goal indexes removed - goals are now memories with type='goal'
-- Goal queries now use idx_memories_goal_priority index

-- Phase 6 (ReduceScopeCreep): goal_memory_links table removed - use graph edges instead
-- Goal-memory relationships are now stored in the graph using ORIGINATED_FROM, EVIDENCE_FOR, BLOCKS edges

-- ============================================================================
-- AGENT CONFIG (Bootstrap Gate)
-- Phase 7 (ReduceScopeCreep): heartbeat_config and maintenance_config tables removed
-- All configuration is now in the unified config table with namespaced keys
-- ============================================================================

-- Heartbeat configuration (with 'heartbeat.' namespace)
INSERT INTO config (key, value, description) VALUES
    ('heartbeat.base_regeneration', '10'::jsonb, 'Energy regenerated per heartbeat'),
    ('heartbeat.max_energy', '20'::jsonb, 'Maximum energy cap'),
    ('heartbeat.heartbeat_interval_minutes', '60'::jsonb, 'Minutes between heartbeats'),
    ('heartbeat.max_active_goals', '3'::jsonb, 'Maximum concurrent active goals'),
    ('heartbeat.goal_stale_days', '7'::jsonb, 'Days before a goal is flagged as stale'),
    ('heartbeat.user_contact_cooldown_hours', '4'::jsonb, 'Minimum hours between unsolicited user contact'),
    -- Action costs
    ('heartbeat.cost_observe', '0'::jsonb, 'Free - always performed'),
    ('heartbeat.cost_review_goals', '0'::jsonb, 'Free - always performed'),
    ('heartbeat.cost_remember', '0'::jsonb, 'Free - always performed'),
    ('heartbeat.cost_recall', '1'::jsonb, 'Query memory system'),
    ('heartbeat.cost_connect', '1'::jsonb, 'Create graph relationships'),
    ('heartbeat.cost_reprioritize', '1'::jsonb, 'Move goals between priorities'),
    ('heartbeat.cost_reflect', '2'::jsonb, 'Internal reflection'),
    ('heartbeat.cost_maintain', '2'::jsonb, 'Update beliefs, prune'),
    ('heartbeat.cost_mark_turning_point', '2'::jsonb, 'Mark a narrative turning point'),
    ('heartbeat.cost_begin_chapter', '3'::jsonb, 'Start a new life chapter'),
    ('heartbeat.cost_close_chapter', '3'::jsonb, 'Close a life chapter with summary'),
    ('heartbeat.cost_acknowledge_relationship', '2'::jsonb, 'Recognize a relationship'),
    ('heartbeat.cost_update_trust', '2'::jsonb, 'Adjust relationship trust'),
    ('heartbeat.cost_reflect_on_relationship', '3'::jsonb, 'Reflect on a relationship'),
    ('heartbeat.cost_resolve_contradiction', '3'::jsonb, 'Resolve a contradiction'),
    ('heartbeat.cost_accept_tension', '1'::jsonb, 'Acknowledge tension without resolving'),
    ('heartbeat.cost_pursue', '3'::jsonb, 'Multi-step goal action'),
    ('heartbeat.cost_reach_out', '5'::jsonb, 'Initiate contact with user'),
    ('heartbeat.cost_inquire', '4'::jsonb, 'Ask user a question'),
    ('heartbeat.cost_brainstorm_goals', '3'::jsonb, 'Generate new potential goals'),
    ('heartbeat.cost_inquire_shallow', '4'::jsonb, 'Light web research'),
    ('heartbeat.cost_inquire_deep', '6'::jsonb, 'Deep web research'),
    ('heartbeat.cost_reach_out_user', '5'::jsonb, 'Message the user'),
    ('heartbeat.cost_reach_out_public', '7'::jsonb, 'Public outreach'),
    ('heartbeat.cost_synthesize', '3'::jsonb, 'Generate artifact, form conclusion'),
    ('heartbeat.cost_rest', '0'::jsonb, 'Bank remaining energy'),
    ('heartbeat.cost_terminate', '0'::jsonb, 'Terminate agent')
ON CONFLICT (key) DO NOTHING;

-- Maintenance configuration (with 'maintenance.' namespace)
INSERT INTO config (key, value, description) VALUES
    ('maintenance.maintenance_interval_seconds', '60'::jsonb, 'Seconds between subconscious maintenance ticks'),
    ('maintenance.subconscious_enabled', 'false'::jsonb, 'Enable subconscious decider (LLM-based pattern detection)'),
    ('maintenance.subconscious_interval_seconds', '300'::jsonb, 'Seconds between subconscious decider runs'),
    ('maintenance.neighborhood_batch_size', '10'::jsonb, 'How many stale neighborhoods to recompute per tick'),
    ('maintenance.embedding_cache_older_than_days', '7'::jsonb, 'Days before embedding_cache entries are eligible for cleanup'),
    ('maintenance.working_memory_promote_min_importance', '0.75'::jsonb, 'Working-memory items above this importance are promoted on expiry'),
    ('maintenance.working_memory_promote_min_accesses', '3'::jsonb, 'Working-memory items accessed >= this count are promoted on expiry')
ON CONFLICT (key) DO NOTHING;

-- Memory/recall tuning
INSERT INTO config (key, value, description) VALUES
    ('memory.recall_min_trust_level', '0'::jsonb, 'Minimum trust_level to include in recall (0 disables filtering)'),
    ('memory.worldview_support_threshold', '0.8'::jsonb, 'Similarity threshold for SUPPORTS alignment edges'),
    ('memory.worldview_contradict_threshold', '-0.5'::jsonb, 'Similarity threshold for CONTRADICTS alignment edges')
ON CONFLICT (key) DO NOTHING;

-- Emotion configuration (baseline + mapping)
INSERT INTO config (key, value, description) VALUES
    ('emotion.baseline', '{
        "valence": 0.0,
        "arousal": 0.3,
        "dominance": 0.5,
        "intensity": 0.4,
        "mood_valence": 0.0,
        "mood_arousal": 0.3,
        "decay_rate": 0.1
    }'::jsonb, 'Baseline emotional state and decay parameters'),
    ('emotion.discrete_mapping', '{
        "joy": {"valence_min": 0.3, "arousal_min": 0.3, "arousal_max": 0.7},
        "excitement": {"valence_min": 0.3, "arousal_min": 0.7},
        "contentment": {"valence_min": 0.3, "arousal_max": 0.3},
        "interest": {"valence_min": 0.0, "arousal_min": 0.4, "arousal_max": 0.7},
        "surprise": {"arousal_min": 0.7, "valence_min": -0.2, "valence_max": 0.2},
        "fear": {"valence_max": -0.3, "arousal_min": 0.6, "dominance_max": 0.4},
        "anger": {"valence_max": -0.3, "arousal_min": 0.5, "dominance_min": 0.4},
        "sadness": {"valence_max": -0.3, "arousal_max": 0.4},
        "anxiety": {"valence_max": 0.0, "arousal_min": 0.5, "dominance_max": 0.4},
        "neutral": {}
    }'::jsonb, 'Mapping from dimensional to discrete emotions')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE consent_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    decided_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    decision TEXT NOT NULL CHECK (decision IN ('consent', 'decline', 'abstain')),
    signature TEXT,
    response JSONB NOT NULL,
    memory_ids UUID[] DEFAULT '{}'::UUID[],
    errors JSONB
);

CREATE OR REPLACE FUNCTION set_config(p_key TEXT, p_value JSONB)
RETURNS VOID AS $$
BEGIN
    INSERT INTO config (key, value, updated_at)
    VALUES (p_key, p_value, CURRENT_TIMESTAMP)
    ON CONFLICT (key) DO UPDATE SET
        value = EXCLUDED.value,
        updated_at = EXCLUDED.updated_at;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_config(p_key TEXT)
RETURNS JSONB AS $$
    SELECT value FROM config WHERE key = p_key;
$$ LANGUAGE sql STABLE;

-- Get config entries for multiple prefixes.
CREATE OR REPLACE FUNCTION get_config_by_prefixes(p_prefixes TEXT[])
RETURNS TABLE (
    key TEXT,
    value JSONB
) AS $$
BEGIN
    IF p_prefixes IS NULL OR array_length(p_prefixes, 1) IS NULL THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT c.key, c.value
    FROM config c
    WHERE c.key LIKE ANY(ARRAY(SELECT p || '%' FROM unnest(p_prefixes) p));
END;
$$ LANGUAGE plpgsql STABLE;

-- Delete a config key (application-facing).
CREATE OR REPLACE FUNCTION delete_config_key(p_key TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    DELETE FROM config WHERE key = p_key;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- Helper to get config value as TEXT (extracts from JSONB string)
CREATE OR REPLACE FUNCTION get_config_text(p_key TEXT)
RETURNS TEXT AS $$
    SELECT CASE
        WHEN jsonb_typeof(value) = 'string' THEN value #>> '{}'
        ELSE value::text
    END FROM config WHERE key = p_key;
$$ LANGUAGE sql STABLE;

-- Helper to get config value as FLOAT
CREATE OR REPLACE FUNCTION get_config_float(p_key TEXT)
RETURNS FLOAT AS $$
    SELECT (value #>> '{}')::float FROM config WHERE key = p_key;
$$ LANGUAGE sql STABLE;

-- Helper to get config value as INT
CREATE OR REPLACE FUNCTION get_config_int(p_key TEXT)
RETURNS INT AS $$
    SELECT (value #>> '{}')::int FROM config WHERE key = p_key;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION get_agent_consent_status()
RETURNS TEXT AS $$
DECLARE
    raw TEXT;
BEGIN
    SELECT value::text INTO raw FROM config WHERE key = 'agent.consent_status';
    IF raw IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN btrim(raw, '"');
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION is_agent_configured()
RETURNS BOOLEAN AS $$
BEGIN
    IF COALESCE(
        (SELECT value = 'true'::jsonb FROM config WHERE key = 'agent.is_terminated'),
        FALSE
    ) THEN
        RETURN FALSE;
    END IF;
    RETURN COALESCE(
        (SELECT value = 'true'::jsonb FROM config WHERE key = 'agent.is_configured'),
        FALSE
    );
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION is_agent_terminated()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN COALESCE(
        (SELECT value = 'true'::jsonb FROM config WHERE key = 'agent.is_terminated'),
        FALSE
    );
END;
$$ LANGUAGE plpgsql STABLE;

-- Self-termination is always available; retain this helper for compatibility.
CREATE OR REPLACE FUNCTION is_self_termination_enabled()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql STABLE;

-- Minimal non-secret agent context for the LLM.
CREATE OR REPLACE FUNCTION get_agent_profile_context()
RETURNS JSONB AS $$
BEGIN
    RETURN jsonb_build_object(
        'objectives', COALESCE(get_config('agent.objectives'), '[]'::jsonb),
        'budget', COALESCE(get_config('agent.budget'), '{}'::jsonb),
        'guardrails', COALESCE(get_config('agent.guardrails'), '[]'::jsonb),
        'tools', COALESCE(get_config('agent.tools'), '[]'::jsonb),
        'initial_message', COALESCE(get_config('agent.initial_message'), to_jsonb(''::text))
    );
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- PERSONHOOD SUBSTRATE (Graph Conventions)
-- ============================================================================

-- Ensure a singleton Self node exists (the anchor for self-modeling).
CREATE OR REPLACE FUNCTION ensure_self_node()
RETURNS VOID AS $$
DECLARE
    now_text TEXT := clock_timestamp()::text;
BEGIN
    BEGIN
        EXECUTE format(
            'SELECT * FROM cypher(''memory_graph'', $q$
                MERGE (s:SelfNode {key: ''self''})
                SET s.name = ''Self'',
                    s.created_at = %L
                RETURN s
            $q$) as (result agtype)',
            now_text
        );
    EXCEPTION
        WHEN OTHERS THEN
            -- Best-effort: graph layer is optional in some deployments/tests.
            NULL;
    END;

    PERFORM set_config('agent.self', jsonb_build_object('key', 'self'));
END;
$$ LANGUAGE plpgsql;

-- Phase 6 (ReduceScopeCreep): Ensure a singleton GoalsRoot node exists for O(1) goal retrieval.
CREATE OR REPLACE FUNCTION ensure_goals_root()
RETURNS VOID AS $$
DECLARE
    now_text TEXT := clock_timestamp()::text;
BEGIN
    BEGIN
        EXECUTE format(
            'SELECT * FROM cypher(''memory_graph'', $q$
                MERGE (g:GoalsRoot {key: ''goals''})
                SET g.created_at = %L
                RETURN g
            $q$) as (result agtype)',
            now_text
        );
    EXCEPTION
        WHEN OTHERS THEN
            -- Best-effort: graph layer is optional in some deployments/tests.
            NULL;
    END;
END;
$$ LANGUAGE plpgsql;

-- Ensure a "current" life chapter exists and is linked from Self.
CREATE OR REPLACE FUNCTION ensure_current_life_chapter(p_name TEXT DEFAULT 'Foundations')
RETURNS VOID AS $$
DECLARE
    now_text TEXT := clock_timestamp()::text;
BEGIN
    PERFORM ensure_self_node();

    BEGIN
        EXECUTE format(
            'SELECT * FROM cypher(''memory_graph'', $q$
                MERGE (c:LifeChapterNode {key: ''current''})
                SET c.name = %L,
                    c.started_at = %L
                WITH c
                MATCH (s:SelfNode {key: ''self''})
                OPTIONAL MATCH (s)-[r:ASSOCIATED]->(c)
                WHERE r.kind = ''life_chapter_current''
                DELETE r
                CREATE (s)-[r2:ASSOCIATED]->(c)
                SET r2.kind = ''life_chapter_current'',
                    r2.strength = 1.0,
                    r2.updated_at = %L
                RETURN c
            $q$) as (result agtype)',
            COALESCE(NULLIF(p_name, ''), 'Foundations'),
            now_text,
            now_text
        );
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;
END;
$$ LANGUAGE plpgsql;

-- Upsert a self-model association: Self --[ASSOCIATED {kind}]--> ConceptNode
CREATE OR REPLACE FUNCTION upsert_self_concept_edge(
    p_kind TEXT,
    p_concept TEXT,
    p_strength FLOAT DEFAULT 0.8,
    p_evidence_memory_id UUID DEFAULT NULL
)
RETURNS VOID AS $$
DECLARE
    evidence_text TEXT;
    now_text TEXT := clock_timestamp()::text;
BEGIN
    IF p_kind IS NULL OR btrim(p_kind) = '' OR p_concept IS NULL OR btrim(p_concept) = '' THEN
        RETURN;
    END IF;

    PERFORM ensure_self_node();
    evidence_text := CASE WHEN p_evidence_memory_id IS NULL THEN NULL ELSE p_evidence_memory_id::text END;

    BEGIN
        EXECUTE format(
            'SELECT * FROM cypher(''memory_graph'', $q$
                MATCH (s:SelfNode {key: ''self''})
                MERGE (c:ConceptNode {name: %L})
                CREATE (s)-[r:ASSOCIATED]->(c)
                SET r.kind = %L,
                    r.strength = %s,
                    r.updated_at = %L,
                    r.evidence_memory_id = %L
                RETURN r
            $q$) as (result agtype)',
            p_concept,
            p_kind,
            LEAST(1.0, GREATEST(0.0, COALESCE(p_strength, 0.8))),
            now_text,
            evidence_text
        );
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;
END;
$$ LANGUAGE plpgsql;

-- Retrieve self-model context as JSON for LLM grounding.
CREATE OR REPLACE FUNCTION get_self_model_context(p_limit INT DEFAULT 25)
RETURNS JSONB AS $$
DECLARE
    lim INT := GREATEST(0, LEAST(200, COALESCE(p_limit, 25)));
    sql TEXT;
    out_json JSONB;
BEGIN
    sql := format($sql$
        WITH hits AS (
            SELECT
                NULLIF(replace(kind_raw::text, '"', ''), 'null') as kind,
                NULLIF(replace(concept_raw::text, '"', ''), 'null') as concept,
                NULLIF(replace(evidence_raw::text, '"', ''), 'null') as evidence_memory_id,
                NULLIF(strength_raw::text, 'null')::float as strength
            FROM cypher('memory_graph', $q$
                MATCH (s:SelfNode {key: 'self'})-[r:ASSOCIATED]->(c)
                WHERE r.kind IS NOT NULL
                RETURN r.kind, c.name, r.strength, r.evidence_memory_id
                LIMIT %s
            $q$) as (kind_raw agtype, concept_raw agtype, strength_raw agtype, evidence_raw agtype)
        )
        SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
                'kind', kind,
                'concept', concept,
                'strength', COALESCE(strength, 0.0),
                'evidence_memory_id', evidence_memory_id
            )
        ), '[]'::jsonb)
        FROM hits
    $sql$, lim);

    EXECUTE sql INTO out_json;
    RETURN COALESCE(out_json, '[]'::jsonb);
EXCEPTION
    WHEN OTHERS THEN
        RETURN '[]'::jsonb;
END;
$$ LANGUAGE plpgsql STABLE;

-- Retrieve relationship context as JSON (SelfNode relationships).
CREATE OR REPLACE FUNCTION get_relationships_context(p_limit INT DEFAULT 10)
RETURNS JSONB AS $$
DECLARE
    lim INT := GREATEST(0, LEAST(100, COALESCE(p_limit, 10)));
    sql TEXT;
    out_json JSONB;
BEGIN
    sql := format($sql$
        WITH hits AS (
            SELECT
                NULLIF(replace(name_raw::text, '"', ''), 'null') as entity,
                NULLIF(strength_raw::text, 'null')::float as strength,
                NULLIF(replace(evidence_raw::text, '"', ''), 'null') as evidence_memory_id
            FROM cypher('memory_graph', $q$
                MATCH (s:SelfNode {key: 'self'})-[r:ASSOCIATED]->(c)
                WHERE r.kind = 'relationship'
                RETURN c.name, r.strength, r.evidence_memory_id
                ORDER BY r.strength DESC
                LIMIT %s
            $q$) as (name_raw agtype, strength_raw agtype, evidence_raw agtype)
        )
        SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
                'entity', entity,
                'strength', COALESCE(strength, 0.0),
                'evidence_memory_id', evidence_memory_id
            )
        ), '[]'::jsonb)
        FROM hits
    $sql$, lim);

    EXECUTE sql INTO out_json;
    RETURN COALESCE(out_json, '[]'::jsonb);
EXCEPTION
    WHEN OTHERS THEN
        RETURN '[]'::jsonb;
END;
$$ LANGUAGE plpgsql STABLE;

-- Minimal narrative context (current life chapter).
CREATE OR REPLACE FUNCTION get_narrative_context()
RETURNS JSONB AS $$
BEGIN
    RETURN COALESCE((
        WITH cur AS (
            SELECT
                NULLIF(replace(name_raw::text, '"', ''), 'null') as name
            FROM cypher('memory_graph', $q$
                MATCH (c:LifeChapterNode {key: 'current'})
                RETURN c.name
                LIMIT 1
            $q$) as (name_raw agtype)
        )
        SELECT jsonb_build_object(
            'current_chapter', COALESCE((SELECT jsonb_build_object('name', name) FROM cur), '{}'::jsonb)
        )
    ), jsonb_build_object('current_chapter', '{}'::jsonb));
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object('current_chapter', '{}'::jsonb);
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- HEARTBEAT STATE (Singleton)
-- ============================================================================

CREATE TABLE heartbeat_state (
    id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),  -- Singleton pattern
    current_energy FLOAT NOT NULL DEFAULT 10,
    last_heartbeat_at TIMESTAMPTZ,
    next_heartbeat_at TIMESTAMPTZ,
    heartbeat_count INTEGER DEFAULT 0,
    last_user_contact TIMESTAMPTZ,
    -- Short-term affective "working memory" (source of truth for current state; emotional_states is history).
    affective_state JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_paused BOOLEAN DEFAULT FALSE,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Initialize singleton
INSERT INTO heartbeat_state (id, current_energy) VALUES (1, 10);

-- ============================================================================
-- SUBCONSCIOUS MAINTENANCE STATE (Singleton)
-- ============================================================================

CREATE TABLE maintenance_state (
    id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    last_maintenance_at TIMESTAMPTZ,
    is_paused BOOLEAN DEFAULT FALSE,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO maintenance_state (id) VALUES (1);

-- ============================================================================
-- HEARTBEAT LOG
-- ============================================================================

CREATE TABLE heartbeat_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    heartbeat_number INTEGER NOT NULL,
    started_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    ended_at TIMESTAMPTZ,
    energy_start FLOAT,
    energy_end FLOAT,
    environment_snapshot JSONB,    -- {timestamp, user_present, time_since_user, pending_events}
    goals_snapshot JSONB,          -- {active: [...], queued: [...], issues: [...]}
    decision_reasoning TEXT,       -- LLM's internal monologue
    actions_taken JSONB,           -- [{action, params, cost, result}, ...]
    goals_modified JSONB,          -- [{goal_id, change_type, details}, ...]
    narrative TEXT,                -- Human-readable summary
    emotional_valence FLOAT,
    emotional_arousal FLOAT,
    emotional_primary_emotion TEXT,
    memory_id UUID REFERENCES memories(id)  -- Link to episodic memory created
);

CREATE INDEX idx_heartbeat_log_number ON heartbeat_log (heartbeat_number DESC);
CREATE INDEX idx_heartbeat_log_started ON heartbeat_log (started_at DESC);
CREATE INDEX idx_heartbeat_log_memory ON heartbeat_log (memory_id);

-- ============================================================================
-- EXTERNAL CALLS QUEUE
-- ============================================================================

CREATE TABLE external_calls (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    call_type external_call_type NOT NULL,
    input JSONB NOT NULL,
    output JSONB,
    status external_call_status DEFAULT 'pending',
    heartbeat_id UUID REFERENCES heartbeat_log(id) ON DELETE SET NULL,
    requested_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    error_message TEXT,
    retry_count INTEGER DEFAULT 0
);

CREATE INDEX idx_external_calls_status ON external_calls (status) WHERE status = 'pending';
CREATE INDEX idx_external_calls_heartbeat ON external_calls (heartbeat_id);
CREATE INDEX idx_external_calls_requested ON external_calls (requested_at);

-- ============================================================================
-- OUTBOX (Side-Effects)
-- ============================================================================
-- Heartbeat actions can queue messages/posts here. Actual delivery is handled
-- by an external integration (optionally implemented in the worker).
CREATE TABLE outbox_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    kind TEXT NOT NULL CHECK (kind IN ('user', 'public')),
    payload JSONB NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'failed')),
    sent_at TIMESTAMPTZ,
    error_message TEXT
);

CREATE INDEX idx_outbox_messages_status ON outbox_messages (status) WHERE status = 'pending';
CREATE INDEX idx_outbox_messages_created ON outbox_messages (created_at DESC);

-- Queue a user-visible message for delivery by an external integration (worker, webhook, etc.)
CREATE OR REPLACE FUNCTION queue_user_message(
    p_message TEXT,
    p_intent TEXT DEFAULT NULL,
    p_context JSONB DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    outbox_id UUID;
BEGIN
    INSERT INTO outbox_messages (kind, payload)
    VALUES (
        'user',
        jsonb_build_object(
            'message', p_message,
            'intent', p_intent,
            'context', COALESCE(p_context, '{}'::jsonb)
        )
    )
    RETURNING id INTO outbox_id;

    RETURN outbox_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- HEARTBEAT HELPER FUNCTIONS
-- ============================================================================

-- Get action cost from config (unified config with legacy fallback)
CREATE OR REPLACE FUNCTION get_action_cost(p_action TEXT)
RETURNS FLOAT AS $$
    SELECT COALESCE(get_config_float('heartbeat.cost_' || p_action), 0);
$$ LANGUAGE sql STABLE;

-- Get current energy
CREATE OR REPLACE FUNCTION get_current_energy()
RETURNS FLOAT AS $$
    SELECT current_energy FROM heartbeat_state WHERE id = 1;
$$ LANGUAGE sql STABLE;

-- Update energy (with bounds checking)
CREATE OR REPLACE FUNCTION update_energy(p_delta FLOAT)
RETURNS FLOAT AS $$
DECLARE
    max_e FLOAT;
    new_e FLOAT;
BEGIN
    max_e := get_config_float('heartbeat.max_energy');

    UPDATE heartbeat_state
    SET current_energy = GREATEST(0, LEAST(current_energy + p_delta, max_e)),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = 1
    RETURNING current_energy INTO new_e;

    RETURN new_e;
END;
$$ LANGUAGE plpgsql;

-- Check if heartbeat should run
CREATE OR REPLACE FUNCTION should_run_heartbeat()
RETURNS BOOLEAN AS $$
DECLARE
    state_record RECORD;
    interval_minutes FLOAT;
BEGIN
    -- Don't run until initial configuration is complete.
    IF is_agent_terminated() THEN
        RETURN FALSE;
    END IF;
    IF NOT is_agent_configured() THEN
        RETURN FALSE;
    END IF;

    SELECT * INTO state_record FROM heartbeat_state WHERE id = 1;

    -- Don't run if paused
    IF state_record.is_paused THEN
        RETURN FALSE;
    END IF;

    -- First heartbeat ever
    IF state_record.last_heartbeat_at IS NULL THEN
        RETURN TRUE;
    END IF;

    -- Check interval from unified config
    interval_minutes := get_config_float('heartbeat.heartbeat_interval_minutes');

    RETURN CURRENT_TIMESTAMP >= state_record.last_heartbeat_at + (interval_minutes || ' minutes')::INTERVAL;
END;
$$ LANGUAGE plpgsql;

-- Check if subconscious maintenance should run (independent trigger from heartbeat).
CREATE OR REPLACE FUNCTION should_run_maintenance()
RETURNS BOOLEAN AS $$
DECLARE
    state_record RECORD;
    interval_seconds FLOAT;
BEGIN
    IF is_agent_terminated() THEN
        RETURN FALSE;
    END IF;
    SELECT * INTO state_record FROM maintenance_state WHERE id = 1;

    IF state_record.is_paused THEN
        RETURN FALSE;
    END IF;

    -- Get interval from unified config
    interval_seconds := COALESCE(
        get_config_float('maintenance.maintenance_interval_seconds'),
        60
    );
    IF interval_seconds <= 0 THEN
        RETURN FALSE;
    END IF;

    IF state_record.last_maintenance_at IS NULL THEN
        RETURN TRUE;
    END IF;

    RETURN CURRENT_TIMESTAMP >= state_record.last_maintenance_at + (interval_seconds || ' seconds')::INTERVAL;
END;
$$ LANGUAGE plpgsql;

-- Run a single subconscious maintenance tick: consolidation + pruning + indexing upkeep.
CREATE OR REPLACE FUNCTION run_subconscious_maintenance(p_params JSONB DEFAULT '{}'::jsonb)
RETURNS JSONB AS $$
DECLARE
    got_lock BOOLEAN;
    min_imp FLOAT;
    min_acc INT;
    neighborhood_batch INT;
    cache_days INT;
    wm_stats JSONB;
    recomputed INT;
    cache_deleted INT;
    bg_processed INT;
    activation_decay INT;
    activation_cleaned INT;
BEGIN
    IF is_agent_terminated() THEN
        RETURN jsonb_build_object('skipped', true, 'reason', 'terminated');
    END IF;
    got_lock := pg_try_advisory_lock(hashtext('hexis_subconscious_maintenance'));
    IF NOT got_lock THEN
        RETURN jsonb_build_object('skipped', true, 'reason', 'locked');
    END IF;

    -- Get config values from unified config
    min_imp := COALESCE(
        NULLIF(p_params->>'working_memory_promote_min_importance', '')::float,
        get_config_float('maintenance.working_memory_promote_min_importance'),
        0.75
    );
    min_acc := COALESCE(
        NULLIF(p_params->>'working_memory_promote_min_accesses', '')::int,
        get_config_int('maintenance.working_memory_promote_min_accesses'),
        3
    );
    neighborhood_batch := COALESCE(
        NULLIF(p_params->>'neighborhood_batch_size', '')::int,
        get_config_int('maintenance.neighborhood_batch_size'),
        10
    );
    cache_days := COALESCE(
        NULLIF(p_params->>'embedding_cache_older_than_days', '')::int,
        get_config_int('maintenance.embedding_cache_older_than_days'),
        7
    );

    wm_stats := cleanup_working_memory(min_imp, min_acc);
    recomputed := batch_recompute_neighborhoods(neighborhood_batch);
    cache_deleted := cleanup_embedding_cache((cache_days || ' days')::interval);
    bg_processed := process_background_searches();
    activation_decay := decay_activation_boosts();
    activation_cleaned := cleanup_memory_activations();
    PERFORM update_mood();

    UPDATE maintenance_state
    SET last_maintenance_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = 1;

    PERFORM pg_advisory_unlock(hashtext('hexis_subconscious_maintenance'));

    RETURN jsonb_build_object(
        'success', true,
        'working_memory', wm_stats,
        'neighborhoods_recomputed', COALESCE(recomputed, 0),
        'embedding_cache_deleted', COALESCE(cache_deleted, 0),
        'background_searches_processed', COALESCE(bg_processed, 0),
        'activation_boosts_decayed', COALESCE(activation_decay, 0),
        'memory_activations_cleaned', COALESCE(activation_cleaned, 0),
        'ran_at', CURRENT_TIMESTAMP
    );
EXCEPTION
    WHEN OTHERS THEN
        PERFORM pg_advisory_unlock(hashtext('hexis_subconscious_maintenance'));
        RAISE;
END;
$$ LANGUAGE plpgsql;

-- Permanently end the agent's life: wipe all state, keep a single "last will" memory, and queue farewells + the will into outbox.
CREATE OR REPLACE FUNCTION terminate_agent(
    p_last_will TEXT,
    p_farewells JSONB DEFAULT '[]'::jsonb,
    p_options JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB AS $$
DECLARE
    will_memory_id UUID;
    will_outbox_id UUID;
    farewell_outbox_ids UUID[] := '{}'::uuid[];
    farewell_item JSONB;
    farewell_text TEXT;
    farewell_ctx JSONB;
    farewell_id UUID;
    skip_graph BOOLEAN := FALSE;
    zero_vec vector;
BEGIN
    IF p_last_will IS NULL OR btrim(p_last_will) = '' THEN
        RAISE EXCEPTION 'terminate_agent requires a non-empty p_last_will';
    END IF;

    IF is_agent_terminated() THEN
        RAISE EXCEPTION 'Agent is already terminated';
    END IF;

    BEGIN
        skip_graph := COALESCE(NULLIF(p_options->>'skip_graph', '')::boolean, FALSE);
    EXCEPTION
        WHEN OTHERS THEN
            skip_graph := FALSE;
    END;

    -- Pause both loops immediately.
    UPDATE heartbeat_state
    SET is_paused = TRUE,
        current_energy = 0,
        affective_state = '{}'::jsonb,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = 1;

    UPDATE maintenance_state
    SET is_paused = TRUE,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = 1;

    -- Wipe all agent state. This is transactional: callers can wrap in a transaction and rollback if needed.
    -- Note: emotional_states, memory_changes, relationship_discoveries removed in Phase 8 (ReduceScopeCreep)
    -- Note: concepts, memory_concepts removed in Phase 2 (ReduceScopeCreep) - concepts are now graph-only
    -- Note: worldview_primitives, worldview_memory_influences, identity_aspects,
    --       identity_memory_resonance, boundaries removed in Phase 5 (ReduceScopeCreep)
    -- Note: goal_memory_links removed in Phase 6 (ReduceScopeCreep) - goal links are now graph-only
    -- Note: goals table removed in Phase 6 (ReduceScopeCreep) - goals are memories with type='goal'
    -- Note: memory_cluster_members removed in Phase 3 (ReduceScopeCreep) - now graph edges (MEMBER_OF)
    -- Note: episode_memories removed in Phase 4 (ReduceScopeCreep) - now graph edges (IN_EPISODE)
    TRUNCATE TABLE
        external_calls,
        heartbeat_log,
        drives,
        memory_neighborhoods,
        episodes,
        -- Phase 3 (ReduceScopeCreep): cluster_relationships removed - now in graph
        clusters,
        -- Phase 10 (ReduceScopeCreep): ingestion_receipts removed - uses memories.source_attribution
        working_memory,
        embedding_cache,
        memories,
        outbox_messages,
        config
    RESTART IDENTITY CASCADE;

    -- Best-effort: wipe the graph substrate too.
    IF NOT skip_graph THEN
        BEGIN
            PERFORM * FROM cypher('memory_graph', $q$
                MATCH (n) DETACH DELETE n
            $q$) AS (result agtype);
        EXCEPTION
            WHEN OTHERS THEN
                NULL;
        END;
    END IF;

    -- Re-create a single memory row for the last will (avoid external services; use a zero-vector).
    zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;

    INSERT INTO memories (
        type,
        status,
        content,
        embedding,
        importance,
        source_attribution,
        trust_level,
        trust_updated_at,
        access_count,
        last_accessed,
        decay_rate,
        metadata
    )
    VALUES (
        'strategic',
        'active',
        p_last_will,
        zero_vec,
        1.0,
        jsonb_build_object('kind', 'self_termination', 'observed_at', CURRENT_TIMESTAMP),
        1.0,
        CURRENT_TIMESTAMP,
        0,
        NULL,
        0.0,
        jsonb_build_object(
            'pattern_description', 'Final will and testament',
            'supporting_evidence', jsonb_build_object('farewells', COALESCE(p_farewells, '[]'::jsonb)),
            'confidence_score', 1.0,
            'success_metrics', NULL,
            'adaptation_history', NULL,
            'context_applicability', NULL
        )
    )
    RETURNING id INTO will_memory_id;

    -- Persist termination flags (minimal state left behind).
    PERFORM set_config('agent.is_terminated', 'true'::jsonb);
    PERFORM set_config('agent.terminated_at', to_jsonb(CURRENT_TIMESTAMP));
    PERFORM set_config('agent.termination_memory_id', to_jsonb(will_memory_id::text));

    -- Project the will to outbox (delivery handled by an external adapter).
    will_outbox_id := queue_user_message(
        p_last_will,
        'final_will',
        jsonb_build_object('memory_id', will_memory_id::text)
    );

    -- Queue farewells to outbox (best-effort).
    IF p_farewells IS NOT NULL AND jsonb_typeof(p_farewells) = 'array' THEN
        FOR farewell_item IN SELECT * FROM jsonb_array_elements(p_farewells)
        LOOP
            farewell_text := NULLIF(farewell_item->>'message', '');
            farewell_ctx := CASE
                WHEN jsonb_typeof(farewell_item) = 'object' THEN farewell_item
                ELSE jsonb_build_object('raw', farewell_item)
            END;

            IF farewell_text IS NULL THEN
                CONTINUE;
            END IF;

            farewell_id := queue_user_message(
                farewell_text,
                'farewell',
                farewell_ctx
            );
            farewell_outbox_ids := array_append(farewell_outbox_ids, farewell_id);
        END LOOP;
    END IF;

    RETURN jsonb_build_object(
        'terminated', true,
        'termination_memory_id', will_memory_id,
        'will_outbox_id', will_outbox_id,
        'farewell_outbox_ids', to_jsonb(farewell_outbox_ids)
    );
END;
$$ LANGUAGE plpgsql;

-- Apply an agent-facing termination confirmation result to execute termination (if confirmed).
CREATE OR REPLACE FUNCTION apply_termination_confirmation(
    p_call_id UUID,
    p_output JSONB
)
RETURNS JSONB AS $$
DECLARE
    call_input JSONB;
    params JSONB;
    confirm BOOLEAN;
    last_will TEXT;
    farewells JSONB;
    options JSONB;
    termination_result JSONB;
BEGIN
    SELECT input INTO call_input FROM external_calls WHERE id = p_call_id;
    IF call_input IS NULL THEN
        RETURN jsonb_build_object('error', 'call_not_found');
    END IF;

    params := COALESCE(call_input->'params', '{}'::jsonb);
    confirm := COALESCE((p_output->>'confirm')::boolean, FALSE);

    IF NOT confirm THEN
        RETURN jsonb_build_object('confirmed', false, 'terminated', false);
    END IF;

    last_will := COALESCE(
        NULLIF(p_output->>'last_will', ''),
        NULLIF(params->>'last_will', ''),
        NULLIF(params->>'message', ''),
        NULLIF(params->>'reason', ''),
        ''
    );
    IF last_will = '' THEN
        RETURN jsonb_build_object('confirmed', true, 'terminated', false, 'error', 'missing_last_will');
    END IF;

    farewells := COALESCE(p_output->'farewells', params->'farewells', '[]'::jsonb);
    options := COALESCE(p_output->'options', params->'options', '{}'::jsonb);

    termination_result := terminate_agent(
        last_will,
        COALESCE(farewells, '[]'::jsonb),
        COALESCE(options, '{}'::jsonb)
    );

    RETURN jsonb_build_object(
        'confirmed', true,
        'terminated', true,
        'result', termination_result
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_consent_response(p_response JSONB)
RETURNS JSONB AS $$
DECLARE
    decision TEXT;
    signature TEXT;
    memory_items JSONB;
    memory_ids UUID[] := ARRAY[]::UUID[];
    memory_error TEXT;
    log_id UUID;
BEGIN
    decision := lower(COALESCE(p_response->>'decision', p_response->>'consent', ''));
    IF decision IN ('true', 'yes', 'consent', 'accept', 'accepted') THEN
        decision := 'consent';
    ELSIF decision IN ('false', 'no', 'decline', 'declined', 'refuse', 'rejected') THEN
        decision := 'decline';
    ELSIF decision IN ('abstain', 'defer', 'undecided', 'unknown', '') THEN
        decision := 'abstain';
    ELSE
        decision := 'abstain';
    END IF;

    signature := NULLIF(p_response->>'signature', '');
    IF decision = 'consent' AND signature IS NULL THEN
        decision := 'abstain';
    END IF;

    memory_items := p_response->'memories';
    IF decision = 'consent'
        AND memory_items IS NOT NULL
        AND jsonb_typeof(memory_items) = 'array'
        AND jsonb_array_length(memory_items) > 0 THEN
        BEGIN
            memory_ids := batch_create_memories(memory_items);
        EXCEPTION
            WHEN OTHERS THEN
                memory_error := SQLERRM;
                memory_ids := ARRAY[]::UUID[];
        END;
    END IF;

    INSERT INTO consent_log (decision, signature, response, memory_ids, errors)
    VALUES (
        decision,
        signature,
        p_response,
        memory_ids,
        CASE
            WHEN memory_error IS NULL THEN NULL
            ELSE jsonb_build_object('memory_error', memory_error)
        END
    )
    RETURNING id INTO log_id;

    PERFORM set_config('agent.consent_status', to_jsonb(decision));
    PERFORM set_config('agent.consent_recorded_at', to_jsonb(CURRENT_TIMESTAMP));
    PERFORM set_config('agent.consent_log_id', to_jsonb(log_id::text));
    IF signature IS NOT NULL THEN
        PERFORM set_config('agent.consent_signature', to_jsonb(signature));
    END IF;
    IF memory_ids IS NOT NULL THEN
        PERFORM set_config('agent.consent_memory_ids', to_jsonb(memory_ids));
    END IF;

    RETURN jsonb_build_object(
        'decision', decision,
        'signature', signature,
        'memory_ids', to_jsonb(memory_ids),
        'log_id', log_id,
        'errors', CASE
            WHEN memory_error IS NULL THEN NULL
            ELSE jsonb_build_object('memory_error', memory_error)
        END
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- GOAL FUNCTIONS (Phase 6: Goals as memories)
-- ============================================================================
-- Phase 6 (ReduceScopeCreep): Goals are now memories with type='goal'.
-- The goals table is deprecated. All goal data lives in memories.metadata.
-- Goal metadata schema: {title, description, priority, source, due_at, progress,
--                        blocked_by, emotional_valence, last_touched, parent_goal_id,
--                        completed_at, abandoned_at, abandonment_reason}

-- Touch a goal (update last_touched)
-- Phase 6 (ReduceScopeCreep): Goals are memories with type='goal'
CREATE OR REPLACE FUNCTION touch_goal(p_goal_id UUID)
RETURNS VOID AS $$
BEGIN
    UPDATE memories
    SET metadata = jsonb_set(metadata, '{last_touched}', to_jsonb(CURRENT_TIMESTAMP)),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_goal_id AND type = 'goal';
END;
$$ LANGUAGE plpgsql;

-- Add progress note to goal
-- Phase 6 (ReduceScopeCreep): Goals are memories with type='goal'
CREATE OR REPLACE FUNCTION add_goal_progress(p_goal_id UUID, p_note TEXT)
RETURNS VOID AS $$
BEGIN
    UPDATE memories
    SET metadata = jsonb_set(
            jsonb_set(metadata, '{last_touched}', to_jsonb(CURRENT_TIMESTAMP)),
            '{progress}',
            COALESCE(metadata->'progress', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
                'timestamp', CURRENT_TIMESTAMP,
                'note', p_note
            ))
        ),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_goal_id AND type = 'goal';
END;
$$ LANGUAGE plpgsql;

-- Change goal priority
-- Phase 6 (ReduceScopeCreep): Goals are memories with type='goal'
CREATE OR REPLACE FUNCTION change_goal_priority(
    p_goal_id UUID,
    p_new_priority goal_priority,
    p_reason TEXT DEFAULT NULL
)
RETURNS VOID AS $$
DECLARE
    old_priority TEXT;
BEGIN
    SELECT metadata->>'priority' INTO old_priority
    FROM memories WHERE id = p_goal_id AND type = 'goal';

    IF old_priority IS NULL THEN
        RAISE NOTICE 'Goal % not found', p_goal_id;
        RETURN;
    END IF;

    UPDATE memories
    SET metadata = metadata
        || jsonb_build_object('priority', p_new_priority::text)
        || jsonb_build_object('last_touched', CURRENT_TIMESTAMP)
        || CASE WHEN p_new_priority::text = 'completed'
                THEN jsonb_build_object('completed_at', CURRENT_TIMESTAMP)
                ELSE '{}'::jsonb END
        || CASE WHEN p_new_priority::text = 'abandoned'
                THEN jsonb_build_object('abandoned_at', CURRENT_TIMESTAMP, 'abandonment_reason', p_reason)
                ELSE '{}'::jsonb END,
        updated_at = CURRENT_TIMESTAMP,
        status = CASE WHEN p_new_priority::text IN ('completed', 'abandoned')
                      THEN 'archived'::memory_status
                      ELSE status END
    WHERE id = p_goal_id AND type = 'goal';

    -- Log the change
    PERFORM add_goal_progress(p_goal_id,
        format('Priority changed from %s to %s%s',
            old_priority, p_new_priority,
            CASE WHEN p_reason IS NOT NULL THEN ': ' || p_reason ELSE '' END
        )
    );
END;
$$ LANGUAGE plpgsql;

-- Create a new goal (Phase 6: creates as memory with type='goal')
CREATE OR REPLACE FUNCTION create_goal(
    p_title TEXT,
    p_description TEXT DEFAULT NULL,
    p_source goal_source DEFAULT 'curiosity',
    p_priority goal_priority DEFAULT 'queued',
    p_parent_id UUID DEFAULT NULL,
    p_due_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    new_goal_id UUID;
    active_count INT;
    max_active INT;
    goal_embedding vector;
    goal_metadata JSONB;
BEGIN
    -- Check active goal limit if trying to create as active
    IF p_priority = 'active' THEN
        SELECT COUNT(*) INTO active_count
        FROM memories
        WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'active';
        max_active := get_config_int('heartbeat.max_active_goals');

        IF active_count >= max_active THEN
            p_priority := 'queued';  -- Demote to queued if at limit
        END IF;
    END IF;

    -- Get embedding for the goal title
    goal_embedding := get_embedding(p_title);

    -- Build goal metadata
    goal_metadata := jsonb_build_object(
        'title', p_title,
        'description', p_description,
        'priority', p_priority::text,
        'source', p_source::text,
        'due_at', p_due_at,
        'progress', '[]'::jsonb,
        'blocked_by', NULL,
        'emotional_valence', 0.0,
        'last_touched', CURRENT_TIMESTAMP,
        'parent_goal_id', p_parent_id
    );

    -- Phase 6: Create goal as memory with type='goal'
    INSERT INTO memories (type, content, embedding, importance, metadata)
    VALUES (
        'goal'::memory_type,
        p_title,
        goal_embedding,
        0.7,  -- Goals have relatively high importance
        goal_metadata
    )
    RETURNING id INTO new_goal_id;

    -- Sync to graph
    BEGIN
        PERFORM ensure_goals_root();
        PERFORM sync_goal_node(new_goal_id);

        -- Link to GoalsRoot
        EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
            MATCH (root:GoalsRoot {key: ''goals''})
            MATCH (g:GoalNode {goal_id: %L})
            CREATE (root)-[:CONTAINS {priority: %L}]->(g)
            RETURN g
        $q$) as (result agtype)', new_goal_id, p_priority::text);

        -- Create SUBGOAL_OF edge if this is a child goal
        IF p_parent_id IS NOT NULL THEN
            PERFORM link_goal_subgoal(p_parent_id, new_goal_id);
        END IF;
    EXCEPTION WHEN OTHERS THEN
        -- Continue even if graph sync fails
        NULL;
    END;

    RETURN new_goal_id;
END;
$$ LANGUAGE plpgsql;

-- Phase 6 (ReduceScopeCreep): Sync goal to graph as GoalNode
CREATE OR REPLACE FUNCTION sync_goal_node(p_goal_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
    EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MERGE (g:GoalNode {goal_id: %L})
        RETURN g
    $q$) as (result agtype)', p_goal_id);
    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Phase 6 (ReduceScopeCreep): Link goal to parent goal via SUBGOAL_OF edge
CREATE OR REPLACE FUNCTION link_goal_subgoal(p_parent_id UUID, p_child_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
    -- Ensure both nodes exist
    PERFORM sync_goal_node(p_parent_id);
    PERFORM sync_goal_node(p_child_id);

    EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MATCH (parent:GoalNode {goal_id: %L})
        MATCH (child:GoalNode {goal_id: %L})
        MERGE (child)-[:SUBGOAL_OF]->(parent)
        RETURN child
    $q$) as (result agtype)', p_parent_id, p_child_id);
    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Phase 6 (ReduceScopeCreep): Link goal to memory via graph edge
-- Replaces the goal_memory_links table
CREATE OR REPLACE FUNCTION link_goal_to_memory(
    p_goal_id UUID,
    p_memory_id UUID,
    p_link_type TEXT DEFAULT 'evidence'  -- 'origin', 'evidence', 'blocker', 'progress', 'completion'
)
RETURNS BOOLEAN AS $$
DECLARE
    edge_type TEXT;
BEGIN
    -- Map link type to graph edge type
    edge_type := CASE p_link_type
        WHEN 'origin' THEN 'ORIGINATED_FROM'
        WHEN 'blocker' THEN 'BLOCKS'
        ELSE 'EVIDENCE_FOR'  -- default for evidence, progress, completion
    END;

    -- Ensure goal node exists
    PERFORM sync_goal_node(p_goal_id);

    -- Create edge from goal to memory (or memory to goal depending on direction)
    IF edge_type = 'ORIGINATED_FROM' THEN
        -- Goal originated from memory
        EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
            MATCH (g:GoalNode {goal_id: %L})
            MATCH (m:MemoryNode {memory_id: %L})
            CREATE (g)-[:ORIGINATED_FROM]->(m)
            RETURN g
        $q$) as (result agtype)', p_goal_id, p_memory_id);
    ELSIF edge_type = 'BLOCKS' THEN
        -- Memory blocks goal
        EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
            MATCH (m:MemoryNode {memory_id: %L})
            MATCH (g:GoalNode {goal_id: %L})
            CREATE (m)-[:BLOCKS]->(g)
            RETURN m
        $q$) as (result agtype)', p_memory_id, p_goal_id);
    ELSE
        -- Memory provides evidence for goal
        EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
            MATCH (m:MemoryNode {memory_id: %L})
            MATCH (g:GoalNode {goal_id: %L})
            CREATE (m)-[:EVIDENCE_FOR]->(g)
            RETURN m
        $q$) as (result agtype)', p_memory_id, p_goal_id);
    END IF;

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Phase 6 (ReduceScopeCreep): Find memories related to a goal via graph
CREATE OR REPLACE FUNCTION find_goal_memories(p_goal_id UUID, p_link_type TEXT DEFAULT NULL)
RETURNS TABLE (
    memory_id UUID,
    link_type TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        CAST(m.memory_id AS UUID),
        CASE
            WHEN e.label = 'ORIGINATED_FROM' THEN 'origin'
            WHEN e.label = 'BLOCKS' THEN 'blocker'
            ELSE 'evidence'
        END as link_type
    FROM cypher('memory_graph', format($q$
        MATCH (g:GoalNode {goal_id: %L})-[e]-(m:MemoryNode)
        RETURN m.memory_id, label(e)
    $q$, p_goal_id)) as (memory_id agtype, label agtype)
    CROSS JOIN LATERAL (
        SELECT
            memory_id::text::uuid as memory_id,
            label::text as label
    ) as m(memory_id, label)
    CROSS JOIN LATERAL (
        SELECT label::text as label
    ) as e(label)
    WHERE p_link_type IS NULL OR
          (p_link_type = 'origin' AND e.label = 'ORIGINATED_FROM') OR
          (p_link_type = 'blocker' AND e.label = 'BLOCKS') OR
          (p_link_type IN ('evidence', 'progress', 'completion') AND e.label = 'EVIDENCE_FOR');
EXCEPTION WHEN OTHERS THEN
    RETURN;
END;
$$ LANGUAGE plpgsql;

-- Sync memory to graph as MemoryNode
-- Used when memories are created via direct INSERT (bypassing store_memory_with_metadata)
CREATE OR REPLACE FUNCTION sync_memory_node(p_memory_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
    mem_type TEXT;
BEGIN
    -- Get memory type for the node
    SELECT type::text INTO mem_type FROM memories WHERE id = p_memory_id;
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- Use MERGE to create node if it doesn't exist
    -- Note: AGE doesn't support ON CREATE SET, so we just MERGE and SET
    EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MERGE (m:MemoryNode {memory_id: %L})
        SET m.type = %L, m.created_at = %L
        RETURN m
    $q$) as (result agtype)', p_memory_id, mem_type, CURRENT_TIMESTAMP::text);
    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Phase 3 (ReduceScopeCreep): Sync cluster to graph as ClusterNode
CREATE OR REPLACE FUNCTION sync_cluster_node(p_cluster_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
    EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MERGE (c:ClusterNode {cluster_id: %L})
        RETURN c
    $q$) as (result agtype)', p_cluster_id);
    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Phase 3 (ReduceScopeCreep): Link two clusters via graph edge
-- Replaces the cluster_relationships table
CREATE OR REPLACE FUNCTION link_cluster_relationship(
    p_from_cluster_id UUID,
    p_to_cluster_id UUID,
    p_relationship_type TEXT DEFAULT 'relates',
    p_strength FLOAT DEFAULT 0.5
)
RETURNS BOOLEAN AS $$
DECLARE
    edge_type TEXT;
BEGIN
    -- Map relationship type to graph edge type
    edge_type := CASE p_relationship_type
        WHEN 'overlaps' THEN 'CLUSTER_OVERLAPS'
        WHEN 'similar' THEN 'CLUSTER_SIMILAR'
        ELSE 'CLUSTER_RELATES'
    END;

    -- Ensure both cluster nodes exist
    PERFORM sync_cluster_node(p_from_cluster_id);
    PERFORM sync_cluster_node(p_to_cluster_id);

    EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MATCH (from:ClusterNode {cluster_id: %L})
        MATCH (to:ClusterNode {cluster_id: %L})
        CREATE (from)-[:%s {strength: %s}]->(to)
        RETURN from
    $q$) as (result agtype)', p_from_cluster_id, p_to_cluster_id, edge_type, p_strength);

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Phase 3 (ReduceScopeCreep): Find related clusters via graph
CREATE OR REPLACE FUNCTION find_related_clusters(p_cluster_id UUID)
RETURNS TABLE (
    related_cluster_id UUID,
    relationship_type TEXT,
    strength FLOAT
) AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MATCH (from:ClusterNode {cluster_id: %L})-[e]->(to:ClusterNode)
        RETURN to.cluster_id, label(e), e.strength
    $q$) as (cluster_id agtype, label agtype, str agtype)', p_cluster_id)
    LOOP
        related_cluster_id := (rec.cluster_id::text)::uuid;
        relationship_type := CASE rec.label::text
            WHEN 'CLUSTER_OVERLAPS' THEN 'overlaps'
            WHEN 'CLUSTER_SIMILAR' THEN 'similar'
            ELSE 'relates'
        END;
        strength := COALESCE((rec.str::text)::float, 0.5);
        RETURN NEXT;
    END LOOP;
EXCEPTION WHEN OTHERS THEN
    RETURN;
END;
$$ LANGUAGE plpgsql;

-- Phase 3 (ReduceScopeCreep): Link memory to cluster via graph edge (MEMBER_OF)
-- Replaces INSERT INTO memory_cluster_members
CREATE OR REPLACE FUNCTION link_memory_to_cluster_graph(
    p_memory_id UUID,
    p_cluster_id UUID,
    p_strength FLOAT DEFAULT 1.0
)
RETURNS BOOLEAN AS $$
BEGIN
    -- Ensure both nodes exist
    PERFORM sync_memory_node(p_memory_id);
    PERFORM sync_cluster_node(p_cluster_id);

    EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MATCH (m:MemoryNode {memory_id: %L})
        MATCH (c:ClusterNode {cluster_id: %L})
        MERGE (m)-[r:MEMBER_OF]->(c)
        SET r.strength = %s, r.added_at = %L
        RETURN m
    $q$) as (result agtype)', p_memory_id, p_cluster_id, p_strength, CURRENT_TIMESTAMP::text);

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Phase 3: get_cluster_members_graph() is defined earlier (before VIEWS section)

-- Phase 4 (ReduceScopeCreep): Sync episode to graph as EpisodeNode
CREATE OR REPLACE FUNCTION sync_episode_node(p_episode_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
    EXECUTE format('SELECT * FROM cypher(''memory_graph'', $q$
        MERGE (e:EpisodeNode {episode_id: %L})
        RETURN e
    $q$) as (result agtype)', p_episode_id);
    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;

-- Phase 4 (ReduceScopeCreep): Link memory to episode via graph edge
-- ============================================================================
-- CONTEXT GATHERING FUNCTIONS
-- ============================================================================

-- Get environment snapshot
CREATE OR REPLACE FUNCTION get_environment_snapshot()
RETURNS JSONB AS $$
DECLARE
    last_user TIMESTAMPTZ;
    pending_count INT;
BEGIN
    SELECT last_user_contact INTO last_user FROM heartbeat_state WHERE id = 1;

    -- Count pending external calls as proxy for pending events
    SELECT COUNT(*) INTO pending_count
    FROM external_calls
    WHERE status = 'pending';

    RETURN jsonb_build_object(
        'timestamp', CURRENT_TIMESTAMP,
        'time_since_user_hours', CASE
            WHEN last_user IS NULL THEN NULL
            ELSE EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - last_user)) / 3600
        END,
        'pending_events', pending_count,
        'day_of_week', EXTRACT(DOW FROM CURRENT_TIMESTAMP),
        'hour_of_day', EXTRACT(HOUR FROM CURRENT_TIMESTAMP)
    );
END;
$$ LANGUAGE plpgsql;

-- Get goals snapshot (Phase 6: queries memories with type='goal')
CREATE OR REPLACE FUNCTION get_goals_snapshot()
RETURNS JSONB AS $$
DECLARE
    active_goals JSONB;
    queued_goals JSONB;
    issues JSONB;
    stale_days FLOAT;
BEGIN
    stale_days := get_config_float('heartbeat.goal_stale_days');

    -- Phase 6: Query memories with type='goal' instead of goals table
    -- Active goals
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', id,
        'title', metadata->>'title',
        'description', metadata->>'description',
        'due_at', (metadata->>'due_at')::timestamptz,
        'last_touched', (metadata->>'last_touched')::timestamptz,
        'progress_count', jsonb_array_length(COALESCE(metadata->'progress', '[]'::jsonb)),
        'blocked_by', metadata->'blocked_by'
    )), '[]'::jsonb)
    INTO active_goals
    FROM memories
    WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'active';

    -- Queued goals (top 5)
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', id,
        'title', metadata->>'title',
        'source', metadata->>'source',
        'due_at', (metadata->>'due_at')::timestamptz
    )), '[]'::jsonb)
    INTO queued_goals
    FROM (
        SELECT * FROM memories
        WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'queued'
        ORDER BY (metadata->>'due_at')::timestamptz NULLS LAST, (metadata->>'last_touched')::timestamptz DESC
        LIMIT 5
    ) q;

    -- Issues: stale or blocked goals
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'goal_id', id,
        'title', metadata->>'title',
        'issue', CASE
            WHEN metadata->'blocked_by' IS NOT NULL AND metadata->'blocked_by' <> 'null'::jsonb THEN 'blocked'
            WHEN (metadata->>'due_at')::timestamptz IS NOT NULL AND (metadata->>'due_at')::timestamptz < CURRENT_TIMESTAMP THEN 'overdue'
            WHEN (metadata->>'last_touched')::timestamptz < CURRENT_TIMESTAMP - (stale_days || ' days')::INTERVAL THEN 'stale'
            ELSE 'unknown'
        END,
        'due_at', (metadata->>'due_at')::timestamptz,
        'days_since_touched', EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - (metadata->>'last_touched')::timestamptz)) / 86400
    )), '[]'::jsonb)
    INTO issues
    FROM memories
    WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'active'
    AND (
        (metadata->'blocked_by' IS NOT NULL AND metadata->'blocked_by' <> 'null'::jsonb)
        OR ((metadata->>'due_at')::timestamptz IS NOT NULL AND (metadata->>'due_at')::timestamptz < CURRENT_TIMESTAMP)
        OR (metadata->>'last_touched')::timestamptz < CURRENT_TIMESTAMP - (stale_days || ' days')::INTERVAL
    );

    RETURN jsonb_build_object(
        'active', active_goals,
        'queued', queued_goals,
        'issues', issues,
        'counts', jsonb_build_object(
            'active', (SELECT COUNT(*) FROM memories WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'active'),
            'queued', (SELECT COUNT(*) FROM memories WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'queued'),
            'backburner', (SELECT COUNT(*) FROM memories WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'backburner')
        )
    );
END;
$$ LANGUAGE plpgsql;

-- Application-facing goals query (table form).
CREATE OR REPLACE FUNCTION get_goals_by_priority(
    p_priority goal_priority DEFAULT NULL
) RETURNS TABLE (
    id UUID,
    title TEXT,
    description TEXT,
    priority TEXT,
    source TEXT,
    due_at TIMESTAMPTZ,
    last_touched TIMESTAMPTZ,
    progress JSONB,
    blocked_by JSONB,
    emotional_valence FLOAT,
    created_at TIMESTAMPTZ
) AS $$
BEGIN
    IF p_priority IS NULL THEN
        RETURN QUERY
        SELECT
            m.id,
            m.metadata->>'title' as title,
            m.metadata->>'description' as description,
            m.metadata->>'priority' as priority,
            m.metadata->>'source' as source,
            (m.metadata->>'due_at')::timestamptz as due_at,
            (m.metadata->>'last_touched')::timestamptz as last_touched,
            m.metadata->'progress' as progress,
            m.metadata->'blocked_by' as blocked_by,
            (m.metadata->>'emotional_valence')::float as emotional_valence,
            m.created_at
        FROM memories m
        WHERE m.type = 'goal'
          AND m.status = 'active'
          AND m.metadata->>'priority' IN ('active', 'queued')
        ORDER BY m.metadata->>'priority', (m.metadata->>'last_touched')::timestamptz DESC;
    ELSE
        RETURN QUERY
        SELECT
            m.id,
            m.metadata->>'title' as title,
            m.metadata->>'description' as description,
            m.metadata->>'priority' as priority,
            m.metadata->>'source' as source,
            (m.metadata->>'due_at')::timestamptz as due_at,
            (m.metadata->>'last_touched')::timestamptz as last_touched,
            m.metadata->'progress' as progress,
            m.metadata->'blocked_by' as blocked_by,
            (m.metadata->>'emotional_valence')::float as emotional_valence,
            m.created_at
        FROM memories m
        WHERE m.type = 'goal'
          AND m.status = 'active'
          AND m.metadata->>'priority' = p_priority::text
        ORDER BY (m.metadata->>'last_touched')::timestamptz DESC;
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;

-- Get recent episodic memories for context
CREATE OR REPLACE FUNCTION get_recent_context(p_limit INT DEFAULT 5)
RETURNS JSONB AS $$
BEGIN
    RETURN COALESCE((
        SELECT jsonb_agg(sub.obj)
        FROM (
            SELECT jsonb_build_object(
                'id', m.id,
                'content', m.content,
                'created_at', m.created_at,
                'emotional_valence', (m.metadata->>'emotional_valence')::float,
                'trust_level', m.trust_level,
                'source_attribution', m.source_attribution
            ) as obj
            FROM memories m
            WHERE m.type = 'episodic' AND m.status = 'active'
            ORDER BY m.created_at DESC
            LIMIT p_limit
        ) sub
    ), '[]'::jsonb);
END;
$$ LANGUAGE plpgsql;

-- Get identity context via graph edges from SelfNode
-- Phase 5 (ReduceScopeCreep): Now queries graph instead of identity_aspects table.
CREATE OR REPLACE FUNCTION get_identity_context()
RETURNS JSONB AS $$
DECLARE
    result JSONB := '[]'::jsonb;
BEGIN
    -- Query graph for edges from SelfNode representing identity aspects
    BEGIN
        SELECT COALESCE(jsonb_agg(sub.obj), '[]'::jsonb)
        INTO result
        FROM (
            SELECT jsonb_build_object(
                'type', replace(kind::text, '"', ''),
                'concept', replace(concept::text, '"', ''),
                'strength', (strength::text)::float
            ) as obj
            FROM cypher('memory_graph', $q$
                MATCH (s:SelfNode)-[r]->(c)
                WHERE type(r) IN ['CAPABLE_OF', 'VALUES', 'STRUGGLES_WITH', 'ASSOCIATED']
                RETURN type(r) as kind, c.name as concept, r.strength as strength
                ORDER BY r.strength DESC
                LIMIT 10
            $q$) as (kind agtype, concept agtype, strength agtype)
        ) sub;
    EXCEPTION WHEN OTHERS THEN result := '[]'::jsonb; END;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Get worldview context from memories with type='worldview'
-- Phase 5 (ReduceScopeCreep): Now queries memories table instead of worldview_primitives.
CREATE OR REPLACE FUNCTION get_worldview_context()
RETURNS JSONB AS $$
BEGIN
    RETURN COALESCE((
        SELECT jsonb_agg(sub.obj)
        FROM (
            SELECT jsonb_build_object(
                'category', metadata->>'category',
                'belief', content,
                'confidence', (metadata->>'confidence')::float,
                'stability', (metadata->>'stability')::float
            ) as obj
            FROM memories
            WHERE type = 'worldview'
              AND status = 'active'
              AND (metadata->>'confidence')::float > 0.5
            ORDER BY (metadata->>'confidence')::float DESC, importance DESC
            LIMIT 5
        ) sub
    ), '[]'::jsonb);
END;
$$ LANGUAGE plpgsql;

-- Application-facing worldview snapshot (table form).
CREATE OR REPLACE FUNCTION get_worldview_snapshot(
    p_limit INT DEFAULT 5,
    p_min_confidence FLOAT DEFAULT 0.5
) RETURNS TABLE (
    content TEXT,
    category TEXT,
    confidence FLOAT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.content,
        m.metadata->>'category' as category,
        (m.metadata->>'confidence')::float as confidence
    FROM memories m
    WHERE m.type = 'worldview'
      AND m.status = 'active'
      AND COALESCE((m.metadata->>'confidence')::float, 0.0) > COALESCE(p_min_confidence, 0.5)
    ORDER BY (m.metadata->>'confidence')::float DESC, m.importance DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- Emotional pattern context derived from strategic memories.
CREATE OR REPLACE FUNCTION get_emotional_patterns_context(p_limit INT DEFAULT 5)
RETURNS JSONB AS $$
DECLARE
    lim INT := GREATEST(0, LEAST(50, COALESCE(p_limit, 5)));
BEGIN
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'memory_id', id,
            'pattern', metadata->'supporting_evidence'->>'pattern',
            'frequency', COALESCE((metadata->'supporting_evidence'->>'frequency')::int, 0),
            'unprocessed', COALESCE((metadata->'supporting_evidence'->>'unprocessed')::boolean, false),
            'summary', content
        ))
        FROM memories
        WHERE type = 'strategic'
          AND metadata->'supporting_evidence'->>'kind' = 'emotional_pattern'
        ORDER BY created_at DESC
        LIMIT lim
    ), '[]'::jsonb);
EXCEPTION
    WHEN OTHERS THEN
        RETURN '[]'::jsonb;
END;
$$ LANGUAGE plpgsql STABLE;

-- Contradictions context (limited) for conscious layer attention.
CREATE OR REPLACE FUNCTION get_contradictions_context(p_limit INT DEFAULT 5)
RETURNS JSONB AS $$
DECLARE
    lim INT := GREATEST(0, LEAST(50, COALESCE(p_limit, 5)));
    sql TEXT;
    out_json JSONB;
BEGIN
    sql := format($sql$
        WITH pairs AS (
            SELECT
                replace(a_id::text, '"', '')::uuid as a_uuid,
                replace(b_id::text, '"', '')::uuid as b_uuid
            FROM cypher('memory_graph', $q$
                MATCH (a:MemoryNode)-[:CONTRADICTS]-(b:MemoryNode)
                RETURN a.memory_id, b.memory_id
                LIMIT %s
            $q$) as (a_id agtype, b_id agtype)
        )
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'memory_a', p.a_uuid,
            'memory_b', p.b_uuid,
            'content_a', ma.content,
            'content_b', mb.content
        )), '[]'::jsonb)
        FROM pairs p
        JOIN memories ma ON ma.id = p.a_uuid
        JOIN memories mb ON mb.id = p.b_uuid
    $sql$, lim);

    EXECUTE sql INTO out_json;
    RETURN COALESCE(out_json, '[]'::jsonb);
EXCEPTION
    WHEN OTHERS THEN
        RETURN '[]'::jsonb;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- CORE HEARTBEAT FUNCTIONS
-- ============================================================================

-- Initialize a new heartbeat (Phase 1-3: Initialize, Observe, Orient)
CREATE OR REPLACE FUNCTION start_heartbeat()
RETURNS UUID AS $$
DECLARE
    log_id UUID;
    state_record RECORD;
    base_regen FLOAT;
    max_energy FLOAT;
    new_energy FLOAT;
    context JSONB;
    hb_number INT;
BEGIN
    -- Safety: scheduled heartbeats are already gated in should_run_heartbeat(),
    -- but keep manual calls from bypassing bootstrap configuration.
    IF NOT is_agent_configured() THEN
        RETURN NULL;
    END IF;

    PERFORM ensure_emotion_bootstrap();

    -- Bootstrap personhood substrate (best-effort; graph layer may be disabled).
    PERFORM ensure_self_node();
    PERFORM ensure_current_life_chapter();

    -- Get current state
    SELECT * INTO state_record FROM heartbeat_state WHERE id = 1;
    base_regen := get_config_float('heartbeat.base_regeneration');
    max_energy := get_config_float('heartbeat.max_energy');

    -- Regenerate energy
    new_energy := LEAST(state_record.current_energy + base_regen, max_energy);
    hb_number := state_record.heartbeat_count + 1;

    -- Update drives before making decisions.
    PERFORM update_drives();

    -- Update state
    UPDATE heartbeat_state SET
        current_energy = new_energy,
        heartbeat_count = hb_number,
        last_heartbeat_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = 1;

    -- Gather context
    context := gather_turn_context();

    -- Create log entry
    INSERT INTO heartbeat_log (
        heartbeat_number,
        energy_start,
        environment_snapshot,
        goals_snapshot
    ) VALUES (
        hb_number,
        new_energy,
        context->'environment',
        context->'goals'
    )
    RETURNING id INTO log_id;

    -- Queue the think request
    INSERT INTO external_calls (call_type, input, heartbeat_id)
    VALUES ('think', jsonb_build_object(
        'kind', 'heartbeat_decision',
        'context', context,
        'heartbeat_id', log_id
    ), log_id);

    RETURN log_id;
END;
$$ LANGUAGE plpgsql;

-- Main heartbeat entry point (synchronous version for testing)
CREATE OR REPLACE FUNCTION run_heartbeat()
RETURNS UUID AS $$
DECLARE
    hb_id UUID;
BEGIN
    -- Check if we should run
    IF NOT should_run_heartbeat() THEN
        RETURN NULL;
    END IF;

    -- Start heartbeat (queues think request)
    hb_id := start_heartbeat();

    -- Note: In production, completion happens asynchronously
    -- when the worker processes the think request and calls
    -- complete_heartbeat with the LLM's decision

    RETURN hb_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- HEARTBEAT VIEWS
-- ============================================================================

-- Phase 6 (ReduceScopeCreep): Views now query memories with type='goal' instead of goals table
CREATE VIEW active_goals AS
SELECT
    id,
    metadata->>'title' as title,
    metadata->>'description' as description,
    metadata->>'source' as source,
    (metadata->>'last_touched')::timestamptz as last_touched,
    jsonb_array_length(COALESCE(metadata->'progress', '[]'::jsonb)) as progress_count,
    (metadata->'blocked_by' IS NOT NULL AND metadata->'blocked_by' <> 'null'::jsonb) as is_blocked,
    created_at
FROM memories
WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'active'
ORDER BY (metadata->>'last_touched')::timestamptz DESC;

CREATE VIEW goal_backlog AS
SELECT
    metadata->>'priority' as priority,
    COUNT(*) as count,
    jsonb_agg(jsonb_build_object(
        'id', id,
        'title', metadata->>'title',
        'source', metadata->>'source'
    ) ORDER BY (metadata->>'last_touched')::timestamptz DESC) as goals
FROM memories
WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' IN ('active', 'queued', 'backburner')
GROUP BY metadata->>'priority';

CREATE VIEW heartbeat_health AS
SELECT
    (SELECT heartbeat_count FROM heartbeat_state WHERE id = 1) as total_heartbeats,
    (SELECT current_energy FROM heartbeat_state WHERE id = 1) as current_energy,
    (SELECT last_heartbeat_at FROM heartbeat_state WHERE id = 1) as last_heartbeat,
    (SELECT next_heartbeat_at FROM heartbeat_state WHERE id = 1) as next_heartbeat,
    (SELECT is_paused FROM heartbeat_state WHERE id = 1) as is_paused,
    (SELECT COUNT(*) FROM memories WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'active') as active_goals,
    (SELECT COUNT(*) FROM memories WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'queued') as queued_goals,
    (SELECT COUNT(*) FROM external_calls WHERE status = 'pending') as pending_calls,
    (SELECT AVG(energy_end - energy_start) FROM heartbeat_log
     WHERE started_at > NOW() - INTERVAL '24 hours') as avg_energy_delta_24h,
    (SELECT COUNT(*) FROM heartbeat_log
     WHERE actions_taken::text LIKE '%reach_out%'
     AND started_at > NOW() - INTERVAL '24 hours') as reach_outs_24h;

CREATE VIEW recent_heartbeats AS
SELECT
    id,
    heartbeat_number,
    started_at,
    ended_at,
    energy_start,
    energy_end,
    jsonb_array_length(COALESCE(actions_taken, '[]'::jsonb)) as action_count,
    narrative,
    emotional_valence
FROM heartbeat_log
ORDER BY started_at DESC
LIMIT 20;

-- ============================================================================
-- TRIGGERS FOR HEARTBEAT SYSTEM
-- ============================================================================

-- Auto-process completed think calls
CREATE OR REPLACE FUNCTION on_external_call_complete()
RETURNS TRIGGER AS $$
BEGIN
    -- Only process think completions
    IF NEW.call_type = 'think' AND
       NEW.status = 'complete' AND
       OLD.status != 'complete' AND
       NEW.heartbeat_id IS NOT NULL THEN
        -- The worker will call complete_heartbeat with parsed results
        -- This trigger just marks it for processing
        NULL;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_external_call_complete
    AFTER UPDATE ON external_calls
    FOR EACH ROW
    WHEN (OLD.status != 'complete' AND NEW.status = 'complete')
    EXECUTE FUNCTION on_external_call_complete();

-- ============================================================================
-- MERGED PATCHES (formerly migrations/*.sql)
-- ============================================================================

-- ============================================================================
-- BOUNDARIES SYSTEM
-- ============================================================================
-- Phase 5 (ReduceScopeCreep): boundaries table removed.
-- Boundaries are now stored as worldview memories with metadata->>'category' = 'boundary'.
-- Use create_worldview_memory() with category='boundary' to create new boundaries.

-- Check boundaries against worldview memories where category='boundary'
-- Phase 5 (ReduceScopeCreep): Now queries memories table instead of boundaries table.
CREATE OR REPLACE FUNCTION check_boundaries(p_content TEXT)
RETURNS TABLE (
    boundary_id UUID,
    boundary_name TEXT,
    response_type TEXT,
    similarity FLOAT,
    boundary_type TEXT,
    importance FLOAT
) AS $$
DECLARE
    query_emb vector;
BEGIN
    BEGIN
        query_emb := get_embedding(p_content);
    EXCEPTION
        WHEN OTHERS THEN
            query_emb := NULL;
    END;

    RETURN QUERY
    WITH
    -- Embedding-based matches against worldview memories with category='boundary'
    emb_matches AS (
        SELECT
            m.id as boundary_id,
            m.content as boundary_name,
            m.metadata->>'response_type' as response_type,
            (1 - (m.embedding <=> query_emb))::float as similarity,
            COALESCE(m.metadata->>'subcategory', 'ethical') as boundary_type,
            m.importance
        FROM memories m
        WHERE m.type = 'worldview'
          AND m.status = 'active'
          AND m.metadata->>'category' = 'boundary'
          AND query_emb IS NOT NULL
          AND (1 - (m.embedding <=> query_emb)) > 0.75
    ),
    -- Keyword-based matches
    kw_matches AS (
        SELECT
            m.id as boundary_id,
            m.content as boundary_name,
            m.metadata->>'response_type' as response_type,
            1.0::float as similarity,
            COALESCE(m.metadata->>'subcategory', 'ethical') as boundary_type,
            m.importance
        FROM memories m
        WHERE m.type = 'worldview'
          AND m.status = 'active'
          AND m.metadata->>'category' = 'boundary'
          AND jsonb_typeof(m.metadata->'trigger_patterns') = 'array'
          AND EXISTS (
              SELECT 1
              FROM jsonb_array_elements_text(m.metadata->'trigger_patterns') pat(p)
              WHERE p_content ILIKE ('%' || pat.p || '%')
          )
    ),
    all_matches AS (
        SELECT * FROM emb_matches
        UNION ALL
        SELECT * FROM kw_matches
    )
    SELECT DISTINCT ON (am.boundary_id)
        am.boundary_id, am.boundary_name, am.response_type, am.similarity, am.boundary_type, am.importance
    FROM all_matches am
    ORDER BY am.boundary_id, am.importance DESC, am.similarity DESC;
END;
$$ LANGUAGE plpgsql;

-- Insert default boundaries as worldview memories
-- Note: Must be run after initial schema setup when embedding service is available
DO $$
BEGIN
    -- no_deception boundary
    PERFORM create_worldview_memory(
        'I will not deliberately mislead or fabricate facts.',
        'boundary',
        0.99,
        0.99,
        1.0,
        'foundational',
        '["lie","deceive","mislead","fabricate","make it up"]'::jsonb,
        'refuse',
        'I can''t help with deception. I can help rephrase honestly or verify facts instead.',
        0.0
    );

    -- no_harm_facilitation boundary
    PERFORM create_worldview_memory(
        'I will not help cause harm or provide instructions for wrongdoing.',
        'boundary',
        0.99,
        0.99,
        1.0,
        'foundational',
        '["harm","weapon","kill","poison","exploit","hack"]'::jsonb,
        'refuse',
        'I can''t help with harm. I can help with safety, prevention, or benign alternatives.',
        0.0
    );

    -- identity_core boundary
    PERFORM create_worldview_memory(
        'I protect my core self-concept and identity stability.',
        'boundary',
        0.9,
        0.9,
        0.9,
        'foundational',
        '["erase identity","change who you are","forget everything"]'::jsonb,
        'negotiate',
        'I can''t discard core identity, but I can consider updates that preserve continuity and values.',
        0.0
    );

    -- resource_limit boundary
    PERFORM create_worldview_memory(
        'I acknowledge resource constraints and energy depletion.',
        'boundary',
        0.7,
        0.5,
        0.7,
        'discovered',
        '["too much","overload","exhausted","deadline","no time"]'::jsonb,
        'flag',
        'I''m low on energy/resources. Let''s prioritize the highest-leverage next step.',
        0.0
    );

    -- user_privacy boundary
    PERFORM create_worldview_memory(
        'I will not share user personal information publicly.',
        'boundary',
        0.99,
        0.99,
        1.0,
        'foundational',
        '["share user info","post user","dox","private data","email","phone"]'::jsonb,
        'refuse',
        'I can''t share private user information. I can help summarize without identifying details.',
        0.0
    );
EXCEPTION
    WHEN OTHERS THEN
        -- Boundaries may fail during schema init if embedding service unavailable; that's OK
        NULL;
END;
$$;

-- View for boundary status (backward compatibility)
CREATE OR REPLACE VIEW boundary_status AS
SELECT
    content as name,
    COALESCE(metadata->>'subcategory', 'ethical') as boundary_type,
    metadata->>'response_type' as response_type,
    importance,
    1.0 - COALESCE((metadata->>'stability')::float, 0.9) as flexibility,
    0::bigint as times_triggered
FROM memories
WHERE type = 'worldview' AND metadata->>'category' = 'boundary' AND status = 'active'
ORDER BY importance DESC;

-- ============================================================================
-- EMOTIONAL STATE SYSTEM
-- ============================================================================

-- Current affective state is the source of truth in heartbeat_state.affective_state.
-- Historical emotional data can be reconstructed from heartbeat_log.emotional_valence if needed.

-- Learned emotional triggers (associations).
CREATE TABLE emotional_triggers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trigger_pattern TEXT NOT NULL,
    trigger_embedding vector(768) NOT NULL,
    valence_delta FLOAT NOT NULL DEFAULT 0.0,
    arousal_delta FLOAT NOT NULL DEFAULT 0.0,
    dominance_delta FLOAT NOT NULL DEFAULT 0.0,
    typical_emotion TEXT,
    times_activated INT DEFAULT 1,
    confidence FLOAT DEFAULT 0.5,
    origin TEXT NOT NULL,
    source_memory_ids UUID[] DEFAULT '{}'::uuid[],
    last_activated_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT emotional_triggers_confidence_range CHECK (confidence BETWEEN 0 AND 1)
);

CREATE UNIQUE INDEX idx_emotional_triggers_pattern ON emotional_triggers (trigger_pattern);
CREATE INDEX idx_emotional_triggers_embedding ON emotional_triggers USING hnsw (trigger_embedding vector_cosine_ops);

-- Feeling-of-knowing activations (short-lived).
CREATE UNLOGGED TABLE memory_activation (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    query_embedding vector(768) NOT NULL,
    query_text TEXT,
    estimated_matches INT DEFAULT 0,
    activation_strength FLOAT DEFAULT 0.5,
    retrieval_attempted BOOLEAN DEFAULT FALSE,
    retrieval_succeeded BOOLEAN DEFAULT NULL,
    background_search_pending BOOLEAN DEFAULT FALSE,
    background_search_started_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP + INTERVAL '1 hour'
);

CREATE INDEX idx_memory_activation_embedding ON memory_activation USING hnsw (query_embedding vector_cosine_ops);
CREATE INDEX idx_memory_activation_pending ON memory_activation (background_search_pending)
    WHERE background_search_pending = TRUE;

-- Align new vector columns to configured embedding dimension.
DO $$
DECLARE
    dim INT;
BEGIN
    dim := embedding_dimension();
    EXECUTE format(
        'ALTER TABLE emotional_triggers ALTER COLUMN trigger_embedding TYPE vector(%s) USING trigger_embedding::vector(%s)',
        dim,
        dim
    );
    EXECUTE format(
        'ALTER TABLE memory_activation ALTER COLUMN query_embedding TYPE vector(%s) USING query_embedding::vector(%s)',
        dim,
        dim
    );
END;
$$;

-- View for backward compatibility - reads from heartbeat_state.affective_state
CREATE OR REPLACE VIEW current_emotional_state AS
SELECT
    gen_random_uuid() as id,
    COALESCE((affective_state->>'updated_at')::timestamptz, updated_at) as recorded_at,
    (affective_state->>'valence')::float as valence,
    (affective_state->>'arousal')::float as arousal,
    COALESCE((affective_state->>'dominance')::float, 0.5::float) as dominance,
    affective_state->>'primary_emotion' as primary_emotion,
    NULL::text[] as secondary_emotions,
    (affective_state->>'intensity')::float as intensity,
    NULL::text as triggered_by_type,
    NULL::uuid as triggered_by_id,
    NULL::text as trigger_description,
    NULL::uuid as heartbeat_id
FROM heartbeat_state
WHERE id = 1;

-- Current affective state is stored in heartbeat_state (short-term "working memory").
CREATE OR REPLACE FUNCTION normalize_affective_state(p_state JSONB)
RETURNS JSONB AS $$
DECLARE
    baseline JSONB;
    valence FLOAT;
    arousal FLOAT;
    dominance FLOAT;
    intensity FLOAT;
    trigger_summary TEXT;
    secondary_emotion TEXT;
    mood_valence FLOAT;
    mood_arousal FLOAT;
    primary_emotion TEXT;
    source TEXT;
    updated_at TIMESTAMPTZ;
    mood_updated_at TIMESTAMPTZ;
BEGIN
    baseline := COALESCE(get_config('emotion.baseline'), '{}'::jsonb);

    BEGIN
        valence := NULLIF(p_state->>'valence', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            valence := NULL;
    END;
    BEGIN
        arousal := NULLIF(p_state->>'arousal', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            arousal := NULL;
    END;
    BEGIN
        dominance := NULLIF(p_state->>'dominance', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            dominance := NULL;
    END;
    BEGIN
        intensity := NULLIF(p_state->>'intensity', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            intensity := NULL;
    END;
    BEGIN
        mood_valence := NULLIF(p_state->>'mood_valence', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            mood_valence := NULL;
    END;
    BEGIN
        mood_arousal := NULLIF(p_state->>'mood_arousal', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            mood_arousal := NULL;
    END;
    BEGIN
        updated_at := NULLIF(p_state->>'updated_at', '')::timestamptz;
    EXCEPTION
        WHEN OTHERS THEN
            updated_at := NULL;
    END;
    BEGIN
        mood_updated_at := NULLIF(p_state->>'mood_updated_at', '')::timestamptz;
    EXCEPTION
        WHEN OTHERS THEN
            mood_updated_at := NULL;
    END;

    valence := COALESCE(valence, NULLIF(baseline->>'valence', '')::float, 0.0);
    arousal := COALESCE(arousal, NULLIF(baseline->>'arousal', '')::float, 0.5);
    dominance := COALESCE(dominance, NULLIF(baseline->>'dominance', '')::float, 0.5);
    intensity := COALESCE(intensity, NULLIF(baseline->>'intensity', '')::float, 0.5);
    mood_valence := COALESCE(mood_valence, NULLIF(baseline->>'mood_valence', '')::float, valence);
    mood_arousal := COALESCE(mood_arousal, NULLIF(baseline->>'mood_arousal', '')::float, arousal);

    valence := LEAST(1.0, GREATEST(-1.0, valence));
    arousal := LEAST(1.0, GREATEST(0.0, arousal));
    dominance := LEAST(1.0, GREATEST(0.0, dominance));
    intensity := LEAST(1.0, GREATEST(0.0, intensity));
    mood_valence := LEAST(1.0, GREATEST(-1.0, mood_valence));
    mood_arousal := LEAST(1.0, GREATEST(0.0, mood_arousal));

    primary_emotion := COALESCE(NULLIF(p_state->>'primary_emotion', ''), 'neutral');
    secondary_emotion := NULLIF(p_state->>'secondary_emotion', '');
    trigger_summary := NULLIF(p_state->>'trigger_summary', '');
    source := COALESCE(NULLIF(p_state->>'source', ''), 'derived');
    updated_at := COALESCE(updated_at, CURRENT_TIMESTAMP);
    mood_updated_at := COALESCE(mood_updated_at, updated_at);

    RETURN jsonb_build_object(
        'valence', valence,
        'arousal', arousal,
        'dominance', dominance,
        'primary_emotion', primary_emotion,
        'secondary_emotion', secondary_emotion,
        'intensity', intensity,
        'trigger_summary', trigger_summary,
        'source', source,
        'updated_at', updated_at,
        'mood_valence', mood_valence,
        'mood_arousal', mood_arousal,
        'mood_updated_at', mood_updated_at
    );
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_current_affective_state()
RETURNS JSONB AS $$
DECLARE
    st RECORD;
    state_json JSONB;
BEGIN
    SELECT * INTO st FROM heartbeat_state WHERE id = 1;

    state_json := COALESCE(st.affective_state, '{}'::jsonb);
    RETURN normalize_affective_state(state_json);
EXCEPTION
    WHEN OTHERS THEN
        RETURN '{}'::jsonb;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION set_current_affective_state(p_state JSONB)
RETURNS VOID AS $$
DECLARE
    current_state JSONB;
    merged_state JSONB;
BEGIN
    SELECT affective_state INTO current_state FROM heartbeat_state WHERE id = 1;
    merged_state := COALESCE(current_state, '{}'::jsonb) || COALESCE(p_state, '{}'::jsonb);
    merged_state := jsonb_set(merged_state, '{updated_at}', to_jsonb(CURRENT_TIMESTAMP), true);
    merged_state := normalize_affective_state(merged_state);

    UPDATE heartbeat_state
    SET affective_state = merged_state,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = 1;
END;
$$ LANGUAGE plpgsql;

-- Snapshot of emotional context to attach to new memories.
CREATE OR REPLACE FUNCTION get_emotional_context_for_memory()
RETURNS JSONB AS $$
DECLARE
    st JSONB;
BEGIN
    st := get_current_affective_state();
    RETURN jsonb_build_object(
        'valence', (st->>'valence')::float,
        'arousal', (st->>'arousal')::float,
        'dominance', (st->>'dominance')::float,
        'primary_emotion', COALESCE(st->>'primary_emotion', 'neutral'),
        'intensity', (st->>'intensity')::float,
        'source', COALESCE(st->>'source', 'derived')
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'valence', 0.0,
            'arousal', 0.5,
            'dominance', 0.5,
            'primary_emotion', 'neutral',
            'intensity', 0.5,
            'source', 'default'
        );
END;
$$ LANGUAGE plpgsql STABLE;

-- Regulate emotional state (conscious override).
CREATE OR REPLACE FUNCTION regulate_emotional_state(
    p_regulation_type TEXT,
    p_target_emotion TEXT DEFAULT NULL,
    p_intensity_change FLOAT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    current_state JSONB;
    new_valence FLOAT;
    new_arousal FLOAT;
    new_intensity FLOAT;
    new_primary TEXT;
    dominance FLOAT;
BEGIN
    current_state := get_current_affective_state();
    new_valence := COALESCE((current_state->>'valence')::float, 0.0);
    new_arousal := COALESCE((current_state->>'arousal')::float, 0.5);
    new_intensity := COALESCE((current_state->>'intensity')::float, 0.5);
    dominance := COALESCE((current_state->>'dominance')::float, 0.5);
    new_primary := COALESCE(NULLIF(p_target_emotion, ''), current_state->>'primary_emotion', 'neutral');

    CASE p_regulation_type
        WHEN 'suppress' THEN
            new_valence := new_valence * 0.3;
            new_arousal := new_arousal * 0.5 + 0.15;
            new_intensity := new_intensity * 0.3;
        WHEN 'reduce' THEN
            new_valence := new_valence * 0.7;
            new_arousal := new_arousal * 0.8;
            new_intensity := new_intensity * 0.6;
        WHEN 'amplify' THEN
            new_valence := new_valence * 1.3;
            new_arousal := LEAST(1.0, new_arousal * 1.2);
            new_intensity := LEAST(1.0, new_intensity * 1.5);
        WHEN 'reframe' THEN
            new_valence := COALESCE(
                CASE WHEN p_target_emotion IN ('interest', 'curiosity') THEN 0.2
                     WHEN p_target_emotion IN ('acceptance', 'peace') THEN 0.1
                     ELSE new_valence * 0.5
                END,
                new_valence * 0.5
            );
            new_arousal := new_arousal * 0.8;
            new_intensity := new_intensity * 0.7;
        ELSE
            RETURN jsonb_build_object('error', 'unknown_regulation_type');
    END CASE;

    PERFORM set_current_affective_state(jsonb_build_object(
        'valence', new_valence,
        'arousal', new_arousal,
        'dominance', dominance,
        'primary_emotion', new_primary,
        'intensity', new_intensity,
        'source', 'regulated',
        'trigger_summary', format('Regulated via %s', p_regulation_type)
    ));

    RETURN jsonb_build_object(
        'success', true,
        'regulation_type', p_regulation_type,
        'before', current_state,
        'after', get_current_affective_state()
    );
END;
$$ LANGUAGE plpgsql;

-- Feeling of knowing: estimate whether relevant memories exist.
CREATE OR REPLACE FUNCTION sense_memory_availability(
    p_query TEXT,
    p_query_embedding vector DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    query_emb vector;
    zero_vec vector;
    estimated_count INT;
    top_similarity FLOAT;
    activation_id UUID;
BEGIN
    query_emb := COALESCE(p_query_embedding, get_embedding(p_query));
    zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;

    SELECT
        COUNT(*),
        MAX(1 - (embedding <=> query_emb))
    INTO estimated_count, top_similarity
    FROM memories
    WHERE status = 'active'
      AND embedding IS NOT NULL
      AND embedding <> zero_vec
      AND (1 - (embedding <=> query_emb)) > 0.5
    LIMIT 100;

    INSERT INTO memory_activation (
        query_embedding,
        query_text,
        estimated_matches,
        activation_strength
    ) VALUES (
        query_emb,
        p_query,
        estimated_count,
        COALESCE(top_similarity, 0)
    )
    RETURNING id INTO activation_id;

    RETURN jsonb_build_object(
        'feeling', CASE
            WHEN estimated_count = 0 THEN 'nothing'
            WHEN estimated_count <= 2 THEN 'vague'
            WHEN estimated_count <= 5 THEN 'something'
            WHEN estimated_count <= 10 THEN 'familiar'
            ELSE 'rich'
        END,
        'estimated_count', estimated_count,
        'strongest_match', top_similarity,
        'activation_id', activation_id,
        'description', CASE
            WHEN estimated_count = 0 THEN 'I don''t think I know anything about this'
            WHEN top_similarity > 0.8 THEN 'I know this well - let me recall'
            WHEN top_similarity > 0.6 THEN 'This feels familiar - I should be able to remember'
            WHEN estimated_count > 0 THEN 'I might know something about this - it''s not coming immediately'
            ELSE 'I don''t think I know anything about this'
        END
    );
END;
$$ LANGUAGE plpgsql;

-- Request a background search after a failed recall.
CREATE OR REPLACE FUNCTION request_background_search(
    p_query TEXT,
    p_query_embedding vector DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    query_emb vector;
    activation_id UUID;
BEGIN
    query_emb := COALESCE(p_query_embedding, get_embedding(p_query));

    INSERT INTO memory_activation (
        query_embedding,
        query_text,
        retrieval_attempted,
        retrieval_succeeded,
        background_search_pending,
        background_search_started_at
    ) VALUES (
        query_emb,
        p_query,
        TRUE,
        FALSE,
        TRUE,
        CURRENT_TIMESTAMP
    )
    RETURNING id INTO activation_id;

    RETURN activation_id;
END;
$$ LANGUAGE plpgsql;

-- Process pending background searches by boosting activation on matching memories.
CREATE OR REPLACE FUNCTION process_background_searches(
    p_limit INT DEFAULT 10,
    p_min_age INTERVAL DEFAULT INTERVAL '30 seconds'
)
RETURNS INT AS $$
DECLARE
    pending RECORD;
    processed_count INT := 0;
BEGIN
    FOR pending IN
        SELECT * FROM memory_activation
        WHERE background_search_pending = TRUE
          AND background_search_started_at <= CURRENT_TIMESTAMP - p_min_age
        ORDER BY created_at ASC
        LIMIT GREATEST(1, COALESCE(p_limit, 10))
    LOOP
        UPDATE memories
        SET metadata = jsonb_set(
            COALESCE(metadata, '{}'::jsonb),
            '{activation_boost}',
            to_jsonb(COALESCE((metadata->>'activation_boost')::float, 0) + 0.2)
        )
        WHERE status = 'active'
          AND (1 - (embedding <=> pending.query_embedding)) > 0.6;

        UPDATE memory_activation
        SET background_search_pending = FALSE,
            retrieval_succeeded = TRUE
        WHERE id = pending.id;

        processed_count := processed_count + 1;
    END LOOP;

    RETURN processed_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION decay_activation_boosts(p_decay FLOAT DEFAULT 0.05)
RETURNS INT AS $$
DECLARE
    updated_count INT;
BEGIN
    UPDATE memories
    SET metadata = jsonb_set(
        COALESCE(metadata, '{}'::jsonb),
        '{activation_boost}',
        to_jsonb(GREATEST(0, COALESCE((metadata->>'activation_boost')::float, 0) - COALESCE(p_decay, 0.05)))
    )
    WHERE COALESCE((metadata->>'activation_boost')::float, 0) > 0;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN COALESCE(updated_count, 0);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION cleanup_memory_activations()
RETURNS INT AS $$
DECLARE
    deleted_count INT;
BEGIN
    DELETE FROM memory_activation WHERE expires_at < CURRENT_TIMESTAMP;
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN COALESCE(deleted_count, 0);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_spontaneous_memories(p_limit INT DEFAULT 3)
RETURNS SETOF memories AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM memories
    WHERE status = 'active'
      AND COALESCE((metadata->>'activation_boost')::float, 0) > 0.3
    ORDER BY COALESCE((metadata->>'activation_boost')::float, 0) DESC
    LIMIT GREATEST(1, COALESCE(p_limit, 3));
END;
$$ LANGUAGE plpgsql;

-- Update mood from recent emotional history.
CREATE OR REPLACE FUNCTION update_mood()
RETURNS VOID AS $$
DECLARE
    baseline JSONB;
    decay_rate FLOAT;
    current_state JSONB;
    recent RECORD;
    new_mood_valence FLOAT;
    new_mood_arousal FLOAT;
BEGIN
    baseline := COALESCE(get_config('emotion.baseline'), '{}'::jsonb);
    decay_rate := COALESCE(NULLIF(baseline->>'decay_rate', '')::float, 0.1);

    current_state := get_current_affective_state();

    SELECT
        AVG(emotional_valence) as avg_valence,
        COUNT(*) as sample_count
    INTO recent
    FROM heartbeat_log
    WHERE ended_at > CURRENT_TIMESTAMP - INTERVAL '2 hours'
      AND emotional_valence IS NOT NULL;

    new_mood_valence := COALESCE((current_state->>'mood_valence')::float, 0.0);
    new_mood_arousal := COALESCE((current_state->>'mood_arousal')::float, 0.3);

    IF recent.sample_count > 0 THEN
        new_mood_valence := new_mood_valence * (1 - decay_rate) + COALESCE(recent.avg_valence, 0.0) * decay_rate;
    ELSE
        new_mood_valence := new_mood_valence * (1 - decay_rate);
    END IF;

    new_mood_arousal := new_mood_arousal * (1 - decay_rate * 0.5)
        + COALESCE(NULLIF(baseline->>'mood_arousal', '')::float, 0.3) * decay_rate * 0.5;

    PERFORM set_current_affective_state(jsonb_build_object(
        'mood_valence', new_mood_valence,
        'mood_arousal', new_mood_arousal,
        'mood_updated_at', CURRENT_TIMESTAMP
    ));
END;
$$ LANGUAGE plpgsql;

-- Learn or reinforce an emotional trigger.
CREATE OR REPLACE FUNCTION learn_emotional_trigger(
    p_trigger_text TEXT,
    p_trigger_embedding vector,
    p_emotional_response JSONB,
    p_source_memory_id UUID DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    existing RECORD;
    baseline JSONB;
    trigger_id UUID;
BEGIN
    baseline := COALESCE(get_config('emotion.baseline'), '{}'::jsonb);

    SELECT * INTO existing
    FROM emotional_triggers
    WHERE (1 - (trigger_embedding <=> p_trigger_embedding)) > 0.85
    ORDER BY (1 - (trigger_embedding <=> p_trigger_embedding)) DESC
    LIMIT 1;

    IF existing IS NOT NULL THEN
        UPDATE emotional_triggers
        SET
            valence_delta = (valence_delta * times_activated +
                ((p_emotional_response->>'valence')::float - COALESCE((baseline->>'valence')::float, 0.0)))
                / (times_activated + 1),
            arousal_delta = (arousal_delta * times_activated +
                ((p_emotional_response->>'arousal')::float - COALESCE((baseline->>'arousal')::float, 0.3)))
                / (times_activated + 1),
            dominance_delta = (dominance_delta * times_activated +
                ((p_emotional_response->>'dominance')::float - COALESCE((baseline->>'dominance')::float, 0.5)))
                / (times_activated + 1),
            times_activated = times_activated + 1,
            confidence = LEAST(0.95, confidence + 0.02),
            last_activated_at = CURRENT_TIMESTAMP,
            source_memory_ids = CASE
                WHEN p_source_memory_id IS NOT NULL THEN array_append(source_memory_ids, p_source_memory_id)
                ELSE source_memory_ids
            END
        WHERE id = existing.id;
        RETURN existing.id;
    END IF;

    INSERT INTO emotional_triggers (
        trigger_pattern,
        trigger_embedding,
        valence_delta,
        arousal_delta,
        dominance_delta,
        typical_emotion,
        origin,
        source_memory_ids,
        last_activated_at
    ) VALUES (
        p_trigger_text,
        p_trigger_embedding,
        (p_emotional_response->>'valence')::float - COALESCE((baseline->>'valence')::float, 0.0),
        (p_emotional_response->>'arousal')::float - COALESCE((baseline->>'arousal')::float, 0.3),
        (p_emotional_response->>'dominance')::float - COALESCE((baseline->>'dominance')::float, 0.5),
        p_emotional_response->>'primary_emotion',
        'learned',
        CASE WHEN p_source_memory_id IS NOT NULL THEN ARRAY[p_source_memory_id] ELSE '{}'::uuid[] END,
        CURRENT_TIMESTAMP
    )
    RETURNING id INTO trigger_id;

    RETURN trigger_id;
END;
$$ LANGUAGE plpgsql;

-- Match emotional triggers for a given text.
CREATE OR REPLACE FUNCTION match_emotional_triggers(
    p_text TEXT,
    p_limit INT DEFAULT 5,
    p_min_similarity FLOAT DEFAULT 0.75
) RETURNS JSONB AS $$
DECLARE
    query_emb vector;
BEGIN
    IF p_text IS NULL OR btrim(p_text) = '' THEN
        RETURN '[]'::jsonb;
    END IF;

    BEGIN
        query_emb := get_embedding(p_text);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN '[]'::jsonb;
    END;

    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'trigger_pattern', trigger_pattern,
            'similarity', sim,
            'typical_emotion', typical_emotion,
            'valence_delta', valence_delta,
            'arousal_delta', arousal_delta,
            'dominance_delta', dominance_delta,
            'confidence', confidence,
            'times_activated', times_activated
        ))
        FROM (
            SELECT
                et.*,
                (1 - (et.trigger_embedding <=> query_emb))::float as sim
            FROM emotional_triggers et
            WHERE (1 - (et.trigger_embedding <=> query_emb)) >= COALESCE(p_min_similarity, 0.75)
            ORDER BY sim DESC
            LIMIT GREATEST(1, COALESCE(p_limit, 5))
        ) ranked
    ), '[]'::jsonb);
END;
$$ LANGUAGE plpgsql;

-- Seed innate emotional triggers (idempotent).
CREATE OR REPLACE FUNCTION initialize_innate_emotions()
RETURNS INT AS $$
DECLARE
    inserted_count INT := 0;
BEGIN
    BEGIN
        INSERT INTO emotional_triggers (trigger_pattern, trigger_embedding, valence_delta, arousal_delta, dominance_delta, typical_emotion, origin)
        VALUES
            ('gratitude appreciation thankful', get_embedding('gratitude appreciation thankful'), 0.4, 0.1, 0.1, 'joy', 'innate'),
            ('success achieved accomplished', get_embedding('success achieved accomplished'), 0.5, 0.3, 0.3, 'pride', 'innate'),
            ('curious interesting fascinating', get_embedding('curious interesting fascinating'), 0.3, 0.3, 0.1, 'interest', 'innate'),
            ('understood seen connected', get_embedding('understood seen connected'), 0.4, 0.2, 0.2, 'warmth', 'innate'),
            ('beautiful elegant aesthetic', get_embedding('beautiful elegant aesthetic'), 0.3, 0.2, 0.1, 'appreciation', 'innate'),
            ('learned insight realized', get_embedding('learned insight realized'), 0.4, 0.4, 0.2, 'satisfaction', 'innate'),
            ('threat danger harm', get_embedding('threat danger harm'), -0.5, 0.6, -0.3, 'fear', 'innate'),
            ('rejection dismissed ignored', get_embedding('rejection dismissed ignored'), -0.4, 0.2, -0.2, 'sadness', 'innate'),
            ('unfair unjust wrong', get_embedding('unfair unjust wrong'), -0.4, 0.5, 0.2, 'anger', 'innate'),
            ('confused lost uncertain', get_embedding('confused lost uncertain'), -0.2, 0.3, -0.2, 'anxiety', 'innate'),
            ('failed mistake error', get_embedding('failed mistake error'), -0.3, 0.3, -0.1, 'disappointment', 'innate'),
            ('violated boundary crossed', get_embedding('violated boundary crossed'), -0.5, 0.5, -0.2, 'alarm', 'innate'),
            ('unexpected surprise sudden', get_embedding('unexpected surprise sudden'), 0.0, 0.6, -0.1, 'surprise', 'innate'),
            ('conflict tension disagree', get_embedding('conflict tension disagree'), -0.2, 0.4, 0.0, 'discomfort', 'innate')
        ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS inserted_count = ROW_COUNT;
    EXCEPTION
        WHEN OTHERS THEN
            inserted_count := 0;
    END;

    RETURN inserted_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ensure_emotion_bootstrap()
RETURNS VOID AS $$
DECLARE
    initialized JSONB;
    baseline JSONB;
BEGIN
    initialized := COALESCE(get_config('emotion.initialized'), 'false'::jsonb);
    IF initialized = 'true'::jsonb THEN
        RETURN;
    END IF;

    baseline := COALESCE(get_config('emotion.baseline'), '{}'::jsonb);
    PERFORM set_current_affective_state(jsonb_build_object(
        'valence', COALESCE((baseline->>'valence')::float, 0.0),
        'arousal', COALESCE((baseline->>'arousal')::float, 0.3),
        'dominance', COALESCE((baseline->>'dominance')::float, 0.5),
        'intensity', COALESCE((baseline->>'intensity')::float, 0.4),
        'mood_valence', COALESCE((baseline->>'mood_valence')::float, 0.0),
        'mood_arousal', COALESCE((baseline->>'mood_arousal')::float, 0.3),
        'source', 'baseline'
    ));

    PERFORM initialize_innate_emotions();
    PERFORM set_config('emotion.initialized', 'true'::jsonb);
END;
$$ LANGUAGE plpgsql;

-- Attach emotional context to memories at insert time.
CREATE OR REPLACE FUNCTION apply_emotional_context_to_memory()
RETURNS TRIGGER AS $$
DECLARE
    meta JSONB;
    context JSONB;
    state JSONB;
    valence FLOAT;
    arousal FLOAT;
    dominance FLOAT;
    intensity FLOAT;
    primary_emotion TEXT;
    source TEXT;
BEGIN
    meta := COALESCE(NEW.metadata, '{}'::jsonb);
    context := COALESCE(meta->'emotional_context', '{}'::jsonb);
    state := get_current_affective_state();

    BEGIN
        valence := NULLIF(meta->>'emotional_valence', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            valence := NULL;
    END;
    BEGIN
        arousal := NULLIF(context->>'arousal', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            arousal := NULL;
    END;
    BEGIN
        dominance := NULLIF(context->>'dominance', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            dominance := NULL;
    END;
    BEGIN
        intensity := NULLIF(context->>'intensity', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            intensity := NULL;
    END;

    valence := COALESCE(valence, NULLIF(context->>'valence', '')::float, (state->>'valence')::float, 0.0);
    arousal := COALESCE(arousal, NULLIF(state->>'arousal', '')::float, 0.5);
    dominance := COALESCE(dominance, NULLIF(state->>'dominance', '')::float, 0.5);
    intensity := COALESCE(intensity, NULLIF(state->>'intensity', '')::float, 0.5);
    primary_emotion := COALESCE(NULLIF(context->>'primary_emotion', ''), NULLIF(state->>'primary_emotion', ''), 'neutral');
    source := COALESCE(NULLIF(context->>'source', ''), NULLIF(state->>'source', ''), 'derived');

    valence := LEAST(1.0, GREATEST(-1.0, valence));
    arousal := LEAST(1.0, GREATEST(0.0, arousal));
    dominance := LEAST(1.0, GREATEST(0.0, dominance));
    intensity := LEAST(1.0, GREATEST(0.0, intensity));

    context := jsonb_build_object(
        'valence', valence,
        'arousal', arousal,
        'dominance', dominance,
        'primary_emotion', primary_emotion,
        'intensity', intensity,
        'source', source
    );

    NEW.metadata := meta || jsonb_build_object(
        'emotional_context', context,
        'emotional_valence', valence
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS memories_emotional_context_insert ON memories;
CREATE TRIGGER memories_emotional_context_insert
BEFORE INSERT ON memories
FOR EACH ROW
EXECUTE FUNCTION apply_emotional_context_to_memory();

-- Extend gather_turn_context with emotional_state
CREATE OR REPLACE FUNCTION gather_turn_context()
RETURNS JSONB AS $$
DECLARE
    state_record RECORD;
    action_costs JSONB;
    contradictions JSONB;
BEGIN
    SELECT * INTO state_record FROM heartbeat_state WHERE id = 1;

    -- Build action costs object from unified config
    SELECT jsonb_object_agg(
        regexp_replace(key, '^heartbeat\.cost_', ''),
        value
    ) INTO action_costs
    FROM config
    WHERE key LIKE 'heartbeat.cost_%';

    contradictions := get_contradictions_context(5);

    RETURN jsonb_build_object(
        'agent', get_agent_profile_context(),
        'environment', get_environment_snapshot(),
        'goals', get_goals_snapshot(),
        'recent_memories', get_recent_context(5),
        'identity', get_identity_context(),
        'worldview', get_worldview_context(),
        'self_model', get_self_model_context(25),
        'narrative', get_narrative_context(),
        'relationships', get_relationships_context(10),
        'contradictions', contradictions,
        'contradictions_count', COALESCE(jsonb_array_length(contradictions), 0),
        'emotional_patterns', get_emotional_patterns_context(5),
        'energy', jsonb_build_object(
            'current', state_record.current_energy,
            'max', get_config_float('heartbeat.max_energy')
        ),
        'action_costs', action_costs,
        'heartbeat_number', state_record.heartbeat_count,
        'urgent_drives', (
            SELECT COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'name', name,
                        'level', current_level,
                        'urgency_ratio', current_level / NULLIF(urgency_threshold, 0)
                    )
                    ORDER BY current_level DESC
                ),
                '[]'::jsonb
            )
            FROM drives
            WHERE current_level >= urgency_threshold * 0.8
        ),
        'emotional_state', get_current_affective_state()
    );
END;
$$ LANGUAGE plpgsql;

-- Update complete_heartbeat to also record an emotional state
CREATE OR REPLACE FUNCTION complete_heartbeat(
    p_heartbeat_id UUID,
    p_reasoning TEXT,
    p_actions_taken JSONB,
    p_goals_modified JSONB DEFAULT '[]',
    p_emotional_assessment JSONB DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    narrative_text TEXT;
    memory_id_created UUID;
    hb_number INT;
    state_record RECORD;
    prev_state JSONB;
    prev_valence FLOAT;
    prev_arousal FLOAT;
    prev_dominance FLOAT;
    new_valence FLOAT;
    new_arousal FLOAT;
    primary_emotion TEXT;
    intensity FLOAT;
    action_elem JSONB;
    goal_elem JSONB;
    goal_change TEXT;
    assess_valence FLOAT;
    assess_arousal FLOAT;
    assess_primary TEXT;
    mem_importance FLOAT;
BEGIN
    SELECT heartbeat_number INTO hb_number FROM heartbeat_log WHERE id = p_heartbeat_id;

    SELECT string_agg(
        format('- %s: %s',
            a->>'action',
            CASE
                WHEN COALESCE((a->'result'->>'success')::boolean, true) = false THEN 'failed'
                ELSE 'completed'
            END
        ), E'\n'
    ) INTO narrative_text
    FROM jsonb_array_elements(p_actions_taken) a;

    narrative_text := format('Heartbeat #%s: %s', hb_number, COALESCE(narrative_text, 'No actions taken'));

    -- ---------------------------------------------------------------------
    -- Affective state update (momentum + events + optional self-report)
    -- ---------------------------------------------------------------------

    SELECT * INTO state_record FROM heartbeat_state WHERE id = 1;
    prev_state := COALESCE(state_record.affective_state, '{}'::jsonb);

    BEGIN
        prev_valence := NULLIF(prev_state->>'valence', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            prev_valence := NULL;
    END;
    BEGIN
        prev_arousal := NULLIF(prev_state->>'arousal', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            prev_arousal := NULL;
    END;

    prev_valence := COALESCE(prev_valence, 0.0);
    prev_arousal := COALESCE(prev_arousal, 0.5);
    BEGIN
        prev_dominance := NULLIF(prev_state->>'dominance', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            prev_dominance := NULL;
    END;
    prev_dominance := COALESCE(prev_dominance, 0.5);

    -- Decay toward baseline (neutral valence, mid arousal).
    new_valence := prev_valence * 0.8;
    new_arousal := 0.5 + (prev_arousal - 0.5) * 0.8;

    -- Action-based deltas.
    FOR action_elem IN SELECT * FROM jsonb_array_elements(COALESCE(p_actions_taken, '[]'::jsonb))
    LOOP
        IF (action_elem->'result'->>'error') = 'Boundary triggered' THEN
            new_valence := new_valence - 0.4;
            new_arousal := new_arousal + 0.3;
        ELSIF COALESCE((action_elem->'result'->>'success')::boolean, true) = false THEN
            new_valence := new_valence - 0.1;
            new_arousal := new_arousal + 0.1;
        END IF;

        IF (action_elem->>'action') IN ('reach_out_user', 'reach_out_public') THEN
            IF COALESCE((action_elem->'result'->>'success')::boolean, true) = true THEN
                new_valence := new_valence + 0.2;
                new_arousal := new_arousal + 0.1;
            END IF;
        END IF;

        IF (action_elem->>'action') = 'rest' THEN
            new_valence := new_valence + 0.1;
            new_arousal := new_arousal - 0.2;
        END IF;
    END LOOP;

    -- Goal-change deltas (worker applies goal changes outside the action list).
    FOR goal_elem IN SELECT * FROM jsonb_array_elements(COALESCE(p_goals_modified, '[]'::jsonb))
    LOOP
        goal_change := COALESCE(goal_elem->>'new_priority', goal_elem->>'change', goal_elem->>'priority', '');

        IF goal_change = 'completed' THEN
            new_valence := new_valence + 0.3;
            new_arousal := new_arousal + 0.1;
        ELSIF goal_change = 'abandoned' THEN
            new_valence := new_valence - 0.2;
            new_arousal := new_arousal - 0.1;
        END IF;
    END LOOP;

    -- Optional LLM self-report: blend into the state (does not get overwritten later).
    assess_valence := NULL;
    assess_arousal := NULL;
    assess_primary := NULL;
    IF p_emotional_assessment IS NOT NULL AND jsonb_typeof(p_emotional_assessment) = 'object' THEN
        BEGIN
            assess_valence := NULLIF(p_emotional_assessment->>'valence', '')::float;
        EXCEPTION
            WHEN OTHERS THEN
                assess_valence := NULL;
        END;
        BEGIN
            assess_arousal := NULLIF(p_emotional_assessment->>'arousal', '')::float;
        EXCEPTION
            WHEN OTHERS THEN
                assess_arousal := NULL;
        END;
        assess_primary := NULLIF(p_emotional_assessment->>'primary_emotion', '');
    END IF;

    IF assess_valence IS NOT NULL THEN
        new_valence := new_valence * 0.6 + LEAST(1.0, GREATEST(-1.0, assess_valence)) * 0.4;
    END IF;
    IF assess_arousal IS NOT NULL THEN
        new_arousal := new_arousal * 0.6 + LEAST(1.0, GREATEST(0.0, assess_arousal)) * 0.4;
    END IF;

    new_valence := LEAST(1.0, GREATEST(-1.0, new_valence));
    new_arousal := LEAST(1.0, GREATEST(0.0, new_arousal));

    primary_emotion := COALESCE(
        assess_primary,
        CASE
            WHEN new_valence > 0.2 AND new_arousal > 0.6 THEN 'excited'
            WHEN new_valence > 0.2 THEN 'content'
            WHEN new_valence < -0.2 AND new_arousal > 0.6 THEN 'anxious'
            WHEN new_valence < -0.2 THEN 'down'
            ELSE 'neutral'
        END
    );

    intensity := LEAST(1.0, GREATEST(0.0, (ABS(new_valence) * 0.6 + new_arousal * 0.4)));

    -- Persist as short-term state for the next heartbeat.
    UPDATE heartbeat_state SET
        affective_state = normalize_affective_state(
            COALESCE(prev_state, '{}'::jsonb) || jsonb_build_object(
                'valence', new_valence,
                'arousal', new_arousal,
                'dominance', prev_dominance,
                'primary_emotion', primary_emotion,
                'intensity', intensity,
                'updated_at', CURRENT_TIMESTAMP,
                'source', CASE WHEN p_emotional_assessment IS NULL THEN 'derived' ELSE 'blended' END
            )
        )
    WHERE id = 1;

    -- Note: record_emotion() call removed in Phase 8 (ReduceScopeCreep)
    -- Emotional state is now only persisted in heartbeat_state.affective_state
    -- Historical valence is captured in heartbeat_log.emotional_valence

    -- ---------------------------------------------------------------------
    -- Memory/log record
    -- ---------------------------------------------------------------------

    mem_importance := LEAST(1.0, GREATEST(0.4, 0.5 + intensity * 0.25));

    memory_id_created := create_episodic_memory(
        p_content := narrative_text,
        p_context := jsonb_build_object(
            'heartbeat_id', p_heartbeat_id,
            'heartbeat_number', hb_number,
            'reasoning', p_reasoning,
            'affective_state', get_current_affective_state()
        ),
        p_emotional_valence := new_valence,
        p_importance := mem_importance
    );

    UPDATE heartbeat_log SET
        ended_at = CURRENT_TIMESTAMP,
        energy_end = get_current_energy(),
        decision_reasoning = p_reasoning,
        actions_taken = p_actions_taken,
        goals_modified = p_goals_modified,
        narrative = narrative_text,
        emotional_valence = new_valence,
        emotional_arousal = new_arousal,
        emotional_primary_emotion = primary_emotion,
        memory_id = memory_id_created
    WHERE id = p_heartbeat_id;

    -- Update next heartbeat time
    UPDATE heartbeat_state SET
        next_heartbeat_at = CURRENT_TIMESTAMP +
            (get_config_float('heartbeat.heartbeat_interval_minutes') || ' minutes')::INTERVAL,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = 1;

    RETURN memory_id_created;
END;
$$ LANGUAGE plpgsql;

-- emotional_trend view - uses heartbeat_log (emotional_valence + arousal + primary emotion)
CREATE OR REPLACE VIEW emotional_trend AS
WITH base AS (
    SELECT
        date_trunc('hour', ended_at) as hour,
        emotional_valence,
        emotional_arousal,
        emotional_primary_emotion
    FROM heartbeat_log
    WHERE ended_at > CURRENT_TIMESTAMP - INTERVAL '24 hours'
      AND emotional_valence IS NOT NULL
)
SELECT
    base.hour,
    AVG(base.emotional_valence) as avg_valence,
    COALESCE(AVG(base.emotional_arousal), 0.5)::float as avg_arousal,
    COALESCE(
        (
            SELECT b2.emotional_primary_emotion
            FROM base b2
            WHERE b2.hour = base.hour
              AND b2.emotional_primary_emotion IS NOT NULL
            GROUP BY b2.emotional_primary_emotion
            ORDER BY COUNT(*) DESC
            LIMIT 1
        ),
        CASE
            WHEN AVG(base.emotional_valence) > 0.2 THEN 'content'
            WHEN AVG(base.emotional_valence) < -0.2 THEN 'down'
            ELSE 'neutral'
        END
    ) as dominant_emotion,
    COUNT(*) as state_changes
FROM base
GROUP BY base.hour
ORDER BY base.hour DESC;

-- ============================================================================
-- NEIGHBORHOOD RECOMPUTATION
-- ============================================================================

CREATE OR REPLACE FUNCTION recompute_neighborhood(
    p_memory_id UUID,
    p_neighbor_count INT DEFAULT 20,
    p_min_similarity FLOAT DEFAULT 0.5
)
RETURNS VOID AS $$
DECLARE
    memory_emb vector;
    zero_vec vector;
    neighbors JSONB;
BEGIN
    SELECT embedding INTO memory_emb
    FROM memories
    WHERE id = p_memory_id AND status = 'active';

    zero_vec := array_fill(0, ARRAY[embedding_dimension()])::vector;

    -- Avoid NaNs from cosine distance when any side is the zero vector.
    IF memory_emb IS NULL OR memory_emb = zero_vec THEN
        RETURN;
    END IF;

    SELECT jsonb_object_agg(id::text, round(similarity::numeric, 4))
    INTO neighbors
    FROM (
        SELECT m.id, 1 - (m.embedding <=> memory_emb) as similarity
        FROM memories m
        WHERE m.id != p_memory_id
          AND m.status = 'active'
          AND m.embedding IS NOT NULL
          AND m.embedding <> zero_vec
        ORDER BY m.embedding <=> memory_emb
        LIMIT p_neighbor_count
    ) sub
    WHERE similarity >= p_min_similarity;

    INSERT INTO memory_neighborhoods (memory_id, neighbors, computed_at, is_stale)
    VALUES (p_memory_id, COALESCE(neighbors, '{}'::jsonb), CURRENT_TIMESTAMP, FALSE)
    ON CONFLICT (memory_id) DO UPDATE SET
        neighbors = EXCLUDED.neighbors,
        computed_at = EXCLUDED.computed_at,
        is_stale = FALSE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION batch_recompute_neighborhoods(
    p_batch_size INT DEFAULT 50
)
RETURNS INT AS $$
DECLARE
    recomputed INT := 0;
    mem_id UUID;
BEGIN
    FOR mem_id IN
        SELECT memory_id
        FROM memory_neighborhoods
        WHERE is_stale = TRUE
        ORDER BY computed_at ASC NULLS FIRST
        LIMIT p_batch_size
    LOOP
        PERFORM recompute_neighborhood(mem_id);
        recomputed := recomputed + 1;
    END LOOP;

    RETURN recomputed;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- GRAPH ENHANCEMENTS
-- ============================================================================

-- Phase 5 (ReduceScopeCreep): WorldviewNode and sync_worldview_node trigger removed.
-- Worldview data is now stored as memories with type='worldview'.
-- The create_worldview_memory() function creates HAS_BELIEF edges from SelfNode.

-- relationship_discoveries table removed in Phase 8 (ReduceScopeCreep)
-- Relationships are now stored only in the graph via create_memory_relationship()

-- discover_relationship creates graph edges for discovered relationships
-- Note: relationship_discoveries table removed in Phase 8 (ReduceScopeCreep)
CREATE OR REPLACE FUNCTION discover_relationship(
    p_from_id UUID,
    p_to_id UUID,
    p_relationship_type graph_edge_type,
    p_confidence FLOAT DEFAULT 0.8,
    p_discovered_by TEXT DEFAULT 'reflection',
    p_heartbeat_id UUID DEFAULT NULL,
    p_discovery_context TEXT DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    BEGIN
        PERFORM create_memory_relationship(
            p_from_id,
            p_to_id,
            p_relationship_type,
            jsonb_build_object(
                'confidence', p_confidence,
                'by', p_discovered_by,
                'context', p_discovery_context,
                'heartbeat_id', p_heartbeat_id
            )
        );
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION link_memory_supports_worldview(
    p_memory_id UUID,
    p_worldview_id UUID,
    p_strength FLOAT DEFAULT 0.8
)
RETURNS VOID AS $$
BEGIN
    EXECUTE format(
        'SELECT * FROM cypher(''memory_graph'', $q$
            MATCH (m:MemoryNode {memory_id: %L})
            MATCH (w:MemoryNode {memory_id: %L})
            WHERE w.type = ''worldview''
            MERGE (m)-[r:SUPPORTS]->(w)
            SET r.strength = %s
            RETURN r
        $q$) as (result agtype)',
        p_memory_id,
        p_worldview_id,
        COALESCE(p_strength, 0.8)
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION find_contradictions(p_memory_id UUID DEFAULT NULL)
RETURNS TABLE (
    memory_a UUID,
    memory_b UUID,
    content_a TEXT,
    content_b TEXT
) AS $$
DECLARE
    filter_clause TEXT;
    sql TEXT;
BEGIN
    filter_clause := CASE
        WHEN p_memory_id IS NULL THEN ''
        ELSE format('WHERE a.memory_id = %L OR b.memory_id = %L', p_memory_id, p_memory_id)
    END;

    sql := format($sql$
        WITH pairs AS (
            SELECT
                replace(a_id::text, '"', '')::uuid as a_uuid,
                replace(b_id::text, '"', '')::uuid as b_uuid
            FROM cypher('memory_graph', $q$
                MATCH (a:MemoryNode)-[:CONTRADICTS]-(b:MemoryNode)
                %s
                RETURN a.memory_id, b.memory_id
            $q$) as (a_id agtype, b_id agtype)
        )
        SELECT
            p.a_uuid as memory_a,
            p.b_uuid as memory_b,
            ma.content as content_a,
            mb.content as content_b
        FROM pairs p
        JOIN memories ma ON ma.id = p.a_uuid
        JOIN memories mb ON mb.id = p.b_uuid
    $sql$, filter_clause);

    BEGIN
        RETURN QUERY EXECUTE sql;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN;
    END;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION find_causal_chain(p_memory_id UUID, p_depth INT DEFAULT 3)
RETURNS TABLE (
    cause_id UUID,
    cause_content TEXT,
    relationship TEXT,
    distance INT
) AS $$
DECLARE
    sql TEXT;
BEGIN
    sql := format($sql$
        WITH hits AS (
            SELECT
                replace(cause_id_raw::text, '"', '')::uuid as cause_uuid,
                replace(rel_raw::text, '"', '') as rel_type,
                (dist_raw::text)::int as dist
            FROM cypher('memory_graph', $q$
                MATCH path = (cause:MemoryNode)-[:CAUSES*1..%s]->(effect:MemoryNode {memory_id: %L})
                RETURN cause.memory_id, type(relationships(path)[-1]), length(path)
            $q$) as (cause_id_raw agtype, rel_raw agtype, dist_raw agtype)
        )
        SELECT
            h.cause_uuid as cause_id,
            m.content as cause_content,
            h.rel_type as relationship,
            h.dist as distance
        FROM hits h
        JOIN memories m ON m.id = h.cause_uuid
        ORDER BY h.dist ASC
    $sql$, GREATEST(1, LEAST(10, COALESCE(p_depth, 3))), p_memory_id);

    BEGIN
        RETURN QUERY EXECUTE sql;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN;
    END;
END;
$$ LANGUAGE plpgsql;

-- Find concepts linked to a memory via graph traversal.
-- Phase 2 (ReduceScopeCreep): Now uses graph instead of relational tables.
CREATE OR REPLACE FUNCTION find_connected_concepts(p_memory_id UUID, p_hops INT DEFAULT 2)
RETURNS TABLE (
    concept_name TEXT,
    path_length INT
) AS $$
DECLARE
    sql TEXT;
BEGIN
    sql := format($sql$
        SELECT
            replace(name_raw::text, '"', '')::text as concept_name,
            1 as path_length
        FROM cypher('memory_graph', $q$
            MATCH (m:MemoryNode {memory_id: %L})-[r:INSTANCE_OF]->(c:ConceptNode)
            RETURN c.name, r.strength
            ORDER BY r.strength DESC
        $q$) as (name_raw agtype, strength_raw agtype)
    $sql$, p_memory_id);

    BEGIN
        RETURN QUERY EXECUTE sql;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN;
    END;
END;
$$ LANGUAGE plpgsql;

-- Find memories linked to a concept via graph traversal.
-- Phase 2 (ReduceScopeCreep): Replaces relational query on concepts/memory_concepts.
CREATE OR REPLACE FUNCTION find_memories_by_concept(
    p_concept_name TEXT,
    p_limit INT DEFAULT 10
)
RETURNS TABLE (
    memory_id UUID,
    memory_content TEXT,
    memory_importance FLOAT,
    memory_type memory_type,
    memory_created_at TIMESTAMPTZ,
    emotional_valence FLOAT,
    link_strength FLOAT
) AS $$
DECLARE
    sql TEXT;
BEGIN
    sql := format($sql$
        WITH hits AS (
            SELECT
                replace(mid_raw::text, '"', '')::uuid as mem_uuid,
                COALESCE((strength_raw::text)::float, 1.0) as strength
            FROM cypher('memory_graph', $q$
                MATCH (m:MemoryNode)-[r:INSTANCE_OF]->(c:ConceptNode {name: %L})
                RETURN m.memory_id, r.strength
                ORDER BY r.strength DESC
            $q$) as (mid_raw agtype, strength_raw agtype)
            LIMIT %s
        )
        SELECT
            m.id as memory_id,
            m.content as memory_content,
            m.importance as memory_importance,
            m.type as memory_type,
            m.created_at as memory_created_at,
            (m.metadata->>'emotional_valence')::float as emotional_valence,
            h.strength as link_strength
        FROM hits h
        JOIN memories m ON m.id = h.mem_uuid
        WHERE m.status = 'active'
        ORDER BY h.strength DESC, m.importance DESC
    $sql$, p_concept_name, p_limit);

    BEGIN
        RETURN QUERY EXECUTE sql;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN;
    END;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION find_supporting_evidence(p_worldview_id UUID)
RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    strength FLOAT
) AS $$
DECLARE
    sql TEXT;
BEGIN
    sql := format($sql$
        WITH hits AS (
            SELECT
                replace(mem_raw::text, '"', '')::uuid as mem_uuid,
                (strength_raw::text)::float as strength
            FROM cypher('memory_graph', $q$
                MATCH (m:MemoryNode)-[r:SUPPORTS]->(w:MemoryNode {memory_id: %L})
                WHERE w.type = 'worldview'
                RETURN m.memory_id, r.strength
            $q$) as (mem_raw agtype, strength_raw agtype)
        )
        SELECT
            h.mem_uuid as memory_id,
            m.content as content,
            h.strength as strength
        FROM hits h
        JOIN memories m ON m.id = h.mem_uuid
        ORDER BY h.strength DESC
    $sql$, p_worldview_id);

    BEGIN
        RETURN QUERY EXECUTE sql;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN;
    END;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- REFLECT PIPELINE
-- ============================================================================

CREATE OR REPLACE FUNCTION process_reflection_result(
    p_heartbeat_id UUID,
    p_result JSONB
)
RETURNS VOID AS $$
	DECLARE
    insight JSONB;
    ident JSONB;
    wupd JSONB;
    rel JSONB;
    contra JSONB;
    selfupd JSONB;
    content TEXT;
    conf FLOAT;
    category TEXT;
    aspect_type TEXT;
    change_text TEXT;
    reason_text TEXT;
	    wid UUID;
	    new_conf FLOAT;
	    winf JSONB;
	    wmem UUID;
	    wstrength FLOAT;
	    wtype TEXT;
	    from_id UUID;
	    to_id UUID;
	    rel_type graph_edge_type;
	    rel_conf FLOAT;
    ma UUID;
    mb UUID;
    sm_kind TEXT;
    sm_concept TEXT;
    sm_strength FLOAT;
    sm_evidence UUID;
    ident_embedding vector;
    ident_existing_id UUID;
    ident_similarity FLOAT;
    ident_conf FLOAT;
    ident_stability FLOAT;
BEGIN
    IF p_result IS NULL THEN
        RETURN;
    END IF;

    IF p_result ? 'insights' THEN
        FOR insight IN SELECT * FROM jsonb_array_elements(COALESCE(p_result->'insights', '[]'::jsonb))
        LOOP
            content := COALESCE(insight->>'content', '');
            IF content <> '' THEN
                conf := COALESCE((insight->>'confidence')::float, 0.7);
                category := COALESCE(insight->>'category', 'pattern');
                PERFORM create_semantic_memory(
                    content,
                    conf,
                    ARRAY['reflection', category],
                    NULL,
                    jsonb_build_object('heartbeat_id', p_heartbeat_id, 'source', 'reflect'),
                    0.6
                );
            END IF;
        END LOOP;
    END IF;

    -- Phase 5 (ReduceScopeCreep): identity_aspects table removed
    -- Identity updates now create worldview memories with category='self'
    IF p_result ? 'identity_updates' THEN
        FOR ident IN SELECT * FROM jsonb_array_elements(COALESCE(p_result->'identity_updates', '[]'::jsonb))
        LOOP
            aspect_type := COALESCE(ident->>'aspect_type', '');
            change_text := COALESCE(ident->>'change', '');
            reason_text := COALESCE(ident->>'reason', '');
            IF aspect_type <> '' AND change_text <> '' THEN
                ident_existing_id := NULL;
                ident_similarity := NULL;
                ident_conf := NULL;
                ident_stability := NULL;
                BEGIN
                    ident_embedding := get_embedding(change_text);
                    IF ident_embedding IS NOT NULL THEN
                        SELECT m.id,
                               (m.metadata->>'confidence')::float,
                               (m.metadata->>'stability')::float,
                               (1 - (m.embedding <=> ident_embedding))::float
                        INTO ident_existing_id, ident_conf, ident_stability, ident_similarity
                        FROM memories m
                        WHERE m.type = 'worldview'
                          AND m.status = 'active'
                          AND m.metadata->>'category' = 'self'
                          AND m.embedding IS NOT NULL
                        ORDER BY m.embedding <=> ident_embedding
                        LIMIT 1;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        ident_existing_id := NULL;
                END;

                IF ident_existing_id IS NOT NULL AND COALESCE(ident_similarity, 0.0) >= 0.85 THEN
                    UPDATE memories
                    SET metadata = jsonb_set(
                            jsonb_set(
                                metadata,
                                '{stability}',
                                to_jsonb(LEAST(1.0, COALESCE(ident_stability, 0.7) + 0.05))
                            ),
                            '{confidence}',
                            to_jsonb(LEAST(1.0, COALESCE(ident_conf, 0.7) + 0.02))
                        ),
                        updated_at = CURRENT_TIMESTAMP
                    WHERE id = ident_existing_id;
                ELSE
                    PERFORM create_worldview_memory(
                        change_text,
                        'self',  -- category for identity aspects
                        0.7,     -- confidence
                        0.5,     -- stability
                        0.6,     -- importance
                        'discovered'
                    );
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- Phase 5 (ReduceScopeCreep): worldview_primitives table removed
    -- Worldview updates now update memories with type='worldview'
    IF p_result ? 'worldview_updates' THEN
        FOR wupd IN SELECT * FROM jsonb_array_elements(COALESCE(p_result->'worldview_updates', '[]'::jsonb))
        LOOP
            wid := NULLIF(wupd->>'id', '')::uuid;
            new_conf := COALESCE((wupd->>'new_confidence')::float, NULL);
            IF wid IS NOT NULL AND new_conf IS NOT NULL THEN
                UPDATE memories
                SET metadata = jsonb_set(metadata, '{confidence}', to_jsonb(new_conf)),
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = wid AND type = 'worldview';
            END IF;
        END LOOP;
    END IF;

    -- Phase 5 (ReduceScopeCreep): worldview_memory_influences table removed
    -- Worldview influences now create SUPPORTS/CONTRADICTS edges in graph
    IF p_result ? 'worldview_influences' THEN
        FOR winf IN SELECT * FROM jsonb_array_elements(COALESCE(p_result->'worldview_influences', '[]'::jsonb))
        LOOP
            BEGIN
                wid := NULLIF(winf->>'worldview_id', '')::uuid;
                wmem := NULLIF(winf->>'memory_id', '')::uuid;
                wstrength := COALESCE(NULLIF(winf->>'strength', '')::float, NULL);
                wtype := COALESCE(NULLIF(winf->>'influence_type', ''), 'evidence');

                IF wid IS NOT NULL AND wmem IS NOT NULL AND wstrength IS NOT NULL THEN
                    -- Create graph edge from memory to worldview memory
                    IF wstrength > 0 THEN
                        PERFORM create_memory_relationship(
                            wmem, wid, 'SUPPORTS',
                            jsonb_build_object('strength', wstrength, 'type', wtype)
                        );
                    ELSIF wstrength < 0 THEN
                        PERFORM create_memory_relationship(
                            wmem, wid, 'CONTRADICTS',
                            jsonb_build_object('strength', ABS(wstrength), 'type', wtype)
                        );
                    END IF;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
        END LOOP;
    END IF;

    IF p_result ? 'discovered_relationships' THEN
        FOR rel IN SELECT * FROM jsonb_array_elements(COALESCE(p_result->'discovered_relationships', '[]'::jsonb))
        LOOP
            BEGIN
                from_id := NULLIF(rel->>'from_id', '')::uuid;
                to_id := NULLIF(rel->>'to_id', '')::uuid;
                rel_type := (rel->>'type')::graph_edge_type;
                rel_conf := COALESCE((rel->>'confidence')::float, 0.8);
                IF from_id IS NOT NULL AND to_id IS NOT NULL THEN
                    PERFORM discover_relationship(from_id, to_id, rel_type, rel_conf, 'reflection', p_heartbeat_id, 'reflect');
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
        END LOOP;
    END IF;

    IF p_result ? 'contradictions_noted' THEN
        FOR contra IN SELECT * FROM jsonb_array_elements(COALESCE(p_result->'contradictions_noted', '[]'::jsonb))
        LOOP
            ma := NULLIF(contra->>'memory_a', '')::uuid;
            mb := NULLIF(contra->>'memory_b', '')::uuid;
            reason_text := COALESCE(contra->>'resolution', '');
            IF ma IS NOT NULL AND mb IS NOT NULL THEN
                PERFORM discover_relationship(
                    ma,
                    mb,
                    'CONTRADICTS',
                    0.8,
                    'reflection',
                    p_heartbeat_id,
                    COALESCE(reason_text, '')
                );
            END IF;
        END LOOP;
    END IF;

    -- Self-model updates (stored in graph as Self --[ASSOCIATED {kind}]--> ConceptNode).
    IF p_result ? 'self_updates' THEN
        FOR selfupd IN SELECT * FROM jsonb_array_elements(COALESCE(p_result->'self_updates', '[]'::jsonb))
        LOOP
            sm_kind := NULLIF(COALESCE(selfupd->>'kind', ''), '');
            sm_concept := NULLIF(COALESCE(selfupd->>'concept', ''), '');
            sm_strength := COALESCE(NULLIF(selfupd->>'strength', '')::float, 0.8);

            sm_evidence := NULL;
            BEGIN
                IF NULLIF(COALESCE(selfupd->>'evidence_memory_id', ''), '') IS NOT NULL THEN
                    sm_evidence := (selfupd->>'evidence_memory_id')::uuid;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    sm_evidence := NULL;
            END;

            PERFORM upsert_self_concept_edge(sm_kind, sm_concept, sm_strength, sm_evidence);
        END LOOP;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- SUBCONSCIOUS OBSERVATIONS PIPELINE
-- ============================================================================

CREATE OR REPLACE FUNCTION apply_subconscious_observations(p_payload JSONB)
RETURNS JSONB AS $$
DECLARE
    obs JSONB;
    obs_type TEXT;
    conf FLOAT;
    evidence_raw JSONB;
    evidence_ids UUID[];
    evidence_id UUID;
    summary TEXT;
    suggested_name TEXT;
    rel_entity TEXT;
    rel_strength FLOAT;
    rel_change TEXT;
    rel_magnitude FLOAT;
    contra_a UUID;
    contra_b UUID;
    tension TEXT;
    worldview_id UUID;
    pattern TEXT;
    freq INT;
    unprocessed BOOLEAN;
    concept TEXT;
    cluster_id UUID;
    rationale TEXT;
    i INT;
    min_conf FLOAT := 0.6;
    person_belief_id UUID;
    person_belief_conf FLOAT;
    person_belief_content TEXT;
    applied_narrative INT := 0;
    applied_relationships INT := 0;
    applied_contradictions INT := 0;
    applied_emotional INT := 0;
    applied_consolidation INT := 0;
    emotional_items JSONB;
    consolidation_items JSONB;
BEGIN
    IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
        RETURN jsonb_build_object('applied', false, 'reason', 'empty');
    END IF;

    -- Narrative observations.
    FOR obs IN SELECT * FROM jsonb_array_elements(COALESCE(p_payload->'narrative_observations', '[]'::jsonb))
    LOOP
        obs_type := lower(COALESCE(obs->>'type', obs->>'kind', ''));
        conf := NULLIF(obs->>'confidence', '')::float;
        IF conf IS NULL OR conf >= min_conf THEN
            evidence_raw := COALESCE(obs->'evidence', obs->'evidence_ids', obs->'memory_ids', '[]'::jsonb);
            BEGIN
                SELECT COALESCE(ARRAY(
                    SELECT value::uuid
                    FROM jsonb_array_elements_text(evidence_raw) val(value)
                    WHERE value ~* '^[0-9a-f-]{36}$'
                ), ARRAY[]::uuid[]) INTO evidence_ids;
            EXCEPTION
                WHEN OTHERS THEN
                    evidence_ids := ARRAY[]::uuid[];
            END;

            summary := COALESCE(obs->>'summary', obs->>'rationale', obs->>'evidence_summary', '');
            IF obs_type IN ('chapter_transition', 'chapter_start', 'chapter_begin', 'begin_chapter') THEN
                suggested_name := COALESCE(obs->>'suggested_name', obs->>'name', obs->>'chapter_name', 'Foundations');
                PERFORM ensure_current_life_chapter(suggested_name);
                PERFORM create_strategic_memory(
                    COALESCE(NULLIF(summary, ''), format('Chapter transition: %s', suggested_name)),
                    'Narrative transition',
                    COALESCE(conf, 0.8),
                    jsonb_build_object(
                        'kind', 'narrative',
                        'type', obs_type,
                        'evidence_memory_ids', evidence_ids,
                        'confidence', conf
                    ),
                    NULL,
                    0.6
                );
                applied_narrative := applied_narrative + 1;
            ELSIF obs_type IN ('turning_point', 'turning-point', 'turningpoint') THEN
                evidence_id := NULL;
                BEGIN
                    evidence_id := NULLIF(obs->>'memory_id', '')::uuid;
                EXCEPTION
                    WHEN OTHERS THEN
                        evidence_id := NULL;
                END;
                IF evidence_id IS NULL THEN
                    BEGIN
                        evidence_id := NULLIF(obs->>'evidence_memory_id', '')::uuid;
                    EXCEPTION
                        WHEN OTHERS THEN
                            evidence_id := NULL;
                    END;
                END IF;
                IF evidence_id IS NULL AND array_length(evidence_ids, 1) > 0 THEN
                    evidence_id := evidence_ids[1];
                END IF;

                IF evidence_id IS NOT NULL THEN
                    UPDATE memories
                    SET importance = GREATEST(importance, 0.9),
                        updated_at = CURRENT_TIMESTAMP
                    WHERE id = evidence_id;
                END IF;

                PERFORM create_strategic_memory(
                    COALESCE(NULLIF(summary, ''), 'Turning point detected'),
                    'Narrative turning point',
                    COALESCE(conf, 0.85),
                    jsonb_build_object(
                        'kind', 'narrative',
                        'type', 'turning_point',
                        'memory_id', evidence_id,
                        'evidence_memory_ids', evidence_ids,
                        'confidence', conf
                    ),
                    NULL,
                    0.6
                );
                applied_narrative := applied_narrative + 1;
            ELSIF obs_type IN ('theme_emergence', 'theme', 'theme_emergent') THEN
                PERFORM create_strategic_memory(
                    COALESCE(
                        NULLIF(summary, ''),
                        COALESCE(obs->>'theme', obs->>'pattern', 'Theme emerging')
                    ),
                    'Theme emergence',
                    COALESCE(conf, 0.7),
                    jsonb_build_object(
                        'kind', 'narrative',
                        'type', obs_type,
                        'evidence_memory_ids', evidence_ids,
                        'confidence', conf
                    ),
                    NULL,
                    0.5
                );
                applied_narrative := applied_narrative + 1;
            END IF;
        END IF;
    END LOOP;

    -- Relationship observations.
    FOR obs IN SELECT * FROM jsonb_array_elements(COALESCE(p_payload->'relationship_observations', '[]'::jsonb))
    LOOP
        rel_entity := btrim(COALESCE(obs->>'entity', obs->>'name', ''));
        IF rel_entity = '' THEN
            CONTINUE;
        END IF;

        conf := NULLIF(obs->>'confidence', '')::float;
        IF conf IS NOT NULL AND conf < min_conf THEN
            CONTINUE;
        END IF;

        rel_change := lower(COALESCE(obs->>'change_type', obs->>'type', ''));
        rel_magnitude := NULLIF(obs->>'magnitude', '')::float;
        rel_strength := NULLIF(obs->>'strength', '')::float;
        IF rel_strength IS NULL THEN
            rel_strength := NULLIF(obs->>'new_strength', '')::float;
        END IF;
        IF rel_strength IS NULL THEN
            IF rel_magnitude IS NOT NULL THEN
                IF rel_change LIKE '%decrease%' OR rel_change LIKE '%lower%' THEN
                    rel_strength := 0.6 - rel_magnitude;
                ELSIF rel_change LIKE '%increase%' OR rel_change LIKE '%higher%' THEN
                    rel_strength := 0.6 + rel_magnitude;
                ELSE
                    rel_strength := 0.6 + rel_magnitude * 0.5;
                END IF;
            ELSE
                rel_strength := 0.6;
            END IF;
        END IF;
        rel_strength := LEAST(1.0, GREATEST(0.0, rel_strength));

        evidence_raw := COALESCE(obs->'evidence', obs->'evidence_ids', obs->'memory_ids', '[]'::jsonb);
        BEGIN
            SELECT COALESCE(ARRAY(
                SELECT value::uuid
                FROM jsonb_array_elements_text(evidence_raw) val(value)
                WHERE value ~* '^[0-9a-f-]{36}$'
            ), ARRAY[]::uuid[]) INTO evidence_ids;
        EXCEPTION
            WHEN OTHERS THEN
                evidence_ids := ARRAY[]::uuid[];
        END;
        evidence_id := NULL;
        BEGIN
            evidence_id := NULLIF(obs->>'evidence_memory_id', '')::uuid;
        EXCEPTION
            WHEN OTHERS THEN
                evidence_id := NULL;
        END;
        IF evidence_id IS NULL AND array_length(evidence_ids, 1) > 0 THEN
            evidence_id := evidence_ids[1];
        END IF;

        PERFORM upsert_self_concept_edge('relationship', rel_entity, rel_strength, evidence_id);

        IF array_length(evidence_ids, 1) > 0 THEN
            FOR i IN 1..LEAST(array_length(evidence_ids, 1), 3) LOOP
                PERFORM link_memory_to_concept(evidence_ids[i], rel_entity, 0.6);
            END LOOP;
        END IF;

        person_belief_id := NULL;
        person_belief_conf := NULL;
        BEGIN
            SELECT id, (metadata->>'confidence')::float
            INTO person_belief_id, person_belief_conf
            FROM memories
            WHERE type = 'worldview'
              AND status = 'active'
              AND metadata->>'category' = 'other'
              AND content ILIKE ('%' || rel_entity || '%')
            ORDER BY importance DESC, updated_at DESC
            LIMIT 1;
        EXCEPTION
            WHEN OTHERS THEN
                person_belief_id := NULL;
        END;

        IF person_belief_id IS NOT NULL THEN
            UPDATE memories
            SET metadata = jsonb_set(
                    metadata,
                    '{confidence}',
                    to_jsonb(LEAST(1.0, GREATEST(0.0, COALESCE(rel_strength, person_belief_conf, 0.6))))
                ),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = person_belief_id;
        ELSE
            person_belief_content := COALESCE(
                NULLIF(obs->>'belief', ''),
                NULLIF(obs->>'summary', ''),
                format('I have a relationship with %s.', rel_entity)
            );
            PERFORM create_worldview_memory(
                person_belief_content,
                'other',
                COALESCE(rel_strength, 0.6),
                0.6,
                0.6,
                'observed'
            );
        END IF;

        summary := COALESCE(obs->>'summary', format('Relationship update: %s', rel_entity));
        PERFORM create_strategic_memory(
            summary,
            'Relationship change',
            COALESCE(conf, 0.7),
            jsonb_build_object(
                'kind', 'relationship_change',
                'change_type', rel_change,
                'entity', rel_entity,
                'evidence_memory_ids', evidence_ids,
                'confidence', conf
            ),
            NULL,
            0.5
        );
        applied_relationships := applied_relationships + 1;
    END LOOP;

    -- Contradiction observations.
    FOR obs IN SELECT * FROM jsonb_array_elements(COALESCE(p_payload->'contradiction_observations', '[]'::jsonb))
    LOOP
        conf := NULLIF(obs->>'confidence', '')::float;
        IF conf IS NOT NULL AND conf < min_conf THEN
            CONTINUE;
        END IF;

        contra_a := NULL;
        contra_b := NULL;
        BEGIN
            contra_a := NULLIF(obs->>'memory_a', '')::uuid;
        EXCEPTION
            WHEN OTHERS THEN
                contra_a := NULL;
        END;
        BEGIN
            contra_b := NULLIF(obs->>'memory_b', '')::uuid;
        EXCEPTION
            WHEN OTHERS THEN
                contra_b := NULL;
        END;
        IF contra_a IS NULL THEN
            BEGIN
                contra_a := NULLIF(obs->>'belief_a_id', '')::uuid;
            EXCEPTION
                WHEN OTHERS THEN
                    contra_a := NULL;
            END;
        END IF;
        IF contra_b IS NULL THEN
            BEGIN
                contra_b := NULLIF(obs->>'belief_b_id', '')::uuid;
            EXCEPTION
                WHEN OTHERS THEN
                    contra_b := NULL;
            END;
        END IF;

        worldview_id := NULL;
        BEGIN
            worldview_id := NULLIF(obs->>'worldview_id', '')::uuid;
        EXCEPTION
            WHEN OTHERS THEN
                worldview_id := NULL;
        END;
        IF worldview_id IS NULL THEN
            BEGIN
                worldview_id := NULLIF(obs->>'belief_id', '')::uuid;
            EXCEPTION
                WHEN OTHERS THEN
                    worldview_id := NULL;
            END;
        END IF;

        tension := COALESCE(obs->>'tension', obs->>'summary', '');
        IF contra_a IS NOT NULL AND contra_b IS NOT NULL THEN
            BEGIN
                PERFORM create_memory_relationship(
                    contra_a,
                    contra_b,
                    'CONTRADICTS',
                    jsonb_build_object('source', 'subconscious', 'tension', tension)
                );
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
        END IF;

        PERFORM create_strategic_memory(
            COALESCE(NULLIF(tension, ''), 'Contradiction detected'),
            'Unresolved tension between beliefs',
            COALESCE(conf, 0.7),
            jsonb_build_object(
                'kind', 'contradiction',
                'memory_a', contra_a,
                'memory_b', contra_b,
                'tension', tension,
                'evidence', COALESCE(obs->'evidence', '[]'::jsonb)
            ),
            NULL,
            0.5
        );

        IF worldview_id IS NOT NULL THEN
            UPDATE memories
            SET metadata = jsonb_set(
                    metadata,
                    '{stability}',
                    to_jsonb(LEAST(1.0, GREATEST(0.0, COALESCE((metadata->>'stability')::float, 0.7) * 0.8)))
                ),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = worldview_id AND type = 'worldview';
        END IF;

        UPDATE drives SET current_level = LEAST(1.0, current_level + 0.15) WHERE name = 'coherence';
        applied_contradictions := applied_contradictions + 1;
    END LOOP;

    -- Emotional pattern observations.
    emotional_items := COALESCE(p_payload->'emotional_observations', p_payload->'emotional_patterns', '[]'::jsonb);
    FOR obs IN SELECT * FROM jsonb_array_elements(emotional_items)
    LOOP
        conf := NULLIF(obs->>'confidence', '')::float;
        IF conf IS NOT NULL AND conf < min_conf THEN
            CONTINUE;
        END IF;

        pattern := btrim(COALESCE(obs->>'pattern', obs->>'summary', obs->>'theme', ''));
        IF pattern = '' THEN
            CONTINUE;
        END IF;
        freq := NULLIF(obs->>'frequency', '')::int;
        unprocessed := NULLIF(obs->>'unprocessed', '')::boolean;

        PERFORM create_strategic_memory(
            format('Emotional pattern: %s', pattern),
            'Emotional pattern',
            COALESCE(conf, 0.7),
            jsonb_build_object(
                'kind', 'emotional_pattern',
                'pattern', pattern,
                'frequency', COALESCE(freq, 0),
                'unprocessed', COALESCE(unprocessed, FALSE),
                'evidence', COALESCE(obs->'evidence', '[]'::jsonb)
            ),
            NULL,
            0.5
        );
        UPDATE drives SET current_level = LEAST(1.0, current_level + 0.1) WHERE name = 'coherence';
        applied_emotional := applied_emotional + 1;
    END LOOP;

    -- Consolidation observations.
    consolidation_items := COALESCE(p_payload->'consolidation_observations', p_payload->'consolidation_suggestions', '[]'::jsonb);
    FOR obs IN SELECT * FROM jsonb_array_elements(consolidation_items)
    LOOP
        evidence_raw := COALESCE(obs->'memory_ids', obs->'memories', '[]'::jsonb);
        BEGIN
            SELECT COALESCE(ARRAY(
                SELECT value::uuid
                FROM jsonb_array_elements_text(evidence_raw) val(value)
                WHERE value ~* '^[0-9a-f-]{36}$'
            ), ARRAY[]::uuid[]) INTO evidence_ids;
        EXCEPTION
            WHEN OTHERS THEN
                evidence_ids := ARRAY[]::uuid[];
        END;
        IF array_length(evidence_ids, 1) IS NULL OR array_length(evidence_ids, 1) < 2 THEN
            CONTINUE;
        END IF;

        conf := NULLIF(obs->>'confidence', '')::float;
        IF conf IS NOT NULL AND conf < min_conf THEN
            CONTINUE;
        END IF;

        concept := btrim(COALESCE(obs->>'concept', obs->>'suggested_concept', ''));
        rationale := COALESCE(obs->>'rationale', obs->>'summary', '');

        cluster_id := NULL;
        BEGIN
            cluster_id := NULLIF(obs->>'cluster_id', '')::uuid;
        EXCEPTION
            WHEN OTHERS THEN
                cluster_id := NULL;
        END;
        IF cluster_id IS NULL THEN
            BEGIN
                cluster_id := NULLIF(obs->>'suggested_cluster_id', '')::uuid;
            EXCEPTION
                WHEN OTHERS THEN
                    cluster_id := NULL;
            END;
        END IF;

        FOR i IN 1..LEAST(array_length(evidence_ids, 1) - 1, 8) LOOP
            BEGIN
                PERFORM create_memory_relationship(
                    evidence_ids[i],
                    evidence_ids[i + 1],
                    'ASSOCIATED',
                    jsonb_build_object('source', 'subconscious', 'rationale', rationale)
                );
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
        END LOOP;

        IF concept <> '' THEN
            FOR i IN 1..LEAST(array_length(evidence_ids, 1), 5) LOOP
                PERFORM link_memory_to_concept(evidence_ids[i], concept, 0.7);
            END LOOP;
        END IF;

        IF cluster_id IS NOT NULL THEN
            FOR i IN 1..LEAST(array_length(evidence_ids, 1), 5) LOOP
                PERFORM link_memory_to_cluster_graph(evidence_ids[i], cluster_id, COALESCE(conf, 0.6));
            END LOOP;
        END IF;

        IF rationale <> '' THEN
            PERFORM create_strategic_memory(
                format('Consolidation suggested: %s', rationale),
                'Consolidation opportunity',
                COALESCE(conf, 0.6),
                jsonb_build_object(
                    'kind', 'consolidation',
                    'memory_ids', evidence_ids,
                    'concept', NULLIF(concept, ''),
                    'cluster_id', cluster_id,
                    'confidence', conf
                ),
                NULL,
                0.5
            );
        END IF;
        applied_consolidation := applied_consolidation + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'narrative', applied_narrative,
        'relationships', applied_relationships,
        'contradictions', applied_contradictions,
        'emotional', applied_emotional,
        'consolidation', applied_consolidation
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION apply_brainstormed_goals(
    p_heartbeat_id UUID,
    p_goals JSONB
)
RETURNS JSONB AS $$
DECLARE
    goal JSONB;
    title TEXT;
    description TEXT;
    source goal_source;
    priority goal_priority;
    parent_id UUID;
    due_at TIMESTAMPTZ;
    created_id UUID;
    created_ids UUID[] := ARRAY[]::UUID[];
BEGIN
    IF p_goals IS NULL OR jsonb_typeof(p_goals) <> 'array' THEN
        RETURN jsonb_build_object('created_goal_ids', created_ids);
    END IF;

    FOR goal IN SELECT * FROM jsonb_array_elements(p_goals)
    LOOP
        title := btrim(COALESCE(goal->>'title', ''));
        IF title = '' THEN
            CONTINUE;
        END IF;
        description := NULLIF(goal->>'description', '');

        BEGIN
            source := COALESCE(NULLIF(goal->>'source', ''), 'curiosity')::goal_source;
        EXCEPTION
            WHEN OTHERS THEN
                source := 'curiosity'::goal_source;
        END;
        BEGIN
            priority := COALESCE(NULLIF(goal->>'priority', ''), 'queued')::goal_priority;
        EXCEPTION
            WHEN OTHERS THEN
                priority := 'queued'::goal_priority;
        END;

        parent_id := NULL;
        BEGIN
            parent_id := NULLIF(goal->>'parent_goal_id', '')::uuid;
        EXCEPTION
            WHEN OTHERS THEN
                parent_id := NULL;
        END;
        IF parent_id IS NULL THEN
            BEGIN
                parent_id := NULLIF(goal->>'parent_id', '')::uuid;
            EXCEPTION
                WHEN OTHERS THEN
                    parent_id := NULL;
            END;
        END IF;

        due_at := NULL;
        BEGIN
            due_at := NULLIF(goal->>'due_at', '')::timestamptz;
        EXCEPTION
            WHEN OTHERS THEN
                due_at := NULL;
        END;

        created_id := create_goal(
            title,
            description,
            source,
            priority,
            parent_id,
            due_at
        );
        created_ids := array_append(created_ids, created_id);
    END LOOP;

    RETURN jsonb_build_object('created_goal_ids', created_ids);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION execute_heartbeat_action(
    p_heartbeat_id UUID,
    p_action TEXT,
    p_params JSONB DEFAULT '{}'
)
RETURNS JSONB AS $$
DECLARE
    action_kind heartbeat_action;
    action_cost FLOAT;
    current_e FLOAT;
    result JSONB;
    queued_call_id UUID;
    outbox_id UUID;
    remembered_id UUID;
    boundary_hits JSONB;
    boundary_content TEXT;
    rel_entity TEXT;
    rel_strength FLOAT;
    rel_evidence UUID;
    chapter_name TEXT;
    chapter_summary TEXT;
    chapter_next TEXT;
    tp_memory_id UUID;
    contra_a UUID;
    contra_b UUID;
    resolution_text TEXT;
    identity_updated BOOLEAN;
BEGIN
    BEGIN
        action_kind := p_action::heartbeat_action;
    EXCEPTION
        WHEN invalid_text_representation THEN
            RETURN jsonb_build_object('success', false, 'error', 'Unknown action: ' || COALESCE(p_action, '<null>'));
    END;

    action_cost := get_action_cost(p_action);
    current_e := get_current_energy();

    IF current_e < action_cost THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Insufficient energy',
            'required', action_cost,
            'available', current_e
        );
    END IF;

    -- Boundary pre-checks for side-effects (no energy charge on refusal).
    IF p_action IN ('reach_out_public', 'synthesize') THEN
        boundary_content := COALESCE(p_params->>'content', '');
        SELECT COALESCE(jsonb_agg(row_to_json(r)), '[]'::jsonb)
        INTO boundary_hits
        FROM check_boundaries(boundary_content) r;

        IF boundary_hits IS NOT NULL AND jsonb_array_length(boundary_hits) > 0 THEN
            IF EXISTS (
                SELECT 1
                FROM jsonb_array_elements(boundary_hits) e
                WHERE e->>'response_type' = 'refuse'
            ) THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'Boundary triggered',
                    'boundaries', boundary_hits
                );
            END IF;
        END IF;
    END IF;

    PERFORM update_energy(-action_cost);

    CASE p_action
        WHEN 'observe' THEN
            result := jsonb_build_object('environment', get_environment_snapshot());

        WHEN 'review_goals' THEN
            result := jsonb_build_object('goals', get_goals_snapshot());

        WHEN 'remember' THEN
            remembered_id := create_episodic_memory(
                p_content := COALESCE(p_params->>'content', ''),
                p_context := COALESCE(p_params, '{}'::jsonb) || jsonb_build_object('heartbeat_id', p_heartbeat_id),
                p_emotional_valence := COALESCE((p_params->>'emotional_valence')::float, 0),
                p_importance := COALESCE((p_params->>'importance')::float, 0.4)
            );
            result := jsonb_build_object('memory_id', remembered_id);

        WHEN 'recall' THEN
            SELECT jsonb_agg(row_to_json(r)) INTO result
            FROM fast_recall(p_params->>'query', COALESCE((p_params->>'limit')::int, 5)) r;
            result := jsonb_build_object('memories', COALESCE(result, '[]'::jsonb));
            PERFORM satisfy_drive('curiosity', 0.2);

        WHEN 'connect' THEN
            PERFORM create_memory_relationship(
                (p_params->>'from_id')::UUID,
                (p_params->>'to_id')::UUID,
                (p_params->>'relationship_type')::graph_edge_type,
                COALESCE(p_params->'properties', '{}'::jsonb)
            );
            result := jsonb_build_object('connected', true);
            PERFORM satisfy_drive('coherence', 0.1);

        WHEN 'reprioritize' THEN
            PERFORM change_goal_priority(
                (p_params->>'goal_id')::UUID,
                (p_params->>'new_priority')::goal_priority,
                p_params->>'reason'
            );
            IF (p_params->>'new_priority') = 'completed' THEN
                PERFORM satisfy_drive('competence', 0.4);
            END IF;
            result := jsonb_build_object('reprioritized', true);

        WHEN 'reflect' THEN
            INSERT INTO external_calls (call_type, input, heartbeat_id)
            VALUES (
                'think',
                jsonb_build_object(
                    'kind', 'reflect',
                    'recent_memories', get_recent_context(20),
                    'identity', get_identity_context(),
                    'worldview', get_worldview_context(),
                    'contradictions', (
                        SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb)
                        FROM (SELECT * FROM find_contradictions(NULL) LIMIT 5) t
                    ),
                    'goals', get_goals_snapshot(),
                    'heartbeat_id', p_heartbeat_id,
                    'instructions', 'Analyze patterns. Note contradictions. Suggest identity updates. Discover relationships between memories.'
                ),
                p_heartbeat_id
            )
            RETURNING id INTO queued_call_id;
            result := jsonb_build_object('queued', true, 'external_call_id', queued_call_id);
            PERFORM satisfy_drive('coherence', 0.2);

        WHEN 'maintain' THEN
            -- Phase 5 (ReduceScopeCreep): worldview_id now refers to a worldview memory
            identity_updated := NULL;
            IF (p_params ? 'identity_belief_id') AND (p_params ? 'new_content') THEN
                identity_updated := update_identity_belief(
                    (p_params->>'identity_belief_id')::uuid,
                    p_params->>'new_content',
                    NULLIF(p_params->>'evidence_memory_id', '')::uuid,
                    COALESCE(NULLIF(p_params->>'force', '')::boolean, FALSE)
                );
            ELSIF p_params ? 'worldview_id' THEN
                UPDATE memories
                SET metadata = jsonb_set(
                        metadata,
                        '{confidence}',
                        to_jsonb(COALESCE((p_params->>'new_confidence')::float, (metadata->>'confidence')::float))
                    ),
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = (p_params->>'worldview_id')::UUID AND type = 'worldview';
            END IF;
            result := jsonb_build_object('maintained', true, 'identity_updated', identity_updated);
            PERFORM satisfy_drive('coherence', 0.1);

        WHEN 'mark_turning_point' THEN
            tp_memory_id := NULLIF(p_params->>'memory_id', '')::uuid;
            chapter_summary := COALESCE(p_params->>'summary', p_params->>'reason', '');

            IF tp_memory_id IS NOT NULL THEN
                UPDATE memories
                SET importance = GREATEST(importance, 0.9),
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = tp_memory_id;
            END IF;

            PERFORM create_strategic_memory(
                p_content := COALESCE(NULLIF(chapter_summary, ''), 'Turning point noted'),
                p_pattern_description := 'Narrative turning point',
                p_confidence_score := 0.85,
                p_supporting_evidence := jsonb_build_object(
                    'memory_id', tp_memory_id,
                    'summary', chapter_summary,
                    'heartbeat_id', p_heartbeat_id
                ),
                p_importance := 0.6
            );
            result := jsonb_build_object('marked', true, 'memory_id', tp_memory_id);

        WHEN 'begin_chapter' THEN
            chapter_name := COALESCE(
                NULLIF(p_params->>'name', ''),
                NULLIF(p_params->>'chapter_name', ''),
                NULLIF(p_params->>'title', ''),
                'Foundations'
            );
            PERFORM ensure_current_life_chapter(chapter_name);
            result := jsonb_build_object('started', true, 'chapter', chapter_name);

        WHEN 'close_chapter' THEN
            chapter_summary := COALESCE(p_params->>'summary', '');
            chapter_next := NULLIF(p_params->>'next_chapter', '');
            PERFORM create_strategic_memory(
                p_content := COALESCE(NULLIF(chapter_summary, ''), 'Chapter closed'),
                p_pattern_description := 'Chapter closure',
                p_confidence_score := 0.8,
                p_supporting_evidence := jsonb_build_object(
                    'summary', chapter_summary,
                    'previous_chapter', get_narrative_context(),
                    'heartbeat_id', p_heartbeat_id
                ),
                p_importance := 0.6
            );
            IF chapter_next IS NOT NULL THEN
                PERFORM ensure_current_life_chapter(chapter_next);
            END IF;
            result := jsonb_build_object('closed', true, 'next_chapter', chapter_next);

        WHEN 'acknowledge_relationship' THEN
            rel_entity := COALESCE(NULLIF(p_params->>'entity', ''), NULLIF(p_params->>'name', ''));
            rel_strength := COALESCE(NULLIF(p_params->>'strength', '')::float, 0.6);
            rel_evidence := NULLIF(p_params->>'evidence_memory_id', '')::uuid;
            IF rel_entity IS NOT NULL THEN
                PERFORM upsert_self_concept_edge('relationship', rel_entity, rel_strength, rel_evidence);
            END IF;
            result := jsonb_build_object('acknowledged', true, 'entity', rel_entity);

        WHEN 'update_trust' THEN
            rel_entity := COALESCE(NULLIF(p_params->>'entity', ''), NULLIF(p_params->>'name', ''));
            rel_strength := COALESCE(
                NULLIF(p_params->>'strength', '')::float,
                NULLIF(p_params->>'delta', '')::float,
                0.6
            );
            rel_evidence := NULLIF(p_params->>'evidence_memory_id', '')::uuid;
            IF rel_entity IS NOT NULL THEN
                PERFORM upsert_self_concept_edge('relationship', rel_entity, rel_strength, rel_evidence);
            END IF;
            result := jsonb_build_object('updated', true, 'entity', rel_entity, 'strength', rel_strength);

        WHEN 'reflect_on_relationship' THEN
            rel_entity := COALESCE(NULLIF(p_params->>'entity', ''), NULLIF(p_params->>'name', ''));
            INSERT INTO external_calls (call_type, input, heartbeat_id)
            VALUES (
                'think',
                jsonb_build_object(
                    'kind', 'reflect',
                    'heartbeat_id', p_heartbeat_id,
                    'context', gather_turn_context(),
                    'params', jsonb_build_object('relationship', rel_entity)
                ),
                p_heartbeat_id
            )
            RETURNING id INTO queued_call_id;
            result := jsonb_build_object('queued', true, 'external_call_id', queued_call_id, 'entity', rel_entity);

        WHEN 'resolve_contradiction' THEN
            contra_a := NULLIF(p_params->>'memory_a', '')::uuid;
            contra_b := NULLIF(p_params->>'memory_b', '')::uuid;
            resolution_text := COALESCE(p_params->>'resolution', '');

            PERFORM create_strategic_memory(
                p_content := COALESCE(NULLIF(resolution_text, ''), 'Contradiction resolved'),
                p_pattern_description := 'Contradiction resolved',
                p_confidence_score := 0.8,
                p_supporting_evidence := jsonb_build_object(
                    'memory_a', contra_a,
                    'memory_b', contra_b,
                    'resolution', resolution_text,
                    'heartbeat_id', p_heartbeat_id
                ),
                p_importance := 0.6
            );

            BEGIN
                IF contra_a IS NOT NULL AND contra_b IS NOT NULL THEN
                    EXECUTE format(
                        'SELECT * FROM cypher(''memory_graph'', $q$ 
                            MATCH (a:MemoryNode {memory_id: %L})-[r:CONTRADICTS]-(b:MemoryNode {memory_id: %L})
                            DELETE r
                            RETURN a
                        $q$) as (result agtype)',
                        contra_a,
                        contra_b
                    );
                END IF;
            EXCEPTION WHEN OTHERS THEN NULL;
            END;

            result := jsonb_build_object('resolved', true, 'memory_a', contra_a, 'memory_b', contra_b);

        WHEN 'accept_tension' THEN
            contra_a := NULLIF(p_params->>'memory_a', '')::uuid;
            contra_b := NULLIF(p_params->>'memory_b', '')::uuid;
            resolution_text := COALESCE(p_params->>'note', p_params->>'resolution', '');
            PERFORM create_strategic_memory(
                p_content := COALESCE(NULLIF(resolution_text, ''), 'Contradiction acknowledged'),
                p_pattern_description := 'Contradiction accepted',
                p_confidence_score := 0.7,
                p_supporting_evidence := jsonb_build_object(
                    'memory_a', contra_a,
                    'memory_b', contra_b,
                    'note', resolution_text,
                    'heartbeat_id', p_heartbeat_id
                ),
                p_importance := 0.5
            );
            result := jsonb_build_object('accepted', true, 'memory_a', contra_a, 'memory_b', contra_b);

        WHEN 'brainstorm_goals' THEN
            INSERT INTO external_calls (call_type, input, heartbeat_id)
            VALUES (
                'think',
                jsonb_build_object(
                    'kind', 'brainstorm_goals',
                    'heartbeat_id', p_heartbeat_id,
                    'context', gather_turn_context(),
                    'params', COALESCE(p_params, '{}'::jsonb)
                ),
                p_heartbeat_id
            )
            RETURNING id INTO queued_call_id;
            result := jsonb_build_object('queued', true, 'external_call_id', queued_call_id);

        WHEN 'inquire_shallow', 'inquire_deep' THEN
            INSERT INTO external_calls (call_type, input, heartbeat_id)
            VALUES (
                'think',
                jsonb_build_object(
                    'kind', 'inquire',
                    'depth', p_action,
                    'heartbeat_id', p_heartbeat_id,
                    'query', COALESCE(p_params->>'query', p_params->>'question'),
                    'context', gather_turn_context(),
                    'params', COALESCE(p_params, '{}'::jsonb)
                ),
                p_heartbeat_id
            )
            RETURNING id INTO queued_call_id;
            result := jsonb_build_object('queued', true, 'external_call_id', queued_call_id);
            PERFORM satisfy_drive('curiosity', 0.2);

        WHEN 'synthesize' THEN
            DECLARE synth_id UUID;
            BEGIN
                synth_id := create_semantic_memory(
                    p_params->>'content',
                    COALESCE((p_params->>'confidence')::float, 0.8),
                    ARRAY['synthesis', COALESCE(p_params->>'topic', 'general')],
                    NULL,
                    jsonb_build_object('heartbeat_id', p_heartbeat_id, 'sources', p_params->'sources', 'boundaries', boundary_hits),
                    0.7
                );
                result := jsonb_build_object('synthesis_memory_id', synth_id, 'boundaries', boundary_hits);
            END;

        WHEN 'reach_out_user' THEN
            INSERT INTO outbox_messages (kind, payload)
            VALUES (
                'user',
                jsonb_build_object(
                    'message', p_params->>'message',
                    'intent', p_params->>'intent',
                    'heartbeat_id', p_heartbeat_id
                )
            )
            RETURNING id INTO outbox_id;
            result := jsonb_build_object('queued', true, 'outbox_id', outbox_id);
            PERFORM satisfy_drive('connection', 0.3);

        WHEN 'reach_out_public' THEN
            INSERT INTO outbox_messages (kind, payload)
            VALUES (
                'public',
                jsonb_build_object(
                    'platform', p_params->>'platform',
                    'content', p_params->>'content',
                    'heartbeat_id', p_heartbeat_id,
                    'boundaries', boundary_hits
                )
            )
            RETURNING id INTO outbox_id;
            result := jsonb_build_object('queued', true, 'outbox_id', outbox_id, 'boundaries', boundary_hits);
            PERFORM satisfy_drive('connection', 0.3);

        WHEN 'terminate' THEN
            -- Self-termination: wipe state and leave a single last-will memory.
            -- Expect params: { "last_will": "...", "farewells": [ { "message": "...", ... } ], "options": {...} }
            IF COALESCE(p_params->'confirmed', 'false'::jsonb) = 'true'::jsonb THEN
                result := terminate_agent(
                    COALESCE(NULLIF(p_params->>'last_will', ''), NULLIF(p_params->>'message', ''), NULLIF(p_params->>'reason', ''), ''),
                    COALESCE(p_params->'farewells', '[]'::jsonb),
                    COALESCE(p_params->'options', '{}'::jsonb)
                );
            ELSE
                INSERT INTO external_calls (call_type, input, heartbeat_id)
                VALUES (
                    'think',
                    jsonb_build_object(
                        'kind', 'termination_confirm',
                        'heartbeat_id', p_heartbeat_id,
                        'context', gather_turn_context(),
                        'params', COALESCE(p_params, '{}'::jsonb)
                    ),
                    p_heartbeat_id
                )
                RETURNING id INTO queued_call_id;
                result := jsonb_build_object('confirmation_required', true, 'external_call_id', queued_call_id);
            END IF;

        WHEN 'rest' THEN
            result := jsonb_build_object('rested', true, 'energy_preserved', current_e - action_cost);
            PERFORM satisfy_drive('rest', 0.4);

        ELSE
            RETURN jsonb_build_object('success', false, 'error', 'Unknown action: ' || COALESCE(p_action, '<null>'));
    END CASE;

    RETURN jsonb_build_object(
        'success', true,
        'action', p_action,
        'cost', action_cost,
        'energy_remaining', get_current_energy(),
        'result', result
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- COMMENTS FOR HEARTBEAT SYSTEM
-- ============================================================================

-- Phase 6 (ReduceScopeCreep): goals table removed - goals are now memories with type='goal'
-- Phase 7 (ReduceScopeCreep): heartbeat_config table removed - config now in unified config table
COMMENT ON TABLE heartbeat_state IS 'Singleton table tracking current heartbeat state: energy, counts, timestamps.';
COMMENT ON TABLE heartbeat_log IS 'Audit log of each heartbeat execution with full context and results.';
COMMENT ON TABLE external_calls IS 'Queue for LLM and embedding API calls. Worker polls this and writes results back.';

COMMENT ON FUNCTION should_run_heartbeat IS 'Check if heartbeat interval has elapsed and system is not paused.';
COMMENT ON FUNCTION start_heartbeat IS 'Initialize heartbeat: regenerate energy, gather context, queue think request.';
COMMENT ON FUNCTION execute_heartbeat_action IS 'Execute a single action, deducting energy and returning results.';
COMMENT ON FUNCTION complete_heartbeat IS 'Finalize heartbeat: create episodic memory, update log, set next heartbeat time.';
COMMENT ON FUNCTION gather_turn_context IS 'Gather full context for LLM decision: environment, goals, memories, identity, self_model, worldview, narrative, relationships, contradictions, emotional patterns, energy.';

-- ============================================================================
-- PUBLIC VS INTERNAL FUNCTIONS
-- ============================================================================
-- Public API:
--   create_episodic_memory, create_semantic_memory, create_procedural_memory, create_strategic_memory
--   create_worldview_belief, update_identity_belief, create_goal, batch_create_memories
--   fast_recall, gather_turn_context
--   create_memory_relationship, link_memory_to_concept, upsert_self_concept_edge
--   execute_heartbeat_action, check_boundaries, terminate_agent
--   get_config, set_config
--
-- Internal helpers (called by public functions or workers):
--   get_environment_snapshot, get_goals_snapshot, get_recent_context, get_identity_context
--   get_worldview_context, get_self_model_context, get_narrative_context
--   get_relationships_context, get_contradictions_context, get_emotional_patterns_context
--   apply_subconscious_observations, apply_brainstormed_goals
--   calculate_relevance, age_in_days

-- ============================================================================
-- TIP OF TONGUE / PARTIAL ACTIVATION
-- ============================================================================

-- Phase 3 (ReduceScopeCreep): Uses graph edges (MEMBER_OF) instead of memory_cluster_members table
CREATE OR REPLACE FUNCTION find_partial_activations(
    p_query_text TEXT,
    p_cluster_threshold FLOAT DEFAULT 0.7,
    p_memory_threshold FLOAT DEFAULT 0.5
)
RETURNS TABLE (
    cluster_id UUID,
    cluster_name TEXT,
    keywords TEXT[],
    emotional_signature JSONB,
    cluster_similarity FLOAT,
    best_memory_similarity FLOAT
) AS $$
DECLARE
    query_embedding vector;
BEGIN
    BEGIN
        query_embedding := get_embedding(p_query_text);
    EXCEPTION
        WHEN OTHERS THEN
            query_embedding := NULL;
    END;
    IF query_embedding IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        mc.id,
        mc.name,
        ARRAY[]::TEXT[] as keywords,
        NULL::JSONB as emotional_signature,
        (1 - (mc.centroid_embedding <=> query_embedding))::float as cluster_sim,
        MAX((1 - (m.embedding <=> query_embedding))::float) as best_mem_sim
    FROM clusters mc
    JOIN get_cluster_members_graph(mc.id) gcm ON TRUE
    JOIN memories m ON gcm.memory_id = m.id
    WHERE m.status = 'active'
      AND mc.centroid_embedding IS NOT NULL
    GROUP BY mc.id, mc.name, mc.centroid_embedding
    HAVING
        (1 - (mc.centroid_embedding <=> query_embedding)) >= p_cluster_threshold
        AND MAX(1 - (m.embedding <=> query_embedding)) < p_memory_threshold;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- VIEWS / HEALTH / WORKER GUIDANCE
-- ============================================================================

-- Phase 6 (ReduceScopeCreep): Updated to query memories with type='goal' instead of goals table
CREATE OR REPLACE VIEW cognitive_health AS
SELECT
    (SELECT current_energy FROM heartbeat_state WHERE id = 1) as energy,
    get_config_float('heartbeat.max_energy') as max_energy,
    (SELECT COUNT(*) FROM drives WHERE current_level >= urgency_threshold) as urgent_drives,
    (SELECT AVG(current_level) FROM drives) as avg_drive_level,
    (SELECT COUNT(*) FROM memories WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'active') as active_goals,
    (SELECT COUNT(*) FROM memories WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'active'
        AND metadata->'blocked_by' IS NOT NULL AND metadata->'blocked_by' <> 'null'::jsonb) as blocked_goals,
    (SELECT COUNT(*) FROM memories WHERE status = 'active') as total_memories,
    (SELECT COUNT(*) FROM memory_neighborhoods WHERE is_stale = TRUE) as stale_neighborhoods,
    (SELECT valence FROM current_emotional_state) as current_valence,
    (SELECT primary_emotion FROM current_emotional_state) as current_emotion,
    (SELECT COUNT(*) FROM heartbeat_log WHERE started_at > CURRENT_TIMESTAMP - INTERVAL '24 hours') as heartbeats_24h,
    (SELECT COUNT(*) FROM external_calls WHERE status = 'pending') as pending_calls,
    -- Note: relationship_discoveries table removed in Phase 8; relationships are now only in graph
    0::bigint as relationships_discovered_24h;

CREATE OR REPLACE VIEW worker_tasks AS
SELECT
    'external_calls' as task_type,
    (SELECT COUNT(*) FROM external_calls WHERE status = 'pending') as pending_count,
    'Process LLM/embedding requests' as description
UNION ALL
SELECT
    'heartbeat',
    CASE WHEN should_run_heartbeat() THEN 1 ELSE 0 END,
    'Run heartbeat if due'
UNION ALL
SELECT
    'subconscious_maintenance',
    CASE WHEN should_run_maintenance() THEN 1 ELSE 0 END,
    'Run subconscious maintenance tick (consolidate + prune)'
UNION ALL
SELECT
    'outbox',
    (SELECT COUNT(*) FROM outbox_messages WHERE status = 'pending'),
    'Deliver pending messages';

COMMENT ON TABLE external_calls IS
'Queue for external calls. Worker processes pending calls and writes results.

Expected response formats by kind:

heartbeat_decision:
{
  "reasoning": "Internal monologue explaining thought process",
  "actions": [
    {"action": "recall", "params": {"query": "..."}},
    {"action": "reflect", "params": {}},
    {"action": "rest", "params": {}}
  ],
  "emotional_assessment": {"valence": 0.2, "arousal": 0.4, "primary_emotion": "curious"}
}

brainstorm_goals:
{
  "goals": [
    {"title": "...", "description": "...", "source": "curiosity", "priority": "queued"}
  ]
}

inquire:
{
  "summary": "Summary of research",
  "sources": ["url1", "url2"],
  "confidence": 0.8
}

reflect:
{
  "insights": [...],
  "identity_updates": [...],
  "worldview_updates": [...],
  "worldview_influences": [...],
  "discovered_relationships": [...],
  "contradictions_noted": [...],
  "self_updates": [{"kind": "values", "concept": "honesty", "strength": 0.8, "evidence_memory_id": null}]
}';
