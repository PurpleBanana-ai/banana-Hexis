"""
Agentic Heartbeat Runner

Runs a heartbeat cycle using the unified AgentLoop. Replaces the legacy
JSON-decision path with direct tool_use. The LLM uses real tools (recall,
remember, reflect, manage_goals, etc.) within its energy budget.
"""

from __future__ import annotations

import json
import logging
from typing import Any, TYPE_CHECKING

from core.agent_loop import AgentEvent, AgentEventData, AgentLoop, AgentLoopConfig
from core.llm_config import load_llm_config
from core.tools.base import ToolContext
from core.tools.config import ContextOverrides
from services.heartbeat_prompt import build_heartbeat_decision_prompt
from services.prompt_resources import (
    compose_personhood_prompt,
    load_heartbeat_agentic_prompt,
    load_heartbeat_task_mode_prompt,
)

if TYPE_CHECKING:
    import asyncpg
    from core.tools.registry import ToolRegistry

logger = logging.getLogger(__name__)


def _detect_task_mode(context: dict[str, Any]) -> bool:
    """Check if backlog has actionable items, triggering task mode."""
    backlog = context.get("backlog", {})
    if not isinstance(backlog, dict):
        return False
    actionable = backlog.get("actionable", [])
    if isinstance(actionable, list) and len(actionable) > 0:
        return True
    counts = backlog.get("counts", {})
    if isinstance(counts, dict):
        todo = counts.get("todo", 0) or 0
        in_progress = counts.get("in_progress", 0) or 0
        if todo + in_progress > 0:
            return True
    return False


def _get_checkpoint_context(context: dict[str, Any]) -> str:
    """Extract checkpoint info from in-progress backlog items for prompt inclusion."""
    backlog = context.get("backlog", {})
    if not isinstance(backlog, dict):
        return ""
    actionable = backlog.get("actionable", [])
    if not isinstance(actionable, list):
        return ""

    checkpoint_parts: list[str] = []
    for item in actionable:
        if not isinstance(item, dict):
            continue
        if item.get("status") != "in_progress":
            continue
        checkpoint = item.get("checkpoint")
        if not isinstance(checkpoint, dict) or not checkpoint:
            continue
        title = item.get("title", "Untitled")
        step = checkpoint.get("step", "unknown")
        progress = checkpoint.get("progress", "")
        next_action = checkpoint.get("next_action", "")
        checkpoint_parts.append(
            f"### Resuming: {title}\n"
            f"- Last step: {step}\n"
            f"- Progress: {progress}\n"
            f"- Next action: {next_action}"
        )
    if not checkpoint_parts:
        return ""
    return "\n\n## Checkpoint Resume\n\n" + "\n\n".join(checkpoint_parts)


async def build_heartbeat_system_prompt(
    registry: "ToolRegistry | None" = None,
    *,
    task_mode: bool = False,
) -> str:
    """Build the system prompt for an agentic heartbeat."""
    base_prompt = load_heartbeat_agentic_prompt().strip()

    personhood = ""
    try:
        personhood = compose_personhood_prompt("heartbeat")
    except Exception:
        logger.debug("Failed to compose personhood prompt", exc_info=True)

    # Add tool descriptions from registry
    tool_section = ""
    if registry:
        try:
            specs = await registry.get_specs(ToolContext.HEARTBEAT)
            tool_names = sorted(s["function"]["name"] for s in specs)
            tool_section = (
                "\n\n## Available Tools\n"
                + ", ".join(tool_names)
                + "\n\nUse these tools via tool_use to take actions. "
                "Each tool has its own parameters — the LLM API will show you the schemas."
            )
        except Exception:
            logger.debug("Failed to get tool specs for heartbeat prompt", exc_info=True)

    parts = [base_prompt]
    if tool_section:
        parts.append(tool_section)

    # Append task mode addendum when backlog has work
    if task_mode:
        task_mode_prompt = load_heartbeat_task_mode_prompt().strip()
        parts.append("\n\n" + task_mode_prompt)

    if personhood:
        parts.append(
            "\n\n----- PERSONHOOD MODULES (for grounding) -----\n\n"
            + personhood
        )
    return "\n".join(parts)


