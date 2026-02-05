"""
Tests for task mode in services/heartbeat_agentic.py.

Covers: task mode detection, checkpoint context extraction, energy boost,
system prompt augmentation, and finalization auto-checkpoint.
"""

from __future__ import annotations

import json
import uuid
from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from services.heartbeat_agentic import (
    _detect_task_mode,
    _get_checkpoint_context,
    build_heartbeat_system_prompt,
    finalize_heartbeat,
    run_agentic_heartbeat,
)

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


# ============================================================================
# Helpers
# ============================================================================


def _mock_registry(tool_names: list[str] | None = None) -> MagicMock:
    registry = MagicMock()
    registry.pool = MagicMock()
    specs = [
        {"type": "function", "function": {"name": n, "description": f"{n} tool", "parameters": {}}}
        for n in (tool_names or ["recall", "remember", "manage_goals", "manage_backlog"])
    ]
    registry.get_specs = AsyncMock(return_value=specs)
    registry.get_spec = MagicMock(return_value=None)
    registry.execute = AsyncMock()
    registry.get_config = AsyncMock(return_value=MagicMock(
        get_context_overrides=MagicMock(return_value=MagicMock(
            allow_shell=False, allow_file_write=False
        )),
        workspace_path=None,
    ))
    return registry


def _base_context(**overrides: Any) -> dict[str, Any]:
    ctx: dict[str, Any] = {
        "agent": {"objectives": ["Test"], "guardrails": [], "tools": [], "budget": {}},
        "environment": {
            "timestamp": "2025-01-15T12:00:00Z",
            "day_of_week": "Wednesday",
            "hour_of_day": 12,
            "time_since_user_hours": 1.0,
            "pending_events": 0,
        },
        "goals": {"counts": {"active": 0, "queued": 0}, "active": [], "queued": [], "issues": []},
        "recent_memories": [],
        "identity": [],
        "worldview": [],
        "self_model": [],
        "narrative": {},
        "urgent_drives": [],
        "emotional_state": {},
        "relationships": [],
        "contradictions": [],
        "emotional_patterns": [],
        "active_transformations": [],
        "transformations_ready": [],
        "energy": {"current": 15, "max": 20},
        "allowed_actions": [],
        "action_costs": {},
        "backlog": {},
        "heartbeat_number": 42,
    }
    ctx.update(overrides)
    return ctx


# ============================================================================
# Unit: _detect_task_mode
# ============================================================================


class TestDetectTaskMode:
    def test_no_backlog_returns_false(self):
        ctx = _base_context(backlog={})
        assert _detect_task_mode(ctx) is False

    def test_empty_counts_returns_false(self):
        ctx = _base_context(backlog={"counts": {"todo": 0, "in_progress": 0}, "actionable": []})
        assert _detect_task_mode(ctx) is False

    def test_actionable_items_returns_true(self):
        ctx = _base_context(backlog={
            "counts": {"todo": 1},
            "actionable": [{"title": "Deploy config", "priority": "high", "status": "todo"}],
        })
        assert _detect_task_mode(ctx) is True

    def test_in_progress_count_returns_true(self):
        ctx = _base_context(backlog={
            "counts": {"todo": 0, "in_progress": 1},
            "actionable": [],
        })
        assert _detect_task_mode(ctx) is True

    def test_non_dict_backlog_returns_false(self):
        ctx = _base_context(backlog="not a dict")
        assert _detect_task_mode(ctx) is False

    def test_missing_backlog_returns_false(self):
        ctx = _base_context()
        del ctx["backlog"]
        assert _detect_task_mode(ctx) is False

    def test_only_done_items_returns_false(self):
        ctx = _base_context(backlog={
            "counts": {"done": 5, "todo": 0, "in_progress": 0},
            "actionable": [],
        })
        assert _detect_task_mode(ctx) is False

    def test_null_counts_with_actionable_returns_true(self):
        ctx = _base_context(backlog={
            "counts": {},
            "actionable": [{"title": "Task", "status": "todo"}],
        })
        assert _detect_task_mode(ctx) is True


