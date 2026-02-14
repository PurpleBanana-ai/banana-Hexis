"""Tests for cron tools: D.1 cron expressions, D.2 delivery routing,
D.3 reliability tracking, D.4 notification channel features."""

from __future__ import annotations

import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from core.tools.base import ToolCategory, ToolContext, ToolErrorType, ToolExecutionContext
from core.tools.cron import (
    ManageScheduleHandler,
    _is_cron_expression,
    _cron_next_run,
    _parse_shorthand_schedule,
    create_cron_tools,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_context():
    registry = MagicMock()
    registry.pool = MagicMock()
    return ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id="test-call",
        registry=registry,
    )


# ---------------------------------------------------------------------------
# D.1: Cron expression detection
# ---------------------------------------------------------------------------

class TestIsCronExpression:
    def test_standard_five_field(self):
        assert _is_cron_expression("0 9 * * *") is True

    def test_every_five_minutes(self):
        assert _is_cron_expression("*/5 * * * *") is True

    def test_complex_expression(self):
        assert _is_cron_expression("0 9 * * 1-5") is True

    def test_six_field(self):
        assert _is_cron_expression("0 0 9 * * *") is True

    def test_comma_separated(self):
        assert _is_cron_expression("0 9,12,18 * * *") is True

    def test_not_cron_shorthand(self):
        assert _is_cron_expression("daily:07:00") is False

    def test_not_cron_empty(self):
        assert _is_cron_expression("") is False

    def test_not_cron_text(self):
        assert _is_cron_expression("every day at 9am") is False

    def test_too_few_fields(self):
        assert _is_cron_expression("* * *") is False

    def test_too_many_fields(self):
        assert _is_cron_expression("* * * * * * *") is False


class TestCronNextRun:
    def test_returns_iso_string(self):
        result = _cron_next_run("0 9 * * *")
        assert result is not None
        assert "T" in result  # ISO 8601

    def test_with_timezone(self):
        result = _cron_next_run("0 9 * * *", "America/New_York")
        assert result is not None

    def test_every_minute(self):
        result = _cron_next_run("* * * * *")
        assert result is not None


# ---------------------------------------------------------------------------
# D.1: Cron expression in shorthand parser
# ---------------------------------------------------------------------------

class TestParseShorthandCron:
    def test_cron_expression_detected(self):
        result = _parse_shorthand_schedule("0 9 * * *")
        assert result is not None
        kind, schedule, _ = result
        assert kind == "cron"
        assert schedule["cron"] == "0 9 * * *"
        assert "_next_run" in schedule

    def test_every_five_minutes(self):
        result = _parse_shorthand_schedule("*/5 * * * *")
        assert result is not None
        assert result[0] == "cron"
        assert result[1]["cron"] == "*/5 * * * *"

    def test_existing_shorthands_still_work(self):
        result = _parse_shorthand_schedule("daily:07:00")
        assert result is not None
        assert result[0] == "daily"

    def test_interval_shorthand_still_works(self):
        result = _parse_shorthand_schedule("every:5m")
        assert result is not None
        assert result[0] == "interval"

    def test_once_shorthand_still_works(self):
        result = _parse_shorthand_schedule("once:+2h")
        assert result is not None
        assert result[0] == "once"


# ---------------------------------------------------------------------------
# D.1: Spec tests
# ---------------------------------------------------------------------------

class TestManageScheduleSpec:
    def test_spec_name(self):
        spec = ManageScheduleHandler().spec
        assert spec.name == "manage_schedule"

    def test_spec_category(self):
        spec = ManageScheduleHandler().spec
        assert spec.category == ToolCategory.MEMORY

    def test_spec_includes_cron(self):
        spec = ManageScheduleHandler().spec
        assert "cron" in spec.description.lower()

    def test_spec_includes_stats_action(self):
        spec = ManageScheduleHandler().spec
        assert "stats" in spec.description

    def test_spec_has_delivery_params(self):
        spec = ManageScheduleHandler().spec
        props = spec.parameters["properties"]
        assert "delivery_mode" in props
        assert "delivery_channel" in props
        assert "delivery_topic" in props
        assert "delivery_webhook_url" in props

    def test_spec_delivery_modes(self):
        spec = ManageScheduleHandler().spec
        modes = spec.parameters["properties"]["delivery_mode"]["enum"]
        assert "outbox" in modes
        assert "channel" in modes
        assert "webhook" in modes
        assert "silent" in modes


# ---------------------------------------------------------------------------
# D.2: Delivery routing
# ---------------------------------------------------------------------------

