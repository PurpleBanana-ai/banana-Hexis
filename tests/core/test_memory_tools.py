"""Tests for memory tool behavior."""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest

from core.tools.base import ToolContext, ToolExecutionContext
from core.tools.memory import RecallHandler


def _make_context(mock_conn: AsyncMock) -> ToolExecutionContext:
    pool = MagicMock()
    pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
    pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)

    registry = MagicMock()
    registry.pool = pool
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


class TestRecallHandlerHybrid:
    @pytest.mark.asyncio
    async def test_query_only_uses_hybrid(self):
        handler = RecallHandler()
        mock_conn = AsyncMock()
        mock_conn.fetch = AsyncMock(return_value=[{
            "memory_id": "00000000-0000-0000-0000-000000000001",
            "content": "Hybrid memory result",
            "memory_type": "episodic",
            "score": 0.88,
            "importance": 0.7,
            "source": "hybrid",
        }])
        mock_conn.execute = AsyncMock(return_value=None)
        ctx = _make_context(mock_conn)

        result = await handler.execute({"query": "hybrid retrieval", "limit": 3}, ctx)

        assert result.success
        sql = mock_conn.fetch.await_args.args[0]
        assert "recall_hybrid" in sql
        assert result.output["count"] == 1
        assert result.output["memories"][0]["retrieval_source"] == "hybrid"
        mock_conn.execute.assert_awaited_once()

    @pytest.mark.asyncio
    async def test_structured_filters_use_structured_query(self):
        handler = RecallHandler()
        mock_conn = AsyncMock()
        mock_conn.fetch = AsyncMock(return_value=[{
            "memory_id": "00000000-0000-0000-0000-000000000002",
            "content": "Structured memory result",
            "memory_type": "semantic",
            "score": 0.75,
            "importance": 0.6,
            "source": "hybrid",
            "source_attribution": {"kind": "web", "label": "Doc"},
        }])
        mock_conn.execute = AsyncMock(return_value=None)
        ctx = _make_context(mock_conn)

        result = await handler.execute(
            {"query": "structured retrieval", "source_kind": "web"},
            ctx,
        )

        assert result.success
        sql = mock_conn.fetch.await_args.args[0]
        assert "recall_memories_structured" in sql
        memory = result.output["memories"][0]
        assert "retrieval_source" not in memory
        assert memory["source_kind"] == "web"

