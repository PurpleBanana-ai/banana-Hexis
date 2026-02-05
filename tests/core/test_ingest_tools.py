"""Tests for core.tools.ingest -- fast, slow, hybrid ingestion tools."""

import json

import pytest

from core.tools.base import ToolCategory, ToolContext


# ---------------------------------------------------------------------------
# FastIngestHandler
# ---------------------------------------------------------------------------

class TestFastIngestHandler:
    """Unit tests for FastIngestHandler."""

    def test_spec_properties(self):
        from core.tools.ingest import FastIngestHandler

        handler = FastIngestHandler()
        spec = handler.spec
        assert spec.name == "fast_ingest"
        assert spec.category == ToolCategory.INGEST
        assert spec.energy_cost == 2
        assert ToolContext.HEARTBEAT in spec.allowed_contexts
        assert ToolContext.CHAT in spec.allowed_contexts
        assert ToolContext.MCP in spec.allowed_contexts
        assert spec.is_read_only is False

    def test_validate_missing_path(self):
        from core.tools.ingest import FastIngestHandler

        handler = FastIngestHandler()
        errors = handler.validate({})
        assert any("path" in e.lower() for e in errors)

    def test_validate_empty_path(self):
        from core.tools.ingest import FastIngestHandler

        handler = FastIngestHandler()
        errors = handler.validate({"path": ""})
        assert any("path" in e.lower() for e in errors)

    def test_validate_valid_path(self):
        from core.tools.ingest import FastIngestHandler

        handler = FastIngestHandler()
        errors = handler.validate({"path": "/tmp/test.md"})
        assert errors == []


# ---------------------------------------------------------------------------
# SlowIngestHandler
# ---------------------------------------------------------------------------

class TestSlowIngestHandler:
    """Unit tests for SlowIngestHandler."""

    def test_spec_properties(self):
        from core.tools.ingest import SlowIngestHandler

        handler = SlowIngestHandler()
        spec = handler.spec
        assert spec.name == "slow_ingest"
        assert spec.category == ToolCategory.INGEST
        assert spec.energy_cost == 5
        assert ToolContext.HEARTBEAT in spec.allowed_contexts
        assert ToolContext.CHAT in spec.allowed_contexts
        assert ToolContext.MCP in spec.allowed_contexts
        assert spec.is_read_only is False

    def test_validate_missing_path(self):
        from core.tools.ingest import SlowIngestHandler

        handler = SlowIngestHandler()
        errors = handler.validate({})
        assert any("path" in e.lower() for e in errors)

    def test_validate_valid_path(self):
        from core.tools.ingest import SlowIngestHandler

        handler = SlowIngestHandler()
        errors = handler.validate({"path": "/tmp/test.md"})
        assert errors == []


# ---------------------------------------------------------------------------
# HybridIngestHandler
# ---------------------------------------------------------------------------

class TestHybridIngestHandler:
    """Unit tests for HybridIngestHandler."""

    def test_spec_properties(self):
        from core.tools.ingest import HybridIngestHandler

        handler = HybridIngestHandler()
        spec = handler.spec
        assert spec.name == "hybrid_ingest"
        assert spec.category == ToolCategory.INGEST
        assert spec.energy_cost == 3
        assert ToolContext.HEARTBEAT in spec.allowed_contexts
        assert ToolContext.CHAT in spec.allowed_contexts
        assert ToolContext.MCP in spec.allowed_contexts
        assert spec.is_read_only is False

    def test_validate_missing_path(self):
        from core.tools.ingest import HybridIngestHandler

        handler = HybridIngestHandler()
        errors = handler.validate({})
        assert any("path" in e.lower() for e in errors)


# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

class TestCreateIngestTools:
    """Test the create_ingest_tools factory."""

    def test_returns_all_handlers(self):
        from core.tools.ingest import create_ingest_tools

        tools = create_ingest_tools()
        assert len(tools) == 3
        names = {t.spec.name for t in tools}
        assert names == {"fast_ingest", "slow_ingest", "hybrid_ingest"}

    def test_all_have_ingest_category(self):
        from core.tools.ingest import create_ingest_tools

        tools = create_ingest_tools()
        for t in tools:
            assert t.spec.category == ToolCategory.INGEST


# ---------------------------------------------------------------------------
# Slow ingest assessment parsing
# ---------------------------------------------------------------------------

