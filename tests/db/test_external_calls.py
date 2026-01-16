import json

import pytest

from tests.utils import get_test_identifier, _coerce_json

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


async def test_apply_external_call_result_applies_side_effects(db_pool, ensure_embedding_service):
    async with db_pool.acquire() as conn:
        await conn.execute("UPDATE heartbeat_state SET current_energy = 20, is_paused = FALSE WHERE id = 1")
        hb_id = await conn.fetchval("SELECT start_heartbeat()")
        assert hb_id is not None

        brainstorm_raw = await conn.fetchval(
            "SELECT execute_heartbeat_action($1::uuid, 'brainstorm_goals', '{}'::jsonb)",
            hb_id,
        )
        brainstorm_result = _coerce_json(brainstorm_raw)
        brainstorm_call_id = (brainstorm_result.get("result") or {}).get("external_call_id")
        assert brainstorm_call_id is not None

        test_id = get_test_identifier("apply_external_call")
        brainstorm_output = {
            "kind": "brainstorm_goals",
            "goals": [
                {"title": f"Goal A {test_id}", "description": "A", "priority": "queued", "source": "curiosity"},
                {"title": f"Goal B {test_id}", "description": "B", "priority": "queued", "source": "curiosity"},
            ],
        }

        await conn.fetchval(
            "SELECT apply_external_call_result($1::uuid, $2::jsonb)",
            brainstorm_call_id,
            json.dumps(brainstorm_output),
        )

        goal_count = await conn.fetchval(
            """
            SELECT COUNT(*)
            FROM memories
            WHERE type = 'goal'
              AND metadata->>'title' IN ($1, $2)
            """,
            f"Goal A {test_id}",
            f"Goal B {test_id}",
        )
        assert goal_count == 2

        inquire_raw = await conn.fetchval(
            "SELECT execute_heartbeat_action($1::uuid, 'inquire_shallow', $2::jsonb)",
            hb_id,
            json.dumps({"query": f"What is an embedding? {test_id}"}),
        )
        inquire_result = _coerce_json(inquire_raw)
        inquire_call_id = (inquire_result.get("result") or {}).get("external_call_id")
        assert inquire_call_id is not None

        inquiry_summary = f"Embeddings are vectors ({test_id})."
        inquire_output = {
            "kind": "inquire",
            "summary": inquiry_summary,
            "confidence": 0.8,
            "sources": [],
            "depth": "inquire_shallow",
            "query": f"What is an embedding? {test_id}",
        }

        await conn.fetchval(
            "SELECT apply_external_call_result($1::uuid, $2::jsonb)",
            inquire_call_id,
            json.dumps(inquire_output),
        )

        inquiry_count = await conn.fetchval(
            "SELECT COUNT(*) FROM memories WHERE type = 'semantic' AND content = $1",
            inquiry_summary,
        )
        assert inquiry_count == 1
