"""
Hexis Tools - Humanizer / Output Quality (L.1-L.2)

Tool handler for detecting and removing AI writing patterns from text.
Combines rule-based pattern detection with optional LLM rewriting.
"""

from __future__ import annotations

import logging
import re
from typing import Any

from .base import (
    ToolCategory,
    ToolContext,
    ToolExecutionContext,
    ToolHandler,
    ToolResult,
    ToolSpec,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# AI Writing Pattern Definitions (24 patterns)
# ---------------------------------------------------------------------------

AI_PATTERNS: list[dict[str, Any]] = [
    {
        "name": "em_dash_overuse",
        "description": "Excessive em dash usage (—) where commas or periods suffice",
        "pattern": r"—",
        "threshold": 2,  # Flag if >2 per paragraph
        "suggestion": "Replace some em dashes with commas, periods, or parentheses",
    },
    {
        "name": "formulaic_opener",
        "description": "Generic opening phrases like 'In today's world' or 'It's worth noting'",
        "pattern": r"(?i)\b(in today'?s (?:world|landscape|era)|it'?s worth noting|it'?s important to|when it comes to|at the end of the day|in the realm of|in the world of)\b",
        "threshold": 1,
        "suggestion": "Start with a specific claim or observation instead",
    },
    {
        "name": "transition_crutch",
        "description": "Overuse of transitional phrases (Moreover, Furthermore, Additionally)",
        "pattern": r"(?i)^(moreover|furthermore|additionally|consequently|nevertheless|in conclusion|to summarize|all in all|in summary)[,:]?\s",
        "threshold": 1,
        "suggestion": "Let ideas flow naturally or use simpler connectors",
    },
    {
        "name": "hedge_stacking",
        "description": "Multiple hedging phrases in one sentence",
        "pattern": r"(?i)\b(it seems|perhaps|arguably|to some extent|in many ways|in a sense|one might argue|it could be said)\b",
        "threshold": 2,
        "suggestion": "Commit to your assertion or remove unnecessary hedges",
    },
    {
        "name": "adverb_inflation",
        "description": "Overuse of intensifying adverbs (incredibly, fundamentally, significantly)",
        "pattern": r"(?i)\b(incredibly|fundamentally|significantly|remarkably|profoundly|essentially|absolutely|literally|extremely)\b",
        "threshold": 2,
        "suggestion": "Show impact through specifics rather than adverbs",
    },
    {
        "name": "passive_voice",
        "description": "Excessive passive constructions",
        "pattern": r"(?i)\b(is|are|was|were|been|being)\s+(being\s+)?\w+ed\b",
        "threshold": 3,
        "suggestion": "Use active voice where possible",
    },
    {
        "name": "list_intro",
        "description": "Formulaic list introductions (Here are X things, Let's explore, Let's dive)",
        "pattern": r"(?i)(here are \d+|let'?s (?:explore|dive|look at|examine|break down|unpack)|without further ado)",
        "threshold": 1,
        "suggestion": "Jump straight into the content",
    },
    {
        "name": "metaphor_cliche",
        "description": "Overused metaphors (tip of the iceberg, game-changer, paradigm shift)",
        "pattern": r"(?i)\b(tip of the iceberg|game[ -]?changer|paradigm shift|double[ -]?edged sword|at the forefront|pave the way|shed light on|a brave new|stand at the crossroads)\b",
        "threshold": 1,
        "suggestion": "Use fresh, specific language instead",
    },
    {
        "name": "grandiose_framing",
        "description": "Unnecessarily grand framing (revolutionary, transformative, groundbreaking)",
        "pattern": r"(?i)\b(revolutionary|transformative|groundbreaking|game[ -]?changing|cutting[ -]?edge|state[ -]?of[ -]?the[ -]?art|world[ -]?class|next[ -]?generation|bleeding[ -]?edge)\b",
        "threshold": 1,
        "suggestion": "Use precise descriptors instead of superlatives",
    },
    {
        "name": "colon_listing",
        "description": "Pattern of colon followed by enumerated list items",
        "pattern": r":\s*\n\s*\d+\.\s",
        "threshold": 2,
        "suggestion": "Vary your structure; not every point needs a numbered list",
    },
    {
        "name": "rhetorical_question",
        "description": "Rhetorical questions used as transitions",
        "pattern": r"(?i)^(but what|so what|but how|what does this|how can we|what if we|have you ever|but why)\b.*\?",
        "threshold": 1,
        "suggestion": "State your point directly instead of asking then answering",
    },
    {
        "name": "triple_structure",
        "description": "Formulaic three-part structures (X, Y, and Z patterns)",
        "pattern": r"(?i)\b\w+,\s+\w+,\s+and\s+\w+\b",
        "threshold": 3,
        "suggestion": "Vary sentence structure; not everything needs three items",
    },
    {
        "name": "conclusion_signal",
        "description": "Obvious conclusion signaling phrases",
        "pattern": r"(?i)\b(in conclusion|to wrap up|to sum up|all things considered|the bottom line|the takeaway|key takeaway|final thoughts)\b",
        "threshold": 1,
        "suggestion": "End naturally without announcing the conclusion",
    },
    {
        "name": "empathy_opener",
        "description": "Performative empathy phrases",
        "pattern": r"(?i)(i understand (?:that|your|how)|i appreciate (?:that|your)|that'?s a great (?:question|point)|great question|absolutely[!,]|of course[!,])",
        "threshold": 1,
        "suggestion": "Address the substance directly",
    },
    {
        "name": "filler_phrases",
        "description": "Padding phrases that add no meaning",
        "pattern": r"(?i)\b(it goes without saying|needless to say|as we all know|as everyone knows|the fact of the matter|at this point in time|for all intents and purposes)\b",
        "threshold": 1,
        "suggestion": "Remove — these phrases carry no information",
    },
    {
        "name": "bookend_structure",
        "description": "Mirroring intro and conclusion too closely",
        "pattern": r"(?i)(as (?:we'?ve|I'?ve) (?:seen|discussed|explored|examined))",
        "threshold": 1,
        "suggestion": "End with new insight rather than restating the introduction",
    },
    {
        "name": "exclamation_enthusiasm",
        "description": "Excessive exclamation marks suggesting forced enthusiasm",
        "pattern": r"!",
        "threshold": 3,
        "suggestion": "Let content convey enthusiasm rather than punctuation",
    },
    {
        "name": "delve",
        "description": "The word 'delve' (strongly associated with AI writing)",
        "pattern": r"(?i)\bdelve\b",
        "threshold": 1,
        "suggestion": "Use 'explore', 'examine', 'look at', or 'investigate' instead",
    },
    {
        "name": "landscape_tapestry",
        "description": "Abstract nouns used as filler (landscape, tapestry, realm, arena)",
        "pattern": r"(?i)\b(the (?:landscape|tapestry|fabric|realm|arena|ecosystem|sphere) of)\b",
        "threshold": 1,
        "suggestion": "Be specific about what you're referring to",
    },
    {
        "name": "both_and",
        "description": "Overuse of 'both X and Y' parallel construction",
        "pattern": r"(?i)\bboth\s+\w+\s+and\s+\w+\b",
        "threshold": 2,
        "suggestion": "Vary sentence structure",
    },
    {
        "name": "certainly_surely",
        "description": "Filler certainty words that weaken rather than strengthen",
        "pattern": r"(?i)\b(certainly|surely|undoubtedly|undeniably|unquestionably)\b",
        "threshold": 2,
        "suggestion": "State facts directly without asserting certainty",
    },
    {
        "name": "navigate_complexity",
        "description": "'Navigate' used metaphorically (navigate the complexities)",
        "pattern": r"(?i)\bnavigate\s+(the\s+)?(complex|intricac|challeng|landscape|world)",
        "threshold": 1,
        "suggestion": "Use 'handle', 'manage', or 'deal with' instead",
    },
    {
        "name": "leverage_utilize",
        "description": "Corporate-speak verbs (leverage, utilize, optimize, synergize)",
        "pattern": r"(?i)\b(leverage|utilize|synergize|incentivize|operationalize|actualize)\b",
        "threshold": 1,
        "suggestion": "Use 'use', 'make the most of', or a specific verb",
    },
    {
        "name": "not_just_but_also",
        "description": "The 'not just X but also Y' construction",
        "pattern": r"(?i)\bnot (?:just|only|merely)\b.*\bbut (?:also|additionally)\b",
        "threshold": 2,
        "suggestion": "Simplify: state both points without the construction",
    },
]


def detect_ai_patterns(text: str) -> list[dict[str, Any]]:
    """
    Detect AI writing patterns in text.

    Returns list of detected patterns with match counts and locations.
    """
    detections: list[dict[str, Any]] = []

    for pattern_def in AI_PATTERNS:
        regex = pattern_def["pattern"]
        threshold = pattern_def["threshold"]

        try:
            matches = list(re.finditer(regex, text, re.MULTILINE))
        except re.error:
            continue

        if len(matches) >= threshold:
            spans = []
            for m in matches[:5]:  # Limit to first 5 examples
                start = max(0, m.start() - 20)
                end = min(len(text), m.end() + 20)
                spans.append(text[start:end].strip())

            detections.append({
                "pattern": pattern_def["name"],
                "description": pattern_def["description"],
                "count": len(matches),
                "threshold": threshold,
                "suggestion": pattern_def["suggestion"],
                "examples": spans,
            })

    return detections


def compute_ai_score(text: str, detections: list[dict[str, Any]]) -> float:
    """
    Compute an AI-ness score from 0.0 (human) to 1.0 (very AI-like).

    Based on pattern density relative to text length.
    """
    if not text.strip():
        return 0.0

    word_count = len(text.split())
    if word_count < 20:
        return 0.0

    total_hits = sum(d["count"] for d in detections)
    unique_patterns = len(detections)

    # Normalize: hits per 100 words, weighted by pattern diversity
    density = (total_hits / word_count) * 100
    diversity_factor = min(unique_patterns / 10, 1.0)

    score = min((density * 0.3 + diversity_factor * 0.7), 1.0)
    return round(score, 2)


# ---------------------------------------------------------------------------
# L.1 & L.2: Humanize Text Tool
# ---------------------------------------------------------------------------


class HumanizeTextHandler(ToolHandler):
    """Detect and optionally rewrite AI writing patterns in text."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="humanize_text",
            description=(
                "Analyze text for AI writing patterns (em dashes, formulaic transitions, "
                "'delve', etc.) and optionally rewrite to sound more natural. "
                "Returns pattern detections, AI-ness score, and rewritten text if requested."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "text": {
                        "type": "string",
                        "description": "The text to analyze and optionally humanize.",
                    },
                    "rewrite": {
                        "type": "boolean",
                        "description": "If true, produce a rewritten version with AI patterns removed. Uses an LLM pass.",
                    },
                },
                "required": ["text"],
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=1,
            is_read_only=True,
            supports_parallel=True,
            optional=True,
        )

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        text = arguments.get("text", "")
        do_rewrite = arguments.get("rewrite", False)

        if not text.strip():
            return ToolResult.error_result("No text provided")

        # Detect patterns
        detections = detect_ai_patterns(text)
        score = compute_ai_score(text, detections)

        result: dict[str, Any] = {
            "ai_score": score,
            "pattern_count": len(detections),
            "total_hits": sum(d["count"] for d in detections),
            "detections": detections,
        }

        # Optional LLM rewrite
        if do_rewrite and detections:
            pool = context.registry.pool if context.registry else None
            if pool:
                try:
                    rewritten = await self._rewrite_text(text, detections, pool)
                    if rewritten:
                        result["rewritten"] = rewritten
                        # Re-score the rewritten version
                        new_detections = detect_ai_patterns(rewritten)
                        result["rewritten_ai_score"] = compute_ai_score(rewritten, new_detections)
                except Exception as e:
                    result["rewrite_error"] = str(e)

        return ToolResult.success_result(result)

    async def _rewrite_text(
        self, text: str, detections: list[dict[str, Any]], pool: Any
    ) -> str | None:
        """Use an LLM to rewrite text removing detected AI patterns."""
        from core.llm import chat_completion
        from core.llm_config import load_llm_config

        pattern_list = "\n".join(
            f"- {d['pattern']}: {d['suggestion']}" for d in detections[:10]
        )

        prompt = (
            "Rewrite the following text to sound more natural and human. "
            "Remove the detected AI writing patterns listed below. "
            "Preserve the original meaning and tone. Do NOT add new content. "
            "Return ONLY the rewritten text, nothing else.\n\n"
            f"Detected AI patterns to fix:\n{pattern_list}\n\n"
            f"Original text:\n{text}"
        )

        try:
            llm_config = await load_llm_config(pool, preference="cheap")
        except Exception:
            llm_config = await load_llm_config(pool)

        response = await chat_completion(
            messages=[{"role": "user", "content": prompt}],
            **llm_config,
        )

        if response and response.get("content"):
            content = response["content"]
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        return block["text"]
            elif isinstance(content, str):
                return content

        return None


# ---------------------------------------------------------------------------
# L.1: Output Post-Processor Hook
# ---------------------------------------------------------------------------


class PostProcessOutputHandler(ToolHandler):
    """Apply output post-processing pipeline to text before delivery."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="post_process_output",
            description=(
                "Apply configured output post-processing transformations to text. "
                "Runs the humanizer and any other configured processors. "
                "Use this before delivering important content to channels."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "text": {
                        "type": "string",
                        "description": "Text to post-process.",
                    },
                    "processors": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Processors to apply. Options: 'humanizer'. Defaults to all enabled processors.",
                    },
                },
                "required": ["text"],
            },
            category=ToolCategory.EXTERNAL,
            energy_cost=2,
            is_read_only=True,
            supports_parallel=True,
            optional=True,
        )

    async def execute(
        self, arguments: dict[str, Any], context: ToolExecutionContext
    ) -> ToolResult:
        text = arguments.get("text", "")
        processors = arguments.get("processors", ["humanizer"])

        if not text.strip():
            return ToolResult.error_result("No text provided")

        result_text = text
        applied = []

        for proc in processors:
            if proc == "humanizer":
                detections = detect_ai_patterns(result_text)
                score = compute_ai_score(result_text, detections)

                if detections and score > 0.3:
                    # Only rewrite if score is meaningfully high
                    pool = context.registry.pool if context.registry else None
                    if pool:
                        try:
                            handler = HumanizeTextHandler()
                            rewritten = await handler._rewrite_text(result_text, detections, pool)
                            if rewritten:
                                result_text = rewritten
                                applied.append({
                                    "processor": "humanizer",
                                    "original_score": score,
                                    "patterns_found": len(detections),
                                })
                        except Exception as e:
                            applied.append({
                                "processor": "humanizer",
                                "error": str(e),
                            })
                else:
                    applied.append({
                        "processor": "humanizer",
                        "skipped": True,
                        "reason": "score too low" if not detections else "no patterns found",
                        "score": score,
                    })

        return ToolResult.success_result({
            "text": result_text,
            "processors_applied": applied,
        })


# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------


def create_humanizer_tools() -> list[ToolHandler]:
    """Create humanizer and output post-processing tool handlers."""
    return [
        HumanizeTextHandler(),
        PostProcessOutputHandler(),
    ]
