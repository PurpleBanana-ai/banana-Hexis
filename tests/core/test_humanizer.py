"""Tests for humanizer / output quality tools (L.1-L.2)."""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from core.tools.humanizer import (
    AI_PATTERNS,
    HumanizeTextHandler,
    PostProcessOutputHandler,
    compute_ai_score,
    create_humanizer_tools,
    detect_ai_patterns,
)
from core.tools.base import ToolContext, ToolExecutionContext

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def _make_context(pool=None):
    registry = MagicMock()
    registry.pool = pool
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


# ============================================================================
# Factory
# ============================================================================


class TestHumanizerFactory:
    def test_factory_returns_all_handlers(self):
        tools = create_humanizer_tools()
        assert len(tools) == 2
        names = {t.spec.name for t in tools}
        assert names == {"humanize_text", "post_process_output"}

    def test_all_have_specs(self):
        for tool in create_humanizer_tools():
            spec = tool.spec
            assert spec.name
            assert spec.description
            assert spec.parameters


# ============================================================================
# AI Pattern Detection
# ============================================================================


class TestPatternDetection:
    def test_patterns_list_not_empty(self):
        assert len(AI_PATTERNS) == 24

    def test_all_patterns_have_required_fields(self):
        for p in AI_PATTERNS:
            assert "name" in p
            assert "pattern" in p
            assert "threshold" in p
            assert "suggestion" in p

    def test_detects_em_dashes(self):
        text = "This — is a test — with em dashes — in it — everywhere."
        detections = detect_ai_patterns(text)
        names = [d["pattern"] for d in detections]
        assert "em_dash_overuse" in names

    def test_detects_delve(self):
        text = "Let's delve into this topic and explore the nuances."
        detections = detect_ai_patterns(text)
        names = [d["pattern"] for d in detections]
        assert "delve" in names

    def test_detects_formulaic_opener(self):
        text = "In today's world, everything is connected."
        detections = detect_ai_patterns(text)
        names = [d["pattern"] for d in detections]
        assert "formulaic_opener" in names

    def test_detects_transition_crutch(self):
        text = "Moreover, this is important.\nFurthermore, we should note."
        detections = detect_ai_patterns(text)
        names = [d["pattern"] for d in detections]
        assert "transition_crutch" in names

    def test_detects_list_intro(self):
        text = "Here are 5 reasons why this matters. Let's dive in."
        detections = detect_ai_patterns(text)
        names = [d["pattern"] for d in detections]
        assert "list_intro" in names

    def test_detects_grandiose_framing(self):
        text = "This revolutionary approach is truly groundbreaking."
        detections = detect_ai_patterns(text)
        names = [d["pattern"] for d in detections]
        assert "grandiose_framing" in names

    def test_detects_empathy_opener(self):
        text = "That's a great question! I appreciate your curiosity."
        detections = detect_ai_patterns(text)
        names = [d["pattern"] for d in detections]
        assert "empathy_opener" in names

    def test_detects_filler_phrases(self):
        text = "It goes without saying that needless to say, this is important."
        detections = detect_ai_patterns(text)
        names = [d["pattern"] for d in detections]
        assert "filler_phrases" in names

    def test_detects_navigate_complexity(self):
        text = "We need to navigate the complexities of this domain."
        detections = detect_ai_patterns(text)
        names = [d["pattern"] for d in detections]
        assert "navigate_complexity" in names

    def test_detects_leverage_utilize(self):
        text = "We should leverage this opportunity and utilize our resources."
        detections = detect_ai_patterns(text)
        names = [d["pattern"] for d in detections]
        assert "leverage_utilize" in names

    def test_detects_landscape_tapestry(self):
        text = "In the landscape of modern technology, the tapestry of innovation unfolds."
        detections = detect_ai_patterns(text)
        names = [d["pattern"] for d in detections]
        assert "landscape_tapestry" in names

    def test_clean_text_no_detections(self):
        text = "The cat sat on the mat. It was warm outside."
        detections = detect_ai_patterns(text)
        assert len(detections) == 0

    def test_detection_includes_examples(self):
        text = "Let's delve into this. We should delve deeper."
        detections = detect_ai_patterns(text)
        delve = [d for d in detections if d["pattern"] == "delve"][0]
        assert len(delve["examples"]) > 0
        assert delve["count"] == 2

    def test_conclusion_signal(self):
        text = "In conclusion, this is the key takeaway from our analysis."
        detections = detect_ai_patterns(text)
        names = [d["pattern"] for d in detections]
        assert "conclusion_signal" in names