async def run_agentic_heartbeat(
    conn: "asyncpg.Connection",
    *,
    pool: "asyncpg.Pool",
    registry: "ToolRegistry",
    heartbeat_id: str,
    context: dict[str, Any],
) -> dict[str, Any]:
    """
    Run a single heartbeat cycle using the AgentLoop.

    Returns a dict with:
    - completed: bool
    - text: str (final agent text)
    - tool_calls_made: list
    - energy_spent: int
    - stopped_reason: str
    - task_mode: bool
    """
    # Detect task mode from backlog
    task_mode = _detect_task_mode(context)
    if task_mode:
        logger.info("Task mode activated — backlog has actionable items")

    # Build system prompt (with task mode addendum if active)
    system_prompt = await build_heartbeat_system_prompt(registry, task_mode=task_mode)

    # Build the user message (heartbeat context snapshot)
    user_message = build_heartbeat_decision_prompt(context)

    # Append checkpoint resume context if there are in-progress items with checkpoints
    if task_mode:
        checkpoint_ctx = _get_checkpoint_context(context)
        if checkpoint_ctx:
            user_message += "\n" + checkpoint_ctx

    # Load LLM config
    llm_config = await load_llm_config(conn, "llm.heartbeat")

    # Extract energy budget from context
    energy = context.get("energy", {})
    energy_budget = energy.get("current", 20)

    # Task mode: double energy budget to allow meaningful work
    if task_mode:
        energy_budget = energy_budget * 2
        logger.info("Task mode energy boost: %d → %d", energy_budget // 2, energy_budget)

    # Task mode: extend timeout to allow longer execution
    timeout = 120.0 if not task_mode else 300.0

    # Build agent loop config
    loop_config = AgentLoopConfig(
        tool_context=ToolContext.HEARTBEAT,
        system_prompt=system_prompt,
        llm_config=llm_config,
        registry=registry,
        pool=pool,
        energy_budget=energy_budget,
        max_iterations=None,  # Timeout-based
        timeout_seconds=timeout,
        temperature=0.7,
        max_tokens=4096 if task_mode else 2048,
        heartbeat_id=heartbeat_id,
        # Gap 1: Planning phases (plan → execute → verify)
        enable_planning=task_mode,
        # Gap 4: Shell + file write access for task execution
        context_overrides=ContextOverrides(
            allow_shell=True,
            allow_file_write=True,
        ) if task_mode else None,
        # Gap 5: Continuation nudge for self-correction
        continuation_prompt=(
            "You stopped without verifying your work. "
            "Check: did the task succeed? Inspect the result. "
            "If there are problems, fix them. If correct, confirm completion."
        ) if task_mode else None,
        max_continuations=2 if task_mode else 0,
    )

    agent = AgentLoop(loop_config)
    result = await agent.run(user_message)

    return {
        "completed": result.stopped_reason == "completed",
        "text": result.text,
        "tool_calls_made": result.tool_calls_made,
        "energy_spent": result.energy_spent,
        "iterations": result.iterations,
        "stopped_reason": result.stopped_reason,
        "timed_out": result.timed_out,
        "task_mode": task_mode,
    }


async def finalize_heartbeat(
    conn: "asyncpg.Connection",
    *,
    heartbeat_id: str,
    result: dict[str, Any],
) -> dict[str, Any]:
    """
    Finalize a heartbeat after the agentic loop completes.

    Records the heartbeat as an episodic memory and updates state.
    If task mode was active, updates in-progress backlog items that were
    not explicitly completed (marks them with checkpoint or blocked status).
    """
    text = result.get("text", "")
    tool_calls = result.get("tool_calls_made", [])
    energy_spent = result.get("energy_spent", 0)
    stopped_reason = result.get("stopped_reason", "completed")
    task_mode = result.get("task_mode", False)

    # Build a summary of what happened
    tool_names = [tc.get("name", "?") for tc in tool_calls]
    summary = text or f"Heartbeat completed: {len(tool_calls)} tool calls, {energy_spent} energy spent."
    if tool_names:
        summary += f" Tools used: {', '.join(tool_names)}."
    if task_mode:
        summary += " [task mode]"

    # Record heartbeat as episodic memory
    try:
        memory_id = await conn.fetchval(
            """
            SELECT create_episodic_memory(
                p_content := $1,
                p_action := 'heartbeat',
                p_context := $2::jsonb,
                p_result := $3,
                p_importance := 0.5,
                p_trust_level := 1.0
            )
            """,
            summary[:2000],
            json.dumps({
                "heartbeat_id": heartbeat_id,
                "energy_spent": energy_spent,
                "tool_calls": len(tool_calls),
                "stopped_reason": stopped_reason,
                "task_mode": task_mode,
            }),
            "completed" if stopped_reason == "completed" else stopped_reason,
        )
    except Exception:
        memory_id = None
        logger.debug("Failed to record heartbeat memory", exc_info=True)

    # Update heartbeat state (mark completion, deduct energy)
    try:
        await conn.execute(
            """
            UPDATE heartbeat_state
            SET last_heartbeat_at = CURRENT_TIMESTAMP,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = 1
            """
        )
    except Exception:
        logger.debug("Failed to update heartbeat state", exc_info=True)

    # Task mode finalization: if heartbeat timed out or ran out of energy,
    # auto-checkpoint any still-in-progress items so next heartbeat can resume
    if task_mode and stopped_reason in ("timeout", "energy_exhausted"):
        try:
            in_progress_items = await conn.fetch(
                """
                SELECT id, title, checkpoint
                FROM public.backlog
                WHERE status = 'in_progress'
                ORDER BY updated_at DESC
                LIMIT 5
                """
            )
            for item in in_progress_items:
                existing_cp = item["checkpoint"]
                if existing_cp is None:
                    # Auto-create a minimal checkpoint
                    auto_checkpoint = json.dumps({
                        "step": "interrupted",
                        "progress": f"Heartbeat ended ({stopped_reason}). {len(tool_calls)} tool calls made.",
                        "next_action": "Continue from where left off",
                    })
                    await conn.execute(
                        """
                        UPDATE public.backlog
                        SET checkpoint = $1::jsonb, updated_at = CURRENT_TIMESTAMP
                        WHERE id = $2
                        """,
                        auto_checkpoint,
                        item["id"],
                    )
                    logger.info(
                        "Auto-checkpointed in-progress item %s: %s",
                        item["id"],
                        item["title"],
                    )
        except Exception:
            logger.debug("Failed to auto-checkpoint backlog items", exc_info=True)

    return {
        "completed": True,
        "memory_id": str(memory_id) if memory_id else None,
        "energy_spent": energy_spent,
        "outbox_messages": [],
        "task_mode": task_mode,
    }
