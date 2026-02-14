from __future__ import annotations

import json
import logging
from typing import Any

logger = logging.getLogger(__name__)


def _coerce_json(raw: Any) -> dict[str, Any]:
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, dict):
                return parsed
        except Exception:
            return {}
    return {}


async def run_heartbeat(conn) -> dict[str, Any] | None:
    raw = await conn.fetchval("SELECT run_heartbeat()")
    if raw is None:
        return None
    return _coerce_json(raw)


async def apply_heartbeat_decision(
    conn,
    *,
    heartbeat_id: str,
    decision: dict[str, Any],
    start_index: int,
    pre_executed_actions: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    raw = await conn.fetchval(
        "SELECT apply_heartbeat_decision($1::uuid, $2::jsonb, $3::int, $4::jsonb)",
        heartbeat_id,
        json.dumps(decision),
        start_index,
        json.dumps(pre_executed_actions or []),
    )
    return _coerce_json(raw)


async def run_maintenance_if_due(conn, stats_hint: dict[str, Any] | None = None) -> dict[str, Any] | None:
    raw = await conn.fetchval(
        "SELECT run_maintenance_if_due($1::jsonb)",
        json.dumps(stats_hint or {}),
    )
    if raw is None:
        return None
    return _coerce_json(raw)


async def run_scheduled_tasks(conn, limit: int = 25) -> dict[str, Any] | None:
    raw = await conn.fetchval("SELECT run_scheduled_tasks($1::int)", int(limit))
    if raw is None:
        return None
    return _coerce_json(raw)


async def recompute_cron_next_runs(conn, task_ids: list[str]) -> int:
    """Recompute next_run_at for cron-type tasks using croniter (Python-side).

    Called after run_scheduled_tasks when cron tasks have been executed,
    since Postgres can't parse cron expressions natively.
    Returns number of tasks updated.
    """
    if not task_ids:
        return 0
    try:
        from croniter import croniter
    except ImportError:
        logger.warning("croniter not installed; cannot recompute cron schedules")
        return 0

    from datetime import datetime, timezone as tz

    updated = 0
    for task_id in task_ids:
        try:
            row = await conn.fetchrow(
                "SELECT schedule, timezone FROM scheduled_tasks WHERE id = $1::uuid",
                task_id,
            )
            if not row:
                continue
            schedule = _coerce_json(row["schedule"])
            cron_expr = schedule.get("cron", "")
            if not cron_expr:
                continue
            task_tz = row["timezone"] or "UTC"
            try:
                import pytz
                local_tz = pytz.timezone(task_tz)
            except Exception:
                local_tz = tz.utc
            now = datetime.now(tz.utc)
            cron = croniter(cron_expr, now.astimezone(local_tz))
            next_dt = cron.get_next(datetime)
            # Ensure timezone-aware
            if next_dt.tzinfo is None:
                next_dt = local_tz.localize(next_dt)
            next_utc = next_dt.astimezone(tz.utc)
            # Update both next_run_at and the _next_run cache in schedule JSONB
            schedule["_next_run"] = next_utc.isoformat()
            import json
            await conn.execute(
                """UPDATE scheduled_tasks
                   SET next_run_at = $2,
                       schedule = $3::jsonb,
                       updated_at = CURRENT_TIMESTAMP
                   WHERE id = $1::uuid""",
                task_id,
                next_utc,
                json.dumps(schedule),
            )
            updated += 1
        except Exception as e:
            logger.warning("Failed to recompute cron next_run for %s: %s", task_id, e)
    return updated


async def apply_external_call_result(
    conn,
    *,
    call: dict[str, Any],
    output: dict[str, Any],
) -> dict[str, Any]:
    raw = await conn.fetchval(
        "SELECT apply_external_call_result($1::jsonb, $2::jsonb)",
        json.dumps(call),
        json.dumps(output),
    )
    return _coerce_json(raw)


async def should_run_subconscious_decider(conn) -> bool:
    return bool(await conn.fetchval("SELECT should_run_subconscious_decider()"))


async def mark_subconscious_decider_run(conn) -> None:
    await conn.execute("SELECT mark_subconscious_decider_run()")


async def is_agent_terminated(conn) -> bool:
    return bool(await conn.fetchval("SELECT is_agent_terminated()"))
