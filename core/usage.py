"""API usage tracking.

Records every LLM and embedding API call to the ``api_usage`` table for
cost analysis and budgeting.  Modelled after OpenClaw's provider-usage
system but backed by Postgres.

Usage recording is **fire-and-forget** — errors are logged but never
propagated so that a tracking failure can't break a chat or heartbeat.
"""

from __future__ import annotations

import json
import logging
from typing import Any

import asyncpg

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Per-million-token cost table (USD).
# Updated Feb 2026.  Add new models as needed.
# ---------------------------------------------------------------------------

_MODEL_COSTS: dict[str, dict[str, float]] = {
    # Anthropic ----------------------------------------------------------
    "claude-opus-4-6":         {"input": 15.0,  "output": 75.0,  "cache_read": 1.5,   "cache_write": 18.75},
    "claude-opus-4-5":         {"input": 15.0,  "output": 75.0,  "cache_read": 1.5,   "cache_write": 18.75},
    "claude-sonnet-4-5":       {"input": 3.0,   "output": 15.0,  "cache_read": 0.3,   "cache_write": 3.75},
    "claude-sonnet-4-5-20250929": {"input": 3.0, "output": 15.0, "cache_read": 0.3,   "cache_write": 3.75},
    "claude-3-5-sonnet":       {"input": 3.0,   "output": 15.0,  "cache_read": 0.3,   "cache_write": 3.75},
    "claude-3-5-haiku":        {"input": 0.8,   "output": 4.0,   "cache_read": 0.08,  "cache_write": 1.0},
    "claude-haiku-4-5":        {"input": 0.8,   "output": 4.0,   "cache_read": 0.08,  "cache_write": 1.0},
    "claude-haiku-4-5-20251001": {"input": 0.8,  "output": 4.0,  "cache_read": 0.08,  "cache_write": 1.0},
    # OpenAI -------------------------------------------------------------
    "gpt-4o":                  {"input": 2.5,   "output": 10.0,  "cache_read": 1.25,  "cache_write": 0.0},
    "gpt-4o-mini":             {"input": 0.15,  "output": 0.6,   "cache_read": 0.075, "cache_write": 0.0},
    "gpt-4-turbo":             {"input": 10.0,  "output": 30.0,  "cache_read": 0.0,   "cache_write": 0.0},
    "o3":                      {"input": 10.0,  "output": 40.0,  "cache_read": 2.5,   "cache_write": 0.0},
    "o3-mini":                 {"input": 1.1,   "output": 4.4,   "cache_read": 0.55,  "cache_write": 0.0},
    "o4-mini":                 {"input": 1.1,   "output": 4.4,   "cache_read": 0.55,  "cache_write": 0.0},
    # Gemini -------------------------------------------------------------
    "gemini-2.5-pro":          {"input": 1.25,  "output": 10.0,  "cache_read": 0.315, "cache_write": 0.0},
    "gemini-2.5-flash":        {"input": 0.15,  "output": 0.6,   "cache_read": 0.0375,"cache_write": 0.0},
    "gemini-2.0-flash":        {"input": 0.1,   "output": 0.4,   "cache_read": 0.025, "cache_write": 0.0},
    # Grok ---------------------------------------------------------------
    "grok-3":                  {"input": 3.0,   "output": 15.0,  "cache_read": 0.0,   "cache_write": 0.0},
    "grok-3-mini":             {"input": 0.3,   "output": 0.5,   "cache_read": 0.0,   "cache_write": 0.0},
}


def estimate_cost(
    provider: str,
    model: str,
    input_tokens: int,
    output_tokens: int,
    cache_read_tokens: int = 0,
    cache_write_tokens: int = 0,
) -> float | None:
    """Estimate cost in USD from token counts.

    Returns None if the model is not in the cost table (e.g. local Ollama).
    """
    costs = _MODEL_COSTS.get(model)
    if costs is None:
        # Try partial match (model id may have a date suffix)
        for key, val in _MODEL_COSTS.items():
            if model.startswith(key) or key.startswith(model):
                costs = val
                break
    if costs is None:
        return None

    total = (
        input_tokens * costs["input"]
        + output_tokens * costs["output"]
        + cache_read_tokens * costs.get("cache_read", 0)
        + cache_write_tokens * costs.get("cache_write", 0)
    ) / 1_000_000
    return round(total, 6)


# ---------------------------------------------------------------------------
# Usage extraction from raw provider responses
# ---------------------------------------------------------------------------