class TestBuildDelivery:
    def test_default_outbox(self):
        delivery = ManageScheduleHandler._build_delivery({})
        assert delivery == {"mode": "outbox"}

    def test_channel_delivery(self):
        delivery = ManageScheduleHandler._build_delivery({
            "delivery_mode": "channel",
            "delivery_channel": "telegram",
            "delivery_topic": "cron-updates",
        })
        assert delivery["mode"] == "channel"
        assert delivery["channel"] == "telegram"
        assert delivery["topic"] == "cron-updates"

    def test_webhook_delivery(self):
        delivery = ManageScheduleHandler._build_delivery({
            "delivery_mode": "webhook",
            "delivery_webhook_url": "https://example.com/hook",
        })
        assert delivery["mode"] == "webhook"
        assert delivery["url"] == "https://example.com/hook"

    def test_silent_delivery(self):
        delivery = ManageScheduleHandler._build_delivery({
            "delivery_mode": "silent",
        })
        assert delivery == {"mode": "silent"}


# ---------------------------------------------------------------------------
# D.1 + D.2: Create with cron + delivery (mocked)
# ---------------------------------------------------------------------------

class TestCreateWithCron:
    @pytest.mark.asyncio
    async def test_create_cron_task(self):
        handler = ManageScheduleHandler()
        ctx = _make_context()

        mock_conn = AsyncMock()
        mock_conn.fetchval = AsyncMock(return_value="00000000-0000-0000-0000-000000000001")
        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        result = await handler.execute({
            "action": "create",
            "name": "Morning standup",
            "schedule": "0 9 * * 1-5",
            "action_kind": "queue_user_message",
            "message": "Time for standup!",
            "delivery_mode": "channel",
            "delivery_channel": "telegram",
            "delivery_topic": "reminders",
        }, ctx)

        assert result.success
        assert result.output["schedule_kind"] == "cron"
        assert result.output["delivery"]["mode"] == "channel"
        assert result.output["delivery"]["channel"] == "telegram"

    @pytest.mark.asyncio
    async def test_invalid_cron_expression(self):
        handler = ManageScheduleHandler()
        ctx = _make_context()

        mock_pool = MagicMock()
        ctx.registry.pool = mock_pool

        result = await handler.execute({
            "action": "create",
            "name": "Bad cron",
            "schedule_kind": "cron",
            "schedule": '{"cron": "not a cron"}',
            "action_kind": "queue_user_message",
            "message": "test",
        }, ctx)

        assert not result.success


# ---------------------------------------------------------------------------
# D.3: Stats action
# ---------------------------------------------------------------------------

class TestStatsAction:
    @pytest.mark.asyncio
    async def test_stats_aggregate(self):
        handler = ManageScheduleHandler()
        ctx = _make_context()

        mock_conn = AsyncMock()
        mock_conn.fetchrow = AsyncMock(return_value={
            "active_count": 3,
            "paused_count": 1,
            "disabled_count": 2,
            "total_runs": 42,
            "tasks_with_errors": 0,
            "last_execution": None,
            "next_execution": None,
        })
        mock_conn.fetch = AsyncMock(return_value=[])

        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        result = await handler.execute({"action": "stats"}, ctx)

        assert result.success
        assert result.output["active_tasks"] == 3
        assert result.output["total_executions"] == 42

    @pytest.mark.asyncio
    async def test_stats_per_task(self):
        handler = ManageScheduleHandler()
        ctx = _make_context()

        mock_conn = AsyncMock()
        mock_conn.fetchrow = AsyncMock(return_value={
            "name": "Morning check",
            "schedule_kind": "daily",
            "status": "active",
            "run_count": 15,
            "max_runs": None,
            "last_run_at": None,
            "next_run_at": None,
            "last_error": None,
            "created_at": "2026-01-01",
        })

        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        result = await handler.execute({
            "action": "stats",
            "task_id": "00000000-0000-0000-0000-000000000001",
        }, ctx)

        assert result.success
        assert result.output["name"] == "Morning check"
        assert result.output["run_count"] == 15

    @pytest.mark.asyncio
    async def test_stats_task_not_found(self):
        handler = ManageScheduleHandler()
        ctx = _make_context()

        mock_conn = AsyncMock()
        mock_conn.fetchrow = AsyncMock(return_value=None)

        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        result = await handler.execute({
            "action": "stats",
            "task_id": "00000000-0000-0000-0000-000000000099",
        }, ctx)

        assert not result.success


# ---------------------------------------------------------------------------
# D.3: Recompute cron next runs
# ---------------------------------------------------------------------------

