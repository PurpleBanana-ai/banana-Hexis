import asyncio
import os

import pytest

from tests.utils import get_test_identifier, _db_dsn

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.core]

EMBEDDING_DIMENSION = int(os.getenv("EMBEDDING_DIMENSION", os.getenv("EMBEDDING_DIM", "768")))


@pytest.fixture(scope="module")
async def cognitive_memory_client(ensure_embedding_service):
    from core.cognitive_memory_api import CognitiveMemory

    client = await CognitiveMemory.create(_db_dsn(), min_size=1, max_size=5)
    yield client
    await client.close()


async def test_api_remember_and_recall_by_id(cognitive_memory_client, db_pool):
    from core.cognitive_memory_api import MemoryType

    test_id = get_test_identifier("api_remember")
    content = f"API semantic memory {test_id}"

    mid = await cognitive_memory_client.remember(
        content,
        type=MemoryType.SEMANTIC,
        importance=0.7,
    )

    try:
        fetched = await cognitive_memory_client.recall_by_id(mid)
        assert fetched is not None
        assert fetched.id == mid
        assert fetched.type == MemoryType.SEMANTIC
        assert fetched.content == content
        assert fetched.importance >= 0.7
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM memories WHERE id = $1", mid)


async def test_api_semantic_sources_affect_trust(cognitive_memory_client, db_pool):
    from core.cognitive_memory_api import MemoryType

    test_id = get_test_identifier("api_trust")
    content = f"API claim from twitter {test_id}"
    source_a = {"kind": "twitter", "ref": f"https://twitter.com/example/status/{test_id}", "trust": 0.2}
    source_b = {"kind": "paper", "ref": f"doi:10.0000/{test_id}", "trust": 0.9}

    mid = await cognitive_memory_client.remember(
        content,
        type=MemoryType.SEMANTIC,
        importance=0.6,
        source_references=source_a,
    )

    try:
        m = await cognitive_memory_client.recall_by_id(mid)
        assert m is not None
        assert m.trust_level is not None
        assert m.trust_level <= 0.30
        assert isinstance(m.source_attribution, dict)

        await cognitive_memory_client.add_source(mid, source_b)
        profile = await cognitive_memory_client.get_truth_profile(mid)
        assert profile.get("type") == "semantic"
        assert float(profile.get("trust_level", 0)) > float(m.trust_level)
        assert int(profile.get("source_count", 0)) >= 2
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM memories WHERE id = $1", mid)


async def test_api_remember_links_concepts_and_find_by_concept(cognitive_memory_client, db_pool):
    from core.cognitive_memory_api import MemoryType

    test_id = get_test_identifier("api_concepts")
    content = f"API concept memory {test_id}"
    concept = f"Concept_{test_id}"

    mid = await cognitive_memory_client.remember(
        content,
        type=MemoryType.SEMANTIC,
        importance=0.6,
        concepts=[concept],
    )

    try:
        hits = await cognitive_memory_client.find_by_concept(concept, limit=25)
        assert any(m.id == mid for m in hits)
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM memories WHERE id = $1", mid)
            await conn.execute("DELETE FROM concepts WHERE name = $1", concept)


async def test_api_hydrate_returns_context(cognitive_memory_client, db_pool):
    from core.cognitive_memory_api import MemoryType

    test_id = get_test_identifier("api_hydrate")
    content = f"Hydrate memory {test_id}"

    mid = await cognitive_memory_client.remember(content, type=MemoryType.SEMANTIC, importance=0.7)
    try:
        # Use a larger limit because the embedding model may not strongly encode
        # random suffixes, making many "Hydrate memory ..." entries near-ties.
        ctx = await cognitive_memory_client.hydrate(content, include_goals=True, memory_limit=50)
        assert ctx.memories
        assert any(test_id in m.content for m in ctx.memories)
        assert isinstance(ctx.identity, list)
        assert isinstance(ctx.worldview, list)
        assert ctx.goals is None or isinstance(ctx.goals, dict)
        assert isinstance(ctx.urgent_drives, list)
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM memories WHERE id = $1", mid)


