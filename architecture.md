# AGI Memory System - Architecture Summary

## Overview

This schema implements a hybrid memory system for an AGI agent, combining:
- **Relational storage** (PostgreSQL) for structured data and aggregations
- **Vector search** (pgvector) for semantic similarity
- **Graph database** (Apache AGE) for reasoning and traversal

## Design Principles

1. **Embeddings are an implementation detail**: The application deals with *meaning* (text). The database handles *indexing* (embeddings). The application never sees or passes embeddings.
2. **Hot Path Optimization**: Primary retrieval uses precomputed data structures
3. **Graph for Reasoning Only**: Graph traversal reserved for cold-path operations
4. **Clusters Stay Relational**: Vector search on centroids requires pgvector

## Embedding Integration

The database generates embeddings internally via HTTP to an embedding service:

```sql
-- Configuration (set once)
INSERT INTO embedding_config (key, value) 
VALUES ('service_url', 'http://embeddings:80/embed');

-- Application just passes text - embedding is transparent
SELECT create_semantic_memory('User prefers dark mode', 0.9);
SELECT * FROM fast_recall('What are the user preferences?');
```

The `get_embedding()` function handles:
- HTTP calls to embedding service
- Response parsing (multiple formats supported)
- Caching via content hash
- Dimension validation

## Architecture Layers

### Layer 1: Core Storage (Relational)
| Table | Purpose |
|-------|---------|
| `memories` | Base memory with embedding, importance, decay |
| `episodic_memories` | Events with context, action, result, emotion |
| `semantic_memories` | Facts with confidence, sources, contradictions |
| `procedural_memories` | How-to with steps, success tracking |
| `strategic_memories` | Patterns with evidence, applicability |
| `working_memory` | Transient short-term buffer |

### Layer 2: Clustering (Relational)
| Table | Purpose |
|-------|---------|
| `memory_clusters` | Thematic groups with centroid embedding |
| `memory_cluster_members` | Membership with strength scores |
| `cluster_relationships` | Inter-cluster links (evolves, contradicts) |

### Layer 3: Acceleration (Precomputed)
| Table | Purpose |
|-------|---------|
| `episodes` | Temporal segmentation with summary embedding |
| `episode_memories` | Ordered memory sequences within episodes |
| `memory_neighborhoods` | Precomputed associative neighbors (JSONB) |
| `activation_cache` | Transient activation state (UNLOGGED) |

### Layer 4: Concepts (Hybrid)
| Table | Purpose |
|-------|---------|
| `concepts` | Abstract ontology with flattened ancestry |
| `memory_concepts` | Memory-to-concept links |

### Layer 5: Identity & Worldview
| Table | Purpose |
|-------|---------|
| `worldview_primitives` | Beliefs that filter perception |
| `worldview_memory_influences` | How beliefs affect memories |
| `identity_aspects` | Normalized self-concept components |
| `identity_memory_resonance` | Memory-identity connections |

### Layer 6: Graph (AGE)
| Node | Purpose |
|------|---------|
| `MemoryNode` | Memory reference for traversal |
| `ConceptNode` | Abstract concept for schema reasoning |

| Edge | Purpose |
|------|---------|
| `TEMPORAL_NEXT` | Narrative sequence |
| `CAUSES` | Causal reasoning |
| `DERIVED_FROM` | Episodic → semantic transformation |
| `CONTRADICTS` | Dialectical tension |
| `SUPPORTS` | Evidence relationship |
| `INSTANCE_OF` | Memory → concept |
| `PARENT_OF` | Concept hierarchy |
| `ASSOCIATED` | Learned co-activation |

## Key Functions

### Retrieval
- `fast_recall(query_text, limit)` - Primary hot-path retrieval (vector + neighborhood + temporal)
- `search_similar_memories(query_text, limit, types)` - Simple vector search
- `search_working_memory(query_text, limit)` - Search transient buffer

### Memory Creation
- `create_memory(type, content, importance)` - Base function
- `create_episodic_memory(content, action, context, result, emotion, time, importance)`
- `create_semantic_memory(content, confidence, category, concepts, sources, importance)`
- `create_procedural_memory(content, steps, prerequisites, importance)`
- `create_strategic_memory(content, pattern, confidence, evidence, applicability, importance)`
- `add_to_working_memory(content, expiry)` - Transient storage

### Internal (not called by application)
- `get_embedding(text)` - Generate embedding via HTTP service (cached)
- `check_embedding_service_health()` - Health check

### Graph Operations
- `create_memory_relationship(from, to, type, properties)`
- `link_memory_to_concept(memory_id, concept_name, strength)`

### Maintenance
- `cleanup_working_memory()`
- `cleanup_embedding_cache(interval)`
- `recalculate_cluster_centroid(cluster_id)`
- `assign_memory_to_clusters(memory_id, max_clusters)`

## Triggers (Automatic)

| Trigger | Action |
|---------|--------|
| `trg_memory_timestamp` | Update `updated_at` on modification |
| `trg_importance_on_access` | Boost importance when accessed |
| `trg_cluster_activation` | Track cluster activation |
| `trg_neighborhood_staleness` | Mark neighborhoods for recomputation |
| `trg_auto_episode_assignment` | Segment memories into episodes |

## Background Jobs Required

| Job | Frequency | Action |
|-----|-----------|--------|
| Neighborhood Refresh | 5 min | Recompute stale neighborhoods |
| Episode Summarization | On close | LLM summary + embedding |
| Concept Extraction | Post-insert | LLM concept extraction |
| Cluster Maintenance | 30 min | Recalculate centroids |
| Cache Cleanup | 1 hour | Remove expired entries |

## Query Patterns

### Hot Path (~10-50ms)
```sql
SELECT * FROM fast_recall(embedding, 10);
```

### Warm Path (~50-100ms)
```sql
-- Find related clusters
SELECT * FROM memory_clusters mc
JOIN cluster_relationships cr ON mc.id = cr.to_cluster_id
WHERE cr.from_cluster_id = $1;
```

### Cold Path (~500ms+)
```sql
-- Graph traversal for causal chains
SELECT * FROM cypher('memory_graph', $$
    MATCH path = (m1:MemoryNode)-[:CAUSES*1..5]->(m2:MemoryNode)
    WHERE m1.memory_id = $start_id
    RETURN path
$$) as (path agtype);
```

## Performance Optimizations

1. **HNSW indexes** on all embedding columns
2. **GiST index** on episode time ranges
3. **GIN indexes** on JSONB neighborhoods
4. **UNLOGGED table** for transient activation
5. **Precomputed neighborhoods** replace live spreading activation
6. **Episode segmentation** replaces temporal chain traversal
7. **Flattened concept ancestry** avoids recursive queries

## Cognitive Effects Modeled

| Effect | Implementation |
|--------|----------------|
| Spreading Activation | Precomputed neighborhoods |
| Temporal Contiguity | Episode segmentation |
| Forgetting Curve | Decay rate per memory |
| Importance Boosting | Access count trigger |
| Schema Memory | Concept hierarchy |
| Recency Bias | Temporal scoring in fast_recall |
| Context Matching | Vector similarity |

## What the Graph Does NOT Do

- Primary retrieval (use `fast_recall`)
- Cluster membership (relational)
- Centroid-based search (pgvector)
- Episode membership (relational)

The graph is reserved for:
- Causal reasoning chains
- Contradiction detection
- Schema/concept traversal
- Background consolidation