# ============================================================================
# Unit: _get_checkpoint_context
# ============================================================================


class TestGetCheckpointContext:
    def test_no_backlog_returns_empty(self):
        ctx = _base_context(backlog={})
        assert _get_checkpoint_context(ctx) == ""

    def test_no_in_progress_returns_empty(self):
        ctx = _base_context(backlog={
            "actionable": [{"title": "Task", "status": "todo", "checkpoint": None}],
        })
        assert _get_checkpoint_context(ctx) == ""

    def test_in_progress_without_checkpoint_returns_empty(self):
        ctx = _base_context(backlog={
            "actionable": [{"title": "Task", "status": "in_progress"}],
        })
        assert _get_checkpoint_context(ctx) == ""

    def test_in_progress_with_checkpoint_returns_context(self):
        ctx = _base_context(backlog={
            "actionable": [{
                "title": "Deploy config",
                "status": "in_progress",
                "checkpoint": {
                    "step": "step 2",
                    "progress": "Wrote config file",
                    "next_action": "Run deploy script",
                },
            }],
        })
        result = _get_checkpoint_context(ctx)
        assert "## Checkpoint Resume" in result
        assert "Deploy config" in result
        assert "step 2" in result
        assert "Run deploy script" in result

    def test_multiple_checkpoints_included(self):
        ctx = _base_context(backlog={
            "actionable": [
                {
                    "title": "Task A",
                    "status": "in_progress",
                    "checkpoint": {"step": "1", "progress": "done", "next_action": "verify"},
                },
                {
                    "title": "Task B",
                    "status": "in_progress",
                    "checkpoint": {"step": "3", "progress": "half", "next_action": "finish"},
                },
            ],
        })
        result = _get_checkpoint_context(ctx)
        assert "Task A" in result
        assert "Task B" in result

    def test_empty_checkpoint_dict_ignored(self):
        ctx = _base_context(backlog={
            "actionable": [{"title": "Task", "status": "in_progress", "checkpoint": {}}],
        })
        assert _get_checkpoint_context(ctx) == ""


# ============================================================================
# Unit: build_heartbeat_system_prompt with task_mode
# ============================================================================


class TestBuildSystemPromptTaskMode:
    async def test_task_mode_false_no_task_prompt(self):
        prompt = await build_heartbeat_system_prompt(None, task_mode=False)
        assert "Task Mode" not in prompt

    async def test_task_mode_true_includes_task_prompt(self):
        prompt = await build_heartbeat_system_prompt(None, task_mode=True)
        assert "Task Mode" in prompt
        assert "PICK" in prompt
        assert "CHECKPOINT" in prompt

    async def test_task_mode_with_registry(self):
        registry = _mock_registry()
        prompt = await build_heartbeat_system_prompt(registry, task_mode=True)
        assert "Task Mode" in prompt
        assert "manage_backlog" in prompt

    async def test_default_is_not_task_mode(self):
        prompt = await build_heartbeat_system_prompt()
        assert "Task Mode" not in prompt


# ============================================================================
# Unit: run_agentic_heartbeat task mode integration
# ============================================================================


