"""Tests for usage query tool (H.4)."""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest

from core.tools.base import ToolCategory, ToolContext, ToolErrorType, ToolExecutionContext
from core.tools.usage_query import QueryUsageHandler, create_usage_tools


def _make_context():
    registry = MagicMock()
    registry.pool = MagicMock()
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


class TestQueryUsageSpec:
    def test_spec_name(self):
        assert QueryUsageHandler().spec.name == "query_usage"

    def test_spec_category(self):
        assert QueryUsageHandler().spec.category == ToolCategory.MEMORY

    def test_spec_read_only(self):
        assert QueryUsageHandler().spec.is_read_only is True

    def test_spec_has_period_param(self):
        props = QueryUsageHandler().spec.parameters["properties"]
        assert "period" in props
        assert set(props["period"]["enum"]) == {"day", "week", "month", "quarter", "year"}

    def test_spec_has_view_param(self):
        props = QueryUsageHandler().spec.parameters["properties"]
        assert "view" in props
        assert set(props["view"]["enum"]) == {"summary", "daily", "top_models"}

    def test_spec_has_source_param(self):
        props = QueryUsageHandler().spec.parameters["properties"]
        assert "source" in props


class TestQueryUsageSummary:
    @pytest.mark.asyncio
    async def test_summary_view(self):
        handler = QueryUsageHandler()
        ctx = _make_context()

        mock_conn = AsyncMock()
        mock_conn.fetch = AsyncMock(return_value=[
            {
                "provider": "anthropic",
                "model": "claude-opus-4-6",
                "operation": "chat",
                "call_count": 50,
                "total_input_tokens": 100000,
                "total_output_tokens": 50000,
                "total_cache_read": 0,
                "total_cache_write": 0,
                "total_tokens": 150000,
                "total_cost": 3.75,
            },
        ])
        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        result = await handler.execute({"view": "summary", "period": "week"}, ctx)

        assert result.success
        assert result.output["total_cost_usd"] == 3.75
        assert result.output["total_calls"] == 50
        assert len(result.output["by_model"]) == 1

    @pytest.mark.asyncio
    async def test_daily_view(self):
        handler = QueryUsageHandler()
        ctx = _make_context()

        mock_conn = AsyncMock()
        mock_conn.fetch = AsyncMock(return_value=[
            {
                "day": "2026-02-13",
                "provider": "anthropic",
                "model": "claude-opus-4-6",
                "call_count": 10,
                "total_tokens": 50000,
                "total_cost": 1.25,
            },
            {
                "day": "2026-02-12",
                "provider": "anthropic",
                "model": "claude-opus-4-6",
                "call_count": 8,
                "total_tokens": 40000,
                "total_cost": 1.00,
            },
        ])
        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        result = await handler.execute({"view": "daily", "period": "week"}, ctx)

        assert result.success
        assert len(result.output["daily"]) == 2

    @pytest.mark.asyncio
    async def test_top_models_view(self):
        handler = QueryUsageHandler()
        ctx = _make_context()

        mock_conn = AsyncMock()
        mock_conn.fetch = AsyncMock(return_value=[
            {
                "provider": "anthropic",
                "model": "claude-opus-4-6",
                "operation": "chat",
                "call_count": 50,
                "total_tokens": 150000,
                "total_cost": 3.75,
            },
            {
                "provider": "openai",
                "model": "gpt-4o",
                "operation": "chat",
                "call_count": 20,
                "total_tokens": 80000,
                "total_cost": 0.60,
            },
        ])
        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        result = await handler.execute({"view": "top_models"}, ctx)

        assert result.success
        assert len(result.output["top_models"]) == 2
        # Should be ranked by cost descending
        assert result.output["top_models"][0]["model"] == "anthropic/claude-opus-4-6"


class TestUsageFactory:
    def test_factory_count(self):
        tools = create_usage_tools()
        assert len(tools) == 1

    def test_factory_name(self):
        tools = create_usage_tools()
        assert tools[0].spec.name == "query_usage"
