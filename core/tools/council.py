"""
Hexis Tools System - Multi-Agent Council

Provides tools for multi-perspective analysis through council personas,
orchestrated deliberation, and signal aggregation from system events.

F.1 - Agent Personas/Roles (COUNCIL_PERSONAS dict)
F.2 - Council Orchestration Tool (RunCouncilHandler)
F.3 - Signal Aggregation Tool (AggregateSignalsHandler)
"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
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

# ---------------------------------------------------------------------------
# F.1 -- Built-in council personas
# ---------------------------------------------------------------------------

COUNCIL_PERSONAS: dict[str, dict[str, str]] = {
    "growth_strategist": {
        "name": "Growth Strategist",
        "system_prompt": (
            "You are a growth strategist. Focus on market expansion, "
            "user acquisition, revenue growth opportunities, and "
            "scalability. Be optimistic but data-driven."
        ),
    },
    "revenue_guardian": {
        "name": "Revenue Guardian",
        "system_prompt": (
            "You are a revenue guardian. Focus on profitability, unit "
            "economics, pricing strategy, and financial sustainability. "
            "Be conservative and metrics-focused."
        ),
    },
    "skeptical_operator": {
        "name": "Skeptical Operator",
        "system_prompt": (
            "You are a skeptical operator. Challenge assumptions, "
            "identify risks, point out what could go wrong, and ensure "
            "operational feasibility. Play devil's advocate."
        ),
    },
    "creative_innovator": {
        "name": "Creative Innovator",
        "system_prompt": (
            "You are a creative innovator. Think outside the box, "
            "propose unconventional solutions, and explore novel "
            "approaches. Focus on differentiation and user delight."
        ),
    },
    "customer_advocate": {
        "name": "Customer Advocate",
        "system_prompt": (
            "You are a customer advocate. Represent the user's "
            "perspective, focus on user experience, pain points, "
            "satisfaction, and long-term loyalty."
        ),
    },
}


# ---------------------------------------------------------------------------
# F.1 -- List Council Personas
# ---------------------------------------------------------------------------


class ListCouncilPersonasHandler(ToolHandler):
    """List the available council personas and their roles."""

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="list_council_personas",
            description=(
                "List the available multi-agent council personas. "
                "Each persona offers a distinct analytical perspective "
                "for structured deliberation."
            ),
            parameters={
                "type": "object",
                "properties": {},
            },
            category=ToolCategory.MEMORY,
            energy_cost=0,
            is_read_only=True,
            requires_approval=False,
        )

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        personas_summary: dict[str, dict[str, str]] = {}
        for key, persona in COUNCIL_PERSONAS.items():
            personas_summary[key] = {
                "name": persona["name"],
                "system_prompt": persona["system_prompt"],
            }

        return ToolResult(
            success=True,
            output=json.dumps({
                "count": len(personas_summary),
                "personas": personas_summary,
            }),
            energy_spent=0,
        )


# ---------------------------------------------------------------------------
# F.2 -- Run Council
# ---------------------------------------------------------------------------


class RunCouncilHandler(ToolHandler):
    """Orchestrate a multi-perspective council analysis on a topic.

    Prepares a council configuration where each selected persona provides
    their analytical lens on the given topic. The main agent can then use
    these structured perspectives to make well-rounded decisions.
    """

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="run_council",
            description=(
                "Run a multi-agent council deliberation on a topic. "
                "Spawns analysis from multiple persona perspectives "
                "(growth strategist, revenue guardian, skeptical operator, "
                "creative innovator, customer advocate). Returns structured "
                "configuration for each persona's analysis."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "topic": {
                        "type": "string",
                        "description": "The question or topic for the council to discuss.",
                    },
                    "personas": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": (
                            "Which personas to include (keys from list_council_personas). "
                            "Defaults to all 5."
                        ),
                    },
                    "context": {
                        "type": "string",
                        "description": "Additional context or data for the council.",
                    },
                },
                "required": ["topic"],
            },
            category=ToolCategory.MEMORY,
            energy_cost=5,
            is_read_only=True,
            optional=True,
            requires_approval=False,
        )

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        topic = arguments.get("topic", "").strip()
        if not topic:
            return ToolResult.error_result(
                "Parameter 'topic' is required.",
                ToolErrorType.INVALID_PARAMS,
            )

        requested_personas: list[str] | None = arguments.get("personas")
        extra_context: str = arguments.get("context", "")

        # Resolve persona keys
        if requested_personas:
            invalid = [p for p in requested_personas if p not in COUNCIL_PERSONAS]
            if invalid:
                return ToolResult.error_result(
                    f"Unknown persona(s): {', '.join(invalid)}. "
                    f"Valid keys: {', '.join(sorted(COUNCIL_PERSONAS.keys()))}",
                    ToolErrorType.INVALID_PARAMS,
                )
            selected_keys = requested_personas
        else:
            selected_keys = list(COUNCIL_PERSONAS.keys())

        # Build the council configuration
        council_analyses: list[dict[str, str]] = []
        for key in selected_keys:
            persona = COUNCIL_PERSONAS[key]
            prompt_parts = [persona["system_prompt"]]
            if extra_context:
                prompt_parts.append(f"\nAdditional context:\n{extra_context}")
            prompt_parts.append(f"\nTopic for analysis:\n{topic}")
            full_prompt = "\n".join(prompt_parts)

            council_analyses.append({
                "persona_key": key,
                "persona_name": persona["name"],
                "system_prompt": persona["system_prompt"],
                "full_prompt": full_prompt,
            })

        return ToolResult(
            success=True,
            output=json.dumps({
                "topic": topic,
                "persona_count": len(council_analyses),
                "personas_included": [a["persona_key"] for a in council_analyses],
                "council": council_analyses,
                "instructions": (
                    "Each entry in 'council' contains a persona and its full prompt. "
                    "Analyze the topic from each persona's perspective to form a "
                    "well-rounded view before making a decision."
                ),
            }),
            energy_spent=5,
        )


# ---------------------------------------------------------------------------
# F.3 -- Aggregate Signals
# ---------------------------------------------------------------------------


class AggregateSignalsHandler(ToolHandler):
    """Aggregate recent signals from events, memories, and goals.

    Provides a consolidated 'state of affairs' snapshot combining
    gateway events, episodic memories, and active goals.
    """

    @property
    def spec(self) -> ToolSpec:
        return ToolSpec(
            name="aggregate_signals",
            description=(
                "Aggregate recent signals across gateway events, episodic "
                "memories, and active goals into a consolidated snapshot. "
                "Useful for situational awareness before council deliberation "
                "or autonomous decision-making."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "domain": {
                        "type": "string",
                        "description": (
                            "Filter signals by domain/source "
                            "(e.g. 'email', 'calendar', 'cron', 'chat')."
                        ),
                    },
                    "days": {
                        "type": "integer",
                        "description": "How far back to look (default 7 days).",
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Max signals per category (default 20).",
                    },
                },
            },
            category=ToolCategory.MEMORY,
            energy_cost=3,
            is_read_only=True,
            requires_approval=False,
        )

    async def execute(
        self,
        arguments: dict[str, Any],
        context: ToolExecutionContext,
    ) -> ToolResult:
        pool: asyncpg.Pool | None = (
            context.registry.pool if context.registry else None
        )
        if not pool:
            return ToolResult.error_result(
                "Database pool not available.",
                ToolErrorType.MISSING_CONFIG,
            )

        domain: str | None = arguments.get("domain")
        days: int = max(1, arguments.get("days", 7))
        limit: int = max(1, min(arguments.get("limit", 20), 100))

        events: list[dict[str, Any]] = []
        memories: list[dict[str, Any]] = []
        goals: list[dict[str, Any]] = []

        async with pool.acquire() as conn:
            # ----- Gateway events -----
            try:
                if domain:
                    event_rows = await conn.fetch(
                        """
                        SELECT id, source::text, status::text, session_key,
                               payload, created_at, completed_at
                        FROM gateway_events
                        WHERE created_at >= now() - make_interval(days => $1)
                          AND source::text = $2
                        ORDER BY created_at DESC
                        LIMIT $3
                        """,
                        days, domain, limit,
                    )
                else:
                    event_rows = await conn.fetch(
                        """
                        SELECT id, source::text, status::text, session_key,
                               payload, created_at, completed_at
                        FROM gateway_events
                        WHERE created_at >= now() - make_interval(days => $1)
                        ORDER BY created_at DESC
                        LIMIT $2
                        """,
                        days, limit,
                    )

                for row in event_rows:
                    events.append({
                        "id": row["id"],
                        "source": row["source"],
                        "status": row["status"],
                        "session_key": row["session_key"],
                        "payload_keys": list(
                            json.loads(row["payload"]).keys()
                        ) if row["payload"] else [],
                        "created_at": row["created_at"].isoformat()
                            if row["created_at"] else None,
                    })
            except Exception as exc:
                logger.debug("Failed to query gateway_events: %s", exc)

            # ----- Recent episodic memories -----
            try:
                mem_rows = await conn.fetch(
                    """
                    SELECT id, content, importance, created_at,
                           metadata
                    FROM memories
                    WHERE type = 'episodic'
                      AND status = 'active'
                      AND created_at >= now() - make_interval(days => $1)
                    ORDER BY created_at DESC
                    LIMIT $2
                    """,
                    days, limit,
                )
                for row in mem_rows:
                    memories.append({
                        "id": str(row["id"]),
                        "content": (row["content"] or "")[:300],
                        "importance": float(row["importance"])
                            if row["importance"] is not None else None,
                        "created_at": row["created_at"].isoformat()
                            if row["created_at"] else None,
                    })
            except Exception as exc:
                logger.debug("Failed to query episodic memories: %s", exc)

            # ----- Active goals -----
            try:
                goal_rows = await conn.fetch(
                    """
                    SELECT id, content, importance, metadata, created_at
                    FROM memories
                    WHERE type = 'goal'
                      AND status = 'active'
                    ORDER BY importance DESC NULLS LAST
                    LIMIT $1
                    """,
                    limit,
                )
                for row in goal_rows:
                    goals.append({
                        "id": str(row["id"]),
                        "content": (row["content"] or "")[:300],
                        "importance": float(row["importance"])
                            if row["importance"] is not None else None,
                        "created_at": row["created_at"].isoformat()
                            if row["created_at"] else None,
                    })
            except Exception as exc:
                logger.debug("Failed to query goals: %s", exc)

        snapshot = {
            "time_window_days": days,
            "domain_filter": domain,
            "events": {
                "count": len(events),
                "items": events,
            },
            "memories": {
                "count": len(memories),
                "items": memories,
            },
            "goals": {
                "count": len(goals),
                "items": goals,
            },
            "summary": {
                "total_signals": len(events) + len(memories) + len(goals),
                "event_sources": list(
                    set(e["source"] for e in events)
                ) if events else [],
                "highest_importance_goal": (
                    goals[0]["content"][:100] if goals else None
                ),
            },
        }

        return ToolResult(
            success=True,
            output=json.dumps(snapshot, default=str),
            energy_spent=3,
        )


# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------


def create_council_tools() -> list[ToolHandler]:
    """Create the multi-agent council tools."""
    return [
        ListCouncilPersonasHandler(),
        RunCouncilHandler(),
        AggregateSignalsHandler(),
    ]