# ============================================================================
# AI Score
# ============================================================================


class TestAIScore:
    def test_clean_text_low_score(self):
        text = "The project is running on schedule. We shipped three features last week."
        detections = detect_ai_patterns(text)
        score = compute_ai_score(text, detections)
        assert score < 0.3

    def test_ai_heavy_text_high_score(self):
        text = (
            "In today's world, it's worth noting that this revolutionary, "
            "groundbreaking approach — leveraging cutting-edge technology — "
            "fundamentally transforms the landscape of innovation. "
            "Let's delve into this transformative paradigm shift. "
            "Moreover, we should navigate the complexities. Furthermore, "
            "it goes without saying that the tapestry of modern solutions "
            "is incredibly significant. In conclusion, the key takeaway is clear."
        )
        detections = detect_ai_patterns(text)
        score = compute_ai_score(text, detections)
        assert score > 0.5

    def test_empty_text_zero_score(self):
        assert compute_ai_score("", []) == 0.0

    def test_short_text_zero_score(self):
        assert compute_ai_score("Hello world", []) == 0.0

    def test_score_range(self):
        text = "Moreover, this is a test. Furthermore, we should note."
        detections = detect_ai_patterns(text)
        score = compute_ai_score(text, detections)
        assert 0.0 <= score <= 1.0


# ============================================================================
# L.2: Humanize Text Handler
# ============================================================================


class TestHumanizeTextHandler:
    def test_spec(self):
        h = HumanizeTextHandler()
        assert h.spec.name == "humanize_text"
        assert h.spec.energy_cost == 1
        assert "text" in h.spec.parameters["required"]

    async def test_empty_text(self):
        ctx = _make_context()
        result = await HumanizeTextHandler().execute({"text": ""}, ctx)
        assert not result.success
        assert "no text" in result.error.lower()

    async def test_analyzes_clean_text(self):
        ctx = _make_context()
        result = await HumanizeTextHandler().execute(
            {"text": "The weather is nice today. I went for a walk."}, ctx
        )
        assert result.success
        assert result.output["ai_score"] == 0.0
        assert result.output["pattern_count"] == 0

    async def test_analyzes_ai_text(self):
        ctx = _make_context()
        text = (
            "In today's world, let's delve into this revolutionary approach. "
            "Moreover, it's incredibly important. Furthermore, we should leverage this. "
            "Additionally, the landscape of innovation is fundamentally changing."
        )
        result = await HumanizeTextHandler().execute({"text": text}, ctx)
        assert result.success
        assert result.output["pattern_count"] > 0
        assert len(result.output["detections"]) > 0

    async def test_rewrite_without_pool(self):
        ctx = _make_context(pool=None)
        text = "Let's delve into this topic. Moreover, it's important."
        result = await HumanizeTextHandler().execute(
            {"text": text, "rewrite": True}, ctx
        )
        assert result.success
        # No rewrite since no pool, but analysis still works
        assert "rewritten" not in result.output

    @patch("core.llm.chat_completion")
    @patch("core.llm_config.load_llm_config")
    async def test_rewrite_with_llm(self, mock_config, mock_chat):
        mock_config.return_value = {"provider": "test", "model": "test"}
        mock_chat.return_value = {
            "content": "Exploring this topic reveals something important."
        }

        pool = AsyncMock()
        ctx = _make_context(pool=pool)
        text = (
            "Let's delve into this topic. Moreover, it's incredibly important. "
            "Furthermore, we should leverage this revolutionary approach."
        )
        result = await HumanizeTextHandler().execute(
            {"text": text, "rewrite": True}, ctx
        )
        assert result.success
        assert "rewritten" in result.output
        assert "rewritten_ai_score" in result.output

    async def test_no_rewrite_on_clean_text(self):
        ctx = _make_context()
        text = "The cat sat on the mat."
        result = await HumanizeTextHandler().execute(
            {"text": text, "rewrite": True}, ctx
        )
        assert result.success
        assert "rewritten" not in result.output  # No detections, no rewrite needed


