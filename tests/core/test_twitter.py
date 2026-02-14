"""Tests for Twitter/X research tools (E.6)."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from core.tools.base import ToolCategory, ToolContext, ToolErrorType, ToolExecutionContext
from core.tools.twitter import (
    SearchTwitterHandler,
    create_twitter_tools,
)


def _make_context():
    registry = MagicMock()
    registry.pool = MagicMock()
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


class TestSearchTwitterSpec:
    def test_spec_name(self):
        assert SearchTwitterHandler().spec.name == "twitter_search"

    def test_spec_category(self):
        assert SearchTwitterHandler().spec.category == ToolCategory.EXTERNAL

    def test_spec_read_only(self):
        assert SearchTwitterHandler().spec.is_read_only is True

    def test_spec_energy_cost(self):
        assert SearchTwitterHandler().spec.energy_cost == 2

    def test_spec_optional(self):
        assert SearchTwitterHandler().spec.optional is True

    def test_spec_required_params(self):
        assert "query" in SearchTwitterHandler().spec.parameters["required"]

    def test_spec_has_max_results_param(self):
        props = SearchTwitterHandler().spec.parameters["properties"]
        assert "max_results" in props
        assert props["max_results"]["type"] == "integer"


class TestTwitterNoAuthRequired:
    """Twitter uses FxTwitter which is free -- no auth failure expected."""

    @pytest.mark.asyncio
    async def test_search_no_key_still_attempts(self):
        """FxTwitter doesn't require auth, so no AUTH_FAILED on missing key."""
        handler = SearchTwitterHandler(api_key_resolver=None)
        ctx = _make_context()
        # Will fail with a network error (not AUTH_FAILED) since we can't reach FxTwitter
        result = await handler.execute({"query": "test"}, ctx)
        # Should NOT be AUTH_FAILED -- FxTwitter is free
        assert result.error_type != ToolErrorType.AUTH_FAILED


class TestTwitterFactory:
    def test_factory_count(self):
        tools = create_twitter_tools()
        assert len(tools) == 1

    def test_factory_names(self):
        names = {t.spec.name for t in create_twitter_tools()}
        assert names == {"twitter_search"}

    def test_factory_passes_resolver(self):
        resolver = lambda: "test-key"
        tools = create_twitter_tools(api_key_resolver=resolver)
        assert tools[0]._api_key_resolver is resolver