async def test_api_hold_and_search_working(cognitive_memory_client, db_pool):
    test_id = get_test_identifier("api_working")
    content = f"Working memory {test_id}"

    wid = await cognitive_memory_client.hold(content, ttl_seconds=3600)
    try:
        # Use the full content as the query to avoid model-dependent synonym distance.
        rows = await cognitive_memory_client.search_working(content, limit=10)
        assert any(test_id in (r.get("content") or "") for r in rows)
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM working_memory WHERE id = $1", wid)


async def test_api_connect_memories_creates_audit_row(cognitive_memory_client, db_pool):
    from core.cognitive_memory_api import MemoryType, RelationshipType

    test_id = get_test_identifier("api_connect")
    a = await cognitive_memory_client.remember(f"Conn A {test_id}", type=MemoryType.SEMANTIC, importance=0.6)
    b = await cognitive_memory_client.remember(f"Conn B {test_id}", type=MemoryType.SEMANTIC, importance=0.6)
    ctx = f"context {test_id}"

    try:
        await cognitive_memory_client.connect_memories(a, b, RelationshipType.ASSOCIATED, confidence=0.9, context=ctx)
        async with db_pool.acquire() as conn:
            n = await conn.fetchval(
                """
                SELECT COUNT(*) FROM relationship_discoveries
                WHERE from_id = $1 AND to_id = $2 AND relationship_type = 'ASSOCIATED'
                  AND discovered_by = 'api' AND discovery_context = $3
                """,
                a,
                b,
                ctx,
            )
            assert int(n) >= 1
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM relationship_discoveries WHERE from_id = $1 AND to_id = $2", a, b)
            await conn.execute("DELETE FROM memories WHERE id = $1", a)
            await conn.execute("DELETE FROM memories WHERE id = $1", b)


async def test_api_remember_batch_raw_success_creates_graph_nodes(cognitive_memory_client, db_pool):
    from core.cognitive_memory_api import MemoryType

    test_id = get_test_identifier("api_batch_raw_ok")
    contents = [f"Batch raw A {test_id}", f"Batch raw B {test_id}"]
    emb = [[0.01] * EMBEDDING_DIMENSION, [0.02] * EMBEDDING_DIMENSION]

    ids = await cognitive_memory_client.remember_batch_raw(contents, emb, type=MemoryType.SEMANTIC, importance=0.55)
    assert len(ids) == 2

    try:
        # Verify rows exist
        async with db_pool.acquire() as conn:
            count = await conn.fetchval("SELECT COUNT(*) FROM memories WHERE id = ANY($1::uuid[])", ids)
            assert int(count) == 2

            # Verify graph nodes exist
            await conn.execute("LOAD 'age';")
            await conn.execute("SET search_path = ag_catalog, public;")
            for mid in ids:
                node_count = await conn.fetchval(
                    f"""
                    SELECT COUNT(*) FROM cypher('memory_graph', $$
                        MATCH (n:MemoryNode {{memory_id: '{mid}'}})
                        RETURN n
                    $$) as (n agtype)
                    """
                )
                assert int(node_count) >= 1
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("LOAD 'age';")
            await conn.execute("SET search_path = ag_catalog, public;")
            for mid in ids:
                await conn.execute(
                    f"""
                    SELECT * FROM cypher('memory_graph', $$
                        MATCH (n:MemoryNode {{memory_id: '{mid}'}})
                        DETACH DELETE n
                    $$) as (v agtype)
                    """
                )
            await conn.execute("DELETE FROM memories WHERE id = ANY($1::uuid[])", ids)


async def test_api_remember_batch_raw_dimension_mismatch_raises(cognitive_memory_client):
    from core.cognitive_memory_api import MemoryType

    with pytest.raises(ValueError):
        await cognitive_memory_client.remember_batch_raw(["x"], [[0.0]], type=MemoryType.SEMANTIC)


async def test_api_hydrate_batch_returns_many(cognitive_memory_client):
    test_id = get_test_identifier("api_hydrate_batch")
    res = await cognitive_memory_client.hydrate_batch([f"q1 {test_id}", f"q2 {test_id}", f"q3 {test_id}"], include_goals=False)
    assert len(res) == 3