# ============================================================================
# L.1: Post-Process Output Handler
# ============================================================================


class TestPostProcessOutput:
    def test_spec(self):
        h = PostProcessOutputHandler()
        assert h.spec.name == "post_process_output"
        assert h.spec.energy_cost == 2

    async def test_empty_text(self):
        ctx = _make_context()
        result = await PostProcessOutputHandler().execute({"text": ""}, ctx)
        assert not result.success
        assert "no text" in result.error.lower()

    async def test_clean_text_passes_through(self):
        ctx = _make_context()
        result = await PostProcessOutputHandler().execute(
            {"text": "Simple clean text."}, ctx
        )
        assert result.success
        assert result.output["text"] == "Simple clean text."
        assert len(result.output["processors_applied"]) > 0

    async def test_skips_low_score_text(self):
        ctx = _make_context()
        result = await PostProcessOutputHandler().execute(
            {"text": "The weather is nice today."}, ctx
        )
        assert result.success
        proc = result.output["processors_applied"][0]
        assert proc.get("skipped") is True

    @patch("core.llm.chat_completion")
    @patch("core.llm_config.load_llm_config")
    async def test_rewrites_high_score_text(self, mock_config, mock_chat):
        mock_config.return_value = {"provider": "test", "model": "test"}
        mock_chat.return_value = {
            "content": "This approach uses technology effectively."
        }

        pool = AsyncMock()
        ctx = _make_context(pool=pool)
        text = (
            "In today's world, let's delve into this revolutionary approach. "
            "Moreover, it's incredibly important. Furthermore, we should leverage "
            "this groundbreaking technology. In conclusion, the key takeaway is clear. "
            "Additionally, the landscape of innovation is fundamentally transforming."
        )
        result = await PostProcessOutputHandler().execute({"text": text}, ctx)
        assert result.success
        # Should have applied the humanizer
        applied = result.output["processors_applied"]
        assert len(applied) > 0

    async def test_custom_processors(self):
        ctx = _make_context()
        result = await PostProcessOutputHandler().execute(
            {"text": "Hello world.", "processors": ["humanizer"]}, ctx
        )
        assert result.success


# ============================================================================
# Integration-style tests
# ============================================================================


class TestHumanizerIntegration:
    def test_multiple_pattern_types_detected(self):
        """A single text triggers multiple different pattern types."""
        text = (
            "In today's world, it's worth noting that this revolutionary paradigm shift "
            "— leveraging cutting-edge technology — is fundamentally transforming "
            "the landscape of innovation. Let's delve deeper. "
            "Moreover, we must navigate the complexities ahead. "
            "In conclusion, the key takeaway is remarkably clear."
        )
        detections = detect_ai_patterns(text)
        patterns = {d["pattern"] for d in detections}
        # Should detect at least 5 different patterns
        assert len(patterns) >= 5

    def test_pattern_names_are_unique(self):
        names = [p["name"] for p in AI_PATTERNS]
        assert len(names) == len(set(names))

    def test_all_patterns_have_valid_regex(self):
        import re
        for p in AI_PATTERNS:
            # Should not raise
            re.compile(p["pattern"])
