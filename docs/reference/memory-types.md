<!--
title: Memory Types
summary: Memory type fields, lifecycle, and SQL functions
read_when:
  - "You want to understand memory type details"
  - "You need to create memories via SQL"
section: reference
-->

# Memory Types

Hexis uses five core memory types plus two special types (worldview and goal).

## Type Overview

| Type | Purpose | Decay | SQL Function |
|------|---------|-------|--------------|
| **Working** | Temporary buffer | Auto-expiry | `add_to_working_memory()` |
| **Episodic** | Events with temporal context | Yes | `create_episodic_memory()` |
| **Semantic** | Facts with confidence | Yes | `create_semantic_memory()` |
| **Procedural** | Step-by-step procedures | Yes | `create_procedural_memory()` |
| **Strategic** | Patterns and strategies | Yes | `create_strategic_memory()` |
| **Worldview** | Beliefs and identity | No (permanent) | `create_memory()` with type='worldview' |
| **Goal** | Active objectives | No (until completed) | `create_memory()` with type='goal' |

## Base Fields (All Types)

All memories share these fields in the `memories` table:

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Primary key |
| `type` | TEXT | Memory type |
| `content` | TEXT | Memory content |
| `embedding` | vector | Vector embedding (NOT NULL) |
| `importance` | FLOAT | 0.0-1.0 importance score |
| `trust_level` | FLOAT | 0.0-1.0 source trust |
| `status` | TEXT | `active`, `archived`, `decayed` |
| `metadata` | JSONB | Type-specific metadata |
| `created_at` | TIMESTAMPTZ | Creation time |
| `last_accessed_at` | TIMESTAMPTZ | Last retrieval time |

## Working Memory

Short-lived buffer with automatic expiry. Information enters here first and may be promoted to long-term memory.

- **Table**: `working_memory` (UNLOGGED for fast writes)
- **Expiry**: Automatic cleanup via `cleanup_working_memory()`
- **Promotion**: Important items promoted to episodic/semantic by maintenance worker

## Episodic Memory

Events with temporal context, actions, results, and emotional valence.

**Key metadata fields**:
- `action` -- what happened
- `context` -- surrounding circumstances
- `result` -- outcome
- `emotional_valence` -- emotional response (-1.0 to 1.0)

**Graph**: Creates `MemoryNode` with `TEMPORAL_NEXT` edges for narrative sequence.

## Semantic Memory

Facts with confidence scores, source tracking, and contradiction management.

**Key metadata fields**:
- `confidence` -- 0.0-1.0 confidence in the fact
- `sources` -- array of source references
- `contradictions` -- tracked contradicting memories

**Graph**: `SUPPORTS` and `CONTRADICTS` edges link related facts.

## Procedural Memory

Step-by-step procedures with success rate tracking.

**Key metadata fields**:
- `steps` -- ordered array of procedure steps
- `prerequisites` -- required conditions
- `success_rate` -- historical success tracking

## Strategic Memory

Patterns and strategies with adaptation history.

**Key metadata fields**:
- `pattern` -- the observed pattern
- `supporting_evidence` -- array of evidence references
- `context_applicability` -- when this pattern applies

## Retrieval

### fast_recall

The primary hot-path function. Combines vector similarity, neighborhood expansion, and temporal context:

```sql
SELECT * FROM fast_recall('query text', 10);
```

### search_similar_memories

With type filtering:

```sql
SELECT * FROM search_similar_memories('query', 10, ARRAY['semantic', 'episodic']);
```

### search_working_memory

```sql
SELECT * FROM search_working_memory('current context');
```

## Creation Examples

```sql
-- Semantic memory
SELECT create_semantic_memory('Python requires 3.10+', 0.95);

-- Episodic memory with metadata
SELECT create_episodic_memory(
    'User asked about deployment',
    0.7,  -- importance
    0.9,  -- trust
    '{"action": "answered question", "emotional_valence": 0.3}'::jsonb
);

-- Working memory (temporary)
SELECT add_to_working_memory('Currently discussing deployment options', 'conversation');
```

## Lifecycle

1. **Creation** -- memory inserted with embedding
2. **Activation** -- accessed via recall, activation tracked
3. **Consolidation** -- maintenance worker links related memories
4. **Decay** -- importance decreases over time (unless permanent)
5. **Archival** -- low-importance memories archived
6. **Removal** -- archived memories eventually pruned

## Related

- [Memory Operations](../guides/memory-operations.md) -- practical usage guide
- [Memory Architecture](../concepts/memory-architecture.md) -- architectural deep-dive
- [Database API](database-api.md) -- SQL function reference