async def test_api_context_manager_connect_works(ensure_embedding_service):
    from core.cognitive_memory_api import CognitiveMemory

    async with CognitiveMemory.connect(_db_dsn(), min_size=1, max_size=3) as mem:
        ctx = await mem.hydrate("test query", include_goals=False)
        assert isinstance(ctx.memories, list)


async def test_api_introspection_methods_return_shapes(cognitive_memory_client):
    health = await cognitive_memory_client.get_health()
    assert isinstance(health, dict)

    drives = await cognitive_memory_client.get_drives()
    assert isinstance(drives, list)

    ident = await cognitive_memory_client.get_identity()
    worldview = await cognitive_memory_client.get_worldview()
    assert isinstance(ident, list)
    assert isinstance(worldview, list)

    goals = await cognitive_memory_client.get_goals()
    assert isinstance(goals, list)


async def test_api_create_goal_sets_due_at(cognitive_memory_client, db_pool):
    from datetime import datetime, timezone
    from core.cognitive_memory_api import GoalPriority, GoalSource

    test_id = get_test_identifier("api_goal_due")
    due_at = datetime.now(timezone.utc)
    goal_id = await cognitive_memory_client.create_goal(
        f"Goal {test_id}",
        description="test due_at",
        source=GoalSource.USER_REQUEST,
        priority=GoalPriority.QUEUED,
        due_at=due_at,
    )
    assert goal_id is not None

    async with db_pool.acquire() as conn:
        stored = await conn.fetchrow("SELECT due_at FROM goals WHERE id = $1::uuid", goal_id)
        assert stored is not None
        assert stored["due_at"] is not None


async def test_api_queue_user_message_creates_outbox(cognitive_memory_client, db_pool):
    test_id = get_test_identifier("api_outbox")
    outbox_id = await cognitive_memory_client.queue_user_message(f"hi {test_id}", intent="status", context={"test_id": test_id})
    assert outbox_id is not None

    async with db_pool.acquire() as conn:
        row = await conn.fetchrow("SELECT kind, status, payload FROM outbox_messages WHERE id = $1::uuid", outbox_id)
        assert row is not None
        assert row["kind"] == "user"
        assert row["status"] == "pending"


async def test_api_ingestion_receipts_roundtrip(cognitive_memory_client):
    from core.cognitive_memory_api import MemoryType

    test_id = get_test_identifier("api_ingestion_receipt")
    mid = await cognitive_memory_client.remember(f"Receipt memory {test_id}", type=MemoryType.EPISODIC, importance=0.4)
    assert mid is not None

    src = f"/tmp/{test_id}.txt"
    content_hash = f"hash_{test_id}"
    inserted = await cognitive_memory_client.record_ingestion_receipts(
        [{"source_file": src, "chunk_index": 0, "content_hash": content_hash, "memory_id": str(mid)}]
    )
    assert inserted == 1
    inserted2 = await cognitive_memory_client.record_ingestion_receipts(
        [{"source_file": src, "chunk_index": 1, "content_hash": content_hash, "memory_id": str(mid)}]
    )
    assert inserted2 == 0

    receipts = await cognitive_memory_client.get_ingestion_receipts(src, [content_hash])
    assert content_hash in receipts


async def test_api_sync_wrapper_basic(ensure_embedding_service):
    from core.cognitive_memory_api import CognitiveMemorySync, MemoryType

    dsn = _db_dsn()

    def _run():
        mem = CognitiveMemorySync.connect(dsn, min_size=1, max_size=2)
        try:
            test_id = get_test_identifier("api_sync")
            mid = mem.remember(f"Sync memory {test_id}", type=MemoryType.SEMANTIC, importance=0.6)
            assert mid is not None
            result = mem.recall(f"Sync memory {test_id}", limit=50)
            assert any(test_id in m.content for m in result.memories)
        finally:
            mem.close()

    await asyncio.to_thread(_run)