class TestSlowIngestAssessment:
    """Test assessment parsing and safe defaults."""

    def test_safe_assessment_valid(self):
        from services.slow_ingest_rlm import _safe_assessment

        raw = {
            "acceptance": "accept",
            "analysis": "Good content.",
            "emotional_reaction": {"valence": 0.5, "arousal": 0.3, "primary_emotion": "curious"},
            "worldview_impact": "extends",
            "importance": 0.8,
            "trust_assessment": 0.9,
            "extracted_facts": ["Fact one", "Fact two"],
            "connections": ["abc-123"],
            "rejection_reasons": [],
        }
        result = _safe_assessment(raw)
        assert result["acceptance"] == "accept"
        assert result["importance"] == 0.8
        assert result["trust_assessment"] == 0.9
        assert len(result["extracted_facts"]) == 2

    def test_safe_assessment_bad_acceptance(self):
        from services.slow_ingest_rlm import _safe_assessment

        raw = {"acceptance": "invalid_value"}
        result = _safe_assessment(raw)
        assert result["acceptance"] == "question"

    def test_safe_assessment_not_dict(self):
        from services.slow_ingest_rlm import _safe_assessment

        result = _safe_assessment("not a dict")
        assert result["acceptance"] == "question"
        assert result["importance"] == 0.5

    def test_safe_assessment_clamps_values(self):
        from services.slow_ingest_rlm import _safe_assessment

        raw = {"importance": 5.0, "trust_assessment": -1.0}
        result = _safe_assessment(raw)
        assert result["importance"] == 1.0
        assert result["trust_assessment"] == 0.0

    def test_safe_assessment_missing_keys(self):
        from services.slow_ingest_rlm import _safe_assessment

        result = _safe_assessment({})
        assert "acceptance" in result
        assert "analysis" in result
        assert "emotional_reaction" in result
        assert "extracted_facts" in result
        assert "rejection_reasons" in result

    def test_trust_multipliers(self):
        from services.slow_ingest_rlm import _TRUST_MULTIPLIERS

        assert _TRUST_MULTIPLIERS["accept"] == 1.0
        assert _TRUST_MULTIPLIERS["contest"] == 0.4
        assert _TRUST_MULTIPLIERS["question"] == 0.7


# ---------------------------------------------------------------------------
# IngestionMode enum extension
# ---------------------------------------------------------------------------

class TestIngestionModeEnum:
    """Verify new ingestion modes exist."""

    def test_fast_mode_exists(self):
        from services.ingest import IngestionMode

        assert IngestionMode.FAST.value == "fast"

    def test_slow_mode_exists(self):
        from services.ingest import IngestionMode

        assert IngestionMode.SLOW.value == "slow"

    def test_hybrid_mode_exists(self):
        from services.ingest import IngestionMode

        assert IngestionMode.HYBRID.value == "hybrid"


# ---------------------------------------------------------------------------
# ToolCategory enum extension
# ---------------------------------------------------------------------------

class TestToolCategoryEnum:
    """Verify INGEST category exists."""

    def test_ingest_category_exists(self):
        assert ToolCategory.INGEST.value == "ingest"


# ---------------------------------------------------------------------------
# DB config keys (requires running DB)
# ---------------------------------------------------------------------------

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


class TestIngestConfigKeys:
    """Verify ingest energy costs are configured in DB."""

    async def test_fast_ingest_cost(self, db_pool):
        async with db_pool.acquire() as conn:
            result = await conn.fetchval(
                "SELECT get_config_float('heartbeat.cost_fast_ingest')"
            )
            assert result == 2.0

    async def test_slow_ingest_cost(self, db_pool):
        async with db_pool.acquire() as conn:
            result = await conn.fetchval(
                "SELECT get_config_float('heartbeat.cost_slow_ingest')"
            )
            assert result == 5.0

    async def test_hybrid_ingest_cost(self, db_pool):
        async with db_pool.acquire() as conn:
            result = await conn.fetchval(
                "SELECT get_config_float('heartbeat.cost_hybrid_ingest')"
            )
            assert result == 3.0

    async def test_allowed_actions_include_ingest(self, db_pool):
        async with db_pool.acquire() as conn:
            result = await conn.fetchval(
                "SELECT get_config('heartbeat.allowed_actions')"
            )
            actions = json.loads(result) if isinstance(result, str) else result
            assert "fast_ingest" in actions
            assert "slow_ingest" in actions
            assert "hybrid_ingest" in actions


# ---------------------------------------------------------------------------
# Prompt loading
# ---------------------------------------------------------------------------

class TestSlowIngestPrompt:
    """Verify the slow ingest prompt loads correctly."""

    def test_prompt_loads(self):
        from services.prompt_resources import load_rlm_slow_ingest_prompt

        prompt = load_rlm_slow_ingest_prompt()
        assert "conscious reading" in prompt.lower() or "REPL" in prompt

    def test_personhood_ingest_kind(self):
        from services.prompt_resources import compose_personhood_prompt

        # Should not raise
        result = compose_personhood_prompt("ingest")
        assert isinstance(result, str)
