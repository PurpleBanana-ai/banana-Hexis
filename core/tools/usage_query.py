"""
Hexis Tools System - Usage Query Tool (H.4)

Allows the agent to query API usage and cost data from the api_usage table.
Wraps the usage_summary() and usage_daily() SQL functions.
"""

from __future__ import annotations

import logging
from typing import Any, TYPE_CHECKING

from .base import (
    ToolCategory,
    ToolContext,
    ToolErrorType,
    ToolExecutionContext,
    ToolHandler,
    ToolResult,
    ToolSpec,
)

if TYPE_CHECKING:
    import asyncpg

logger = logging.getLogger(__name__)


class QueryUsageHandler(ToolHandler):
    """Query API usage and cost data."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="query_usage",
            description=(
                "Query API usage statistics and costs. "
                "View spend by provider/model, daily trends, or overall summary. "
                "Answers questions like 'How much did I spend this week?', "
                "'Which model costs the most?', 'Show 30-day trend'."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "period": {
                        "type": "string",
                        "enum": ["day", "week", "month", "quarter", "year"],
                        "default": "month",
                        "description": "Time period to query",
                    },
                    "view": {
                        "type": "string",
                        "enum": ["summary", "daily", "top_models"],
                        "default": "summary",
                        "description": "View type: 'summary' (grouped totals), 'daily' (day-by-day breakdown), 'top_models' (ranked by cost)",
                    },
                    "source": {
                        "type": "string",
                        "enum": ["chat", "heartbeat", "cron", "sub_agent", "maintenance"],
                        "description": "Filter by usage source",
                    },
                },
            },
            category=ToolCategory.MEMORY,
            energy_cost=1,
            is_read_only=True,
            allowed_contexts={ToolContext.HEARTBEAT, ToolContext.CHAT, ToolContext.MCP},
        )

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        pool = context.registry.pool if context.registry else None
        if not pool:
            return ToolResult.error_result(
                "Database pool not available",
                ToolErrorType.MISSING_CONFIG,
            )

        period = arguments.get("period", "month")
        view = arguments.get("view", "summary")
        source = arguments.get("source")

        interval_map = {
            "day": "1 day",
            "week": "7 days",
            "month": "30 days",
            "quarter": "90 days",
            "year": "365 days",
        }
        interval = interval_map.get(period, "30 days")

        try:
            async with pool.acquire() as conn:
                if view == "daily":
                    return await self._daily_view(conn, interval, source, period)
                elif view == "top_models":
                    return await self._top_models_view(conn, interval, source, period)
                else:
                    return await self._summary_view(conn, interval, source, period)
        except Exception as e:
            logger.error("Failed to query usage: %s", e)
            return ToolResult.error_result(f"Failed to query usage: {e}")

    async def _summary_view(
        self, conn, interval: str, source: str | None, period: str
    ) -> ToolResult:
        rows = await conn.fetch(
            "SELECT * FROM usage_summary($1::interval, $2)", interval, source
        )
        models = []
        total_cost = 0.0
        total_tokens = 0
        total_calls = 0
        for r in rows:
            cost = float(r["total_cost"]) if r["total_cost"] else 0.0
            tokens = int(r["total_tokens"]) if r["total_tokens"] else 0
            calls = int(r["call_count"])
            models.append({
                "provider": r["provider"],
                "model": r["model"],
                "operation": r["operation"],
                "calls": calls,
                "tokens": tokens,
                "cost_usd": round(cost, 4),
            })
            total_cost += cost
            total_tokens += tokens
            total_calls += calls

        return ToolResult.success_result(
            {
                "period": period,
                "total_cost_usd": round(total_cost, 4),
                "total_tokens": total_tokens,
                "total_calls": total_calls,
                "by_model": models,
            },
            display_output=(
                f"Usage ({period}): ${total_cost:.2f} total, "
                f"{total_tokens:,} tokens, {total_calls:,} calls"
            ),
        )

    async def _daily_view(
        self, conn, interval: str, source: str | None, period: str
    ) -> ToolResult:
        rows = await conn.fetch(
            "SELECT * FROM usage_daily($1::interval, $2)", interval, source
        )
        days: dict[str, dict[str, Any]] = {}
        for r in rows:
            day_str = str(r["day"])
            if day_str not in days:
                days[day_str] = {"date": day_str, "cost_usd": 0.0, "tokens": 0, "calls": 0}
            cost = float(r["total_cost"]) if r["total_cost"] else 0.0
            days[day_str]["cost_usd"] += cost
            days[day_str]["tokens"] += int(r["total_tokens"]) if r["total_tokens"] else 0
            days[day_str]["calls"] += int(r["call_count"])

        daily_list = sorted(days.values(), key=lambda d: d["date"], reverse=True)
        for d in daily_list:
            d["cost_usd"] = round(d["cost_usd"], 4)

        return ToolResult.success_result(
            {"period": period, "daily": daily_list},
            display_output=f"Daily usage for last {period}: {len(daily_list)} day(s)",
        )

    async def _top_models_view(
        self, conn, interval: str, source: str | None, period: str
    ) -> ToolResult:
        rows = await conn.fetch(
            "SELECT * FROM usage_summary($1::interval, $2)", interval, source
        )
        # Aggregate by model (across operations)
        model_totals: dict[str, dict[str, Any]] = {}
        for r in rows:
            key = f"{r['provider']}/{r['model']}"
            if key not in model_totals:
                model_totals[key] = {"model": key, "cost_usd": 0.0, "tokens": 0, "calls": 0}
            cost = float(r["total_cost"]) if r["total_cost"] else 0.0
            model_totals[key]["cost_usd"] += cost
            model_totals[key]["tokens"] += int(r["total_tokens"]) if r["total_tokens"] else 0
            model_totals[key]["calls"] += int(r["call_count"])

        ranked = sorted(model_totals.values(), key=lambda m: m["cost_usd"], reverse=True)
        for m in ranked:
            m["cost_usd"] = round(m["cost_usd"], 4)

        return ToolResult.success_result(
            {"period": period, "top_models": ranked},
            display_output=f"Top models by cost ({period}): {len(ranked)} model(s)",
        )


def create_usage_tools() -> list[ToolHandler]:
    """Create usage query tools."""
    return [QueryUsageHandler()]
