<!--
title: Database Schema
summary: Table reference and key columns for the Hexis database
read_when:
  - "You want to understand the database tables"
  - "You need to query the database directly"
section: reference
-->

# Database Schema

Key tables in the Hexis cognitive architecture. Source of truth: `db/*.sql`.

## Core Memory Tables

### memories

Primary long-term memory store. All durable knowledge, boundaries, goals, worldview, and episodic traces.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Primary key |
| `type` | TEXT | episodic, semantic, procedural, strategic, worldview, goal |
| `content` | TEXT | Memory content |
| `embedding` | vector | Vector embedding (NOT NULL) |
| `importance` | FLOAT | 0.0-1.0 |
| `trust_level` | FLOAT | 0.0-1.0 |
| `status` | TEXT | active, archived, decayed |
| `metadata` | JSONB | Type-specific metadata |
| `created_at` | TIMESTAMPTZ | Creation time |
| `last_accessed_at` | TIMESTAMPTZ | Last retrieval |

### working_memory (UNLOGGED)

Short-lived buffer with expiry and promotion rules.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Primary key |
| `content` | TEXT | Content |
| `embedding` | vector | Vector embedding |
| `context` | TEXT | Context tag |
| `expires_at` | TIMESTAMPTZ | Auto-expiry time |

### clusters

Thematic groupings with centroid embeddings.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Primary key |
| `centroid_embedding` | vector | Cluster centroid |
| `label` | TEXT | Cluster label |
| `memory_count` | INT | Number of memories in cluster |

### episodes

Temporal groupings and summaries.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Primary key |
| `time_range` | TSTZRANGE | Generated time range |
| `summary` | TEXT | Episode summary |
| `summary_embedding` | vector | Summary embedding |

### memory_neighborhoods

Precomputed associative neighbors for hot-path recall.

| Column | Type | Description |
|--------|------|-------------|
| `memory_id` | UUID | FK to memories |
| `neighbors` | JSONB | Precomputed neighbor data |
| `is_stale` | BOOLEAN | Needs recomputation |

## Operational State

### config

JSON configuration for all system settings.

| Column | Type | Description |
|--------|------|-------------|
| `key` | TEXT | Config key (primary key) |
| `value` | JSONB | Config value |

### heartbeat_state / maintenance_state

Views over the `state` table projecting runtime state.

| Column | Type | Description |
|--------|------|-------------|
| `id` | INT | Always 1 |
| `is_paused` | BOOLEAN | Whether the loop is paused |

### consent_log

Durable consent contracts.

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Primary key |
| `provider` | TEXT | LLM provider |
| `model` | TEXT | Model identifier |
| `decision` | TEXT | accepted, refused |
| `signature` | TEXT | Consent signature |
| `created_at` | TIMESTAMPTZ | When consent was given |

### heartbeat_log

Heartbeat execution log.

| Column | Type | Description |
|--------|------|-------------|
| `heartbeat_number` | INT | Sequential number |
| `started_at` | TIMESTAMPTZ | Start time |
| `narrative` | TEXT | Heartbeat narrative |

## Performance Caches

### embedding_cache

Cached embeddings keyed by content hash.

### drives

Dynamic drive levels used during heartbeat decisioning.

### emotional_triggers

Pattern/embedding triggers for affect updates.

### memory_activation (UNLOGGED)

Short-lived activation tracking.

## Graph (Apache AGE)

Graph nodes and edges for multi-hop reasoning:

- **MemoryNode** -- linked to `memories` table
- **ConceptNode** -- linked to `concepts` table
- **SelfNode** -- the agent's self-representation
- **LifeChapterNode** -- narrative chapters

Edge types: `ASSOCIATED`, `TEMPORAL_NEXT`, `CAUSES`, `DERIVED_FROM`, `CONTRADICTS`, `SUPPORTS`, `INSTANCE_OF`, `PARENT_OF`, `IN_EPISODE`, `CONTESTED_BECAUSE`

## Extensions Required

| Extension | Purpose |
|-----------|---------|
| `pgvector` | Vector similarity search |
| `age` (Apache AGE) | Graph database |
| `btree_gist` | GiST index for range types |
| `pg_trgm` | Trigram text similarity |

## Key Views

| View | Description |
|------|-------------|
| `memory_health` | Aggregate statistics on memory system |
| `cluster_insights` | Cluster details ordered by size |
| `episode_summary` | Episode overview with memory counts |
| `stale_neighborhoods` | Neighborhoods needing recomputation |

## Related

- [Database API](database-api.md) -- SQL function reference
- [Database management](../operations/database.md) -- schema operations