class TestRunAgenticHeartbeatTaskMode:
    @patch("services.heartbeat_agentic.AgentLoop")
    @patch("services.heartbeat_agentic.load_llm_config")
    async def test_task_mode_doubles_energy(self, mock_load_config, mock_agent_class):
        mock_load_config.return_value = {
            "provider": "openai", "model": "gpt-4o", "endpoint": None, "api_key": "t",
        }
        mock_agent = AsyncMock()
        mock_agent.run.return_value = MagicMock(
            text="Done.", tool_calls_made=[], iterations=1,
            energy_spent=0, timed_out=False, stopped_reason="completed",
        )
        mock_agent_class.return_value = mock_agent

        ctx = _base_context(backlog={
            "counts": {"todo": 1},
            "actionable": [{"title": "Task", "status": "todo"}],
        })
        ctx["energy"]["current"] = 10

        result = await run_agentic_heartbeat(
            AsyncMock(), pool=MagicMock(), registry=_mock_registry(),
            heartbeat_id="hb-tm-001", context=ctx,
        )

        config_arg = mock_agent_class.call_args[0][0]
        assert config_arg.energy_budget == 20  # 10 * 2
        assert result["task_mode"] is True

    @patch("services.heartbeat_agentic.AgentLoop")
    @patch("services.heartbeat_agentic.load_llm_config")
    async def test_no_task_mode_normal_energy(self, mock_load_config, mock_agent_class):
        mock_load_config.return_value = {
            "provider": "openai", "model": "gpt-4o", "endpoint": None, "api_key": "t",
        }
        mock_agent = AsyncMock()
        mock_agent.run.return_value = MagicMock(
            text="Done.", tool_calls_made=[], iterations=1,
            energy_spent=0, timed_out=False, stopped_reason="completed",
        )
        mock_agent_class.return_value = mock_agent

        ctx = _base_context(backlog={"counts": {}, "actionable": []})
        ctx["energy"]["current"] = 10

        result = await run_agentic_heartbeat(
            AsyncMock(), pool=MagicMock(), registry=_mock_registry(),
            heartbeat_id="hb-tm-002", context=ctx,
        )

        config_arg = mock_agent_class.call_args[0][0]
        assert config_arg.energy_budget == 10  # unchanged
        assert result["task_mode"] is False

    @patch("services.heartbeat_agentic.AgentLoop")
    @patch("services.heartbeat_agentic.load_llm_config")
    async def test_task_mode_extends_timeout(self, mock_load_config, mock_agent_class):
        mock_load_config.return_value = {
            "provider": "openai", "model": "gpt-4o", "endpoint": None, "api_key": "t",
        }
        mock_agent = AsyncMock()
        mock_agent.run.return_value = MagicMock(
            text="Done.", tool_calls_made=[], iterations=1,
            energy_spent=0, timed_out=False, stopped_reason="completed",
        )
        mock_agent_class.return_value = mock_agent

        ctx = _base_context(backlog={
            "counts": {"todo": 1},
            "actionable": [{"title": "Task", "status": "todo"}],
        })

        await run_agentic_heartbeat(
            AsyncMock(), pool=MagicMock(), registry=_mock_registry(),
            heartbeat_id="hb-tm-003", context=ctx,
        )

        config_arg = mock_agent_class.call_args[0][0]
        assert config_arg.timeout_seconds == 300.0

    @patch("services.heartbeat_agentic.AgentLoop")
    @patch("services.heartbeat_agentic.load_llm_config")
    async def test_task_mode_increases_max_tokens(self, mock_load_config, mock_agent_class):
        mock_load_config.return_value = {
            "provider": "openai", "model": "gpt-4o", "endpoint": None, "api_key": "t",
        }
        mock_agent = AsyncMock()
        mock_agent.run.return_value = MagicMock(
            text="Done.", tool_calls_made=[], iterations=1,
            energy_spent=0, timed_out=False, stopped_reason="completed",
        )
        mock_agent_class.return_value = mock_agent

        ctx = _base_context(backlog={
            "counts": {"todo": 1},
            "actionable": [{"title": "Task", "status": "todo"}],
        })

        await run_agentic_heartbeat(
            AsyncMock(), pool=MagicMock(), registry=_mock_registry(),
            heartbeat_id="hb-tm-004", context=ctx,
        )

        config_arg = mock_agent_class.call_args[0][0]
        assert config_arg.max_tokens == 4096

    @patch("services.heartbeat_agentic.AgentLoop")
    @patch("services.heartbeat_agentic.load_llm_config")
    async def test_checkpoint_context_appended_to_user_message(self, mock_load_config, mock_agent_class):
        mock_load_config.return_value = {
            "provider": "openai", "model": "gpt-4o", "endpoint": None, "api_key": "t",
        }
        mock_agent = AsyncMock()
        mock_agent.run.return_value = MagicMock(
            text="Done.", tool_calls_made=[], iterations=1,
            energy_spent=0, timed_out=False, stopped_reason="completed",
        )
        mock_agent_class.return_value = mock_agent

        ctx = _base_context(backlog={
            "counts": {"in_progress": 1},
            "actionable": [{
                "title": "Deploy",
                "status": "in_progress",
                "checkpoint": {"step": "2", "progress": "Built", "next_action": "Push"},
            }],
        })

        await run_agentic_heartbeat(
            AsyncMock(), pool=MagicMock(), registry=_mock_registry(),
            heartbeat_id="hb-tm-005", context=ctx,
        )

        # The user_message passed to agent.run should include checkpoint context
        user_msg = mock_agent.run.call_args[0][0]
        assert "Checkpoint Resume" in user_msg
        assert "Deploy" in user_msg
        assert "Push" in user_msg


