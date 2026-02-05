"""Tests for RLM chat integration."""

import json

import pytest


class TestChatRLMFlagDefault:
    """Verify that chat.use_rlm defaults to true."""

    @pytest.mark.asyncio(loop_scope="session")
    async def test_chat_rlm_flag_defaults_true(self, db_pool):
        """chat.use_rlm defaults to true."""
        async with db_pool.acquire() as conn:
            result = await conn.fetchval("SELECT get_config_bool('chat.use_rlm')")
            assert result is True


class TestRLMChatSession:
    """Unit tests for RLM chat session management."""

    def test_session_cleanup(self):
        """Stale sessions are cleaned up."""
        import time
        from services.hexis_rlm import _chat_sessions, _session_last_used, _cleanup_stale_sessions, _SESSION_TTL
        from services.rlm_repl import HexisLocalREPL

        # Create a fake stale session
        session_id = "test_stale_session"
        repl = HexisLocalREPL()
        repl.setup(context_payload="test")
        _chat_sessions[session_id] = repl
        _session_last_used[session_id] = time.time() - _SESSION_TTL - 10

        _cleanup_stale_sessions()

        assert session_id not in _chat_sessions
        assert session_id not in _session_last_used


class TestRLMChatParsing:
    """Test that chat-oriented FINAL parsing works correctly."""

    def test_final_with_plain_text(self):
        """Chat FINAL contains plain text, not JSON."""
        from services.hexis_rlm import find_final_answer

        text = "FINAL(Hello! I remember you mentioned enjoying hiking last time.)"
        answer = find_final_answer(text)
        assert answer is not None
        assert "hiking" in answer

    def test_final_multiline(self):
        """FINAL can span multiple lines."""
        from services.hexis_rlm import find_final_answer

        text = """FINAL(Hello there!

I found some interesting memories about our previous conversations.
Let me share what I discovered.)"""
        answer = find_final_answer(text)
        assert answer is not None
        assert "interesting memories" in answer