class TestRecomputeCronNextRuns:
    @pytest.mark.asyncio
    async def test_recompute_updates_schedule(self):
        from core.state import recompute_cron_next_runs

        mock_conn = AsyncMock()
        mock_conn.fetchrow = AsyncMock(return_value={
            "schedule": json.dumps({"cron": "0 9 * * *", "_next_run": ""}),
            "timezone": "UTC",
        })
        mock_conn.execute = AsyncMock()

        updated = await recompute_cron_next_runs(mock_conn, ["00000000-0000-0000-0000-000000000001"])

        assert updated == 1
        mock_conn.execute.assert_called_once()
        call_args = mock_conn.execute.call_args
        # Args: (sql, task_id, next_utc_datetime, schedule_json_str)
        schedule_json_str = call_args[0][3]
        updated_schedule = json.loads(schedule_json_str)
        assert updated_schedule["_next_run"] != ""
        assert "T" in updated_schedule["_next_run"]

    @pytest.mark.asyncio
    async def test_recompute_empty_ids(self):
        from core.state import recompute_cron_next_runs

        mock_conn = AsyncMock()
        updated = await recompute_cron_next_runs(mock_conn, [])
        assert updated == 0

    @pytest.mark.asyncio
    async def test_recompute_missing_task(self):
        from core.state import recompute_cron_next_runs

        mock_conn = AsyncMock()
        mock_conn.fetchrow = AsyncMock(return_value=None)

        updated = await recompute_cron_next_runs(mock_conn, ["nonexistent"])
        assert updated == 0


# ---------------------------------------------------------------------------
# Valid schedule kinds
# ---------------------------------------------------------------------------

class TestValidScheduleKinds:
    def test_cron_in_valid_kinds(self):
        from core.tools.cron import _VALID_SCHEDULE_KINDS
        assert "cron" in _VALID_SCHEDULE_KINDS

    def test_stats_in_valid_actions(self):
        from core.tools.cron import _VALID_ACTIONS
        assert "stats" in _VALID_ACTIONS


# ---------------------------------------------------------------------------
# D.4: Delivery mode in list output
# ---------------------------------------------------------------------------

class TestListIncludesDelivery:
    @pytest.mark.asyncio
    async def test_list_shows_delivery(self):
        handler = ManageScheduleHandler()
        ctx = _make_context()

        mock_conn = AsyncMock()
        mock_conn.fetch = AsyncMock(return_value=[
            {
                "id": "00000000-0000-0000-0000-000000000001",
                "name": "Test Task",
                "description": None,
                "schedule_kind": "daily",
                "status": "active",
                "next_run_at": "2026-02-14T09:00:00+00:00",
                "last_run_at": None,
                "run_count": 0,
                "action_kind": "queue_user_message",
                "delivery": json.dumps({"mode": "channel", "channel": "telegram", "topic": "cron"}),
                "last_error": None,
            }
        ])

        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        result = await handler.execute({"action": "list"}, ctx)

        assert result.success
        assert result.output["count"] == 1
        task = result.output["tasks"][0]
        assert task["delivery"]["mode"] == "channel"
        assert task["delivery"]["channel"] == "telegram"

    @pytest.mark.asyncio
    async def test_list_hides_default_delivery(self):
        handler = ManageScheduleHandler()
        ctx = _make_context()

        mock_conn = AsyncMock()
        mock_conn.fetch = AsyncMock(return_value=[
            {
                "id": "00000000-0000-0000-0000-000000000002",
                "name": "Default Delivery",
                "description": None,
                "schedule_kind": "interval",
                "status": "active",
                "next_run_at": None,
                "last_run_at": None,
                "run_count": 0,
                "action_kind": "queue_user_message",
                "delivery": json.dumps({"mode": "outbox"}),
                "last_error": None,
            }
        ])

        mock_pool = MagicMock()
        mock_pool.acquire.return_value.__aenter__ = AsyncMock(return_value=mock_conn)
        mock_pool.acquire.return_value.__aexit__ = AsyncMock(return_value=False)
        ctx.registry.pool = mock_pool

        result = await handler.execute({"action": "list"}, ctx)

        assert result.success
        task = result.output["tasks"][0]
        assert "delivery" not in task  # Default delivery not shown


# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

class TestFactory:
    def test_factory_returns_handler(self):
        tools = create_cron_tools()
        assert len(tools) == 1
        assert isinstance(tools[0], ManageScheduleHandler)

    def test_factory_tool_name(self):
        tools = create_cron_tools()
        assert tools[0].spec.name == "manage_schedule"