# ============================================================================
# Integration: finalize_heartbeat auto-checkpoint
# ============================================================================


class TestFinalizeAutoCheckpoint:
    async def test_auto_checkpoint_on_timeout(self, db_pool):
        """In-progress items without checkpoints get auto-checkpointed on timeout."""
        async with db_pool.acquire() as conn:
            # Create an in-progress backlog item
            item_id = await conn.fetchval(
                """
                INSERT INTO public.backlog (title, status, priority)
                VALUES ('Auto-checkpoint test', 'in_progress', 'high')
                RETURNING id
                """
            )

            try:
                result = await finalize_heartbeat(
                    conn,
                    heartbeat_id=str(uuid.uuid4()),
                    result={
                        "text": "Ran out of time.",
                        "tool_calls_made": [{"name": "shell"}],
                        "energy_spent": 20,
                        "stopped_reason": "timeout",
                        "task_mode": True,
                    },
                )

                assert result["completed"] is True
                assert result["task_mode"] is True

                # Verify checkpoint was set
                row = await conn.fetchrow(
                    "SELECT checkpoint FROM public.backlog WHERE id = $1", item_id
                )
                checkpoint = json.loads(row["checkpoint"])
                assert checkpoint["step"] == "interrupted"
                assert "timeout" in checkpoint["progress"]
            finally:
                await conn.execute("DELETE FROM public.backlog WHERE id = $1", item_id)

    async def test_no_auto_checkpoint_when_already_checkpointed(self, db_pool):
        """Items with existing checkpoints are not overwritten."""
        async with db_pool.acquire() as conn:
            original_cp = json.dumps({"step": "step 3", "progress": "good", "next_action": "verify"})
            item_id = await conn.fetchval(
                """
                INSERT INTO public.backlog (title, status, priority, checkpoint)
                VALUES ('Already checkpointed', 'in_progress', 'high', $1::jsonb)
                RETURNING id
                """,
                original_cp,
            )

            try:
                await finalize_heartbeat(
                    conn,
                    heartbeat_id=str(uuid.uuid4()),
                    result={
                        "text": "Timed out.",
                        "tool_calls_made": [],
                        "energy_spent": 10,
                        "stopped_reason": "timeout",
                        "task_mode": True,
                    },
                )

                row = await conn.fetchrow(
                    "SELECT checkpoint FROM public.backlog WHERE id = $1", item_id
                )
                checkpoint = json.loads(row["checkpoint"])
                assert checkpoint["step"] == "step 3"  # unchanged
            finally:
                await conn.execute("DELETE FROM public.backlog WHERE id = $1", item_id)

    async def test_no_auto_checkpoint_on_normal_completion(self, db_pool):
        """No auto-checkpoint when heartbeat completes normally."""
        async with db_pool.acquire() as conn:
            item_id = await conn.fetchval(
                """
                INSERT INTO public.backlog (title, status, priority)
                VALUES ('Normal completion', 'in_progress', 'normal')
                RETURNING id
                """
            )

            try:
                await finalize_heartbeat(
                    conn,
                    heartbeat_id=str(uuid.uuid4()),
                    result={
                        "text": "All done.",
                        "tool_calls_made": [],
                        "energy_spent": 5,
                        "stopped_reason": "completed",
                        "task_mode": True,
                    },
                )

                row = await conn.fetchrow(
                    "SELECT checkpoint FROM public.backlog WHERE id = $1", item_id
                )
                assert row["checkpoint"] is None  # not auto-checkpointed
            finally:
                await conn.execute("DELETE FROM public.backlog WHERE id = $1", item_id)

    async def test_no_auto_checkpoint_without_task_mode(self, db_pool):
        """No auto-checkpoint when task_mode is False."""
        async with db_pool.acquire() as conn:
            item_id = await conn.fetchval(
                """
                INSERT INTO public.backlog (title, status, priority)
                VALUES ('No task mode', 'in_progress', 'normal')
                RETURNING id
                """
            )

            try:
                await finalize_heartbeat(
                    conn,
                    heartbeat_id=str(uuid.uuid4()),
                    result={
                        "text": "Timed out.",
                        "tool_calls_made": [],
                        "energy_spent": 10,
                        "stopped_reason": "timeout",
                        "task_mode": False,
                    },
                )

                row = await conn.fetchrow(
                    "SELECT checkpoint FROM public.backlog WHERE id = $1", item_id
                )
                assert row["checkpoint"] is None
            finally:
                await conn.execute("DELETE FROM public.backlog WHERE id = $1", item_id)

    async def test_auto_checkpoint_on_energy_exhausted(self, db_pool):
        """Auto-checkpoint also triggers on energy_exhausted."""
        async with db_pool.acquire() as conn:
            item_id = await conn.fetchval(
                """
                INSERT INTO public.backlog (title, status, priority)
                VALUES ('Energy exhausted test', 'in_progress', 'urgent')
                RETURNING id
                """
            )

            try:
                await finalize_heartbeat(
                    conn,
                    heartbeat_id=str(uuid.uuid4()),
                    result={
                        "text": "Out of energy.",
                        "tool_calls_made": [{"name": "shell"}, {"name": "recall"}],
                        "energy_spent": 40,
                        "stopped_reason": "energy_exhausted",
                        "task_mode": True,
                    },
                )

                row = await conn.fetchrow(
                    "SELECT checkpoint FROM public.backlog WHERE id = $1", item_id
                )
                checkpoint = json.loads(row["checkpoint"])
                assert checkpoint["step"] == "interrupted"
                assert "energy_exhausted" in checkpoint["progress"]
            finally:
                await conn.execute("DELETE FROM public.backlog WHERE id = $1", item_id)