def extract_usage(provider: str, raw: Any) -> dict[str, int]:
    """Extract token counts from a provider's raw response object.

    Returns a dict with keys: input_tokens, output_tokens,
    cache_read_tokens, cache_write_tokens.
    """
    result = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_read_tokens": 0,
        "cache_write_tokens": 0,
    }

    if raw is None:
        return result

    # Anthropic Messages API
    if hasattr(raw, "usage"):
        usage = raw.usage
        if hasattr(usage, "input_tokens"):
            result["input_tokens"] = getattr(usage, "input_tokens", 0) or 0
            result["output_tokens"] = getattr(usage, "output_tokens", 0) or 0
            result["cache_read_tokens"] = getattr(usage, "cache_read_input_tokens", 0) or 0
            result["cache_write_tokens"] = getattr(usage, "cache_creation_input_tokens", 0) or 0
            return result
        # OpenAI Chat Completions
        if hasattr(usage, "prompt_tokens"):
            result["input_tokens"] = getattr(usage, "prompt_tokens", 0) or 0
            result["output_tokens"] = getattr(usage, "completion_tokens", 0) or 0
            # OpenAI caching (prompt_tokens_details)
            details = getattr(usage, "prompt_tokens_details", None)
            if details:
                result["cache_read_tokens"] = getattr(details, "cached_tokens", 0) or 0
            return result

    # Gemini
    if hasattr(raw, "usage_metadata"):
        meta = raw.usage_metadata
        result["input_tokens"] = getattr(meta, "prompt_token_count", 0) or 0
        result["output_tokens"] = getattr(meta, "candidates_token_count", 0) or 0
        result["cache_read_tokens"] = getattr(meta, "cached_content_token_count", 0) or 0
        return result

    # Dict-style responses (some providers return dicts)
    if isinstance(raw, dict):
        usage = raw.get("usage", {})
        if isinstance(usage, dict):
            result["input_tokens"] = usage.get("input_tokens") or usage.get("prompt_tokens") or 0
            result["output_tokens"] = usage.get("output_tokens") or usage.get("completion_tokens") or 0
            result["cache_read_tokens"] = usage.get("cache_read_input_tokens") or usage.get("cached_tokens") or 0
            result["cache_write_tokens"] = usage.get("cache_creation_input_tokens") or 0
            return result

    return result


# ---------------------------------------------------------------------------
# Recording
# ---------------------------------------------------------------------------

# Module-level pool reference — set by the application entrypoint.
_pool: asyncpg.Pool | None = None


def set_usage_pool(pool: asyncpg.Pool) -> None:
    """Set the DB pool used for usage recording.

    Called once at startup by the API server or worker.
    """
    global _pool
    _pool = pool


async def record_usage(
    *,
    provider: str,
    model: str,
    operation: str = "chat",
    input_tokens: int = 0,
    output_tokens: int = 0,
    cache_read_tokens: int = 0,
    cache_write_tokens: int = 0,
    cost_usd: float | None = None,
    session_key: str | None = None,
    source: str = "chat",
    metadata: dict[str, Any] | None = None,
    pool: asyncpg.Pool | None = None,
) -> None:
    """Fire-and-forget usage recording.

    Errors are logged but never raised.
    """
    p = pool or _pool
    if p is None:
        logger.debug("Usage pool not set — skipping recording")
        return

    if cost_usd is None:
        cost_usd = estimate_cost(
            provider, model,
            input_tokens, output_tokens,
            cache_read_tokens, cache_write_tokens,
        )

    try:
        await p.fetchval(
            "SELECT record_api_usage($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",
            provider,
            model,
            operation,
            input_tokens,
            output_tokens,
            cache_read_tokens,
            cache_write_tokens,
            cost_usd,
            session_key,
            source,
            json.dumps(metadata or {}),
        )
    except Exception:
        logger.debug("Failed to record API usage", exc_info=True)


async def record_llm_usage(
    *,
    provider: str,
    model: str,
    raw_response: Any,
    operation: str = "chat",
    session_key: str | None = None,
    source: str = "chat",
    pool: asyncpg.Pool | None = None,
) -> None:
    """Extract usage from a raw LLM response and record it."""
    usage = extract_usage(provider, raw_response)
    await record_usage(
        provider=provider,
        model=model,
        operation=operation,
        input_tokens=usage["input_tokens"],
        output_tokens=usage["output_tokens"],
        cache_read_tokens=usage["cache_read_tokens"],
        cache_write_tokens=usage["cache_write_tokens"],
        session_key=session_key,
        source=source,
        pool=pool,
    )