# ============================================================================
# Unit: prompt_resources task mode loader
# ============================================================================


class TestTaskModePromptLoader:
    def test_load_task_mode_prompt(self):
        from services.prompt_resources import load_heartbeat_task_mode_prompt
        prompt = load_heartbeat_task_mode_prompt()
        assert "Task Mode" in prompt
        assert "PICK" in prompt
        assert "EXECUTE" in prompt
        assert "VERIFY" in prompt
        assert "CHECKPOINT" in prompt


# ============================================================================
# Integration: task mode wires planning, overrides, continuation
# ============================================================================


class TestTaskModeAgentLoopWiring:
    """Verify that task mode correctly wires the three gap-closing features."""

    @patch("services.heartbeat_agentic.AgentLoop")
    @patch("services.heartbeat_agentic.load_llm_config")
    async def test_task_mode_enables_planning(self, mock_load_config, mock_agent_class):
        mock_load_config.return_value = {
            "provider": "openai", "model": "gpt-4o", "endpoint": None, "api_key": "t",
        }
        mock_agent = AsyncMock()
        mock_agent.run.return_value = MagicMock(
            text="Done.", tool_calls_made=[], iterations=1,
            energy_spent=0, timed_out=False, stopped_reason="completed",
        )
        mock_agent_class.return_value = mock_agent

        ctx = _base_context(backlog={
            "counts": {"todo": 1},
            "actionable": [{"title": "Deploy config", "status": "todo"}],
        })

        await run_agentic_heartbeat(
            AsyncMock(), pool=MagicMock(), registry=_mock_registry(),
            heartbeat_id="hb-gap1", context=ctx,
        )

        config_arg = mock_agent_class.call_args[0][0]
        assert config_arg.enable_planning is True

    @patch("services.heartbeat_agentic.AgentLoop")
    @patch("services.heartbeat_agentic.load_llm_config")
    async def test_task_mode_enables_context_overrides(self, mock_load_config, mock_agent_class):
        mock_load_config.return_value = {
            "provider": "openai", "model": "gpt-4o", "endpoint": None, "api_key": "t",
        }
        mock_agent = AsyncMock()
        mock_agent.run.return_value = MagicMock(
            text="Done.", tool_calls_made=[], iterations=1,
            energy_spent=0, timed_out=False, stopped_reason="completed",
        )
        mock_agent_class.return_value = mock_agent

        ctx = _base_context(backlog={
            "counts": {"todo": 1},
            "actionable": [{"title": "Write script", "status": "todo"}],
        })

        await run_agentic_heartbeat(
            AsyncMock(), pool=MagicMock(), registry=_mock_registry(),
            heartbeat_id="hb-gap4", context=ctx,
        )

        config_arg = mock_agent_class.call_args[0][0]
        assert config_arg.context_overrides is not None
        assert config_arg.context_overrides.allow_shell is True
        assert config_arg.context_overrides.allow_file_write is True

    @patch("services.heartbeat_agentic.AgentLoop")
    @patch("services.heartbeat_agentic.load_llm_config")
    async def test_task_mode_enables_continuation(self, mock_load_config, mock_agent_class):
        mock_load_config.return_value = {
            "provider": "openai", "model": "gpt-4o", "endpoint": None, "api_key": "t",
        }
        mock_agent = AsyncMock()
        mock_agent.run.return_value = MagicMock(
            text="Done.", tool_calls_made=[], iterations=1,
            energy_spent=0, timed_out=False, stopped_reason="completed",
        )
        mock_agent_class.return_value = mock_agent

        ctx = _base_context(backlog={
            "counts": {"todo": 1},
            "actionable": [{"title": "Run tests", "status": "todo"}],
        })

        await run_agentic_heartbeat(
            AsyncMock(), pool=MagicMock(), registry=_mock_registry(),
            heartbeat_id="hb-gap5", context=ctx,
        )

        config_arg = mock_agent_class.call_args[0][0]
        assert config_arg.continuation_prompt is not None
        assert "verify" in config_arg.continuation_prompt.lower()
        assert config_arg.max_continuations == 2

    @patch("services.heartbeat_agentic.AgentLoop")
    @patch("services.heartbeat_agentic.load_llm_config")
    async def test_non_task_mode_has_defaults(self, mock_load_config, mock_agent_class):
        mock_load_config.return_value = {
            "provider": "openai", "model": "gpt-4o", "endpoint": None, "api_key": "t",
        }
        mock_agent = AsyncMock()
        mock_agent.run.return_value = MagicMock(
            text="Done.", tool_calls_made=[], iterations=1,
            energy_spent=0, timed_out=False, stopped_reason="completed",
        )
        mock_agent_class.return_value = mock_agent

        ctx = _base_context(backlog={"counts": {}, "actionable": []})

        await run_agentic_heartbeat(
            AsyncMock(), pool=MagicMock(), registry=_mock_registry(),
            heartbeat_id="hb-defaults", context=ctx,
        )

        config_arg = mock_agent_class.call_args[0][0]
        assert config_arg.enable_planning is False
        assert config_arg.context_overrides is None
        assert config_arg.continuation_prompt is None
        assert config_arg.max_continuations == 0
